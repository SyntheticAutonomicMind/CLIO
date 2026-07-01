"""
CLIO Agent for Terminal-Bench.

Runs CLIO (Command Line Intelligence Orchestrator) as an agent
in the Terminal-Bench evaluation framework.

Usage:
    # Add this directory to PYTHONPATH, then:
    tb run \
        --agent-import-path clio_tb_agent:ClioAgent \
        --model anthropic/claude-sonnet-4-20250514 \
        --dataset terminal-bench-core==head \
        --task-id hello-world

    # Or set PYTHONPATH inline:
    PYTHONPATH=terminal-bench tb run \
        --agent-import-path clio_tb_agent:ClioAgent \
        --model anthropic/claude-sonnet-4-20250514 \
        --dataset terminal-bench-core==head

    # With custom API key
    CLIO_API_KEY=sk-... tb run \
        --agent-import-path clio_tb_agent:ClioAgent \
        --model openai/gpt-4.1 \
        --dataset terminal-bench-core==head

    # With custom CLIO path
    tb run \
        --agent-import-path clio_tb_agent:ClioAgent \
        --agent-kwarg clio_path=/path/to/clio \
        --model anthropic/claude-sonnet-4-20250514 \
        --dataset terminal-bench-core==head

OSC Protocol:
    CLIO supports structured communication via OSC escape sequences
    (CLIO_HOST_PROTOCOL=1). When enabled, CLIO emits events like:
      - clio:status:{"state":"thinking"}
      - clio:tool:{"action":"start","name":"file_operations"}
      - clio:tokens:{"prompt":45000,"completion":1200,"total":46200}

    This adapter enables the protocol and parses token events from
    the asciinema cast file to populate AgentResult token counts.
    Tmux strips OSC sequences from its scrollback, so the cast file
    is the only reliable source for these events.
"""

import inspect
import os
import re
import shlex
import json
from pathlib import Path

from terminal_bench.agents.base_agent import AgentResult
from terminal_bench.agents.failure_mode import FailureMode
from terminal_bench.agents.installed_agents.abstract_installed_agent import (
    AbstractInstalledAgent,
)
from terminal_bench.terminal.models import TerminalCommand
from terminal_bench.terminal.tmux_session import TmuxSession


# OSC protocol pattern: ESC ] 0 ; clio:<type>:<json> BEL
# Matches the structured events CLIO emits when CLIO_HOST_PROTOCOL=1
# Applied against decoded terminal output (after json.loads of asciinema data)
_OSC_PATTERN = re.compile(
    r"\x1b\]0;clio:(\w+):(\{[^}]*\})\x07"
)


class ClioAgent(AbstractInstalledAgent):
    """CLIO agent for Terminal-Bench.

    Installs CLIO into the Docker task container and runs it
    with --input/--exit for non-interactive task execution.

    CLIO is a Perl-based AI coding assistant with zero external
    dependencies (pure core Perl). This adapter:

    1. Copies the CLIO source tree into the container
    2. Installs Perl and system dependencies via setup script
    3. Runs CLIO in non-interactive mode with the task instruction
    4. Parses OSC protocol events for token usage reporting
    """

    @staticmethod
    def name() -> str:
        return "clio"

    def __init__(self, model_name: str, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._model_name = model_name
        self._version = kwargs.get("version", "latest")
        self._clio_path = kwargs.get("clio_path", None)
        # Reasoning/thinking settings for models that support it
        # (NVIDIA Nemotron, DeepSeek, etc.). Defaults: on, medium.
        self._enable_reasoning = kwargs.get("enable_reasoning", True)
        self._reasoning_effort = kwargs.get("reasoning_effort", "medium")

        # Auto-detect CLIO source path
        if self._clio_path:
            self._clio_source_dir = Path(self._clio_path).resolve()
        else:
            # Look for CLIO repo relative to this adapter file
            # terminal-bench/clio_tb_agent.py -> ../ (project root)
            agent_dir = Path(inspect.getfile(self.__class__)).parent
            project_root = agent_dir.parent
            if (project_root / "clio").exists() and (project_root / "clio" / "lib").exists():
                self._clio_source_dir = project_root / "clio"
            elif (project_root / "lib" / "CLIO").exists():
                self._clio_source_dir = project_root
            else:
                self._clio_source_dir = None

        # Parse provider from model name
        if "/" in model_name:
            self._provider = model_name.split("/")[0]
        else:
            self._provider = "openai"

    @property
    def _env(self) -> dict[str, str]:
        """Environment variables for CLIO inside the container.

        CLIO uses CLIO_API_KEY as the primary env var (Priority 3 in
        APIManager._get_api_key), falling back to provider-specific keys.

        Also enables the OSC host protocol so CLIO emits structured
        events that can be parsed for token usage reporting.
        """
        env = {
            # Enable OSC protocol for structured event emission
            "CLIO_HOST_PROTOCOL": "1",
        }

        # CLIO_API_KEY is the universal key env var
        if "CLIO_API_KEY" in os.environ:
            env["CLIO_API_KEY"] = os.environ["CLIO_API_KEY"]

        # Provider-specific keys that CLIO also checks
        provider_keys = {
            "anthropic": ["ANTHROPIC_API_KEY"],
            "openai": ["OPENAI_API_KEY"],
            "google": ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
            "github-copilot": ["GITHUB_TOKEN"],
            "deepseek": ["DEEPSEEK_API_KEY"],
            "xai": ["XAI_API_KEY"],
            "minimax": ["MINIMAX_API_KEY"],
            "openrouter": ["OPENROUTER_API_KEY"],
            "nvidia": ["NVIDIA_API_KEY"],
            "zai": ["ZAI_API_KEY"],
            "groq": ["GROQ_API_KEY"],
            "cerebras": ["CEREBRAS_API_KEY"],
            "sambanova": ["SAMBANOVA_API_KEY"],
            "together": ["TOGETHER_API_KEY"],
            "fireworks": ["FIREWORKS_API_KEY"],
            "mistral": ["MISTRAL_API_KEY"],
            "perplexity": ["PERPLEXITY_API_KEY"],
            "ollama_cloud": ["OLLAMA_CLOUD_API_KEY"],
        }

        for provider, keys in provider_keys.items():
            for key in keys:
                if key in os.environ:
                    env[key] = os.environ[key]
                    # If no CLIO_API_KEY yet, use the first provider key found
                    if "CLIO_API_KEY" not in env:
                        env["CLIO_API_KEY"] = os.environ[key]

        # Also read host CLIO config for provider-specific keys
        # CLIO stores per-provider keys in ~/.clio/config.json api_keys hash
        if "CLIO_API_KEY" not in env:
            try:
                import json
                config_path = Path.home() / ".clio" / "config.json"
                if config_path.exists():
                    with open(config_path) as f:
                        config = json.load(f)
                    api_keys = config.get("api_keys", {})
                    provider_key = api_keys.get(self._provider)
                    if provider_key:
                        env["CLIO_API_KEY"] = provider_key
            except Exception:
                pass

        # Also pass any env var ending with _API_KEY
        for key, value in os.environ.items():
            if key.endswith("_API_KEY") and key not in env:
                env[key] = value

        return env

    @property
    def _install_agent_script_path(self) -> Path:
        return self._get_templated_script_path("clio-setup.sh.j2")

    def _get_template_variables(self) -> dict[str, str]:
        """Template variables for the setup script."""
        variables = {}
        if self._version and self._version != "latest":
            variables["version"] = self._version
        return variables

    def perform_task(
        self,
        instruction: str,
        session: TmuxSession,
        logging_dir: Path | None = None,
    ) -> AgentResult:
        """Override perform_task to copy CLIO source before installing.

        The default AbstractInstalledAgent.perform_task only copies the
        install script. We also copy the entire CLIO source tree so the
        install script can set it up.
        """
        # Copy CLIO source tree into the container
        if self._clio_source_dir and self._clio_source_dir.exists():
            self._copy_clio_source(session)

        # Run the standard installed agent flow
        result = super().perform_task(instruction, session, logging_dir)

        # Parse OSC events from asciinema cast for token usage
        if result.total_input_tokens == 0 and result.total_output_tokens == 0:
            result = self._extract_token_usage(result, session)

        return result

    def _copy_clio_source(self, session: TmuxSession) -> None:
        """Copy CLIO source tree into the container at /opt/clio.

        Uses docker cp to copy the source tree, which handles large
        directories better than the Docker API's put_archive method
        (which can fail with OSError(22) on some Docker runtimes
        like colima/VZ).
        """
        import subprocess

        source = self._clio_source_dir
        container_id = session.container.id

        # Create target directory
        session.container.exec_run("mkdir -p /opt/clio")

        # Use docker cp to copy the source tree
        # This is more reliable than put_archive for large directories
        result = subprocess.run(
            ["docker", "cp", str(source) + "/.", f"{container_id}:/opt/clio/"],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            # Fallback: try without trailing slash
            result2 = subprocess.run(
                ["docker", "cp", str(source), f"{container_id}:/opt/"],
                capture_output=True,
                text=True,
            )
            if result2.returncode != 0:
                raise RuntimeError(
                    f"Failed to copy CLIO source to container: "
                    f"{result.stderr} / {result2.stderr}"
                )

    def _extract_token_usage(
        self, result: AgentResult, session: TmuxSession
    ) -> AgentResult:
        """Parse OSC protocol events for token counts.

        CLIO emits clio:tokens events via OSC 0 when CLIO_HOST_PROTOCOL=1.
        These contain prompt/completion/total token counts that we can
        use to populate AgentResult.

        Tmux strips OSC sequences from its scrollback and pipe-pane output.
        The only place they survive is in the asciinema cast file.

        The asciinema v2 format stores terminal output as JSON-encoded strings.
        Each line after the header is a JSON array: [timestamp, type, data].
        The data field contains JSON-escaped terminal output, so \\u001b
        represents ESC and \\u0007 represents BEL. We parse each line with
        json.loads() to get the decoded data, then search for OSC events.
        """
        import json

        cast_content = None

        # Try reading from the container
        try:
            import time
            time.sleep(0.5)
            exit_code, output = session.container.exec_run(
                ["cat", "/logs/agent.cast"]
            )
            if exit_code == 0 and output:
                cast_content = output.decode(errors="replace")
        except Exception:
            pass

        # Fallback: try reading from the host-mounted log directory
        if not cast_content or "clio:" not in (cast_content or ""):
            try:
                import glob
                for cast_path in glob.glob(
                    "tb-results/*/hello-world/*/sessions/agent.cast"
                ):
                    with open(cast_path, "r", errors="replace") as f:
                        cast_content = f.read()
                    if "clio:" in cast_content:
                        break
                else:
                    cast_content = None
            except Exception:
                pass

        if not cast_content:
            return result

        total_input = 0
        total_output = 0

        # Parse asciinema v2 format: header line + data lines
        # Each data line is a JSON array: [timestamp, type, data]
        # The data field is JSON-decoded, turning \\u001b into actual ESC
        for line in cast_content.strip().split("\n")[1:]:  # Skip header
            try:
                entry = json.loads(line)
                if len(entry) >= 3 and entry[1] == "o":
                    data = entry[2]
                    # Search for OSC events in decoded terminal output
                    for match in _OSC_PATTERN.finditer(data):
                        event_type = match.group(1)
                        payload = match.group(2)
                        if event_type == "tokens":
                            try:
                                token_data = json.loads(payload)
                                total_input += token_data.get("prompt", 0)
                                total_output += token_data.get("completion", 0)
                            except (json.JSONDecodeError, ValueError):
                                pass
            except (json.JSONDecodeError, ValueError, IndexError):
                pass

        if total_input > 0 or total_output > 0:
            return AgentResult(
                total_input_tokens=total_input,
                total_output_tokens=total_output,
                failure_mode=result.failure_mode,
                timestamped_markers=result.timestamped_markers,
            )

        return result

    def _run_agent_commands(self, instruction: str) -> list[TerminalCommand]:
        """Run CLIO with the task instruction.

        CLIO is invoked in non-interactive mode:
            clio --new --model <model> --input <instruction> --exit

        Flags:
            --new       Start a fresh session
            --model     Use the specified model (provider/model format)
            --input     Process the given input
            --exit      Exit after processing

        Note: We do NOT use --no-color because it would strip OSC escape
        sequences that carry token usage data. The OSC events are parsed
        from the asciinema cast file, not the tmux scrollback.
        """
        # Write a CLIO config file before launching the agent so that
        # reasoning/thinking settings apply. The container has no
        # persistent ~/.clio/config.json so we seed it here.
        if self._enable_reasoning:
            config_json = json.dumps({
                "show_thinking": True,
                "thinking_effort": self._reasoning_effort,
            })
            # Build the config-write command; clio is launched after.
            config_cmd = (
                f"mkdir -p ~/.clio && "
                f"echo {shlex.quote(config_json)} > ~/.clio/config.json"
            )
        else:
            config_cmd = ":"

        escaped_instruction = shlex.quote(instruction)
        model_flag = f"--model {shlex.quote(self._model_name)}"

        return [
            TerminalCommand(
                command=(
                    f"{config_cmd} && "
                    f"clio --new {model_flag} "
                    f"--input {escaped_instruction} --exit"
                ),
                min_timeout_sec=0.0,
                max_timeout_sec=float("inf"),
                block=True,
                append_enter=True,
            ),
        ]
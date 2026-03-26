# CLIO - Command Line Intelligence Orchestrator
# Multi-architecture container image
#
# Usage:
#   docker run -it --rm \
#       -v "$(pwd)":/workspace \
#       -w /workspace \
#       ghcr.io/syntheticautonomicmind/clio:latest \
#       --new
#
# With auth persistence:
#   docker run -it --rm \
#       -v "$(pwd)":/workspace \
#       -v clio-config:/root/.clio \
#       -w /workspace \
#       ghcr.io/syntheticautonomicmind/clio:latest \
#       --new

FROM perl:5.38-slim-bookworm

# Image metadata
LABEL org.opencontainers.image.title="CLIO"
LABEL org.opencontainers.image.description="Command Line Intelligence Orchestrator - AI code assistant for the terminal"
LABEL org.opencontainers.image.source="https://github.com/SyntheticAutonomicMind/CLIO"
LABEL org.opencontainers.image.licenses="GPL-3.0-only"

# Install essential tools and development dependencies
# These are common tools CLIO agents use for development tasks
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Version control
    git \
    # Networking
    curl \
    wget \
    ca-certificates \
    # Search
    ripgrep \
    # JSON processing
    jq \
    # Text editors (minimal)
    less \
    vim-tiny \
    # Build tools (for projects that need them)
    make \
    gcc \
    libc-dev \
    # SSL support
    libssl-dev \
    zlib1g-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install Perl modules required by CLIO
# Using cpanm for cleaner installation
RUN cpanm --notest --quiet \
    # HTTPS support for HTTP::Tiny (core)
    IO::Socket::SSL \
    Net::SSLeay \
    # Terminal handling
    Term::ReadKey \
    && rm -rf ~/.cpanm

# Copy CLIO into the container
COPY . /opt/clio

# Create symlink for easy invocation
RUN chmod +x /opt/clio/clio && \
    ln -s /opt/clio/clio /usr/local/bin/clio

# Create non-root user for security
RUN groupadd -r clio && useradd -r -g clio -m -s /bin/bash clio

# Create .clio directory for config persistence (owned by clio user)
# This directory should be mounted as a volume for auth persistence
RUN mkdir -p /home/clio/.clio && chown -R clio:clio /home/clio/.clio

# Default working directory is mounted project
WORKDIR /workspace

# Run as non-root user
USER clio

# Default: run CLIO interactively
# Override with your own args: docker run ... ghcr.io/.../clio --new
ENTRYPOINT ["/opt/clio/clio"]

# Default to showing help if no args provided
CMD ["--help"]

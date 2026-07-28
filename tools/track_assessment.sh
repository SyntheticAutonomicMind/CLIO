#!/usr/bin/env bash
# track_assessment.sh - Append current assessment to history for trend tracking
#
# Usage:
#   tools/track_assessment.sh [message]
#
# Records the current assess_codebase.pl output (JSON) with timestamp to
# runs/assessment-history.jsonl. Each line is a self-contained JSON record.
#
# Invoke manually before releases or as a scheduled task. CI can use the
# exit code (non-zero on assessment failure) to fail builds when metrics
# regress.

set -euo pipefail

# Find project root (parent of tools/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

mkdir -p runs

OUTPUT="runs/assessment-history.jsonl"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
NOTE="${1:-}"

# Capture assessment (need -I lib for JSON module path)
RECORD=$(perl -I lib tools/assess_codebase.pl --json 2>/dev/null || {
    echo "ERROR: assessment failed" >&2
    exit 1
})

# Augment with timestamp + note + commit hash
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
COMMIT_MSG=$(git log -1 --pretty=%s 2>/dev/null || echo "")

python3 - <<EOF
import json, sys
record = json.loads('''$RECORD''')
record['timestamp'] = '$TIMESTAMP'
record['commit'] = '$COMMIT'
record['commit_message'] = '''$COMMIT_MSG'''
record['note'] = '''$NOTE'''
with open('$OUTPUT', 'a') as f:
    f.write(json.dumps(record) + '\n')
EOF

# Show one-line summary
python3 -c "
import json
with open('$OUTPUT') as f:
    line = f.readlines()[-1]
r = json.loads(line)
print(f\"Recorded: weighted={r['weighted_total']} hygiene={r['scores']['hygiene']} arch={r['scores']['architecture']} methods={r['scores']['methods']} testing={r['scores']['testing']} docs={r['scores']['documentation']} deps={r['scores']['dependencies']}\")
"

echo "Appended to $OUTPUT"
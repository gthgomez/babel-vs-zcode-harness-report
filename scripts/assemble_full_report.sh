#!/usr/bin/env bash
# Assemble FULL_REPORT.md from README.md + reports/01..10 in order.
set -euo pipefail
cd "$(dirname "$0")/.."

sections=(
  reports/01-completion-authority.md
  reports/02-verifier-architecture.md
  reports/03-isolation-sandbox.md
  reports/04-workspace-transactions.md
  reports/05-task-contracts-budgets.md
  reports/06-context-compaction.md
  reports/07-evidence-replay.md
  reports/08-orchestration-controllers.md
  reports/09-instruction-stacking.md
  reports/10-self-governance.md
)

{
  cat README.md
  echo
  echo "---"
  echo
  for s in "${sections[@]}"; do
    if [ ! -f "$s" ]; then echo "MISSING: $s" >&2; exit 1; fi
    cat "$s"
    echo
    echo "---"
    echo
  done
} > FULL_REPORT.md

echo "Assembled FULL_REPORT.md ($(wc -l < FULL_REPORT.md) lines, $(wc -w < FULL_REPORT.md) words)"

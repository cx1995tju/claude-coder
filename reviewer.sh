#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$SCRIPT_DIR"

REPO="$WORKSPACE/repo"
TMPDIR="${TMPDIR:-$WORKSPACE/tmp}"
LOG_DIR="${LOG_DIR:-$WORKSPACE/logs/manual}"

mkdir -p "$LOG_DIR"

cd "$REPO"

COMMIT=$(cat "$TMPDIR/last_commit.txt")
RUN_ID=$(date +%s)
LOG_FILE="$LOG_DIR/reviewer_${RUN_ID}.log"

echo "======================================================================" | tee -a "$LOG_FILE"
echo "[reviewer] $(date '+%Y-%m-%d %H:%M:%S') — reviewing $COMMIT" | tee -a "$LOG_FILE"
echo "[reviewer] log: $LOG_FILE" | tee -a "$LOG_FILE"
echo "======================================================================" | tee -a "$LOG_FILE"

git diff "$COMMIT~1..$COMMIT" > "$TMPDIR/patch.diff"

REVIEW_PROMPT="You are a stateless senior code reviewer. Review this patch only, then exit.

PATCH:
$(cat "$TMPDIR/patch.diff")

RULES:
- no repo assumptions, only review what you see in the diff
- no design/architecture suggestions unless it's a safety issue
- focus on:
  - undefined behavior
  - memory safety (leaks, double-free, use-after-free, buffer overflow)
  - concurrency bugs (data races, deadlocks)
  - API misuse (wrong args, error handling gaps)
  - logic errors visible in the diff

OUTPUT FORMAT:

# Review

## Critical (must fix — bugs, safety, crashes)

## Warning (likely wrong — edge cases, error handling)

## Minor (style, readability, non-critical)

For each issue that requires a fix, output a line like:
FIX: path/to/file: brief explanation of what to fix

At the very end, append a machine-readable block:

---RESULT---
CRITICAL_COUNT: <N>
WARNING_COUNT: <N>
FIX_COUNT: <N>
---END---"

REVIEW_PROMPT_FILE="$TMPDIR/review_prompt_${RUN_ID}.txt"
printf '%s' "$REVIEW_PROMPT" > "$REVIEW_PROMPT_FILE"

# reviewer 不需要交互：patch 内容已在 prompt 中，claude 只需要文本分析
script -q -e -c "claude -p - < $REVIEW_PROMPT_FILE" "$LOG_FILE"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG_FILE" > "$TMPDIR/review.md"

cp "$TMPDIR/review.md" "$LOG_DIR/review_${RUN_ID}.md"
cp "$TMPDIR/patch.diff" "$LOG_DIR/patch_${RUN_ID}.diff"

echo "[reviewer] done" | tee -a "$LOG_FILE"

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
DONE_FILE="$TMPDIR/reviewer_done_${RUN_ID}"

echo "======================================================================"
echo "[reviewer] $(date '+%Y-%m-%d %H:%M:%S') — reviewing $COMMIT"
echo "[reviewer] log: $LOG_FILE"
echo "======================================================================"

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

# ── start claude in a tmux split pane ─────────────────────────────────────

rm -f "$DONE_FILE"

# split-window 天然继承当前 pane 的所有环境变量
PANE_ID=$(tmux split-window -h -P -F '#{pane_id}' \
  "claude -p - < $REVIEW_PROMPT_FILE | tee $TMPDIR/review_raw_${RUN_ID}.txt; touch $DONE_FILE")
echo "[reviewer] claude running in pane: $PANE_ID"

sleep 2

# pipe-pane 保存完整日志
tmux pipe-pane -t "$PANE_ID" "cat >> $LOG_FILE"

echo "[reviewer] prompt sent, monitoring for done file..."

# ── monitor done file ─────────────────────────────────────────────────────

while [ ! -f "$DONE_FILE" ]; do
  sleep 2
done

sleep 3
echo "[reviewer] done file detected, closing pane"

tmux kill-pane -t "$PANE_ID" 2>/dev/null || true
rm -f "$DONE_FILE"

# ── process output ────────────────────────────────────────────────────────

sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$TMPDIR/review_raw_${RUN_ID}.txt" > "$TMPDIR/review.md"

cp "$TMPDIR/review.md" "$LOG_DIR/review_${RUN_ID}.md"
cp "$TMPDIR/patch.diff" "$LOG_DIR/patch_${RUN_ID}.diff"

echo "[reviewer] done"

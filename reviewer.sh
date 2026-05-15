#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$SCRIPT_DIR"

REPO="$WORKSPACE/repo"
TMPDIR="${TMPDIR:-$WORKSPACE/tmp}"
LOG_DIR="${LOG_DIR:-$TMPDIR/manual}"

mkdir -p "$LOG_DIR"

cd "$REPO"

COMMIT=$(cat "$TMPDIR/last_commit.txt" 2>/dev/null || git rev-parse HEAD)
LOG_FILE="$LOG_DIR/reviewer.log"
DONE_FILE="$TMPDIR/reviewer_done"
OUTPUT_FILE="$LOG_DIR/review.md"

echo "======================================================================"
echo "[reviewer] $(date '+%Y-%m-%d %H:%M:%S') — reviewing $COMMIT"
echo "[reviewer] log: $LOG_FILE"
echo "======================================================================"

git diff "$COMMIT~1..$COMMIT" > "$LOG_DIR/patch.diff"

# reviewer 不需要 repo 目录，切回 workspace 让 claude 拿到 workspace 的权限
cd "$WORKSPACE"

REVIEW_PROMPT="You are a code reviewer agent with full tool access. Review the patch below, then write the result to a file.

TASK:
$(cat "$TMPDIR/task_desc.txt" 2>/dev/null || echo "(no task info)")

PATCH:
$(cat "$LOG_DIR/patch.diff")

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
---END---

---
WHEN YOUR REVIEW IS COMPLETE, do these two steps in order:
1. Write the complete review (including the ---RESULT--- block) to: ${OUTPUT_FILE}
2. Run this exact command: touch ${DONE_FILE}
These MUST be the very last things you do. Do NOT run them before the review is complete."

# ── start claude in a tmux split pane ─────────────────────────────────────

rm -f "$DONE_FILE" "$OUTPUT_FILE"

PANE_ID=$(tmux split-window -h -P -F '#{pane_id}' "claude")
echo "[reviewer] claude running in pane: $PANE_ID"

sleep 2

tmux pipe-pane -t "$PANE_ID" "cat >> $LOG_FILE"

printf '%s' "$REVIEW_PROMPT" | tmux load-buffer -
tmux paste-buffer -t "$PANE_ID"
tmux send-keys -t "$PANE_ID" Escape Enter

echo "[reviewer] prompt sent, monitoring for done file..."

# ── monitor done file ─────────────────────────────────────────────────────

while [ ! -f "$DONE_FILE" ]; do
  sleep 2
done

sleep 3
echo "[reviewer] done file detected, closing claude pane"

tmux send-keys -t "$PANE_ID" "/exit" Enter
sleep 2

tmux kill-pane -t "$PANE_ID" 2>/dev/null || true
rm -f "$DONE_FILE"

# ── process output ────────────────────────────────────────────────────────

sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTPUT_FILE" > "$TMPDIR/review.md"

echo "[reviewer] done"

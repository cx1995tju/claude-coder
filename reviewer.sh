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

# ── start claude in a tmux split pane ─────────────────────────────────────

PANE_ID=$(tmux split-window -h -P -F '#{pane_id}' "claude")
echo "[reviewer] claude running in pane: $PANE_ID"

# 等待 claude 初始化
sleep 2

# pipe-pane 保存完整日志
tmux pipe-pane -t "$PANE_ID" "cat >> $LOG_FILE"

# 喂 prompt 并提交
printf '%s' "$REVIEW_PROMPT" | tmux load-buffer -
tmux paste-buffer -t "$PANE_ID"
tmux send-keys -t "$PANE_ID" Escape Enter

echo "[reviewer] prompt sent, waiting for review to complete..."

# ── monitor pipe-pane log for completion ───────────────────────────────────

TIMEOUT=600
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  if [ -f "$LOG_FILE" ] && grep -q '---END---' "$LOG_FILE" 2>/dev/null; then
    break
  fi
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
  echo "[reviewer] timeout after ${TIMEOUT}s, closing pane"
fi

sleep 3
echo "[reviewer] review complete, closing claude pane"

# 抓取 pane 全部内容
tmux capture-pane -t "$PANE_ID" -p -S - > "$TMPDIR/review_raw_${RUN_ID}.txt"

# 发 /exit 让 claude 正常退出
tmux send-keys -t "$PANE_ID" "/exit" Enter
sleep 2

# 关掉 claude pane
tmux kill-pane -t "$PANE_ID" 2>/dev/null || true

# ── process output ────────────────────────────────────────────────────────

sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$TMPDIR/review_raw_${RUN_ID}.txt" > "$TMPDIR/review.md"

cp "$TMPDIR/review.md" "$LOG_DIR/review_${RUN_ID}.md"
cp "$TMPDIR/patch.diff" "$LOG_DIR/patch_${RUN_ID}.diff"

echo "[reviewer] done"

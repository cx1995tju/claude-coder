#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$SCRIPT_DIR"

REPO="$WORKSPACE/repo"
PROJECT="$WORKSPACE/.ai/project.md"
MEM="$WORKSPACE/.ai/state.md"
MEM_FIXED="$WORKSPACE/.ai/memory_fixed.md"
TMPDIR="${TMPDIR:-$WORKSPACE/tmp}"
LOG_DIR="${LOG_DIR:-$TMPDIR/manual}"

mkdir -p "$TMPDIR" "$LOG_DIR"

cd "$REPO"

TASK="${1:-implement pending task}"
LOG_FILE="$LOG_DIR/coder.log"
DONE_FILE="$TMPDIR/coder_done"

echo "======================================================================"
echo "[coder] $(date '+%Y-%m-%d %H:%M:%S') — task: $TASK"
echo "[coder] log: $LOG_FILE"
echo "======================================================================"

# ── prompt ────────────────────────────────────────────────────────────────

if [ -n "${CODER_BASE_REF:-}" ]; then
  GIT_LOG=$(git log "${CODER_BASE_REF}..HEAD" --oneline 2>/dev/null || echo "(no commits since base)")
else
  GIT_LOG=$(git log -n 5 --oneline)
fi

REVIEW_FEEDBACK=""
if [ -f "$LOG_DIR/review.md" ] && [ "${CODER_AMEND:-0}" = "1" ]; then
  REVIEW_FEEDBACK="
REVIEW FEEDBACK FROM LAST ATTEMPT — FIX THESE ISSUES:
$(cat "$LOG_DIR/review.md")
"
fi

FIXED_MEM=""
if [ -f "$MEM_FIXED" ] && [ -s "$MEM_FIXED" ]; then
  FIXED_MEM="
IMMUTABLE RULES (must always follow, never violate):
$(cat "$MEM_FIXED")
"
fi

PROJECT_CONTENT=$(cat "$PROJECT" 2>/dev/null || echo "(no project overview)")
MEM_CONTENT=$(cat "$MEM" 2>/dev/null || echo "(no project memory)")

PROMPT="You are a persistent coding agent. Complete the task, then signal completion.

PROJECT OVERVIEW:
${PROJECT_CONTENT}

${FIXED_MEM}
PROJECT MEMORY (learned facts, may be updated):
${MEM_CONTENT}

RECENT GIT HISTORY:
${GIT_LOG}
${REVIEW_FEEDBACK}
RULES:
- modify code directly
- keep changes minimal and focused
- do NOT over-engineer
- always produce compilable, correct code
- commit your changes with git

TASK:
${TASK}

---
WHEN ALL WORK IS COMPLETE AND CHANGES ARE COMMITTED, run this exact command:
touch ${DONE_FILE}
This MUST be the very last thing you do. Do NOT run it before all work is done."

# ── start claude in a tmux split pane ─────────────────────────────────────

rm -f "$DONE_FILE"

PANE_ID=$(tmux split-window -h -P -F '#{pane_id}' "claude")
echo "[coder] claude running in pane: $PANE_ID"

sleep 2

tmux pipe-pane -t "$PANE_ID" "cat >> $LOG_FILE"

printf '%s' "$PROMPT" | tmux load-buffer -
tmux paste-buffer -t "$PANE_ID"
tmux send-keys -t "$PANE_ID" Escape Enter

echo "[coder] prompt sent, monitoring for done file..."

# ── monitor done file ─────────────────────────────────────────────────────

while [ ! -f "$DONE_FILE" ]; do
  sleep 2
done

sleep 3
echo "[coder] done file detected, closing claude pane"

tmux send-keys -t "$PANE_ID" "/exit" Enter
sleep 2

tmux kill-pane -t "$PANE_ID" 2>/dev/null || true
rm -f "$DONE_FILE"

# ── git commit ────────────────────────────────────────────────────────────

git add -A

if [ "${CODER_AMEND:-0}" = "1" ]; then
  git commit --amend --no-edit || echo "[coder] amend skipped (no changes)"
  echo "[coder] amended previous commit" | tee -a "$LOG_FILE"
else
  git commit -m "[coder] $TASK" || echo "[coder] commit skipped (no changes)"
fi

COMMIT=$(git rev-parse HEAD)
echo "[coder] commit: $COMMIT" | tee -a "$LOG_FILE"
echo "$COMMIT" > "$TMPDIR/last_commit.txt"

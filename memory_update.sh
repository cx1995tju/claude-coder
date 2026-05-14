#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$SCRIPT_DIR"

MEM="$WORKSPACE/.ai/state.md"
MEM_FIXED="$WORKSPACE/.ai/memory_fixed.md"
TMPDIR="${TMPDIR:-$WORKSPACE/tmp}"
LOG_DIR="${LOG_DIR:-$WORKSPACE/logs/manual}"

mkdir -p "$LOG_DIR"

COMMIT=$(cat "$TMPDIR/last_commit.txt")
PATCH=$(cat "$TMPDIR/patch.diff")
REVIEW=$(cat "$TMPDIR/review.md")
RUN_ID=$(date +%s)
LOG_FILE="$LOG_DIR/memory_${RUN_ID}.log"

echo "======================================================================" | tee -a "$LOG_FILE"
echo "[memory] $(date '+%Y-%m-%d %H:%M:%S') — updating state" | tee -a "$LOG_FILE"
echo "======================================================================" | tee -a "$LOG_FILE"

MEM_SIZE=$(wc -l < "$MEM" 2>/dev/null || echo 0)
MAX_LINES=200

COMPACT_HINT=""
if [ "$MEM_SIZE" -gt "$MAX_LINES" ]; then
  COMPACT_HINT="
IMPORTANT: memory is ${MEM_SIZE} lines (over ${MAX_LINES}). You MUST compact it:
- merge related entries
- remove resolved/obsolete facts
- drop information no longer relevant
Target: under 100 lines.
"
fi

FIXED_CTX=""
if [ -f "$MEM_FIXED" ] && [ -s "$MEM_FIXED" ]; then
  FIXED_CTX="
IMMUTABLE RULES (these are always present — do NOT duplicate or modify):
$(cat "$MEM_FIXED")
"
fi

MEM_PROMPT="You maintain the project's learnable memory file (state.md).
${FIXED_CTX}
CURRENT MEMORY (you may update/compact this):
$(cat "$MEM")

CONTEXT (what just happened):
Commit: $COMMIT
Patch:
$PATCH
Review:
$REVIEW

TASK:
Update the memory file with new facts learned from this change:
- new invariants or constraints discovered
- bugs found (not yet fixed)
- architectural decisions made
- coding rules that must be followed going forward

Also REMOVE entries that are:
- fixed and no longer relevant
- superseded by later changes
- duplicate or redundant
${COMPACT_HINT}
IMPORTANT: The immutable rules are automatically included in every session.
Do NOT copy them into the memory file.

Output ONLY the updated state.md content, nothing else.
If nothing changed, output the current memory as-is, then exit."

MEM_PROMPT_FILE="$TMPDIR/mem_prompt_${RUN_ID}.txt"
printf '%s' "$MEM_PROMPT" > "$MEM_PROMPT_FILE"

script -q -e -c "claude -p - < $MEM_PROMPT_FILE" "$LOG_FILE"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG_FILE" > "$MEM"

cp "$MEM" "$LOG_DIR/state_${RUN_ID}.md"

echo "[memory] updated ($(wc -l < "$MEM") lines)" | tee -a "$LOG_FILE"

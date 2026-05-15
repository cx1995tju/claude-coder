#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$SCRIPT_DIR"
TASKS_FILE="$WORKSPACE/tasks.json"
TMPDIR="$WORKSPACE/tmp"
REPO="$WORKSPACE/repo"

MAX_RETRIES=3

# ── tmux bootstrap ──────────────────────────────────────────────────────
# 如果不在 tmux 里运行，自动创建一个 session 并重新执行
# 同时把代理/认证相关的环境变量透传到 tmux session 里

if [ -z "${TMUX:-}" ]; then
  # 收集需要透传给 tmux 的环境变量（代理 + anthropic 认证 + 其他关键变量）
  ENV_ARGS=""
  for var in $(env | cut -d= -f1 | grep -iE '^(http|https|ftp|all|no)_proxy$|^ANTHROPIC|^CLAUDE|^OPENAI|^GIT_|^SSH_|^LANG$|^LC_|^PATH$|^HOME$|^USER$|^TERM$|^SHELL$|^DISPLAY$|^LD_|^PYTHON|^NODE|^JAVA_HOME|^GOPATH|^CARGO' 2>/dev/null || true); do
    val="$(printenv "$var")"
    if [ -n "$val" ]; then
      ENV_ARGS="$ENV_ARGS -e $var='$val'"
    fi
  done
  exec tmux new-session -s "coder-loop" $ENV_ARGS "bash $SCRIPT_DIR/loop.sh $*"
fi

# 从此刻起，我们在 tmux 内部运行
CURRENT_SESSION=$(tmux display-message -p '#S')

# 确保关键环境变量在 tmux 内对所有新 window 生效
for var in $(env | cut -d= -f1 | grep -iE '^(http|https|ftp|all|no)_proxy$|^ANTHROPIC|^CLAUDE' 2>/dev/null || true); do
  val="$(printenv "$var")"
  [ -n "$val" ] && tmux setenv "$var" "$val" 2>/dev/null || true
done

# ── logging ─────────────────────────────────────────────────────────────

SESSION_ID=$(date +%Y-%m-%d_%H-%M-%S)
LOG_DIR="$TMPDIR/$SESSION_ID"
LOOP_LOG="$LOG_DIR/loop.log"

mkdir -p "$TMPDIR" "$LOG_DIR"

log() {
  local msg="[loop] $(date '+%H:%M:%S') $*"
  echo "$msg"
  echo "$msg" >> "$LOOP_LOG"
}

log "======================================================================"
log "session: $SESSION_ID  tmux: $CURRENT_SESSION"
log "log dir:  $LOG_DIR"
log "======================================================================"

# ── helpers ─────────────────────────────────────────────────────────────

task_count() { jq '.tasks | length' "$TASKS_FILE"; }

parse_result() {
  local key="$1"
  local review_file="$TASK_LOG_DIR/review.md"
  if [ -f "$review_file" ]; then
    sed -n '/^---RESULT---$/,/^---END---$/p' "$review_file" \
      | grep "^${key}:" | head -1 | cut -d' ' -f2
  fi
}

# ── guard ───────────────────────────────────────────────────────────────

if [ "$(task_count)" -eq 0 ]; then
  log "no tasks in tasks.json, nothing to do"
  exit 0
fi

cp "$TASKS_FILE" "$LOG_DIR/tasks_snapshot.json"

# ── main loop ───────────────────────────────────────────────────────────

for i in $(seq 0 $(( $(task_count) - 1 ))); do

  task_id=$(   jq -r ".tasks[$i].id"          "$TASKS_FILE")
  task_desc=$( jq -r ".tasks[$i].description" "$TASKS_FILE")
  task_done=$( jq -r ".tasks[$i].done // false" "$TASKS_FILE")

  if [ "$task_done" = "true" ]; then
    log "task $task_id already done, skipping"
    continue
  fi

  log "===== task $task_id: $task_desc ====="

  TASK_LOG_DIR="$LOG_DIR/task_${task_id}"
  mkdir -p "$TASK_LOG_DIR"

  export LOG_DIR="$TASK_LOG_DIR"
  export TMPDIR="$TMPDIR"
  export TMUX_SESSION="$CURRENT_SESSION"
  export TASK_ID="$task_id"

  BASE_REF=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo "HEAD")
  export CODER_BASE_REF="$BASE_REF"

  retry=0
  task_ok=0
  current_desc="$task_desc"
  CODER_AMEND=0

  while [ $retry -lt $MAX_RETRIES ]; do
    log "task $task_id attempt $((retry + 1))/$MAX_RETRIES"

    export CODER_AMEND

    # coder: 交互式，tmux 窗口
    bash "$WORKSPACE/coder.sh" "$current_desc" || {
      log "coder failed (exit $?), will retry"
      retry=$((retry + 1))
      CODER_AMEND=1
      continue
    }

    # 把 task 信息留给 reviewer
    echo "$current_desc" > "$TMPDIR/task_desc.txt"

    # reviewer: 交互式，tmux 窗口
    bash "$WORKSPACE/reviewer.sh" || {
      log "reviewer failed (exit $?), will retry"
      retry=$((retry + 1))
      CODER_AMEND=1
      continue
    }

    critical_count=$(parse_result "CRITICAL_COUNT")
    log "review: critical=$critical_count"

    if [ "${critical_count:-0}" -gt 0 ]; then
      fixes=$(grep '^FIX:' "$TASK_LOG_DIR/review.md" || true)
      current_desc="$task_desc [REVIEW: $fixes]"
      retry=$((retry + 1))
      CODER_AMEND=1
      log "critical issues found, feeding back to coder"
      continue
    fi

    log "no critical issues, task complete"
    task_ok=1
    break
  done

  if [ "$task_ok" -eq 0 ]; then
    log "task $task_id FAILED after $MAX_RETRIES retries, skipping"
    echo "FAILED after $MAX_RETRIES retries" > "$TASK_LOG_DIR/status.txt"
    continue
  fi

  # memory update: 非交互
  bash "$WORKSPACE/memory_update.sh" || log "memory update failed (non-fatal)"

  jq ".tasks[$i].done = true" "$TASKS_FILE" > "$TASKS_FILE.tmp" \
    && mv "$TASKS_FILE.tmp" "$TASKS_FILE"

  echo "OK ($retry retries)" > "$TASK_LOG_DIR/status.txt"
  log "task $task_id complete (retries: $retry)"
done

cp "$TASKS_FILE" "$LOG_DIR/tasks_final.json"
log "all tasks processed"
log "session complete: $LOG_DIR"

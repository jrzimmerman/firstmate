#!/usr/bin/env bash
# drive.sh <bin-root> <label> <status-line> <hold-mode:origin|none> <seconds>
set -u
ROOTBIN=$1; LABEL=$2; LINE=$3; MODE=$4; SECS=$5
WT=/Users/justin/.no-mistakes/worktrees/acf03fba152a/01M65HRRKZ7RA864227FMGEYT8
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"; unset TMUX TMUX_PANE
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$LAB"
cleanup() { tmux kill-server 2>/dev/null; [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
cat > "$LAB/.tasks.toml" <<'T'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
T
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
(cd "$LAB" && tasks-axi add plan-scout 'investigate the board' --file data/backlog.md) >/dev/null 2>&1 || { echo "add failed"; exit 1; }
if [ "$MODE" = origin ]; then
  "$WT/bin/fm-captain-hold.sh" hold scout-board-design --title 'board review the scout raised' \
    --reason 'awaiting the captain on the board review' --origin plan-scout || { echo hold failed; exit 1; }
fi
echo "--- backlog"; cat "$LAB/data/backlog.md"
# Live pane emulating Claude's per-tick countdown status line.
tmux new-session -d -s fm -n fm-scout -x 120 -y 30 \
  'n=0; while :; do clear; printf "> board review ready\n\n  Opus 5.5 | ctx 41%% | 5h 61%% (in 4h%02dm)\n" $((59-n%60)); n=$((n+1)); sleep ${TICK:-12}; done'
W=fm:fm-scout
printf 'window=%s\nkind=scout\nharness=claude\nbackend=tmux\n' "$W" > "$LAB/state/plan-scout.meta"
printf '%s\n' "$LINE" > "$LAB/state/plan-scout.status"
FM_STATE_OVERRIDE="$LAB/state" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' _ "$WT/bin/fm-wake-lib.sh" "$LAB/state" "$LAB/state/plan-scout.status"
ack() {
  local err="$LAB/state/.drain.err" seq gen
  "$ROOTBIN/fm-drain.sh" > "$LAB/drain.out" 2> "$err" || true
  cat "$LAB/drain.out" | sed 's/^/    drained: /'
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && "$ROOTBIN/fm-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
start=$(date +%s); launches=0; wakes=0
echo "--- driving watcher ($ROOTBIN) for ${SECS}s on live pane $W, status: $LINE"
while [ $(( $(date +%s) - start )) -lt "$SECS" ]; do
  launches=$((launches+1))
  FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOTBIN/fm-watch.sh" > "$LAB/watch.$launches.out" 2>&1 &
  WPID=$!
  while kill -0 "$WPID" 2>/dev/null && [ $(( $(date +%s) - start )) -lt "$SECS" ]; do sleep 0.5; done
  if kill -0 "$WPID" 2>/dev/null; then
    kill "$WPID"; wait "$WPID" 2>/dev/null; WPID=
    printf '  t=%ss watcher #%s still running at end (absorbing)\n' $(( $(date +%s) - start )) "$launches"
  else
    wait "$WPID"; WPID=; wakes=$((wakes+1))
    printf '  t=%ss watcher #%s exited with wake: %s\n' $(( $(date +%s) - start )) "$launches" "$(grep -v '^$' "$LAB/watch.$launches.out" | tail -3 | tr '\n' '|')"
    ack
  fi
done
echo "--- pane at end:"; tmux capture-pane -p -t "$W" | grep -v '^$'
stale=$(cat "$LAB/state/.wake-queue"* 2>/dev/null | awk -F '\t' '$3=="stale"{n++} END{print n+0}')
echo "--- state:"; ls -a "$LAB/state" | tr "\n" " "; echo; for f in "$LAB"/watch.*.out; do echo "== $f"; tail -5 "$f"; done
echo "count=$(cat "$LAB"/state/.count-* 2>/dev/null)"; echo "--- triage log:"; tail -8 "$LAB/state/.watch-triage.log" 2>/dev/null
echo "RESULT label=$LABEL watcher_launches=$launches wake_exits=$wakes"

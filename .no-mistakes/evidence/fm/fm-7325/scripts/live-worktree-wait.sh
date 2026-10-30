#!/usr/bin/env bash
# Live lab driver: real bin/fm-spawn.sh, real tmux (private fm-lab socket),
# real treehouse (pool under the lab), real codex launch. A post-checkout hook
# that sleeps stands in for a large repository's slow slot checkout.
set -u
WT=$1 EV=$2
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
printf 'codex\n' > "$LAB/config/crew-harness"
export TMUX_TMPDIR="$LAB/tmux"
T() { tmux -L fm-lab "$@"; }
cleanup() { T kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT

mkproj() { # <name> <hook-sleep>
  local p="$LAB/src/$1"
  mkdir -p "$p"; git -C "$p" init -q -b main
  echo "# $1" > "$p/README.md"; git -C "$p" add README.md
  git -C "$p" -c user.name=lab -c user.email=lab@example.invalid commit -qm init
  git clone -q --bare "$p" "$p.origin.git"; git -C "$p" remote add origin "file://$p.origin.git"
  git -C "$p" fetch -q origin
  printf '#!/bin/sh\nsleep %s\n' "$2" > "$p/.git/hooks/post-checkout"; chmod +x "$p/.git/hooks/post-checkout"
  printf '%s\n' "$p"
}
mkbrief() {
  mkdir -p "$LAB/data/$1"
  printf '# Task\n## Captain'"'"'s intent\nLab check of worktree wait for %s.\n\n## Firstmate spec\nDo nothing; lab fixture.\n' "$1" > "$LAB/data/$1/brief.md"
}
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  tmux -L fm-lab new-session -d -s primary -c "$WT" -e FM_HOME="$LAB" -e TREEHOUSE_ROOT="$LAB/pool" -e FM_SPAWN_NO_GUARD=1 bash --norc --noprofile
touch "$LAB/state/.last-watcher-beat"

run() { # <label> <id> <proj> <worktree-wait-content|ABSENT>
  local label=$1 id=$2 proj=$3 val=$4 out="$LAB/out-$2.txt" done="$LAB/done-$2"
  if [ "$val" = ABSENT ]; then rm -f "$LAB/config/worktree-wait"; else printf '%s\n' "$val" > "$LAB/config/worktree-wait"; fi
  mkbrief "$id"
  echo "===== $label ====="
  echo "config/worktree-wait: $( [ "$val" = ABSENT ] && echo '<absent>' || printf "'%s'" "$val")"
  echo "windows before: $(T list-windows -a -F '#{window_name}' | tr '\n' ' ')"
  T send-keys -t primary "SECONDS=0; bin/fm-spawn.sh $id $proj --mode local-only --yolo off > $out 2>&1; echo \"exit=\$? elapsed=\${SECONDS}s\" >> $out; touch $done" Enter
  while [ ! -e "$done" ]; do sleep 1; done
  sed "s#$LAB#\$LAB#g" "$out"
  echo "windows after: $(T list-windows -a -F '#{window_name}' | tr '\n' ' ')"
  if [ -f "$LAB/state/$id.meta" ]; then echo "meta: $(grep -E '^(worktree|backend|harness)=' "$LAB/state/$id.meta" | sed "s#$LAB#\$LAB#g" | tr '\n' ' ')"; else echo "meta: <none>"; fi
  echo
}

# S1: invalid values refuse before any endpoint/record
P=$(mkproj invalid 0)
n=0; for v in 0 abc -5 1234567890; do n=$((n+1)); run "S1 invalid value '$v'" lab-bad-$n "$P" "$v"; done
# S2: configured short bound times out on a slow slot, naming the configured value
P=$(mkproj short 40); run "S2 configured 5s on a 40s slot" lab-short "$P" 5
# S3: default (absent) still 60s on a 75s slot
P=$(mkproj dflt 75); run "S3 absent config on a 75s slot (default 60)" lab-default "$P" ABSENT
# S4: raised bound admits a 75s slot
P=$(mkproj slow 75); run "S4 configured 120s on a 75s slot" lab-slow "$P" 120
echo "===== pane capture (primary) ====="
T capture-pane -p -t primary | sed "s#$LAB#\$LAB#g" | grep -v '^$' | tail -15

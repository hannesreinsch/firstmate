#!/usr/bin/env bash
# Live cold-cache park scenario driver: real Claude Code scout spawned by the
# real fm-spawn into a guarded fm-lab-* Herdr session, then driven through the
# real fm-send, fm-control park/relaunch, fm-watch, and fm-park-stopped.
# Usage: cold-park-herdr-live.sh <repo-root> <evidence-dir>
set -u
ROOT=$1
EV=$2
LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
unset NO_MISTAKES_GATE FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
unset FM_GATE_REFUSE_BYPASS   # the marked lab home authorizes lifecycle, no bypass

ORIGINAL_PATH=$PATH
REAL_HERDR=$(command -v herdr)
SESSION=$("$LAB_HELPER" name coldpark)
LAB=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-lab.XXXXXX")
rmdir "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab home create failed"; exit 1; }
FAKEBIN=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-lab-bin.XXXXXX")
TASK=cp1
STATUS="$LAB/state/$TASK.status"
LOG="$EV/cold-park-herdr-live.transcript.txt"
: > "$LOG"
RESULTS="$EV/cold-park-herdr-live.results.txt"
: > "$RESULTS"

say() { printf '\n### %s\n' "$*" | tee -a "$LOG"; }
run() { printf '$ %s\n' "$*" >> "$LOG"; "$@" >>"$LOG" 2>&1; local rc=$?; printf '[exit %s]\n' "$rc" >> "$LOG"; return "$rc"; }
res() { printf '%s\n' "$*" | tee -a "$RESULTS" "$LOG"; }

cleanup() {
  say "teardown"
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" >>"$LOG" 2>&1 && echo "herdr lab $SESSION torn down" >> "$LOG"
  rm -rf "$LAB" "$FAKEBIN"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<SH
#!/usr/bin/env bash
set -u
args=("\$@")
last=\$((\${#args[@]} - 1)); flag=\$((last - 1))
if [ "\${#args[@]}" -ge 2 ] && [ "\${args[\$flag]}" = --session ] && [ "\${args[\$last]}" = "$SESSION" ]; then
  unset "args[\$last]" "args[\$flag]"
fi
set -- "\${args[@]}"
for a in "\$@"; do case "\$a" in --session|--session=*) echo "lab shim refused foreign session" >&2; exit 9 ;; esac; done
if [ "\${1:-}" = --version ]; then exec env PATH="$ORIGINAL_PATH" "$REAL_HERDR" "\$@"; fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\$@"
SH
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" >>"$LOG" 2>&1 || { echo "provision failed"; exit 1; }
export PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$LAB" HERDR_SESSION="$SESSION" TREEHOUSE_ROOT="$LAB/pool"
printf 'herdr\n' > "$LAB/config/backend"
printf '1\n' > "$LAB/config/cold-cache-minutes"
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

P="$LAB/projects/coldp"
mkdir -p "$P"
git -C "$P" init -q -b main && git -C "$P" config user.email t@example.invalid && git -C "$P" config user.name t
printf 'cold park probe\n' > "$P/README.md"; printf 'root = "."\n' > "$P/treehouse.toml"; printf '.treehouse/\n' > "$P/.gitignore"; git -C "$P" add README.md treehouse.toml .gitignore; git -C "$P" commit -qm init

say "scaffold brief and spawn a real Claude scout on Herdr"
run "$ROOT/bin/fm-brief.sh" "$TASK" coldp --scout || exit 1
python3 - "$LAB/data/$TASK/brief.md" "$STATUS" <<'PY'
from pathlib import Path
import sys
b = Path(sys.argv[1]); s = sys.argv[2]
b.write_text(b.read_text().replace("{TASK}", f'''Cold-cache probe.
Immediately append exactly `needs-decision [at=<epoch>] [key=k1]: awaiting instruction` to `{s}` (substitute <epoch> as rule 4 says), then stop and wait for a firstmate message.
When a firstmate message arrives, do exactly what it says and nothing else.
Do not change project files or make a commit.''').replace("{FIRSTMATE_SPEC}", "Follow the Task exactly; no other work."))
PY
run "$ROOT/bin/fm-spawn.sh" "$TASK" "$P" --scout --harness claude --model haiku --backend herdr || { res "FAIL spawn"; exit 1; }
cp "$LAB/state/$TASK.meta" "$EV/cold-park-herdr-live.meta-at-spawn.txt"
T=$(awk -F= '/^window=/{print $2}' "$LAB/state/$TASK.meta"); PANE=${T#*:}
echo "endpoint=$T" >> "$LOG"

pane_text() { lab pane read "$1" --source visible 2>/dev/null; }
trusted=0
for i in $(seq 1 120); do
  s=$(pane_text "$PANE")
  case "$s" in
    *'Yes, I trust this folder'*) [ $trusted = 0 ] && { lab pane send-keys "$PANE" down enter >/dev/null; trusted=1; } ;;
    *'Yes, I accept'*) lab pane send-keys "$PANE" down enter >/dev/null; sleep 2 ;;
  esac
  grep -q '^needs-decision' "$STATUS" 2>/dev/null && grep -q 'state=idle' "$LAB/state/$TASK.busy-state" 2>/dev/null && break
  sleep 2
done
grep -q 'state=idle' "$LAB/state/$TASK.busy-state" || { res "FAIL worker never reached an idle needs-decision"; pane_text "$PANE" >> "$LOG"; exit 1; }
echo "busy-state: $(cat "$LAB/state/$TASK.busy-state")" >> "$LOG"
pane_text "$PANE" > "$EV/cold-park-herdr-live.pane-01-idle-worker.txt"

say "S1: fm-send to a worker idle past the threshold is refused before anything is recorded"
sleep 66
rc=0; out=$("$ROOT/bin/fm-send.sh" "$TASK" "please append hello" 2>&1) || rc=$?
printf '$ fm-send.sh %s "please append hello"\n%s\n[exit %s]\n' "$TASK" "$out" "$rc" >> "$LOG"
inbox_n=$(ls "$LAB/state/$TASK.inbox"/*.msg 2>/dev/null | wc -l | tr -d ' ')
if [ "$rc" = 4 ] && printf '%s' "$out" | grep -q 'relaunch --note-file' && [ "$inbox_n" = 0 ] && [ -s "$LAB/state/$TASK.cold-relaunch-note" ]; then
  res "PASS S1 cold steer refused (exit 4), relaunch command printed, no inbox record, note file written"
  cp "$LAB/state/$TASK.cold-relaunch-note" "$EV/cold-park-herdr-live.default-note.txt"
else res "FAIL S1 rc=$rc inbox=$inbox_n"; fi

if [ "${SKIP_BUSY:-0}" != 1 ]; then
say "S2: --cold-ok delivers anyway; S3: park refuses the now-busy worker and does not interrupt it"
rc=0; run "$ROOT/bin/fm-send.sh" "$TASK" --cold-ok "Use your Bash tool once, in the foreground (do not use run_in_background), to run exactly: python3 -c 'import time; time.sleep(30)' After it finishes, append exactly needs-decision [at=<epoch>] [key=k2]: awaiting second instruction to $STATUS and stop." || rc=$?
busy=0
for i in $(seq 1 30); do grep -q 'state=busy' "$LAB/state/$TASK.busy-state" && { busy=1; break; }; sleep 1; done
[ "$rc" = 0 ] && [ "$busy" = 1 ] && res "PASS S2 --cold-ok steer delivered and the worker started a turn" || res "FAIL S2 rc=$rc busy=$busy"
sleep 5
prc=0; run "$ROOT/bin/fm-control.sh" "$TASK" park || prc=$?
st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
pane_text "$PANE" > "$EV/cold-park-herdr-live.pane-02-busy-after-refused-park.txt"
for i in $(seq 1 90); do grep -q 'key=k2' "$STATUS" && break; sleep 2; done
if [ "$prc" = 1 ] && [ ! -e "$LAB/state/$TASK.cold-parked" ] && grep -q 'key=k2' "$STATUS"; then
  res "PASS S3 park refused a busy worker (exit $prc, herdr status=$st), no marker, the worker finished its turn uninterrupted"
else res "FAIL S3 park rc=$prc marker=$(ls "$LAB/state/$TASK.cold-parked" 2>&1) k2=$(grep -c k2 "$STATUS")"; fi

fi
say "S4: the watcher parks the cold paused worker on its own and closes its Herdr pane"
for i in $(seq 1 30); do grep -q 'state=idle' "$LAB/state/$TASK.busy-state" && break; sleep 1; done
sleep 66
lab pane list > "$EV/cold-park-herdr-live.panes-before-park.json" 2>&1
for round in 1 2 3 4 5 6; do
  [ -e "$LAB/state/$TASK.cold-parked" ] && break
  d=$("$ROOT/bin/fm-wake-drain.sh" 2>&1); printf '$ fm-wake-drain.sh\n%s\n' "$d" >> "$LOG"
  ack=$(printf '%s\n' "$d" | sed -n 's/.*run bin\/fm-wake-drain.sh \(--ack-through [0-9]* --recovery-generation [A-Za-z0-9._-]*\).*/\1/p' | tail -n 1)
  [ -n "$ack" ] && run "$ROOT/bin/fm-wake-drain.sh" $ack
  FM_POLL=2 "$ROOT/bin/fm-watch.sh" >>"$LOG" 2>&1 &
  wpid=$!
  for i in $(seq 1 60); do [ -e "$LAB/state/$TASK.cold-parked" ] && break; kill -0 "$wpid" 2>/dev/null || break; sleep 1; done
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
  for i in $(seq 1 40); do [ -e "$LAB/state/$TASK.cold-parked" ] && break; sleep 1; done
done
cat "$LAB/state/.cold-park-last-$TASK" >> "$LOG" 2>/dev/null
grep 'cold-park' "$LAB/state"/*triage* >> "$LOG" 2>/dev/null
lab pane list > "$EV/cold-park-herdr-live.panes-after-park.json" 2>&1
gone=0; lab pane get "$PANE" >/dev/null 2>&1 || gone=1
if [ -e "$LAB/state/$TASK.cold-parked" ] && [ "$gone" = 1 ] && grep -q 'endpoint=closed' "$LAB/state/$TASK.cold-parked"; then
  res "PASS S4 watcher parked $TASK: marker written, endpoint=closed, pane $PANE gone from the lab session"
  cp "$LAB/state/$TASK.cold-parked" "$EV/cold-park-herdr-live.cold-parked-marker.txt"
  cp "$LAB/state/.cold-park-last-$TASK" "$EV/cold-park-herdr-live.watcher-park-output.txt" 2>/dev/null
else res "FAIL S4 marker=$([ -e "$LAB/state/$TASK.cold-parked" ] && echo y) gone=$gone"; fi
git -C "$(awk -F= '/^worktree=/{print $2}' "$LAB/state/$TASK.meta")" status --short >> "$LOG" 2>&1

say "S5: a parked worker refuses every text steer, --cold-ok included"
rc=0; run "$ROOT/bin/fm-send.sh" "$TASK" --cold-ok "hello" || rc=$?
[ "$rc" = 4 ] && res "PASS S5 send to parked worker refused with --cold-ok (exit 4)" || res "FAIL S5 rc=$rc"
run "$ROOT/bin/fm-crew-state.sh" "$TASK"

say "S6: relaunch without --note uses the default note, opens a fresh Herdr endpoint, removes the marker"
rc=0; run "$ROOT/bin/fm-control.sh" "$TASK" relaunch || rc=$?
T2=$(awk -F= '/^window=/{print $2}' "$LAB/state/$TASK.meta"); PANE2=${T2#*:}
st2=$(lab agent get "$PANE2" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
if [ "$rc" = 0 ] && [ ! -e "$LAB/state/$TASK.cold-parked" ] && [ "$PANE2" != "$PANE" ] && [ -n "$st2" ]; then
  res "PASS S6 relaunch rc=0 new endpoint $T2 agent_status=$st2, marker removed"
else res "FAIL S6 rc=$rc T2=$T2 st=$st2"; fi
grep -rl 'stopped on purpose' "$LAB/data/$TASK" 2>/dev/null | head -1 | xargs -I{} cp {} "$EV/cold-park-herdr-live.relaunch-brief-with-note.md"
for i in $(seq 1 30); do
  s=$(pane_text "$PANE2")
  case "$s" in *'Yes, I trust this folder'*|*'Yes, I accept'*) lab pane send-keys "$PANE2" down enter >/dev/null ;; esac
  grep -q 'state=busy' "$LAB/state/$TASK.busy-state" 2>/dev/null && break
  sleep 2
done
pane_text "$PANE2" > "$EV/cold-park-herdr-live.pane-03-relaunched.txt"

say "S7: fm-park-stopped closes the pane of a worker whose agent already stopped"
for i in $(seq 1 60); do grep -q 'state=idle' "$LAB/state/$TASK.busy-state" 2>/dev/null && break; sleep 2; done
run "$ROOT/bin/fm-control.sh" "$TASK" exit
rc=0; out=$("$ROOT/bin/fm-park-stopped.sh" 2>&1) || rc=$?
printf '$ fm-park-stopped.sh\n%s\n[exit %s]\n' "$out" "$rc" >> "$LOG"
gone2=0; lab pane get "$PANE2" >/dev/null 2>&1 || gone2=1
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "summary: parked=1 skipped=0 failed=0" && [ -e "$LAB/state/$TASK.cold-parked" ] && [ "$gone2" = 1 ]; then
  res "PASS S7 fm-park-stopped parked the stopped worker and its pane $PANE2 is gone"
else res "FAIL S7 rc=$rc gone=$gone2"; fi
lab pane list > "$EV/cold-park-herdr-live.panes-final.json" 2>&1

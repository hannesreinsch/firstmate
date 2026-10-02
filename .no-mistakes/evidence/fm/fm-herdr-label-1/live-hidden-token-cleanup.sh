#!/usr/bin/env bash
# Real restored-shell E2E for home-local session-start Herdr projection cleanup.
# Every CLI operation is routed through one guarded named non-default lab, and
# lab teardown verifies that the default fleet session is byte-identical.
set -u

ROOT=${ROOT:?}
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'skip: python3 not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-session-cleanup-e2e.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/config"
touch "$HOME_DIR/config/herdr-presentation-spaces"
printf '%s\n' herdr > "$HOME_DIR/config/backend"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name hidden-token-clean)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
# Keep the lab helper as the only CLI transport. Production adapter calls have
# already appended the exact session; this shim strips that pair, refuses every
# other caller-supplied session, and delegates the command to helper run.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
production_process_proof() {
  FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY=1 PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
    bash -c '. "$1"; fm_backend_herdr_pane_idle_shell_pid "$2" "$3" >/dev/null' \
      _ "$ROOT/bin/fm-herdr-session-cleanup.sh" "$HERDR_LAB_SESSION" "$PANE"
}
focus_snapshot() {
  local list workspace tab tabs
  list=$(lab workspace list) || return 1
  workspace=$(printf '%s' "$list" | jq -er '[.result.workspaces[] | select(.focused == true)] | select(length == 1) | .[0].workspace_id') || return 1
  tab=$(printf '%s' "$list" | jq -er --arg workspace "$workspace" '[.result.workspaces[] | select(.workspace_id == $workspace)] | select(length == 1) | .[0].active_tab_id') || return 1
  tabs=$(lab tab list --workspace "$workspace") || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '([.result.tabs[] | select(.focused == true)] | length) == 1 and ([.result.tabs[] | select(.focused == true)][0].tab_id == $tab)' >/dev/null || return 1
  printf '%s\t%s' "$workspace" "$tab"
}

ANCHOR=$(lab workspace create --cwd "$ROOT" --label captain-anchor --focus) || fail 'anchor'
HOME_REAL=$(cd "$HOME_DIR" && pwd -P)
TOKEN=AbCdEfGhIjKlMnOpQrStUv
ID=hidden-tok
TITLE="└ $ID"
mk() { lab workspace create --cwd "$ROOT" --label "$1" --no-focus; }
# A: orphan bound projection showing only the visible label, with a v2 journal.
A=$(mk "$TITLE") || fail 'create A'
WS=$(printf '%s' "$A" | jq -r '.result.workspace.workspace_id'); TAB=$(printf '%s' "$A" | jq -r '.result.tab.tab_id'); PANE=$(printf '%s' "$A" | jq -r '.result.root_pane.pane_id')
# B: human workspace with a corner label and no journal.
B=$(mk "└ my-notes") || fail 'create B'; WSB=$(printf '%s' "$B" | jq -r '.result.workspace.workspace_id')
# C: same visible title as A's task, but journal is bound to A not C.
C=$(mk "└ other-task") || fail 'create C'; WSC=$(printf '%s' "$C" | jq -r '.result.workspace.workspace_id')
{
  printf 'version=2\ntask_id=%s\nprojection_id=%s\nhome=%s\n' "$ID" "$TOKEN" "$HOME_REAL"
  printf 'session=%s\nworkspace_id=%s\ntab_id=%s\npane_id=%s\n' "$HERDR_LAB_SESSION" "$WS" "$TAB" "$PANE"
  printf 'parent_workspace_id=w1\nparent_label=firstmate\nworkspace_label=%s\ntask_label=fm-%s\n' "$TITLE" "$ID"
} > "$HOME_DIR/state/$ID.herdr-presentation"
# D: v2 journal for task other-task bound to a different (nonexistent) workspace id.
{
  printf 'version=2\ntask_id=other-task\nprojection_id=ZyXwVuTsRqPoNmLkJiHgFe\nhome=%s\n' "$HOME_REAL"
  printf 'session=%s\nworkspace_id=w999\ntab_id=t999\npane_id=p999\n' "$HERDR_LAB_SESSION"
  printf 'parent_workspace_id=w1\nparent_label=firstmate\nworkspace_label=└ other-task\ntask_label=fm-other-task\n'
} > "$HOME_DIR/state/other-task.herdr-presentation"
echo "--- before cleanup"; lab workspace list | jq -r '.result.workspaces[] | "\(.workspace_id)\t\(.label)"'
attempt=0
while [ "$attempt" -lt 50 ]; do production_process_proof && break; sleep 0.1; attempt=$((attempt+1)); done
[ "$attempt" -lt 50 ] || fail 'idle shell shape'
BEFORE_FOCUS=$(focus_snapshot)
FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" "$ROOT/bin/fm-herdr-session-cleanup.sh" || fail 'cleanup failed'
echo "--- after cleanup"; lab workspace list | jq -r '.result.workspaces[] | "\(.workspace_id)\t\(.label)"'
[ "$(focus_snapshot)" = "$BEFORE_FOCUS" ] || fail 'focus changed'
if lab workspace get "$WS" >/dev/null 2>&1; then fail 'bound visible-label orphan survived'; fi
[ ! -e "$HOME_DIR/state/$ID.herdr-presentation" ] || fail 'journal survived'
pass 'cleanup closes the orphan whose label is only "└ hidden-tok", proven by v2 workspace id binding'
lab workspace get "$WSB" >/dev/null 2>&1 || fail 'human └ my-notes workspace was closed'
pass 'human "└ my-notes" workspace without a journal is untouched'
lab workspace get "$WSC" >/dev/null 2>&1 || fail '└ other-task bound elsewhere was closed'
[ -e "$HOME_DIR/state/other-task.herdr-presentation" ] || fail 'other-task journal removed'
pass '"└ other-task" whose journal binds a different workspace id is untouched'

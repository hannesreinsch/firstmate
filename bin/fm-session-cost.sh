#!/usr/bin/env bash
# fm-session-cost.sh - read a worker's context size and idle time from its
# harness transcript, and surface a large or cold session once so firstmate
# can start a fresh worker with a handoff note instead of continuing it.
#
# Usage:
#   fm-session-cost.sh show [--json] <task-id>
#   fm-session-cost.sh scan
#
# Why: every turn of a session re-reads its whole context, so a worker's cost
# per turn grows with its context size, and a turn after the provider's prompt
# cache expired re-writes that whole context at full price. A fresh worker in
# the same local copy, started from a short written handoff note, costs a small
# fraction of either. This script is only the measurement and the one-time
# notice; the decision and the handoff procedure belong to the supervisor and
# live in the `session-cache` agent skill, not here.
#
# Opt-in: `scan` is a silent no-op unless config/session-cache exists (absent
# means off). `show` measures on explicit request even without the file, using
# the defaults below for its advice.
#
# config/session-cache holds optional `key=value` lines; blank lines and lines
# starting with `#` are ignored, and an empty file enables every default:
#   fresh_tokens=300000     advise fresh at or above this context size
#   cold_fresh_tokens=150000 advise fresh at or above this size once the cache
#                           is cold
#   cache_ttl_minutes=60    idle time after which the cache counts as cold
#   min_idle_minutes=5      `scan` only surfaces a worker idle at least this
#                           long, so a notice lands between turns, not mid-turn
# Every value is a positive whole number. An unknown key or an invalid value
# makes both subcommands exit 2 with the offending line on stderr.
#
# Measurement (Claude workers only; other harnesses report
# `status=unsupported`): the transcript is the newest
# ~/.claude/projects/<dir>/*.jsonl, where <dir> is the worker's recorded
# worktree path with every character outside [A-Za-z0-9] replaced by `-`,
# modified no earlier than the task's current spawn_gen incarnation, so a
# reused local copy or a relaunch never reads a previous session.
# CLAUDE_CONFIG_DIR relocates ~/.claude exactly as it does for Claude Code.
# context_tokens is input_tokens + cache_creation_input_tokens +
# cache_read_input_tokens of the newest main-chain (not sidechain) assistant
# entry carrying usage. idle_seconds is the age of the transcript's last write.
# A missing transcript or usage reports `status=unknown` and no advice.
#
# show prints one line (or one JSON object with --json):
#   status=ok context_tokens=<n> idle_seconds=<n> cache=<warm|cold> advice=<continue|fresh> reason=<-|size|cold> transcript=<path>
#   status=<unknown|unsupported> detail=<why>
#
# scan visits every local ship and scout record in this home (secondmates and
# remote records are skipped). For each worker whose advice is `fresh` and
# that has been idle at least min_idle_minutes, it appends one durable `check`
# wake row whose payload is
#   check: session-cost: <task> context=<n>k idle=<n>m cache=<warm|cold> reason=<size|cold>
# and prints `actionable: <payload>`. A per-task marker
# state/.session-cost-<task> records the transcript and reason already
# surfaced, so one session crossing one threshold wakes firstmate once; a new
# reason (a cold mid-size session that grows past fresh_tokens) or a new
# transcript (a relaunch) surfaces again, while a size notice already covers
# that session going cold. Markers of tasks with no record are removed.
# FM_SESSION_COST_SECS (default 300) bounds how often scan does any work, via
# the state/.session-cost-scan mtime, so the watcher can call it every poll.
# FM_SESSION_COST_NOW overrides the clock for tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="$CONFIG/session-cache"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die_usage() { printf 'fm-session-cost: %s\n' "$1" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "fm-session-cost: jq not found" >&2; exit 1; }

FRESH_TOKENS=300000
COLD_FRESH_TOKENS=150000
CACHE_TTL_MINUTES=60
MIN_IDLE_MINUTES=5

load_config() {
  local line key value
  [ -f "$CONFIG_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    case "$line" in *=*) ;; *) die_usage "config/session-cache: not key=value: $line" ;; esac
    case "$value" in ''|*[!0-9]*|0*) die_usage "config/session-cache: not a positive whole number: $line" ;; esac
    case "$key" in
      fresh_tokens) FRESH_TOKENS=$value ;;
      cold_fresh_tokens) COLD_FRESH_TOKENS=$value ;;
      cache_ttl_minutes) CACHE_TTL_MINUTES=$value ;;
      min_idle_minutes) MIN_IDLE_MINUTES=$value ;;
      *) die_usage "config/session-cache: unknown key: $line" ;;
    esac
  done < "$CONFIG_FILE"
}

if [ "$(uname)" = Darwin ]; then
  file_mtime() { /usr/bin/stat -f %m "$1" 2>/dev/null; }
else
  file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

now_epoch() {
  case "${FM_SESSION_COST_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_SESSION_COST_NOW" ;;
  esac
}

meta_value() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1
}

# The epoch of the task's current incarnation: spawn_gen=s<epoch>.<...>.
spawn_epoch() {  # <meta>
  local gen
  gen=$(meta_value "$1" spawn_gen)
  gen=${gen#s}
  gen=${gen%%.*}
  case "$gen" in ''|*[!0-9]*) echo 0 ;; *) echo "$gen" ;; esac
}

# Newest transcript for <worktree> modified at or after <since>, or nothing.
find_transcript() {  # <worktree> <since>
  local worktree=$1 since=$2 candidate dir best='' best_m=0 m f
  for candidate in "$worktree" "$(cd "$worktree" 2>/dev/null && pwd -P)"; do
    [ -n "$candidate" ] || continue
    dir="$CLAUDE_DIR/projects/$(printf '%s' "$candidate" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
    [ -d "$dir" ] || continue
    for f in "$dir"/*.jsonl; do
      [ -f "$f" ] || continue
      m=$(file_mtime "$f") || continue
      [ "$m" -ge "$since" ] || continue
      if [ "$m" -gt "$best_m" ]; then best=$f; best_m=$m; fi
    done
  done
  [ -n "$best" ] && printf '%s\n' "$best"
}

# Context size of the newest main-chain assistant entry with usage, or nothing.
context_tokens() {  # <transcript>
  local lines
  for lines in 400 4000; do
    tail -n "$lines" "$1" 2>/dev/null | jq -Rr '
      fromjson? // empty
      | select(.type == "assistant" and (.isSidechain // false) == false)
      | .message.usage // empty
      | select((.input_tokens | type) == "number")
      | (.input_tokens + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))
    ' | tail -n 1 | grep . && return 0
  done
  return 1
}

# Sets M_STATUS M_DETAIL M_CONTEXT M_IDLE M_CACHE M_ADVICE M_REASON M_TRANSCRIPT.
measure() {  # <task-id>
  local id=$1 meta harness worktree since now m
  meta="$STATE/$id.meta"
  M_STATUS=unknown M_DETAIL='' M_CONTEXT='' M_IDLE='' M_CACHE='' M_ADVICE='' M_REASON=- M_TRANSCRIPT=''
  if [ ! -f "$meta" ]; then M_DETAIL=no-task-record; return; fi
  harness=$(meta_value "$meta" harness)
  if [ "$harness" != claude ]; then
    M_STATUS=unsupported M_DETAIL="harness-${harness:-unknown}"
    return
  fi
  worktree=$(meta_value "$meta" worktree)
  if [ -z "$worktree" ]; then M_DETAIL=no-worktree; return; fi
  since=$(spawn_epoch "$meta")
  M_TRANSCRIPT=$(find_transcript "$worktree" "$since") || true
  if [ -z "$M_TRANSCRIPT" ]; then M_DETAIL=no-transcript; return; fi
  M_CONTEXT=$(context_tokens "$M_TRANSCRIPT") || true
  if [ -z "$M_CONTEXT" ]; then M_DETAIL=no-usage; return; fi
  now=$(now_epoch)
  m=$(file_mtime "$M_TRANSCRIPT") || m=$now
  M_IDLE=$((now - m))
  [ "$M_IDLE" -ge 0 ] || M_IDLE=0
  if [ "$M_IDLE" -ge $((CACHE_TTL_MINUTES * 60)) ]; then M_CACHE=cold; else M_CACHE=warm; fi
  if [ "$M_CONTEXT" -ge "$FRESH_TOKENS" ]; then
    M_ADVICE=fresh M_REASON=size
  elif [ "$M_CACHE" = cold ] && [ "$M_CONTEXT" -ge "$COLD_FRESH_TOKENS" ]; then
    M_ADVICE=fresh M_REASON=cold
  else
    M_ADVICE='continue'
  fi
  M_STATUS=ok
}

valid_task_id() {
  case "$1" in ''|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

cmd_show() {
  local json=0 id
  if [ "${1:-}" = --json ]; then json=1; shift; fi
  [ $# -eq 1 ] || die_usage "usage: fm-session-cost.sh show [--json] <task-id>"
  id=$1
  valid_task_id "$id" || die_usage "invalid task id: $id"
  load_config
  measure "$id"
  if [ "$json" -eq 1 ]; then
    jq -cn --arg status "$M_STATUS" --arg detail "$M_DETAIL" --arg context "$M_CONTEXT" \
      --arg idle "$M_IDLE" --arg cache "$M_CACHE" --arg advice "$M_ADVICE" \
      --arg reason "$M_REASON" --arg transcript "$M_TRANSCRIPT" '
      def num: if . == "" then null else tonumber end;
      def str: if . == "" or . == "-" then null else . end;
      {status:$status, detail:($detail|str), context_tokens:($context|num),
       idle_seconds:($idle|num), cache:($cache|str), advice:($advice|str),
       reason:($reason|str), transcript:($transcript|str)}'
  elif [ "$M_STATUS" = ok ]; then
    printf 'status=ok context_tokens=%s idle_seconds=%s cache=%s advice=%s reason=%s transcript=%s\n' \
      "$M_CONTEXT" "$M_IDLE" "$M_CACHE" "$M_ADVICE" "$M_REASON" "$M_TRANSCRIPT"
  else
    printf 'status=%s detail=%s\n' "$M_STATUS" "$M_DETAIL"
  fi
}

cmd_scan() {
  local marker meta id kind fingerprint payload now last
  [ $# -eq 0 ] || die_usage "usage: fm-session-cost.sh scan"
  [ -e "$CONFIG_FILE" ] || return 0
  load_config
  now=$(now_epoch)
  last=$(file_mtime "$STATE/.session-cost-scan" 2>/dev/null || echo 0)
  [ $((now - last)) -ge "${FM_SESSION_COST_SECS:-300}" ] || return 0
  touch "$STATE/.session-cost-scan"

  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"

  for marker in "$STATE"/.session-cost-*; do
    [ -f "$marker" ] || continue
    id=${marker#"$STATE"/.session-cost-}
    [ "$id" = scan ] && continue
    [ -f "$STATE/$id.meta" ] || rm -f "$marker"
  done

  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    valid_task_id "$id" || continue
    kind=$(meta_value "$meta" kind)
    case "${kind:-ship}" in ship|scout) ;; *) continue ;; esac
    [ -z "$(meta_value "$meta" remote_host)" ] || continue
    measure "$id"
    [ "$M_STATUS" = ok ] && [ "$M_ADVICE" = fresh ] || continue
    [ "$M_IDLE" -ge $((MIN_IDLE_MINUTES * 60)) ] || continue
    fingerprint="$M_TRANSCRIPT $M_REASON"
    [ "$(cat "$STATE/.session-cost-$id" 2>/dev/null)" = "$fingerprint" ] && continue
    payload="check: session-cost: $id context=$((M_CONTEXT / 1000))k idle=$((M_IDLE / 60))m cache=$M_CACHE reason=$M_REASON"
    fm_wake_append check "session-cost:$id" "$payload" || return 1
    printf '%s\n' "$fingerprint" > "$STATE/.session-cost-$id"
    printf 'actionable: %s\n' "$payload"
  done
}

case "${1:-}" in
  show) shift; cmd_show "$@" ;;
  scan) shift; cmd_scan "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac

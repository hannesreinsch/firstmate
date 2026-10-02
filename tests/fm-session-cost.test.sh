#!/usr/bin/env bash
# Behavior tests for bin/fm-session-cost.sh: transcript measurement, advice,
# opt-in scan, the once-per-crossing notice, and config validation.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COST="$ROOT/bin/fm-session-cost.sh"
TMP_ROOT=$(fm_test_tmproot fm-session-cost)
NOW=2000000000

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/config" "$home/claude" "$home/wt-$1"
  printf '%s\n' "$home"
}

transcript_dir() {  # <home> <worktree>
  printf '%s/claude/projects/%s\n' "$1" "$(printf '%s' "$2" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
}

assistant_line() {  # <cache-read> [sidechain]
  printf '{"type":"assistant","isSidechain":%s,"message":{"usage":{"input_tokens":5,"cache_creation_input_tokens":995,"cache_read_input_tokens":%s}}}\n' \
    "${2:-false}" "$1"
}

# write_task <home> <id> <harness> <kind> <spawn-epoch>
write_task() {
  fm_write_meta "$1/state/$2.meta" \
    "window=s:fm-$2" "worktree=$1/wt-$(basename "$1")" "harness=$3" "kind=$4" \
    "spawn_gen=s$5.1.1"
}

# write_transcript <home> <name> <mtime-epoch> <line>...
write_transcript() {
  local home=$1 name=$2 epoch=$3 dir
  shift 3
  dir=$(transcript_dir "$home" "$home/wt-$(basename "$home")")
  mkdir -p "$dir"
  printf '%s\n' "$@" > "$dir/$name.jsonl"
  fm_touch_epoch "$epoch" "$dir/$name.jsonl"
}

run_cost() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" CLAUDE_CONFIG_DIR="$home/claude" FM_SESSION_COST_NOW=$NOW "$COST" "$@"
}

test_show_measures_newest_main_chain_turn() {
  local home out
  home=$(make_home show)
  write_task "$home" w1 claude ship $((NOW - 7200))
  write_transcript "$home" old $((NOW - 9000)) "$(assistant_line 900000)"
  write_transcript "$home" cur $((NOW - 60)) "$(assistant_line 100000)" "$(assistant_line 199000)" \
    "$(assistant_line 500000 true)" '{"type":"user"}'
  out=$(run_cost "$home" show w1)
  assert_contains "$out" "status=ok context_tokens=200000 idle_seconds=60 cache=warm advice=continue reason=-" \
    "show should read the newest main-chain usage of the current incarnation's transcript"
  assert_contains "$out" "/cur.jsonl" "show should name the current transcript"
  pass "show measures the newest main-chain turn of the current session"
}

test_show_advice_size_and_cold() {
  local home out
  home=$(make_home advice)
  write_task "$home" w1 claude ship 1
  write_transcript "$home" a $((NOW - 60)) "$(assistant_line 310000)"
  out=$(run_cost "$home" show w1)
  assert_contains "$out" "cache=warm advice=fresh reason=size" "a large warm session should advise fresh for size"
  write_transcript "$home" a $((NOW - 3700)) "$(assistant_line 160000)"
  out=$(run_cost "$home" show w1)
  assert_contains "$out" "cache=cold advice=fresh reason=cold" "a mid-size cold session should advise fresh"
  write_transcript "$home" a $((NOW - 3700)) "$(assistant_line 100000)"
  out=$(run_cost "$home" show w1)
  assert_contains "$out" "cache=cold advice=continue" "a small cold session is cheap to continue"
  printf 'fresh_tokens=50000\n' > "$home/config/session-cache"
  write_transcript "$home" a $((NOW - 60)) "$(assistant_line 60000)"
  out=$(run_cost "$home" show w1)
  assert_contains "$out" "advice=fresh reason=size" "the configured threshold should apply"
  pass "show advises fresh for a large or a cold mid-size session"
}

test_show_unknown_and_unsupported() {
  local home out
  home=$(make_home unknown)
  write_task "$home" w1 claude ship $((NOW - 60))
  write_transcript "$home" stale $((NOW - 600)) "$(assistant_line 400000)"
  out=$(run_cost "$home" show w1)
  assert_equals "status=unknown detail=no-transcript" "$out" \
    "a transcript older than the incarnation must not be attributed to it"
  write_task "$home" w2 codex ship 1
  out=$(run_cost "$home" show w2)
  assert_equals "status=unsupported detail=harness-codex" "$out" "a non-Claude worker is unsupported"
  out=$(run_cost "$home" show --json w2)
  assert_equals '"unsupported"' "$(printf '%s' "$out" | jq -c .status)" "json show should carry the status"
  pass "show reports unknown and unsupported sessions honestly"
}

test_scan_is_off_without_config() {
  local home out
  home=$(make_home off)
  write_task "$home" w1 claude ship 1
  write_transcript "$home" a $((NOW - 3600)) "$(assistant_line 900000)"
  out=$(run_cost "$home" scan)
  assert_equals "" "$out" "scan must be silent without config/session-cache"
  assert_absent "$home/state/.wake-queue" "scan must not queue a wake without config/session-cache"
  assert_absent "$home/state/.session-cost-w1" "scan must not write a marker without config/session-cache"
  pass "scan is a no-op unless the home opted in"
}

test_scan_surfaces_once_per_crossing() {
  local home out
  home=$(make_home scan)
  : > "$home/config/session-cache"
  write_task "$home" w1 claude ship 1
  write_task "$home" busy claude scout 1
  write_task "$home" mate claude secondmate 1
  write_transcript "$home" a $((NOW - 600)) "$(assistant_line 320000)"
  out=$(FM_SESSION_COST_SECS=0 run_cost "$home" scan)
  assert_contains "$out" "actionable: check: session-cost: w1 context=321k idle=10m cache=warm reason=size" \
    "scan should surface a large idle worker"
  assert_contains "$out" "check: session-cost: busy" "scan should cover scouts"
  assert_not_contains "$out" "mate" "scan must skip secondmates"
  assert_grep "check: session-cost: w1" "$home/state/.wake-queue" "scan should queue a durable wake row"
  out=$(FM_SESSION_COST_SECS=0 run_cost "$home" scan)
  assert_equals "" "$out" "the same crossing must not surface twice"
  write_transcript "$home" a $((NOW - 4000)) "$(assistant_line 320000)"
  out=$(FM_SESSION_COST_SECS=0 run_cost "$home" scan)
  assert_equals "" "$out" "a size notice already covers the same session going cold"
  rm -f "$home/state/busy.meta"
  out=$(FM_SESSION_COST_SECS=0 run_cost "$home" scan)
  assert_absent "$home/state/.session-cost-busy" "scan should drop markers of tasks with no record"
  pass "scan surfaces each crossing once and only for ships and scouts"
}

test_scan_waits_for_idle_and_cadence() {
  local home out
  home=$(make_home idle)
  printf 'min_idle_minutes=5\n' > "$home/config/session-cache"
  write_task "$home" w1 claude ship 1
  write_transcript "$home" a $((NOW - 30)) "$(assistant_line 320000)"
  out=$(FM_SESSION_COST_SECS=0 run_cost "$home" scan)
  assert_equals "" "$out" "a worker active within min_idle_minutes must not be surfaced"
  write_transcript "$home" a $((NOW - 400)) "$(assistant_line 320000)"
  fm_touch_epoch $((NOW - 10)) "$home/state/.session-cost-scan"
  out=$(FM_SESSION_COST_SECS=300 run_cost "$home" scan)
  assert_equals "" "$out" "scan must respect its cadence"
  out=$(FM_SESSION_COST_SECS=0 run_cost "$home" scan)
  assert_contains "$out" "check: session-cost: w1" "an idle worker should surface once the cadence allows"
  pass "scan waits for a quiet worker and its own cadence"
}

test_invalid_config_refuses() {
  local home rc
  home=$(make_home invalid)
  write_task "$home" w1 claude ship 1
  for bad in 'fresh_tokens=abc' 'fresh_tokens=0' 'nonsense=1' 'fresh_tokens'; do
    printf '%s\n' "$bad" > "$home/config/session-cache"
    rc=0
    FM_SESSION_COST_SECS=0 run_cost "$home" scan >/dev/null 2>&1 || rc=$?
    expect_code 2 "$rc" "scan with '$bad'"
    rc=0
    run_cost "$home" show w1 >/dev/null 2>&1 || rc=$?
    expect_code 2 "$rc" "show with '$bad'"
  done
  printf '# comment\n\ncold_fresh_tokens=1000\ncache_ttl_minutes=1\n' > "$home/config/session-cache"
  rc=0
  run_cost "$home" show w1 >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "comments and blank lines are allowed"
  pass "an invalid config refuses instead of guessing"
}

test_show_measures_newest_main_chain_turn
test_show_advice_size_and_cold
test_show_unknown_and_unsupported
test_scan_is_off_without_config
test_scan_surfaces_once_per_crossing
test_scan_waits_for_idle_and_cadence
test_invalid_config_refuses

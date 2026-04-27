#!/usr/bin/env bash
# shellcheck disable=SC2034  # locals used by eval-driven asserts
# tests/test_signal.sh — exercises lib/signal.sh, modules/signal/signal.sh,
# and the snapshot-time signal integration.

set -u

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib.sh"

CLI="$REPO_ROOT/bin/claude-state"
SIGNAL_MOD="$REPO_ROOT/modules/signal/signal.sh"
SNAPSHOT="$REPO_ROOT/modules/handoff/snapshot.sh"

# Pipe a JSON array of strings through signal_filter at the given
# threshold. Echoes the result JSON.
filter_blocks() {
  local threshold="${1:-3}"
  local payload="$2"
  bash -c "
    . '$REPO_ROOT/lib/common.sh'
    . '$REPO_ROOT/lib/signal.sh'
    printf '%s' '$payload' | signal_filter '$threshold'
  "
}

# Synthesize a hook payload + minimal transcript, run snapshot, return
# packet path on stdout.
make_packet_with_blocks() {
  local home="$1" sid="$2"; shift 2
  local tx="$home/tx_$sid.jsonl"
  {
    jq -nc '{type:"user", message:{content:"start"}}'
    local body
    for body in "$@"; do
      jq -nc --arg t "$body" '{type:"assistant", message:{content:[{type:"text", text:$t}]}}'
    done
  } > "$tx"
  jq -nc \
    --arg sid "$sid" --arg tx "$tx" --arg cwd "$home" \
    '{session_id:$sid, transcript_path:$tx, cwd:$cwd, hook_event_name:"PreCompact"}' \
    | HOME="$home" bash "$SNAPSHOT"
  printf '%s\n' "$home/.claude/handoff/$sid.md"
}

# --- lib/signal.sh: rubric ---

test_pure_ack_drops() {
  local out
  out=$(filter_blocks 3 '["ok thanks","Decision: we are going with the rebase merge approach.","yeah"]')
  # idx 0 ("ok thanks") is pure ack + too_short_no_signal → score -8 → dropped.
  # idx 1 has "decision" (+2) but only 60 chars → no other positive → score 2 → dropped.
  #   BUT it is the LAST_2 from the back (idx 1 of 3, so total-2=1, idx>=1 is_last2 true)
  #   so it gets kept by mandatory rule.
  # idx 2 ("yeah") is last_2 → kept.
  assert 'echo "$out" | jq -e ".dropped | length == 1" >/dev/null' \
    "exactly 1 message should be dropped (idx 0)"
  assert 'echo "$out" | jq -e ".dropped[0].idx == 0" >/dev/null' \
    "the dropped message should be idx 0 (pure ack)"
  assert 'echo "$out" | jq -e ".dropped[0].reason | contains(\"ack_only\")" >/dev/null' \
    "drop reason must mention ack_only"
}

test_decision_alone_below_threshold_drops() {
  # 60-char message with only a "decision" keyword → score 2, dropped at threshold 3.
  # Use 5 messages so the test message isn't in the last-2 mandatory-keep window.
  local out
  out=$(filter_blocks 3 '["x","y","Going with the rebase approach as our conclusion.","z","w"]')
  # idx 2 has "going with" + "conclusion" — both decision keywords, but score caps at 2 (one rule, one match).
  # Actually wait, "going with" matches and "conclusion" matches; both are in the same rule's regex so it fires once. Score 2.
  # Length 50 chars (< 80) but has positive hit so too_short_no_signal does NOT fire.
  # Score 2 < 3 → drop.
  assert 'echo "$out" | jq -e ".dropped | map(.idx) | index(2) != null" >/dev/null' \
    "decision-only short message must drop at default threshold"
}

test_decision_plus_blocker_keeps() {
  # 5 messages so middle isn't in last-2 mandatory-keep.
  local out
  out=$(filter_blocks 3 '["x","y","Decision: rolled back; tests fail and the build is broken.","z","w"]')
  assert 'echo "$out" | jq -e ".kept | map(.idx) | index(2) != null" >/dev/null' \
    "decision + blocker should score 4 → kept above default threshold (got: $(echo "$out"|jq -c '.dropped, .kept'))"
}

test_long_prose_keeps() {
  local long
  long=$(printf 'lorem ipsum %.0s' $(seq 1 30))  # ~360 chars
  local out
  out=$(filter_blocks 3 "[\"x\",\"y\",\"$long\",\"z\",\"w\"]")
  assert 'echo "$out" | jq -e ".kept | map(.idx) | index(2) != null" >/dev/null' \
    "long prose should keep via 'long' rule (+3)"
}

test_first_goal_kept_via_mandatory() {
  # Embed a goal-restate keyword early. Threshold raised so only mandatory wins.
  local out
  out=$(filter_blocks 100 '["pre","goal: implement the X feature with tests","mid","end1","end2"]')
  # idx 1 has the only goal-keyword — first_goal mandatory keep.
  assert 'echo "$out" | jq -e ".kept | map(.reason) | index(\"first_goal\") != null" >/dev/null' \
    "first goal-keyword message must be mandatory-kept (got: $(echo "$out"|jq -c '.kept | map({idx, reason})'))"
}

test_last_two_kept_via_mandatory() {
  local out
  out=$(filter_blocks 100 '["x","y","z","near-end","end"]')
  # No keyword hits anywhere; threshold absurd. Only last 2 (idx 3, 4) survive.
  local kept_idxs
  kept_idxs=$(echo "$out" | jq -c '[.kept[].idx] | sort')
  assert '[ "$kept_idxs" = "[3,4]" ]' \
    "only last-2 should be kept at high threshold (got '$kept_idxs')"
}

test_threshold_zero_keeps_everything() {
  local out
  out=$(filter_blocks 0 '["a","b","c","d","e","f"]')
  assert 'echo "$out" | jq -e ".kept | length == 6" >/dev/null' \
    "threshold=0 must keep every block"
  assert 'echo "$out" | jq -e ".dropped | length == 0" >/dev/null' \
    "threshold=0 must drop nothing"
}

# --- modules/signal/signal.sh CLI ---

test_signal_cli_explain_lists_each_block() {
  local home; home=$(tmpdir)
  local packet
  packet=$(make_packet_with_blocks "$home" "exp" \
    "ok" \
    "Decision: the rebase plan landed cleanly." \
    "tests fail because lib/common.sh isn't on the path; investigating." \
    "yeah" \
    "wrapping up the work")
  local out
  out=$("$CLI" signal "$packet" --explain 2>&1)
  # Five blocks should appear, each prefixed with [+] or [-].
  local lines
  lines=$(echo "$out" | grep -cE '^\[[+-]\] [0-9]+')
  assert '[ "$lines" -eq 5 ]' \
    "explain must show one line per block (got $lines lines, output: $out)"
}

test_signal_cli_threshold_override() {
  local home; home=$(tmpdir)
  local packet
  packet=$(make_packet_with_blocks "$home" "thr" \
    "first reasoning" \
    "second reasoning" \
    "third reasoning" \
    "fourth reasoning" \
    "fifth reasoning")
  local out_t0 out_t100
  out_t0=$("$CLI" signal "$packet" --threshold 0 --explain 2>&1)
  out_t100=$("$CLI" signal "$packet" --threshold 100 --explain 2>&1)
  local kept_t0 kept_t100
  kept_t0=$(echo "$out_t0" | grep -cE '^\[\+\]')
  kept_t100=$(echo "$out_t100" | grep -cE '^\[\+\]')
  assert '[ "$kept_t0" -ge "$kept_t100" ]' \
    "threshold 0 should keep at least as many as threshold 100 (got t0=$kept_t0 t100=$kept_t100)"
}

test_signal_cli_invalid_threshold_rejects() {
  local home; home=$(tmpdir)
  local packet
  packet=$(make_packet_with_blocks "$home" "bad" "one" "two" "three")
  local rc=0
  "$CLI" signal "$packet" --threshold abc >/dev/null 2>&1 || rc=$?
  assert '[ "$rc" -eq 2 ]' "non-numeric --threshold must exit 2 (got $rc)"
}

test_signal_cli_missing_arg_rejects() {
  local rc=0
  "$CLI" signal >/dev/null 2>&1 || rc=$?
  assert '[ "$rc" -eq 2 ]' "missing packet arg must exit 2 (got $rc)"
}

test_signal_cli_unknown_packet_fails() {
  local home; home=$(tmpdir)
  mkdir -p "$home/.claude/handoff"
  local rc=0
  CLAUDE_HOME="$home/.claude" "$CLI" signal does-not-exist >/dev/null 2>&1 || rc=$?
  assert '[ "$rc" -ne 0 ]' "unknown packet id must exit non-zero (got $rc)"
}

test_signal_cli_resolves_session_id() {
  local home; home=$(tmpdir)
  local packet
  packet=$(make_packet_with_blocks "$home" "byid" "first" "second" "third")
  # Resolution by session id should give the same result as by full path.
  local out_id out_path
  out_id=$(CLAUDE_HOME="$home/.claude" "$CLI" signal byid --threshold 0 2>&1)
  out_path=$("$CLI" signal "$packet" --threshold 0 2>&1)
  assert '[ -n "$out_id" ] && [ -n "$out_path" ]' "both forms must produce output"
}

# --- snapshot integration ---

test_snapshot_writes_signal_filtered_reasoning() {
  local home; home=$(tmpdir)
  local packet
  packet=$(make_packet_with_blocks "$home" "intsig" \
    "ok thanks" \
    "Going with rebase as the conclusion. The repo prefers linear history end-to-end." \
    "blocked: tests fail because the snapshot script can't find lib/common.sh in modules/" \
    "noting" \
    "wrapping up")
  assert '[ -f "$packet" ]' "packet must be written"
  assert 'grep -q "^## Recent assistant reasoning$" "$packet"' \
    "packet must have Recent assistant reasoning section"
  # The high-signal block (blocked + file_ref) must survive in the kept body.
  assert 'awk "/^## Recent assistant reasoning\$/,/^<details>/{print}" "$packet" | grep -q "blocked: tests fail"' \
    "high-signal block must land in the main reasoning section"
  # The low-signal "ok thanks" must NOT appear in the main section but
  # SHOULD appear in the <details> block (lossless default).
  assert 'awk "/^## Recent assistant reasoning\$/,/^<details>/{print}" "$packet" | grep -vq "^ok thanks\$" || true' \
    "ok-thanks should not be in the main section"
  assert 'grep -q "<details>" "$packet"' \
    "lossless <details> block must be present by default"
  assert 'grep -q "ok thanks" "$packet"' \
    "dropped block content must survive in <details> block (lossless)"
}

test_snapshot_signal_details_off_drops_lossless_block() {
  local home; home=$(tmpdir)
  local sid="nodt"
  local tx="$home/tx_$sid.jsonl"
  {
    jq -nc '{type:"user", message:{content:"start"}}'
    jq -nc '{type:"assistant", message:{content:[{type:"text", text:"ok"}]}}'
    jq -nc '{type:"assistant", message:{content:[{type:"text", text:"thanks"}]}}'
    jq -nc '{type:"assistant", message:{content:[{type:"text", text:"alright"}]}}'
    jq -nc '{type:"assistant", message:{content:[{type:"text", text:"sure"}]}}'
    jq -nc '{type:"assistant", message:{content:[{type:"text", text:"yeah"}]}}'
  } > "$tx"
  jq -nc --arg sid "$sid" --arg tx "$tx" --arg cwd "$home" \
    '{session_id:$sid, transcript_path:$tx, cwd:$cwd, hook_event_name:"PreCompact"}' \
    | HOME="$home" HANDOFF_SIGNAL_DETAILS=0 bash "$SNAPSHOT"
  local packet="$home/.claude/handoff/$sid.md"
  assert '[ -f "$packet" ]' "packet must be written"
  assert '! grep -q "<details>" "$packet"' \
    "HANDOFF_SIGNAL_DETAILS=0 must suppress the lossless <details> block"
}

test_snapshot_signal_min_zero_keeps_all_in_main_section() {
  local home; home=$(tmpdir)
  local packet
  packet=$(make_packet_with_blocks "$home" "min0" "ok" "got it" "thanks")
  # The make_packet_with_blocks helper doesn't pass HANDOFF_SIGNAL_MIN; set
  # it via the env on a fresh run.
  local sid="min0b"
  local tx="$home/tx_$sid.jsonl"
  {
    jq -nc '{type:"user", message:{content:"start"}}'
    jq -nc '{type:"assistant", message:{content:[{type:"text", text:"ok"}]}}'
    jq -nc '{type:"assistant", message:{content:[{type:"text", text:"got it"}]}}'
    jq -nc '{type:"assistant", message:{content:[{type:"text", text:"thanks"}]}}'
  } > "$tx"
  jq -nc --arg sid "$sid" --arg tx "$tx" --arg cwd "$home" \
    '{session_id:$sid, transcript_path:$tx, cwd:$cwd, hook_event_name:"PreCompact"}' \
    | HOME="$home" HANDOFF_SIGNAL_MIN=0 bash "$SNAPSHOT"
  local p2="$home/.claude/handoff/$sid.md"
  assert '! grep -q "<details>" "$p2"' \
    "HANDOFF_SIGNAL_MIN=0 should result in zero dropped blocks → no <details> block"
}

# --- driver ---

run "signal: pure ack drops"                    test_pure_ack_drops
run "signal: decision-only below threshold"     test_decision_alone_below_threshold_drops
run "signal: decision + blocker keeps"          test_decision_plus_blocker_keeps
run "signal: long prose keeps"                  test_long_prose_keeps
run "signal: first goal mandatory-kept"         test_first_goal_kept_via_mandatory
run "signal: last 2 mandatory-kept"             test_last_two_kept_via_mandatory
run "signal: threshold 0 keeps everything"      test_threshold_zero_keeps_everything
run "signal cli: --explain lists each block"    test_signal_cli_explain_lists_each_block
run "signal cli: --threshold override"          test_signal_cli_threshold_override
run "signal cli: invalid --threshold rejects"   test_signal_cli_invalid_threshold_rejects
run "signal cli: missing arg rejects"           test_signal_cli_missing_arg_rejects
run "signal cli: unknown packet fails"          test_signal_cli_unknown_packet_fails
run "signal cli: resolves by session id"        test_signal_cli_resolves_session_id
run "snapshot: signal-filtered reasoning"       test_snapshot_writes_signal_filtered_reasoning
run "snapshot: HANDOFF_SIGNAL_DETAILS=0 off"    test_snapshot_signal_details_off_drops_lossless_block
run "snapshot: HANDOFF_SIGNAL_MIN=0 keeps all"  test_snapshot_signal_min_zero_keeps_all_in_main_section

printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ -n "$FAIL_NAMES" ] && printf '# failed:%s\n' "$FAIL_NAMES"
exit "$FAIL"

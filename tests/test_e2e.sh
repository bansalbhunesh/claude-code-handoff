#!/usr/bin/env bash
# shellcheck disable=SC2034  # locals used by eval-driven asserts
# tests/test_e2e.sh — full snapshot → resume round-trip without Claude
# Code in the loop. Builds a synthetic JSONL transcript, runs the
# snapshot script over it, then runs the resume script and verifies the
# emitted JSON contains the expected packet sections.

set -u

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib.sh"

SNAPSHOT="$REPO_ROOT/modules/handoff/snapshot.sh"
RESUME="$REPO_ROOT/modules/handoff/resume.sh"

# Build a JSONL transcript with the shapes handoff-snapshot.sh actually
# parses out: a couple of user messages (one meta we should ignore, one
# real), an assistant text block, a TaskCreate tool_use, and an Edit
# tool_use. Pipe each `jq -nc` directly into the file rather than going
# through a shell variable.
make_full_transcript() {
  local path="$1"
  {
    # Meta user message — should be filtered out of "Original goal".
    jq -nc '{type:"user", isMeta:true, message:{content:"<meta-info>"}}'
    # First real user message — this should become the "Original goal".
    jq -nc '{type:"user", message:{content:"Implement feature X with tests"}}'
    # Assistant text block — should land in "Recent assistant reasoning".
    jq -nc '{type:"assistant", message:{content:[
      {type:"text", text:"Plan: scaffold module, then write tests."}
    ]}}'
    # Assistant tool_use: TaskCreate.
    jq -nc '{type:"assistant", message:{content:[
      {type:"tool_use", name:"TaskCreate", input:{subject:"scaffold module"}}
    ]}}'
    # Assistant tool_use: Edit.
    jq -nc '{type:"assistant", message:{content:[
      {type:"tool_use", name:"Edit", input:{file_path:"/repo/src/feature.ts"}}
    ]}}'
    # Another user message that should NOT replace the original goal.
    jq -nc '{type:"user", message:{content:"and add a README"}}'
  } > "$path"
}

# --- tests ---

test_round_trip() {
  local home; home=$(tmpdir)
  local sid="abc123e2e"
  local tx="$home/transcript.jsonl"
  make_full_transcript "$tx"

  # Run snapshot. Pipe jq directly into the script — never via $().
  jq -nc \
    --arg sid "$sid" \
    --arg tx "$tx" \
    --arg cwd "$home" \
    '{session_id:$sid, transcript_path:$tx, cwd:$cwd, hook_event_name:"PreCompact"}' \
    | HOME="$home" bash "$SNAPSHOT"

  local packet="$home/.claude/handoff/$sid.md"
  assert '[ -f "$packet" ]' "snapshot must produce a packet at $packet"

  # The packet must contain each expected section header AND each
  # expected datum.
  assert 'grep -q "^# Handoff packet" "$packet"' "packet must have header"
  assert 'grep -q "^## Original goal" "$packet"' "packet must have Original goal section"
  assert 'grep -q "Implement feature X with tests" "$packet"' \
    "packet must capture the first real user message as the goal"
  assert '! grep -q "<meta-info>" "$packet"' \
    "packet must NOT include the meta user message in the goal"
  assert 'grep -q "^## Task tracker" "$packet"' "packet must have Task tracker section"
  assert 'grep -q "scaffold module" "$packet"' \
    "packet must include the TaskCreate subject"
  assert 'grep -q "^## Recently edited files" "$packet"' \
    "packet must have Recently edited files section"
  assert 'grep -q "/repo/src/feature.ts" "$packet"' \
    "packet must include the Edit file_path"
  assert 'grep -q "^## Recent assistant reasoning" "$packet"' \
    "packet must have Recent assistant reasoning section"
  assert 'grep -q "Plan: scaffold module" "$packet"' \
    "packet must include the assistant text block"

  # Now run resume with the same session_id.
  local out
  out=$(jq -nc --arg sid "$sid" '{session_id:$sid, source:"resume"}' \
        | HOME="$home" bash "$RESUME")
  assert '[ -n "$out" ]' "resume must emit output for matching session_id"
  assert 'printf "%s" "$out" | jq -e . >/dev/null 2>&1' \
    "resume output must be valid JSON"
  local hen
  hen=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')
  assert '[ "$hen" = "SessionStart" ]' \
    "hookEventName must be SessionStart (got '$hen')"

  local ctx
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
  # The emitted additionalContext must contain the same key data the
  # packet did — proving the round trip is faithful.
  assert 'printf "%s" "$ctx" | grep -q "Implement feature X with tests"' \
    "resume context must contain the original goal"
  assert 'printf "%s" "$ctx" | grep -q "scaffold module"' \
    "resume context must contain the TaskCreate subject"
  assert 'printf "%s" "$ctx" | grep -q "/repo/src/feature.ts"' \
    "resume context must contain the edited file path"
  assert 'printf "%s" "$ctx" | grep -q "Plan: scaffold module"' \
    "resume context must contain the assistant text"
  assert 'printf "%s" "$ctx" | grep -q "Resuming after resume"' \
    "resume context must include the source-derived prelude"
  assert 'printf "%s" "$ctx" | grep -q "session $sid"' \
    "resume context must reference the prior session id"
}

# --- driver ---

run "e2e: snapshot → resume round trip" test_round_trip

printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ -n "$FAIL_NAMES" ] && printf '# failed:%s\n' "$FAIL_NAMES"
exit "$FAIL"

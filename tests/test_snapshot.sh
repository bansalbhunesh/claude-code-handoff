#!/usr/bin/env bash
# shellcheck disable=SC2034  # locals used by eval-driven asserts
# tests/test_snapshot.sh — exercises scripts/handoff-snapshot.sh.
# Each test isolates itself with a fresh HOME under mktemp -d so we
# never touch the real ~/.claude.

set -u

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib.sh"

SNAPSHOT="$REPO_ROOT/scripts/handoff-snapshot.sh"

# Helper: synthesize the PreCompact-shaped hook payload and feed it to
# the snapshot script under a sandboxed HOME. Echoes the HOME so the
# caller can inspect ~/.claude/handoff/.
# Args: <home> <session_id> <transcript_path> [event]
invoke_snapshot() {
  local home="$1" sid="$2" tx="$3" event="${4:-PreCompact}"
  jq -nc \
    --arg sid "$sid" \
    --arg tx "$tx" \
    --arg cwd "$home" \
    --arg event "$event" \
    '{session_id:$sid, transcript_path:$tx, cwd:$cwd, hook_event_name:$event}' \
    | HOME="$home" bash "$SNAPSHOT"
}

# Build a minimal valid JSONL transcript with one user message and an
# assistant text block. Used by tests that just need *some* valid input.
make_transcript() {
  local path="$1"
  {
    jq -nc '{type:"user", message:{content:"hello"}}'
    jq -nc '{type:"assistant", message:{content:[{type:"text", text:"hi"}]}}'
  } > "$path"
}

# --- tests ---

test_missing_transcript() {
  local home; home=$(tmpdir)
  invoke_snapshot "$home" "abc" "$home/does-not-exist.jsonl" || true
  # Should produce no packet because transcript file doesn't exist.
  assert '! [ -d "$home/.claude/handoff" ] || [ -z "$(ls -A "$home/.claude/handoff" 2>/dev/null)" ]' \
    "no packet should be written when transcript is missing"
}

test_empty_transcript() {
  local home; home=$(tmpdir)
  local tx="$home/empty.jsonl"
  : > "$tx"
  invoke_snapshot "$home" "session-empty" "$tx" || true
  # Empty transcript should still result in a packet (the script's jq
  # filters all degrade to "(unknown)" / "(no ...)" placeholders), but it
  # should at minimum not crash and not write anything outside handoff/.
  assert '[ -f "$home/.claude/handoff/session-empty.md" ]' \
    "empty transcript should still produce a packet"
}

test_binary_transcript() {
  local home; home=$(tmpdir)
  local tx="$home/binary.jsonl"
  # 64 bytes of pseudo-random binary, definitely not valid JSONL. We use
  # `head -c` for portability — `dd status=none` is GNU-only.
  head -c 64 /dev/urandom > "$tx" 2>/dev/null \
    || dd if=/dev/urandom of="$tx" bs=64 count=1 2>/dev/null
  invoke_snapshot "$home" "session-bin" "$tx" || true
  # Script must not error out on a non-JSONL transcript. It still creates
  # a packet (jq returns empty / placeholders for each section).
  assert '[ -f "$home/.claude/handoff/session-bin.md" ]' \
    "binary transcript should not crash; packet should still be produced"
}

test_session_id_rejects_dotdot() {
  local home; home=$(tmpdir)
  local tx="$home/tx.jsonl"
  make_transcript "$tx"
  invoke_snapshot "$home" ".." "$tx" || true
  # No file named `.md` should appear and nothing should escape handoff/.
  assert '! [ -f "$home/.claude/handoff/...md" ]' \
    "session_id '..' must be rejected"
  assert '! [ -e "$home/.claude/handoff/.." ]' \
    "session_id '..' must not produce a parent-dir traversal"
}

test_session_id_rejects_dotfile() {
  local home; home=$(tmpdir)
  local tx="$home/tx.jsonl"
  make_transcript "$tx"
  invoke_snapshot "$home" ".bashrc" "$tx" || true
  assert '! [ -f "$home/.claude/handoff/.bashrc.md" ]' \
    "session_id '.bashrc' must be rejected (regex requires alnum first char)"
}

test_session_id_rejects_semicolon() {
  local home; home=$(tmpdir)
  local tx="$home/tx.jsonl"
  make_transcript "$tx"
  invoke_snapshot "$home" "foo;rm" "$tx" || true
  # The literal filename "foo;rm.md" should not exist; the regex rejects
  # any session_id containing a `;`.
  assert '! [ -f "$home/.claude/handoff/foo;rm.md" ]' \
    "session_id with shell metachar ';' must be rejected"
}

test_packet_mode_600() {
  local home; home=$(tmpdir)
  local tx="$home/tx.jsonl"
  make_transcript "$tx"
  invoke_snapshot "$home" "abc123" "$tx" || true
  local packet="$home/.claude/handoff/abc123.md"
  assert '[ -f "$packet" ]' "packet should be created"
  local mode; mode=$(file_mode "$packet")
  # Some umasks may leave it as 600 directly; either way we want owner-only.
  assert '[ "$mode" = "600" ]' "packet mode should be 600 (got $mode)"
}

test_handoff_dir_mode_700() {
  local home; home=$(tmpdir)
  local tx="$home/tx.jsonl"
  make_transcript "$tx"
  invoke_snapshot "$home" "abc123" "$tx" || true
  local d="$home/.claude/handoff"
  assert '[ -d "$d" ]' "handoff dir should exist"
  local mode; mode=$(file_mode "$d")
  assert '[ "$mode" = "700" ]' "handoff dir mode should be 700 (got $mode)"
}

test_symlinked_handoff_dir_refused() {
  local home; home=$(tmpdir)
  local tx="$home/tx.jsonl"
  make_transcript "$tx"
  # Replace ~/.claude/handoff with a symlink to a separate target dir.
  mkdir -p "$home/.claude"
  local target; target=$(tmpdir)
  if ! mklink "$target" "$home/.claude/handoff"; then
    # Symlinks unsupported on this fs — silently skip with a passing assert.
    assert 'true' "symlinks unsupported on this filesystem; skipping"
    return 0
  fi
  invoke_snapshot "$home" "abc123" "$tx" || true
  # Nothing should be written through the symlink.
  assert '! [ -e "$target/abc123.md" ]' \
    "symlinked handoff dir must be refused; nothing written through it"
}

test_malformed_stdin_silent() {
  local home; home=$(tmpdir)
  # Garbage on stdin: not even close to JSON.
  local out; out=$(mktemp)
  printf 'this is not json at all' | HOME="$home" bash "$SNAPSHOT" > "$out" 2>&1
  local rc=$?
  assert '[ "$rc" = "0" ]' "malformed stdin should exit 0 (got $rc)"
  assert '! [ -s "$out" ] || ! grep -qi error "$out"' \
    "malformed stdin should not print errors"
  rm -f "$out"
}

test_empty_stdin_silent() {
  local home; home=$(tmpdir)
  local out; out=$(mktemp)
  : | HOME="$home" bash "$SNAPSHOT" > "$out" 2>&1
  local rc=$?
  assert '[ "$rc" = "0" ]' "empty stdin should exit 0 (got $rc)"
  assert '! [ -d "$home/.claude/handoff" ] || [ -z "$(ls -A "$home/.claude/handoff" 2>/dev/null)" ]' \
    "empty stdin should not produce any packet"
  rm -f "$out"
}

test_claude_home_override() {
  # When CLAUDE_HOME is set, the script must write to $CLAUDE_HOME/handoff,
  # not to $HOME/.claude/handoff. This was a real bug found during the v0.2.0
  # exploratory pass: install.sh honored CLAUDE_HOME but the runtime scripts
  # didn't, so a non-default install location silently broke the round trip.
  local home; home=$(tmpdir)
  local cdir; cdir=$(tmpdir)
  local tx="$home/tx.jsonl"
  make_transcript "$tx"
  jq -nc --arg sid "abc123" --arg tx "$tx" --arg cwd "$home" \
    '{session_id:$sid, transcript_path:$tx, cwd:$cwd, hook_event_name:"PreCompact"}' \
    | HOME="$home" CLAUDE_HOME="$cdir" bash "$SNAPSHOT"
  assert '[ -f "$cdir/handoff/abc123.md" ]' \
    "with CLAUDE_HOME=$cdir, packet should land at \$CLAUDE_HOME/handoff, not \$HOME/.claude/handoff"
  assert '! [ -f "$home/.claude/handoff/abc123.md" ]' \
    "with CLAUDE_HOME set, packet should NOT appear under \$HOME/.claude"
}

test_keep_n_prunes() {
  local home; home=$(tmpdir)
  local tx="$home/tx.jsonl"
  make_transcript "$tx"
  # Snapshot 5 packets with HANDOFF_KEEP_N=2; expect only the 2 newest to survive.
  for i in 1 2 3 4 5; do
    jq -nc --arg sid "k$i" --arg tx "$tx" --arg cwd "$home" \
      '{session_id:$sid, transcript_path:$tx, cwd:$cwd, hook_event_name:"PreCompact"}' \
      | HOME="$home" HANDOFF_KEEP_N=2 bash "$SNAPSHOT"
    sleep 0.05
  done
  local count; count=$(ls "$home/.claude/handoff/"*.md 2>/dev/null | wc -l | tr -d ' ')
  assert '[ "$count" = "2" ]' "HANDOFF_KEEP_N=2 should leave 2 packets (got $count)"
  assert '[ -f "$home/.claude/handoff/k5.md" ]' "newest packet (k5) should survive"
  assert '[ -f "$home/.claude/handoff/k4.md" ]' "second-newest (k4) should survive"
  assert '! [ -f "$home/.claude/handoff/k1.md" ]' "oldest (k1) should be deleted"
}

test_keep_n_invalid_is_noop() {
  local home; home=$(tmpdir)
  local tx="$home/tx.jsonl"
  make_transcript "$tx"
  jq -nc --arg sid "abc" --arg tx "$tx" --arg cwd "$home" \
    '{session_id:$sid, transcript_path:$tx, cwd:$cwd, hook_event_name:"PreCompact"}' \
    | HOME="$home" HANDOFF_KEEP_N="not-a-number" bash "$SNAPSHOT"
  assert '[ -f "$home/.claude/handoff/abc.md" ]' \
    "non-numeric HANDOFF_KEEP_N should be ignored, packet still created"
}

test_debug_log() {
  local home; home=$(tmpdir)
  local tx="$home/tx.jsonl"
  make_transcript "$tx"
  jq -nc --arg sid "dbg" --arg tx "$tx" --arg cwd "$home" \
    '{session_id:$sid, transcript_path:$tx, cwd:$cwd, hook_event_name:"PreCompact"}' \
    | HOME="$home" HANDOFF_DEBUG=1 bash "$SNAPSHOT"
  local logf="$home/.claude/handoff/.log"
  assert '[ -f "$logf" ]' "HANDOFF_DEBUG=1 should produce a .log file"
  assert 'grep -q "session=dbg" "$logf"' ".log should contain a line for the session id"
  assert 'grep -q "PreCompact" "$logf"' ".log should mention the hook event"
}

# --- driver ---

run "snapshot: missing transcript"           test_missing_transcript
run "snapshot: empty transcript"             test_empty_transcript
run "snapshot: binary transcript"            test_binary_transcript
run "snapshot: rejects session_id '..'"      test_session_id_rejects_dotdot
run "snapshot: rejects session_id '.bashrc'" test_session_id_rejects_dotfile
run "snapshot: rejects session_id 'foo;rm'"  test_session_id_rejects_semicolon
run "snapshot: CLAUDE_HOME override"         test_claude_home_override
run "snapshot: HANDOFF_KEEP_N prunes"        test_keep_n_prunes
run "snapshot: HANDOFF_KEEP_N invalid noop"  test_keep_n_invalid_is_noop
run "snapshot: HANDOFF_DEBUG writes log"     test_debug_log
run "snapshot: packet mode is 600"           test_packet_mode_600
run "snapshot: handoff dir mode is 700"      test_handoff_dir_mode_700
run "snapshot: symlinked handoff refused"    test_symlinked_handoff_dir_refused
run "snapshot: malformed stdin silent"       test_malformed_stdin_silent
run "snapshot: empty stdin silent"           test_empty_stdin_silent

printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ -n "$FAIL_NAMES" ] && printf '# failed:%s\n' "$FAIL_NAMES"
exit "$FAIL"

#!/usr/bin/env bash
# tests/test_resume.sh — exercises scripts/handoff-resume.sh.
#
# Implementation note: the resume script reads JSON on stdin and emits
# JSON on stdout (the SessionStart hookSpecificOutput shape). Earlier
# versions of this suite captured the input payload via `payload=$(jq -nc
# ...)` and then `printf '%s' "$payload" | bash $SCRIPT`, which under
# some shells re-interpreted `\n` escapes embedded in the captured
# string and produced subtly malformed JSON on stdin. To avoid that
# pitfall, every test below pipes jq's output directly into the script.

set -u

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib.sh"

RESUME="$REPO_ROOT/scripts/handoff-resume.sh"

# --- tests ---

test_no_handoff_dir() {
  local home; home=$(tmpdir)
  # No ~/.claude/handoff at all.
  local out
  out=$(jq -nc --arg sid "abc" '{session_id:$sid, source:"resume"}' \
        | HOME="$home" bash "$RESUME")
  local rc=$?
  assert '[ "$rc" = "0" ]' "should exit 0 with no handoff dir (got $rc)"
  assert '[ -z "$out" ]' "should emit no output with no handoff dir"
}

test_empty_handoff_dir() {
  local home; home=$(tmpdir)
  mkdir -p "$home/.claude/handoff"
  local out
  out=$(jq -nc --arg sid "abc" '{session_id:$sid, source:"resume"}' \
        | HOME="$home" bash "$RESUME")
  local rc=$?
  assert '[ "$rc" = "0" ]' "should exit 0 with empty handoff dir (got $rc)"
  assert '[ -z "$out" ]' "should emit no output with empty handoff dir"
}

test_session_id_match_preferred() {
  local home; home=$(tmpdir)
  mkdir -p "$home/.claude/handoff"
  # Create three packets. Make the session-id-matched one OLDER than the
  # other two, so any "fall back to mtime" bug would skip it.
  printf '# OLD MATCHED PACKET BODY\n' > "$home/.claude/handoff/abc.md"
  # touch -t YYMMDDhhmm — 2001-01-01 00:00 is far in the past.
  touch -t 200101010000 "$home/.claude/handoff/abc.md"
  printf '# NEWER OTHER\n' > "$home/.claude/handoff/zzz.md"
  printf '# NEWEST OTHER\n' > "$home/.claude/handoff/yyy.md"

  local out
  out=$(jq -nc --arg sid "abc" '{session_id:$sid, source:"resume"}' \
        | HOME="$home" bash "$RESUME")
  assert '[ -n "$out" ]' "should emit output when packet exists"
  # The output's additionalContext must reference the session-id match,
  # not the most-recently modified packet.
  local ctx
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
  assert 'printf "%s" "$ctx" | grep -q "OLD MATCHED PACKET BODY"' \
    "session_id-match should be preferred over mtime"
  assert '! printf "%s" "$ctx" | grep -q "NEWEST OTHER"' \
    "should not include NEWEST OTHER content"
}

test_fallback_to_most_recent() {
  local home; home=$(tmpdir)
  mkdir -p "$home/.claude/handoff"
  printf '# OLDER\n' > "$home/.claude/handoff/foo.md"
  touch -t 200101010000 "$home/.claude/handoff/foo.md"
  printf '# NEWEST CONTENT\n' > "$home/.claude/handoff/bar.md"

  local out
  # session_id "missing" doesn't match any packet; should fall back to
  # the most recently modified file (bar.md).
  out=$(jq -nc --arg sid "missing" '{session_id:$sid, source:"compact"}' \
        | HOME="$home" bash "$RESUME")
  assert '[ -n "$out" ]' "should emit output via mtime fallback"
  local ctx
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
  assert 'printf "%s" "$ctx" | grep -q "NEWEST CONTENT"' \
    "should fall back to newest packet on session_id miss"
}

test_valid_json_shape() {
  local home; home=$(tmpdir)
  mkdir -p "$home/.claude/handoff"
  printf '# Handoff packet\n- session: abc\n' > "$home/.claude/handoff/abc.md"

  local out
  out=$(jq -nc --arg sid "abc" '{session_id:$sid, source:"resume"}' \
        | HOME="$home" bash "$RESUME")
  # Output must parse as JSON.
  assert 'printf "%s" "$out" | jq -e . >/dev/null 2>&1' \
    "output must be valid JSON"
  # And it must have the documented hookEventName.
  local hen
  hen=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')
  assert '[ "$hen" = "SessionStart" ]' \
    "hookEventName must be 'SessionStart' (got '$hen')"
}

test_utf8_truncation_at_16000_codepoints() {
  local home; home=$(tmpdir)
  mkdir -p "$home/.claude/handoff"
  # Build a packet whose codepoint count exceeds 16000. Use a multibyte
  # emoji so we exercise the codepoint-aware slicing path (each emoji
  # is one codepoint but multiple bytes — 4 bytes for U+1F600). 17000
  # emoji = well over the 16000-codepoint cap. We use `jq -r` (raw
  # output, no JSON quoting) so the file contains the literal emoji
  # runs rather than a quoted JSON string.
  local emoji_pkt="$home/.claude/handoff/big.md"
  jq -nr --arg one '😀' --argjson n 17000 \
    '[range(0; $n)] | map($one) | join("")' > "$emoji_pkt"

  local out
  out=$(jq -nc --arg sid "big" '{session_id:$sid, source:"compact"}' \
        | HOME="$home" bash "$RESUME")
  # 1) Output must be valid JSON despite multibyte truncation boundary.
  assert 'printf "%s" "$out" | jq -e . >/dev/null 2>&1' \
    "truncated output must remain valid JSON (UTF-8-safe slicing)"
  # 2) The truncation marker must appear in additionalContext.
  local ctx
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
  assert 'printf "%s" "$ctx" | grep -q "(truncated; full packet at"' \
    "truncation marker must appear when over the cap"
}

test_small_packet_no_truncation_marker() {
  local home; home=$(tmpdir)
  mkdir -p "$home/.claude/handoff"
  printf '# Handoff packet\nsmall content\n' > "$home/.claude/handoff/abc.md"

  local out
  out=$(jq -nc --arg sid "abc" '{session_id:$sid, source:"resume"}' \
        | HOME="$home" bash "$RESUME")
  local ctx
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
  assert '! printf "%s" "$ctx" | grep -q "(truncated; full packet at"' \
    "no truncation marker on small packets"
  assert 'printf "%s" "$ctx" | grep -q "small content"' \
    "small packet content must round-trip"
}

test_symlinked_target_refused() {
  local home; home=$(tmpdir)
  mkdir -p "$home/.claude/handoff"
  # Real file we don't want exposed.
  local secret; secret=$(tmpdir)
  printf 'SECRETS\n' > "$secret/secret.md"
  if ! mklink "$secret/secret.md" "$home/.claude/handoff/abc.md"; then
    assert 'true' "symlinks unsupported; skipping"
    return 0
  fi
  # Also drop a regular fallback packet so we can confirm the symlink is
  # what's being skipped (not just "no packets at all").
  printf '# FALLBACK BODY\n' > "$home/.claude/handoff/zzz.md"

  local out
  out=$(jq -nc --arg sid "abc" '{session_id:$sid, source:"resume"}' \
        | HOME="$home" bash "$RESUME")
  if [ -z "$out" ]; then
    # Acceptable: script refused both symlink-as-match and (defensively)
    # didn't fall through. As long as SECRETS didn't escape, we're good.
    assert 'true' "no output emitted; symlink refused"
    return 0
  fi
  local ctx
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
  assert '! printf "%s" "$ctx" | grep -q "SECRETS"' \
    "symlinked packet contents must not be emitted"
}

test_symlinked_handoff_dir_refused() {
  local home; home=$(tmpdir)
  mkdir -p "$home/.claude"
  local target; target=$(tmpdir)
  printf '# DECOY\n' > "$target/abc.md"
  if ! mklink "$target" "$home/.claude/handoff"; then
    assert 'true' "symlinks unsupported; skipping"
    return 0
  fi
  local out
  out=$(jq -nc --arg sid "abc" '{session_id:$sid, source:"resume"}' \
        | HOME="$home" bash "$RESUME")
  assert '[ -z "$out" ]' "symlinked handoff dir must yield no output"
}

test_malformed_stdin_silent() {
  local home; home=$(tmpdir)
  mkdir -p "$home/.claude/handoff"
  printf '# packet\n' > "$home/.claude/handoff/abc.md"

  local out
  out=$(printf 'not json' | HOME="$home" bash "$RESUME")
  local rc=$?
  assert '[ "$rc" = "0" ]' "malformed stdin should exit 0"
  assert '[ -z "$out" ]' "malformed stdin should emit nothing"
}

test_empty_stdin_silent() {
  local home; home=$(tmpdir)
  mkdir -p "$home/.claude/handoff"
  printf '# packet\n' > "$home/.claude/handoff/abc.md"

  local out
  out=$(: | HOME="$home" bash "$RESUME")
  local rc=$?
  assert '[ "$rc" = "0" ]' "empty stdin should exit 0"
  assert '[ -z "$out" ]' "empty stdin should emit nothing"
}

# --- driver ---

run "resume: no handoff dir"                    test_no_handoff_dir
run "resume: empty handoff dir"                 test_empty_handoff_dir
run "resume: session_id match preferred"        test_session_id_match_preferred
run "resume: fallback to most-recent on miss"   test_fallback_to_most_recent
run "resume: valid JSON output shape"           test_valid_json_shape
run "resume: UTF-8 16K codepoint truncation"    test_utf8_truncation_at_16000_codepoints
run "resume: small packet no truncation marker" test_small_packet_no_truncation_marker
run "resume: symlinked packet refused"          test_symlinked_target_refused
run "resume: symlinked handoff dir refused"     test_symlinked_handoff_dir_refused
run "resume: malformed stdin silent"            test_malformed_stdin_silent
run "resume: empty stdin silent"                test_empty_stdin_silent

printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ -n "$FAIL_NAMES" ] && printf '# failed:%s\n' "$FAIL_NAMES"
exit "$FAIL"

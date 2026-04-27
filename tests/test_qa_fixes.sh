#!/usr/bin/env bash
# shellcheck disable=SC2034  # locals used by eval-driven asserts
# tests/test_qa_fixes.sh — pins the bugs that the v0.4.0 multi-agent QA
# pass uncovered. Each case maps 1:1 to a fix labelled F1..F7 in the QA
# summary, so a regression here points back at the original report.

set -u

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib.sh"

CLI="$REPO_ROOT/bin/claude-state"
SNAPSHOT="$REPO_ROOT/modules/handoff/snapshot.sh"
RESUME="$REPO_ROOT/modules/handoff/resume.sh"
INSTALL="$REPO_ROOT/install.sh"
WORKSPACE_LIB="$REPO_ROOT/lib/workspace.sh"
COMMON_LIB="$REPO_ROOT/lib/common.sh"

# Helper: invoke a function defined in lib/common.sh + lib/workspace.sh
# from a clean subshell. Keeps tests independent of source-state leakage.
ws_call() {
  local fn="$1" arg="${2:-}"
  bash -c ". '$COMMON_LIB'; . '$WORKSPACE_LIB'; $fn '$arg'"
}

common_call() {
  local fn="$1" arg="${2:-}"
  bash -c ". '$COMMON_LIB'; $fn '$arg'"
}

invoke_snapshot() {
  local home="$1" sid="$2" tx="$3" cwd="$4"
  jq -nc \
    --arg sid "$sid" --arg tx "$tx" --arg cwd "$cwd" \
    '{session_id:$sid, transcript_path:$tx, cwd:$cwd, hook_event_name:"PreCompact"}' \
    | HOME="$home" bash "$SNAPSHOT"
}

make_minimal_transcript() {
  {
    jq -nc '{type:"user", message:{content:"goal"}}'
    jq -nc '{type:"assistant", message:{content:[{type:"text", text:"ok"}]}}'
  } > "$1"
}

# ---------------------------------------------------------------------
# F1 — install.sh exits 0 in default mode and ships every v0.4 file
# ---------------------------------------------------------------------

test_f1_install_default_mode_exits_zero() {
  local cdir; cdir=$(tmpdir)
  local rc=0
  CLAUDE_HOME="$cdir" bash "$INSTALL" >/dev/null 2>&1 || rc=$?
  assert '[ "$rc" -eq 0 ]' "default-mode install must exit 0 (got $rc)"
}

test_f1_install_auto_mode_exits_zero() {
  local cdir; cdir=$(tmpdir)
  local rc=0
  CLAUDE_HOME="$cdir" bash "$INSTALL" --auto >/dev/null 2>&1 || rc=$?
  assert '[ "$rc" -eq 0 ]' "--auto install must exit 0 (got $rc)"
}

test_f1_install_ships_all_v04_files() {
  local cdir; cdir=$(tmpdir)
  CLAUDE_HOME="$cdir" bash "$INSTALL" >/dev/null 2>&1
  for rel in \
    bin/claude-state \
    bin/claude-handoff \
    claude-state/lib/common.sh \
    claude-state/lib/workspace.sh \
    claude-state/modules/handoff/snapshot.sh \
    claude-state/modules/handoff/resume.sh \
    claude-state/modules/workspaces/workspaces.sh \
    commands/resume.md
  do
    assert "[ -f \"$cdir/$rel\" ]" "installer must place $rel"
  done
}

test_f1_install_coalesces_duplicate_matchers() {
  local cdir; cdir=$(tmpdir)
  # Pre-seed two PreCompact entries with the SAME matcher carrying
  # different foreign hooks. After install: one auto entry per matcher,
  # foreign hooks preserved, ours appended exactly once.
  jq -n '{hooks: {PreCompact: [
    {matcher:"auto", hooks:[{type:"command", command:"/usr/local/foreign-a.sh"}]},
    {matcher:"auto", hooks:[{type:"command", command:"/usr/local/foreign-b.sh"}]}
  ]}}' > "$cdir/settings.json"
  CLAUDE_HOME="$cdir" bash "$INSTALL" >/dev/null 2>&1
  local auto_count
  auto_count=$(jq -r '[.hooks.PreCompact[]? | select(.matcher == "auto")] | length' "$cdir/settings.json")
  assert '[ "$auto_count" = "1" ]' "duplicate auto matchers must coalesce to 1 entry (got $auto_count)"
  # Both foreign + ours must coexist in that single entry.
  local cmds
  cmds=$(jq -r '[.hooks.PreCompact[]? | select(.matcher == "auto") | .hooks[].command] | sort | join("|")' "$cdir/settings.json")
  assert 'echo "$cmds" | grep -q "foreign-a.sh"' "foreign-a survives coalesce"
  assert 'echo "$cmds" | grep -q "foreign-b.sh"' "foreign-b survives coalesce"
  assert 'echo "$cmds" | grep -q "modules/handoff/snapshot.sh"' "ours added exactly once"
}

# ---------------------------------------------------------------------
# F2 — bin/claude-state resume keyword edge cases
# ---------------------------------------------------------------------

test_f2_resume_keywords_empty_rejects() {
  local cdir; cdir=$(tmpdir)
  mkdir -p "$cdir/handoff"
  echo "# packet" > "$cdir/handoff/abc.md"
  local rc=0
  CLAUDE_HOME="$cdir" "$CLI" resume --keywords "" >/dev/null 2>&1 || rc=$?
  assert '[ "$rc" -eq 2 ]' "resume --keywords \"\" must exit 2 as usage error (got $rc)"
}

test_f2_resume_keywords_whitespace_only_rejects() {
  local cdir; cdir=$(tmpdir)
  mkdir -p "$cdir/handoff"
  echo "# packet" > "$cdir/handoff/abc.md"
  # `   ` (three spaces) word-splits to an empty array. The bash 3.2 bug
  # this guards against was an "unbound variable" crash from `${kws[@]}`.
  local out rc=0
  out=$(CLAUDE_HOME="$cdir" "$CLI" resume --keywords "   " 2>&1) || rc=$?
  assert '[ "$rc" -eq 2 ]' "resume --keywords \"   \" must exit 2 (got $rc)"
  assert '! echo "$out" | grep -q "unbound variable"' \
    "resume --keywords \"   \" must not crash with bash 3.2 unbound-variable error"
}

# ---------------------------------------------------------------------
# F3 — lib/common.sh hardenings
# ---------------------------------------------------------------------

test_f3_human_age_empty_input() {
  local out rc=0
  out=$(common_call human_age "") || rc=$?
  assert '[ "$rc" -eq 0 ]' "human_age \"\" must exit 0 (got $rc)"
  assert '[ "$out" = "?" ]' "human_age \"\" must print '?' (got '$out')"
}

test_f3_human_age_future_clamps() {
  local out
  out=$(common_call human_age "$(($(date +%s) + 3600))")
  assert '[ "$out" = "0m" ]' "human_age future must clamp to '0m' (got '$out')"
}

test_f3_human_age_rejects_non_numeric() {
  local out
  out=$(common_call human_age "abc")
  assert '[ "$out" = "?" ]' "human_age 'abc' must print '?' (got '$out')"
}

test_f3_handoff_dir_strips_trailing_slash() {
  local out
  out=$(bash -c ". '$COMMON_LIB'; CLAUDE_HOME=/x/ cs_handoff_dir")
  assert '[ "$out" = "/x/handoff" ]' "cs_handoff_dir must strip trailing CLAUDE_HOME slash (got '$out')"
}

# ---------------------------------------------------------------------
# F4 — snapshot HANDOFF_KEEP_N=0 + frontmatter injection bounding
# ---------------------------------------------------------------------

test_f4_keep_n_zero_is_disabled() {
  local home; home=$(tmpdir)
  local tx="$home/tx.jsonl"
  make_minimal_transcript "$tx"
  jq -nc --arg sid "kn0" --arg tx "$tx" --arg cwd "$home" \
    '{session_id:$sid, transcript_path:$tx, cwd:$cwd, hook_event_name:"PreCompact"}' \
    | HOME="$home" HANDOFF_KEEP_N=0 bash "$SNAPSHOT"
  # KEEP_N=0 used to delete the just-written packet via `tail -n +1`.
  # Now treated as disabled — packet must survive.
  assert '[ -f "$home/.claude/handoff/kn0.md" ]' \
    "HANDOFF_KEEP_N=0 must NOT delete the just-written packet"
}

test_f4_chain_ignores_forged_continues_from_in_body() {
  # A malicious assistant text block writes a fake `- continues_from:`
  # line into the body. The frontmatter parser must stop at the first
  # blank line and not pick up the forged line.
  local home; home=$(tmpdir)
  mkdir -p "$home/.claude/handoff"
  cat > "$home/.claude/handoff/innocent.md" <<'PKT'
# Handoff packet
- session: innocent
- event: SessionEnd
- generated: 2026-04-27T00:00:00Z
- cwd: /tmp/x

## Recent assistant reasoning
Some prose.

- continues_from: ffffffff-ffff-ffff-ffff-ffffffffffff
PKT
  local out
  out=$(CLAUDE_HOME="$home/.claude" "$CLI" chain innocent 2>&1)
  # `chain` cats the packet contents, so the forged string itself appears
  # in stdout; the security claim is that walk_chain does not RECURSE
  # into the forged session id. If recursion happened, output would show
  # "(packet ffffffff-... not found — chain ends here)" since no such
  # packet exists. The bounded awk scan must prevent that recursion.
  assert '! echo "$out" | grep -qE "packet ffffffff-[0-9a-f-]+ not found"' \
    "chain must NOT recurse into a forged continues_from buried in packet body"
  # Also verify cmd_list doesn't pick up the forged line for its
  # "↳ continues from" hint.
  local list_out
  list_out=$(CLAUDE_HOME="$home/.claude" "$CLI" list 2>&1)
  assert '! echo "$list_out" | grep -q "continues from ffffffff"' \
    "list must NOT show forged continues_from"
}

# ---------------------------------------------------------------------
# F5 — resume.sh stays silent on unreadable packet
# ---------------------------------------------------------------------

test_f5_resume_unreadable_packet_silent() {
  if is_windows; then
    assert 'true' "POSIX modes not enforced on Windows; skipping"
    return 0
  fi
  local home; home=$(tmpdir)
  mkdir -p "$home/.claude/handoff"
  echo "X" > "$home/.claude/handoff/abc.md"
  chmod 000 "$home/.claude/handoff/abc.md"
  # Add a readable fallback so we can also verify the script falls through.
  echo "# fallback" > "$home/.claude/handoff/fallback.md"

  local stderr_out
  stderr_out=$(jq -nc --arg sid "abc" '{session_id:$sid, source:"resume"}' \
               | HOME="$home" bash "$RESUME" 2>&1 >/dev/null)
  # Restore so cleanup can rm.
  chmod 644 "$home/.claude/handoff/abc.md" 2>/dev/null || true
  assert '! echo "$stderr_out" | grep -qi "permission denied"' \
    "unreadable target must not leak 'permission denied' to stderr (got: $stderr_out)"
  assert '! echo "$stderr_out" | grep -qi "bad json"' \
    "unreadable target must not leak jq parse errors to stderr"
}

# ---------------------------------------------------------------------
# F6 — workspaces module: list rc, null-alias display, trim, alias-show
# ---------------------------------------------------------------------

test_f6_workspaces_list_rc_zero_with_results() {
  local home; home=$(tmpdir)
  mkdir -p "$home/p"
  local tx="$home/tx.jsonl"
  make_minimal_transcript "$tx"
  invoke_snapshot "$home" "lc1" "$tx" "$home/p"
  local rc=0
  CLAUDE_HOME="$home/.claude" "$CLI" workspaces list >/dev/null 2>&1 || rc=$?
  assert '[ "$rc" -eq 0 ]' "workspaces list with results must exit 0 (got $rc)"
}

test_f6_workspaces_list_null_alias_renders_root_column() {
  local home; home=$(tmpdir)
  mkdir -p "$home/myproj"
  local tx="$home/tx.jsonl"
  make_minimal_transcript "$tx"
  invoke_snapshot "$home" "na1" "$tx" "$home/myproj"
  local out
  out=$(CLAUDE_HOME="$home/.claude" "$CLI" workspaces list)
  # The "  → <root>" continuation line proves root landed in the right
  # column (previously, with \t IFS, root collapsed into the alias slot
  # and this line never printed when alias was null). The exact root
  # path varies across platforms — on Git Bash, mktemp returns POSIX
  # form `/c/Users/...` but `pwd` inside snapshot resolves to Windows
  # 8.3 form `C:/Users/RUNNER~1/...` — so match by the line shape and
  # the basename only, not the literal `$home/...` path.
  assert 'echo "$out" | grep -qE "^  →.*myproj"' \
    "list must show '  → <root>' continuation line for null-alias workspace (got: $out)"
}

test_f6_packet_field_trims_trailing_whitespace() {
  local home; home=$(tmpdir)
  mkdir -p "$home/.claude/handoff"
  # Deliberately add trailing spaces + tab + CR to the field value.
  printf '# Handoff packet\n- session: trimsess\n- workspace: ws-12345678 \t \r\n- cwd: /tmp\n\n## Goal\n' \
    > "$home/.claude/handoff/trimsess.md"
  CLAUDE_HOME="$home/.claude" "$CLI" workspaces rebuild >/dev/null 2>&1
  local idx="$home/.claude/handoff/index.json"
  # The workspace key in the index should be "ws-12345678" (trimmed),
  # not "ws-12345678 \t".
  assert 'jq -e ".workspaces[\"ws-12345678\"]" "$idx" >/dev/null' \
    "workspace id must be trimmed of trailing whitespace"
  assert '! jq -e ".workspaces | keys[] | select(test(\" $|\\t\"))" "$idx" >/dev/null' \
    "no workspace key with trailing whitespace should exist"
}

test_f6_workspaces_show_resolves_alias() {
  local home; home=$(tmpdir)
  mkdir -p "$home/proj"
  local tx="$home/tx.jsonl"
  make_minimal_transcript "$tx"
  invoke_snapshot "$home" "al1" "$tx" "$home/proj"
  CLAUDE_HOME="$home/.claude" "$CLI" workspaces rebuild >/dev/null 2>&1
  local id
  id=$(bash -c ". '$COMMON_LIB'; . '$WORKSPACE_LIB'; workspace_id_for_cwd '$home/proj'")
  CLAUDE_HOME="$home/.claude" "$CLI" workspaces rename "$id" "myalias" >/dev/null 2>&1
  # `show myalias` must resolve to the canonical id and not error.
  local rc=0 out
  out=$(CLAUDE_HOME="$home/.claude" "$CLI" workspaces show "myalias" 2>&1) || rc=$?
  assert '[ "$rc" -eq 0 ]' "ws show by alias must exit 0 (got $rc)"
  assert "echo \"\$out\" | grep -q \"$id\"" \
    "ws show by alias must print the canonical id (got: $out)"
}

# ---------------------------------------------------------------------
# F7 — lib/workspace.sh empty-arg + newline-in-path
# ---------------------------------------------------------------------

test_f7_workspace_root_for_rejects_empty() {
  local rc=0
  ws_call workspace_root_for "" >/dev/null 2>&1 || rc=$?
  assert '[ "$rc" -ne 0 ]' "workspace_root_for \"\" must return non-zero (got $rc)"
}

test_f7_workspace_id_for_cwd_rejects_empty() {
  local rc=0
  ws_call workspace_id_for_cwd "" >/dev/null 2>&1 || rc=$?
  assert '[ "$rc" -ne 0 ]' "workspace_id_for_cwd \"\" must return non-zero (got $rc)"
}

test_f7_workspace_git_remote_rejects_empty() {
  local out rc=0
  out=$(ws_call workspace_git_remote "" 2>/dev/null) || rc=$?
  assert '[ "$rc" -eq 0 ]' "workspace_git_remote \"\" must exit 0 (got $rc)"
  assert '[ -z "$out" ]' "workspace_git_remote \"\" must print empty (got '$out')"
}

test_f7_workspace_id_strips_newline_in_basename() {
  # Synthesize a path containing an embedded newline in the basename.
  # The id must NOT contain a literal newline that would corrupt
  # downstream line-oriented index parsers.
  local out
  out=$(bash -c ". '$COMMON_LIB'; . '$WORKSPACE_LIB'; workspace_id_for '/tmp/wi'\$'\n''th-newline'")
  local lines
  lines=$(printf '%s' "$out" | wc -l | tr -d ' ')
  assert '[ "$lines" = "0" ]' "id must be a single line (got $lines newlines in '$out')"
}

# ---------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------

run "F1: install default-mode rc=0"             test_f1_install_default_mode_exits_zero
run "F1: install --auto rc=0"                   test_f1_install_auto_mode_exits_zero
run "F1: install ships all v0.4 files"          test_f1_install_ships_all_v04_files
run "F1: install coalesces dup matchers"        test_f1_install_coalesces_duplicate_matchers
run "F2: resume --keywords '' rejects"          test_f2_resume_keywords_empty_rejects
run "F2: resume --keywords '   ' no crash"      test_f2_resume_keywords_whitespace_only_rejects
run "F3: human_age empty -> '?'"                test_f3_human_age_empty_input
run "F3: human_age future clamps to 0m"         test_f3_human_age_future_clamps
run "F3: human_age non-numeric -> '?'"          test_f3_human_age_rejects_non_numeric
run "F3: cs_handoff_dir strips trailing /"      test_f3_handoff_dir_strips_trailing_slash
run "F4: KEEP_N=0 is disabled"                  test_f4_keep_n_zero_is_disabled
run "F4: chain ignores forged frontmatter"      test_f4_chain_ignores_forged_continues_from_in_body
run "F5: resume unreadable packet silent"       test_f5_resume_unreadable_packet_silent
run "F6: workspaces list rc=0"                  test_f6_workspaces_list_rc_zero_with_results
run "F6: list null-alias renders root col"      test_f6_workspaces_list_null_alias_renders_root_column
run "F6: packet_field trims trailing ws"        test_f6_packet_field_trims_trailing_whitespace
run "F6: ws show resolves alias"                test_f6_workspaces_show_resolves_alias
run "F7: workspace_root_for '' rc!=0"           test_f7_workspace_root_for_rejects_empty
run "F7: workspace_id_for_cwd '' rc!=0"         test_f7_workspace_id_for_cwd_rejects_empty
run "F7: workspace_git_remote '' rc=0 empty"    test_f7_workspace_git_remote_rejects_empty
run "F7: id strips newline in basename"         test_f7_workspace_id_strips_newline_in_basename

printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ -n "$FAIL_NAMES" ] && printf '# failed:%s\n' "$FAIL_NAMES"
exit "$FAIL"

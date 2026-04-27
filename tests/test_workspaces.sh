#!/usr/bin/env bash
# shellcheck disable=SC2034  # locals used by eval-driven asserts
# tests/test_workspaces.sh — exercises lib/workspace.sh, the snapshot's
# workspace frontmatter, modules/workspaces/workspaces.sh, and the smart
# resume in bin/claude-state.

set -u

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib.sh"

CLI="$REPO_ROOT/bin/claude-state"
SNAPSHOT="$REPO_ROOT/modules/handoff/snapshot.sh"
WORKSPACE_LIB="$REPO_ROOT/lib/workspace.sh"

# Shell out into a subshell that sources the workspace lib and prints the
# id for a given path. Keeps the test driver simple and avoids state
# leaks across cases.
ws_id_for() {
  local path="$1"
  bash -c "
    . '$REPO_ROOT/lib/common.sh'
    . '$WORKSPACE_LIB'
    workspace_id_for '$path'
  "
}

ws_id_for_cwd() {
  local path="$1"
  bash -c "
    . '$REPO_ROOT/lib/common.sh'
    . '$WORKSPACE_LIB'
    workspace_id_for_cwd '$path'
  "
}

# Synthesize a hook payload and feed it to snapshot under a sandboxed HOME.
invoke_snapshot() {
  local home="$1" sid="$2" tx="$3" cwd="$4"
  jq -nc \
    --arg sid "$sid" \
    --arg tx "$tx" \
    --arg cwd "$cwd" \
    '{session_id:$sid, transcript_path:$tx, cwd:$cwd, hook_event_name:"PreCompact"}' \
    | HOME="$home" bash "$SNAPSHOT"
}

make_minimal_transcript() {
  local path="$1"
  {
    jq -nc '{type:"user", message:{content:"work goal"}}'
    jq -nc '{type:"assistant", message:{content:[{type:"text", text:"reasoning"}]}}'
  } > "$path"
}

# Like make_minimal_transcript, but the assistant text is set to the
# caller-provided body. Used to embed keyword content into a packet via
# the normal snapshot flow (rather than post-editing the packet file,
# which collides with chmod 600 + mode-700 dir on Git Bash).
make_keyword_transcript() {
  local path="$1" body="$2"
  {
    jq -nc '{type:"user", message:{content:"goal"}}'
    jq -nc --arg t "$body" '{type:"assistant", message:{content:[{type:"text", text:$t}]}}'
  } > "$path"
}

# --- workspace identity ---

test_id_outside_git_uses_cwd() {
  local home; home=$(tmpdir)
  mkdir -p "$home/myproj"
  local id
  id=$(ws_id_for_cwd "$home/myproj")
  assert '[ -n "$id" ]' "id should be non-empty"
  assert 'echo "$id" | grep -qE "^myproj-[0-9a-f]{8}$"' \
    "id should be 'myproj-<8hex>' (got '$id')"
}

test_id_inside_git_uses_toplevel() {
  command -v git >/dev/null 2>&1 || { assert 'true' "no git; skipping"; return 0; }
  local home; home=$(tmpdir)
  mkdir -p "$home/repo/sub/dir"
  ( cd "$home/repo" && git init -q && git config user.email t@t && git config user.name t \
    && git commit --allow-empty -q -m init ) || { assert 'true' "git init failed; skipping"; return 0; }
  local id_top id_sub
  id_top=$(ws_id_for_cwd "$home/repo")
  id_sub=$(ws_id_for_cwd "$home/repo/sub/dir")
  assert '[ "$id_top" = "$id_sub" ]' \
    "id should be the same from any subdir of the same repo (top=$id_top sub=$id_sub)"
  assert 'echo "$id_top" | grep -qE "^repo-[0-9a-f]{8}$"' \
    "id should be 'repo-<8hex>' (got '$id_top')"
}

test_id_distinguishes_same_basename() {
  local home; home=$(tmpdir)
  mkdir -p "$home/a/proj" "$home/b/proj"
  local id_a id_b
  id_a=$(ws_id_for_cwd "$home/a/proj")
  id_b=$(ws_id_for_cwd "$home/b/proj")
  assert '[ "$id_a" != "$id_b" ]' \
    "two cwds with same basename but different paths must have different ids ($id_a vs $id_b)"
}

test_id_sanitizes_basename() {
  local home; home=$(tmpdir)
  mkdir -p "$home/My Project!"
  local id
  id=$(ws_id_for_cwd "$home/My Project!")
  assert 'echo "$id" | grep -qE "^my-project-[0-9a-f]{8}$"' \
    "basename should lowercase + collapse non-alnum (got '$id')"
}

# --- snapshot writes workspace fields ---

test_snapshot_writes_workspace_field() {
  local home; home=$(tmpdir)
  local cwd="$home/proj"
  mkdir -p "$cwd"
  local tx="$home/tx.jsonl"
  make_minimal_transcript "$tx"
  invoke_snapshot "$home" "abcws" "$tx" "$cwd"
  local packet="$home/.claude/handoff/abcws.md"
  assert '[ -f "$packet" ]' "packet must be written"
  assert 'grep -q "^- workspace: " "$packet"' "packet must include 'workspace:' field"
  assert 'grep -q "^- workspace_root: " "$packet"' "packet must include 'workspace_root:' field"
  local expect_id
  expect_id=$(ws_id_for_cwd "$cwd")
  assert "grep -q '^- workspace: $expect_id\$' \"\$packet\"" \
    "packet's workspace field must equal workspace_id_for_cwd('$cwd')"
}

test_snapshot_skips_workspace_when_cwd_missing() {
  local home; home=$(tmpdir)
  local tx="$home/tx.jsonl"
  make_minimal_transcript "$tx"
  # Empty cwd in payload — snapshot must not crash, must not write workspace fields.
  jq -nc \
    --arg sid "nocwd" --arg tx "$tx" --arg cwd "" \
    '{session_id:$sid, transcript_path:$tx, cwd:$cwd, hook_event_name:"PreCompact"}' \
    | HOME="$home" bash "$SNAPSHOT"
  local packet="$home/.claude/handoff/nocwd.md"
  assert '[ -f "$packet" ]' "packet must still be written when cwd is empty"
  assert '! grep -q "^- workspace: " "$packet"' \
    "no workspace field should be written when cwd is empty"
}

# --- workspaces subcommand ---

test_workspaces_rebuild_groups_packets() {
  local home; home=$(tmpdir)
  mkdir -p "$home/p1" "$home/p2"
  local tx="$home/tx.jsonl"
  make_minimal_transcript "$tx"
  invoke_snapshot "$home" "s1a" "$tx" "$home/p1"
  invoke_snapshot "$home" "s1b" "$tx" "$home/p1"
  invoke_snapshot "$home" "s2a" "$tx" "$home/p2"
  CLAUDE_HOME="$home" "$CLI" workspaces rebuild >/dev/null 2>&1
  local idx="$home/handoff/index.json"
  # Snapshot writes to $home/.claude/handoff/, but CLI honors CLAUDE_HOME=$home,
  # so the workspaces module looks at $home/handoff/. Re-run workspaces against
  # the same CLAUDE_HOME the snapshot used.
  CLAUDE_HOME="$home/.claude" "$CLI" workspaces rebuild >/dev/null 2>&1
  idx="$home/.claude/handoff/index.json"
  assert '[ -f "$idx" ]' "rebuild must create index.json"
  assert 'jq -e .workspaces "$idx" >/dev/null' "index.json must have a workspaces key"
  local count
  count=$(jq -r '.workspaces | length' "$idx")
  assert '[ "$count" = "2" ]' "two distinct cwds must produce 2 workspaces (got $count)"
  # The p1 workspace must contain both s1a and s1b.
  local p1_id
  p1_id=$(ws_id_for_cwd "$home/p1")
  local p1_sessions
  p1_sessions=$(jq -r --arg w "$p1_id" '.workspaces[$w].sessions | sort | join(",")' "$idx")
  assert '[ "$p1_sessions" = "s1a,s1b" ]' \
    "p1 workspace must list s1a,s1b (got '$p1_sessions')"
}

test_workspaces_rebuild_backfills_v03_packets() {
  local home; home=$(tmpdir)
  mkdir -p "$home/.claude/handoff" "$home/legacyproj"
  # Hand-craft a v0.3 packet: has cwd: but no workspace: field.
  cat > "$home/.claude/handoff/legacy.md" <<EOF
# Handoff packet
- session: legacy
- event: SessionEnd
- generated: 2026-04-27T00:00:00Z
- cwd: $home/legacyproj

## Original goal
old packet
EOF
  CLAUDE_HOME="$home/.claude" "$CLI" workspaces rebuild >/dev/null 2>&1
  local idx="$home/.claude/handoff/index.json"
  local expect_id
  expect_id=$(ws_id_for_cwd "$home/legacyproj")
  assert "jq -e --arg w '$expect_id' '.workspaces[\$w]' \"\$idx\" >/dev/null" \
    "v0.3 packet must be backfilled into workspace '$expect_id'"
}

test_workspaces_rename_sets_alias() {
  local home; home=$(tmpdir)
  mkdir -p "$home/proj"
  local tx="$home/tx.jsonl"
  make_minimal_transcript "$tx"
  invoke_snapshot "$home" "ren1" "$tx" "$home/proj"
  CLAUDE_HOME="$home/.claude" "$CLI" workspaces rebuild >/dev/null 2>&1
  local id
  id=$(ws_id_for_cwd "$home/proj")
  CLAUDE_HOME="$home/.claude" "$CLI" workspaces rename "$id" "myalias" >/dev/null 2>&1
  local alias_val
  alias_val=$(jq -r --arg w "$id" '.workspaces[$w].alias' "$home/.claude/handoff/index.json")
  assert '[ "$alias_val" = "myalias" ]' \
    "rename should set alias to 'myalias' (got '$alias_val')"
}

test_workspaces_rename_preserved_across_rebuild() {
  local home; home=$(tmpdir)
  mkdir -p "$home/proj"
  local tx="$home/tx.jsonl"
  make_minimal_transcript "$tx"
  invoke_snapshot "$home" "ren2" "$tx" "$home/proj"
  CLAUDE_HOME="$home/.claude" "$CLI" workspaces rebuild >/dev/null 2>&1
  local id
  id=$(ws_id_for_cwd "$home/proj")
  CLAUDE_HOME="$home/.claude" "$CLI" workspaces rename "$id" "stick" >/dev/null 2>&1
  CLAUDE_HOME="$home/.claude" "$CLI" workspaces rebuild >/dev/null 2>&1
  local alias_val
  alias_val=$(jq -r --arg w "$id" '.workspaces[$w].alias' "$home/.claude/handoff/index.json")
  assert '[ "$alias_val" = "stick" ]' \
    "rebuild must preserve aliases (got '$alias_val')"
}

# --- smart resume ---

test_resume_here_finds_workspace_packet() {
  local home; home=$(tmpdir)
  mkdir -p "$home/proj"
  local tx="$home/tx.jsonl"
  make_minimal_transcript "$tx"
  invoke_snapshot "$home" "rh1" "$tx" "$home/proj"
  # cd into proj and run resume --here.
  local out
  out=$(cd "$home/proj" && CLAUDE_HOME="$home/.claude" "$CLI" resume --here 2>&1)
  assert 'echo "$out" | grep -q "claude-state resume: rh1"' \
    "resume --here must pick the workspace's packet"
}

test_resume_here_errors_when_unknown_workspace() {
  local home; home=$(tmpdir)
  # No packets at all.
  mkdir -p "$home/.claude/handoff" "$home/lonely"
  local rc=0
  ( cd "$home/lonely" && CLAUDE_HOME="$home/.claude" "$CLI" resume --here >/dev/null 2>&1 ) || rc=$?
  assert '[ "$rc" -ne 0 ]' \
    "resume --here in an unknown workspace must error (got exit $rc)"
}

test_resume_keywords_picks_highest_score() {
  local home; home=$(tmpdir)
  mkdir -p "$home/proj"
  local tx_a="$home/tx_a.jsonl"
  local tx_b="$home/tx_b.jsonl"
  local tx_c="$home/tx_c.jsonl"
  make_keyword_transcript "$tx_a" "auth bug in middleware-adjacent layer"
  make_keyword_transcript "$tx_b" "auth bug middleware fix landed"
  make_keyword_transcript "$tx_c" "unrelated rendering pipeline tweak"
  invoke_snapshot "$home" "kw_a" "$tx_a" "$home/proj"
  invoke_snapshot "$home" "kw_b" "$tx_b" "$home/proj"
  invoke_snapshot "$home" "kw_c" "$tx_c" "$home/proj"
  # Sanity: confirm each packet actually got the embedded keyword text
  # before we exercise the keyword scorer. If snapshot's transcript
  # extraction silently dropped the text (e.g. CRLF in transcript on
  # Git Bash), we want a precise error here, not a downstream
  # "no packets matched".
  assert 'grep -q "middleware-adjacent" "$home/.claude/handoff/kw_a.md"' \
    "kw_a packet must contain the embedded text 'middleware-adjacent'"
  assert 'grep -q "middleware fix landed" "$home/.claude/handoff/kw_b.md"' \
    "kw_b packet must contain the embedded text 'middleware fix landed'"
  assert 'grep -q "rendering pipeline" "$home/.claude/handoff/kw_c.md"' \
    "kw_c packet must contain the embedded text 'rendering pipeline'"
  local out
  out=$(CLAUDE_HOME="$home/.claude" "$CLI" resume --keywords "auth middleware")
  # kw_a matches "auth" + "middleware" via "middleware-adjacent" (score 2),
  # kw_b matches both (score 2), kw_c matches neither (0). Tiebreak between
  # kw_a and kw_b is recency: kw_b was snapshotted later → wins.
  assert 'echo "$out" | grep -q "claude-state resume: kw_b"' \
    "resume --keywords must pick the highest-scoring packet (kw_b)"
}

test_resume_keywords_no_hits_errors() {
  local home; home=$(tmpdir)
  mkdir -p "$home/proj"
  local tx="$home/tx.jsonl"
  make_minimal_transcript "$tx"
  invoke_snapshot "$home" "nh1" "$tx" "$home/proj"
  local rc=0
  CLAUDE_HOME="$home/.claude" "$CLI" resume --keywords "definitelynotinanypacket" >/dev/null 2>&1 || rc=$?
  assert '[ "$rc" -ne 0 ]' \
    "resume --keywords with no matches must error (got $rc)"
}

test_resume_default_falls_back_to_global_newest() {
  local home; home=$(tmpdir)
  mkdir -p "$home/known" "$home/unknown"
  local tx="$home/tx.jsonl"
  make_minimal_transcript "$tx"
  invoke_snapshot "$home" "globalnew" "$tx" "$home/known"
  # Resume from a cwd whose workspace has NO packets — must fall back to global newest.
  local out
  out=$(cd "$home/unknown" && CLAUDE_HOME="$home/.claude" "$CLI" resume 2>&1)
  assert 'echo "$out" | grep -q "claude-state resume: globalnew"' \
    "resume default must fall back to global newest when cwd workspace has no packets"
}

test_resume_specific_session_id() {
  local home; home=$(tmpdir)
  mkdir -p "$home/proj"
  local tx="$home/tx.jsonl"
  make_minimal_transcript "$tx"
  invoke_snapshot "$home" "spec1" "$tx" "$home/proj"
  invoke_snapshot "$home" "spec2" "$tx" "$home/proj"
  local out
  out=$(CLAUDE_HOME="$home/.claude" "$CLI" resume spec1)
  assert 'echo "$out" | grep -q "claude-state resume: spec1"' \
    "resume <id> must select that specific packet"
}

# --- driver ---

run "ws id: outside git uses cwd basename"        test_id_outside_git_uses_cwd
run "ws id: inside git uses toplevel"             test_id_inside_git_uses_toplevel
run "ws id: distinguishes same basename"          test_id_distinguishes_same_basename
run "ws id: sanitizes basename"                   test_id_sanitizes_basename
run "snapshot: writes workspace + workspace_root" test_snapshot_writes_workspace_field
run "snapshot: skips workspace when cwd empty"    test_snapshot_skips_workspace_when_cwd_missing
run "ws cmd: rebuild groups packets"              test_workspaces_rebuild_groups_packets
run "ws cmd: rebuild backfills v0.3 packets"      test_workspaces_rebuild_backfills_v03_packets
run "ws cmd: rename sets alias"                   test_workspaces_rename_sets_alias
run "ws cmd: rename survives rebuild"             test_workspaces_rename_preserved_across_rebuild
run "resume --here: finds workspace packet"       test_resume_here_finds_workspace_packet
run "resume --here: errors on unknown workspace"  test_resume_here_errors_when_unknown_workspace
run "resume --keywords: picks highest score"      test_resume_keywords_picks_highest_score
run "resume --keywords: no hits errors"           test_resume_keywords_no_hits_errors
run "resume default: falls back to global newest" test_resume_default_falls_back_to_global_newest
run "resume <id>: selects specific packet"        test_resume_specific_session_id

printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ -n "$FAIL_NAMES" ] && printf '# failed:%s\n' "$FAIL_NAMES"
exit "$FAIL"

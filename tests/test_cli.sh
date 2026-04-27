#!/usr/bin/env bash
# shellcheck disable=SC2034  # locals used by eval-driven asserts
# tests/test_cli.sh — exercise the bin/claude-handoff CLI end-to-end.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

CLI="$REPO_ROOT/bin/claude-handoff"

# All CLI tests run against an isolated CLAUDE_HOME so the user's real
# ~/.claude/ is untouched.

t_help_shows_usage() {
  out=$("$CLI" help 2>&1)
  assert '[ -n "$out" ]' "help should print non-empty output"
  assert 'echo "$out" | grep -q "Usage: claude-handoff"' "help should mention Usage"
  assert 'echo "$out" | grep -q "list"' "help should list 'list' subcommand"
  assert 'echo "$out" | grep -q "prune"' "help should list 'prune' subcommand"
}

t_no_args_exits_2() {
  "$CLI" >/dev/null 2>&1
  ec=$?
  assert '[ "$ec" -eq 2 ]' "no-args should exit 2 (got $ec)"
}

t_unknown_command_exits_2() {
  "$CLI" frobnicate >/dev/null 2>&1
  ec=$?
  assert '[ "$ec" -eq 2 ]' "unknown command should exit 2 (got $ec)"
}

t_path_prints_handoff_dir() {
  tmp=$(tmpdir)
  out=$(CLAUDE_HOME="$tmp" "$CLI" path)
  assert '[ "$out" = "$tmp/handoff" ]' "path should echo \$CLAUDE_HOME/handoff"
}

t_status_runs_when_uninstalled() {
  tmp=$(tmpdir)
  out=$(CLAUDE_HOME="$tmp" "$CLI" status 2>&1)
  ec=$?
  assert '[ "$ec" -eq 0 ]' "status should exit 0 even when nothing is installed (got $ec)"
  assert 'echo "$out" | grep -q "MISSING"' "status should report missing components"
}

t_list_handles_empty_dir() {
  tmp=$(tmpdir)
  mkdir -p "$tmp/handoff"
  out=$(CLAUDE_HOME="$tmp" "$CLI" list 2>&1)
  ec=$?
  assert '[ "$ec" -eq 0 ]' "list on empty dir should exit 0 (got $ec)"
  assert 'echo "$out" | grep -q "No packets"' "list should report 'No packets' on empty dir"
}

t_list_orders_newest_first() {
  tmp=$(tmpdir)
  mkdir -p "$tmp/handoff"
  echo "# old" > "$tmp/handoff/aaa.md"
  touch -t 200001010000 "$tmp/handoff/aaa.md"
  echo "# mid" > "$tmp/handoff/bbb.md"
  touch -t 201001010000 "$tmp/handoff/bbb.md"
  echo "# new" > "$tmp/handoff/ccc.md"
  touch -t 202401010000 "$tmp/handoff/ccc.md"
  out=$(CLAUDE_HOME="$tmp" "$CLI" list)
  first_id=$(echo "$out" | head -1 | awk '{print $1}')
  assert '[ "$first_id" = "ccc" ]' "list should put newest first (got '$first_id')"
}

t_view_default_picks_newest() {
  tmp=$(tmpdir)
  mkdir -p "$tmp/handoff"
  echo "# OLD CONTENT" > "$tmp/handoff/old.md"
  touch -t 200001010000 "$tmp/handoff/old.md"
  echo "# NEW CONTENT" > "$tmp/handoff/new.md"
  out=$(CLAUDE_HOME="$tmp" "$CLI" view </dev/null)
  assert 'echo "$out" | grep -q "NEW CONTENT"' "view default should show newest"
}

t_view_by_id_works() {
  tmp=$(tmpdir)
  mkdir -p "$tmp/handoff"
  echo "# WANT" > "$tmp/handoff/want.md"
  echo "# OTHER" > "$tmp/handoff/other.md"
  out=$(CLAUDE_HOME="$tmp" "$CLI" view want </dev/null)
  assert 'echo "$out" | grep -q "WANT"' "view by id should show requested packet"
}

t_view_unknown_id_fails() {
  tmp=$(tmpdir)
  mkdir -p "$tmp/handoff"
  CLAUDE_HOME="$tmp" "$CLI" view nonexistent </dev/null >/dev/null 2>&1
  ec=$?
  assert '[ "$ec" -ne 0 ]' "view of unknown id should exit non-zero (got $ec)"
}

t_prune_keep_no_op_when_under_limit() {
  tmp=$(tmpdir)
  mkdir -p "$tmp/handoff"
  echo "# a" > "$tmp/handoff/a.md"
  echo "# b" > "$tmp/handoff/b.md"
  out=$(echo y | CLAUDE_HOME="$tmp" "$CLI" prune --keep 5 2>&1)
  assert 'echo "$out" | grep -q "Nothing to prune"' "prune --keep larger than count → no-op"
  assert '[ -f "$tmp/handoff/a.md" ] && [ -f "$tmp/handoff/b.md" ]' "files should remain after no-op prune"
}

t_prune_keep_deletes_excess() {
  tmp=$(tmpdir)
  mkdir -p "$tmp/handoff"
  echo "# old" > "$tmp/handoff/old.md"
  touch -t 200001010000 "$tmp/handoff/old.md"
  echo "# mid" > "$tmp/handoff/mid.md"
  touch -t 201001010000 "$tmp/handoff/mid.md"
  echo "# new" > "$tmp/handoff/new.md"
  echo y | CLAUDE_HOME="$tmp" "$CLI" prune --keep 1 >/dev/null 2>&1
  assert '[ -f "$tmp/handoff/new.md" ]' "newest packet should survive --keep 1"
  assert '[ ! -f "$tmp/handoff/old.md" ] && [ ! -f "$tmp/handoff/mid.md" ]' "older packets should be deleted"
}

t_prune_keep_aborts_on_n() {
  tmp=$(tmpdir)
  mkdir -p "$tmp/handoff"
  echo "# old" > "$tmp/handoff/old.md"
  touch -t 200001010000 "$tmp/handoff/old.md"
  echo "# new" > "$tmp/handoff/new.md"
  echo n | CLAUDE_HOME="$tmp" "$CLI" prune --keep 1 >/dev/null 2>&1
  assert '[ -f "$tmp/handoff/old.md" ] && [ -f "$tmp/handoff/new.md" ]' "all files should remain after declining prune"
}

t_prune_rejects_bad_args() {
  tmp=$(tmpdir)
  mkdir -p "$tmp/handoff"
  CLAUDE_HOME="$tmp" "$CLI" prune --keep abc >/dev/null 2>&1
  ec=$?
  assert '[ "$ec" -eq 2 ]' "prune --keep with non-numeric arg should exit 2 (got $ec)"
  CLAUDE_HOME="$tmp" "$CLI" prune --weird >/dev/null 2>&1
  ec=$?
  assert '[ "$ec" -eq 2 ]' "prune with unknown flag should exit 2 (got $ec)"
  CLAUDE_HOME="$tmp" "$CLI" prune --older-than 7h >/dev/null 2>&1
  ec=$?
  assert '[ "$ec" -eq 2 ]' "prune --older-than 7h (hours not supported) should exit 2 (got $ec)"
}

t_search_rejects_empty_query() {
  tmp=$(tmpdir)
  mkdir -p "$tmp/handoff"
  CLAUDE_HOME="$tmp" "$CLI" search >/dev/null 2>&1
  ec=$?
  assert '[ "$ec" -eq 2 ]' "search without query should exit 2 (got $ec)"
}

t_search_finds_matches() {
  tmp=$(tmpdir)
  mkdir -p "$tmp/handoff"
  echo "auth bug in middleware" > "$tmp/handoff/aaa.md"
  echo "rendering issue in tabs" > "$tmp/handoff/bbb.md"
  out=$(CLAUDE_HOME="$tmp" "$CLI" search auth 2>/dev/null)
  assert 'echo "$out" | grep -q "aaa"' "search should locate the matching packet"
  assert 'echo "$out" | grep -q "1 packet(s) matched"' "search should report match count"
}

t_search_no_matches() {
  tmp=$(tmpdir)
  mkdir -p "$tmp/handoff"
  echo "nothing relevant" > "$tmp/handoff/aaa.md"
  CLAUDE_HOME="$tmp" "$CLI" search xyzfoobar >/dev/null 2>&1
  ec=$?
  assert '[ "$ec" -eq 1 ]' "search with no matches should exit 1 (got $ec)"
}

t_chain_walks_continues_from() {
  tmp=$(tmpdir)
  mkdir -p "$tmp/handoff"
  printf '# Handoff packet\n- session: aaa\n- continues_from: bbb\n## Original goal\nlatest\n' > "$tmp/handoff/aaa.md"
  printf '# Handoff packet\n- session: bbb\n- continues_from: ccc\n## Original goal\nmiddle\n' > "$tmp/handoff/bbb.md"
  printf '# Handoff packet\n- session: ccc\n## Original goal\nfirst\n' > "$tmp/handoff/ccc.md"
  touch -t 202001010000 "$tmp/handoff/ccc.md"
  touch -t 202101010000 "$tmp/handoff/bbb.md"
  touch -t 202201010000 "$tmp/handoff/aaa.md"
  out=$(CLAUDE_HOME="$tmp" "$CLI" chain 2>/dev/null)
  assert 'echo "$out" | grep -q "session: aaa"' "chain should include latest packet"
  assert 'echo "$out" | grep -q "session: bbb"' "chain should walk to bbb via continues_from"
  assert 'echo "$out" | grep -q "session: ccc"' "chain should walk all the way to ccc"
}

t_chain_with_explicit_id() {
  tmp=$(tmpdir)
  mkdir -p "$tmp/handoff"
  printf '# Handoff packet\n- session: aaa\n## Original goal\nstandalone\n' > "$tmp/handoff/aaa.md"
  printf '# Handoff packet\n- session: bbb\n## Original goal\nother\n' > "$tmp/handoff/bbb.md"
  out=$(CLAUDE_HOME="$tmp" "$CLI" chain bbb 2>/dev/null)
  assert 'echo "$out" | grep -q "session: bbb"' "chain bbb should print bbb"
  ! echo "$out" | grep -q "session: aaa" || exit 1
}

t_chain_missing_packet_handles_gracefully() {
  tmp=$(tmpdir)
  mkdir -p "$tmp/handoff"
  printf '# Handoff packet\n- session: aaa\n- continues_from: ghost\n## Original goal\norphan\n' > "$tmp/handoff/aaa.md"
  out=$(CLAUDE_HOME="$tmp" "$CLI" chain aaa 2>/dev/null)
  assert 'echo "$out" | grep -q "ghost"' "chain should mention the missing parent id"
  assert 'echo "$out" | grep -q "chain ends here"' "chain should indicate where it terminated"
}

t_edit_rejects_missing_arg() {
  tmp=$(tmpdir)
  mkdir -p "$tmp/handoff"
  CLAUDE_HOME="$tmp" "$CLI" edit >/dev/null 2>&1
  ec=$?
  assert '[ "$ec" -eq 2 ]' "edit without id should exit 2 (got $ec)"
}

t_edit_invokes_editor() {
  tmp=$(tmpdir)
  mkdir -p "$tmp/handoff"
  echo "# Packet" > "$tmp/handoff/aaa.md"
  # Use `true` as an editor — no-ops, but exits 0.
  EDITOR=true CLAUDE_HOME="$tmp" "$CLI" edit aaa >/dev/null 2>&1
  ec=$?
  assert '[ "$ec" -eq 0 ]' "edit with valid id and EDITOR=true should exit 0 (got $ec)"
}

t_edit_unknown_id_fails() {
  tmp=$(tmpdir)
  mkdir -p "$tmp/handoff"
  CLAUDE_HOME="$tmp" "$CLI" edit nonexistent >/dev/null 2>&1
  ec=$?
  assert '[ "$ec" -ne 0 ]' "edit of unknown id should exit non-zero (got $ec)"
}

run "cli: help shows usage"            t_help_shows_usage
run "cli: no-args exits 2"             t_no_args_exits_2
run "cli: unknown command exits 2"     t_unknown_command_exits_2
run "cli: path prints handoff dir"     t_path_prints_handoff_dir
run "cli: status runs uninstalled"     t_status_runs_when_uninstalled
run "cli: list handles empty dir"      t_list_handles_empty_dir
run "cli: list orders newest first"    t_list_orders_newest_first
run "cli: view default picks newest"   t_view_default_picks_newest
run "cli: view by id works"            t_view_by_id_works
run "cli: view unknown id fails"       t_view_unknown_id_fails
run "cli: prune --keep no-op under"    t_prune_keep_no_op_when_under_limit
run "cli: prune --keep deletes excess" t_prune_keep_deletes_excess
run "cli: prune declined aborts"       t_prune_keep_aborts_on_n
run "cli: prune rejects bad args"      t_prune_rejects_bad_args
run "cli: search rejects empty query"  t_search_rejects_empty_query
run "cli: search finds matches"        t_search_finds_matches
run "cli: search no matches exits 1"   t_search_no_matches
run "cli: chain walks continues_from"  t_chain_walks_continues_from
run "cli: chain with explicit id"      t_chain_with_explicit_id
run "cli: chain missing parent ok"     t_chain_missing_packet_handles_gracefully
run "cli: edit rejects missing arg"    t_edit_rejects_missing_arg
run "cli: edit invokes editor"         t_edit_invokes_editor
run "cli: edit unknown id fails"       t_edit_unknown_id_fails

printf '# pass=%d fail=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

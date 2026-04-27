#!/usr/bin/env bash
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

printf '# pass=%d fail=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

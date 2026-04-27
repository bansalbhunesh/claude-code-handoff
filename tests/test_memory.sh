#!/usr/bin/env bash
# shellcheck disable=SC2034  # locals used by eval-driven asserts
# tests/test_memory.sh — exercises lib/memory.sh + modules/memory/memory.sh.

set -u

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib.sh"

CLI="$REPO_ROOT/bin/claude-state"

# Run claude-state memory in a sandboxed memory dir.
run_mem() {
  local mdir="$1"; shift
  CS_MEMORY_DIR="$mdir" "$CLI" memory "$@"
}

# --- add / list / get round-trip ---

test_add_writes_frontmatter() {
  local mdir; mdir=$(tmpdir)
  echo "Body of the memory" | run_mem "$mdir" add \
    --name aaa --type feedback --description "test desc" --content -
  assert '[ -f "$mdir/aaa.md" ]' "memory file must be created"
  assert 'grep -q "^name: aaa$" "$mdir/aaa.md"' "name field must be present"
  assert 'grep -q "^type: feedback$" "$mdir/aaa.md"' "type field must be present"
  assert 'grep -q "^description: test desc$" "$mdir/aaa.md"' "description must be present"
  assert 'grep -q "^state: active$" "$mdir/aaa.md"' "state must default to active"
  assert 'grep -q "^created: " "$mdir/aaa.md"' "created timestamp must be set"
  assert 'grep -q "Body of the memory" "$mdir/aaa.md"' "body must be preserved"
}

test_add_compiles_memory_md() {
  local mdir; mdir=$(tmpdir)
  echo "body" | run_mem "$mdir" add \
    --name foo --type feedback --description "alpha" --content -
  echo "body" | run_mem "$mdir" add \
    --name bar --type project  --description "beta"  --content -
  assert '[ -f "$mdir/MEMORY.md" ]' "MEMORY.md must be auto-compiled"
  assert 'grep -q "^- \[foo\](foo.md) — alpha$" "$mdir/MEMORY.md"' "MEMORY.md must list foo"
  assert 'grep -q "^- \[bar\](bar.md) — beta$"  "$mdir/MEMORY.md"' "MEMORY.md must list bar"
}

test_add_existing_name_rejects() {
  local mdir; mdir=$(tmpdir)
  echo "body" | run_mem "$mdir" add --name dup --type x --description "v1" --content -
  local rc=0
  echo "body2" | run_mem "$mdir" add --name dup --type x --description "v2" --content - >/dev/null 2>&1 || rc=$?
  assert '[ "$rc" -ne 0 ]' "adding over existing name must fail (got $rc)"
}

test_add_invalid_name_rejects() {
  local mdir; mdir=$(tmpdir)
  local rc=0
  echo "body" | run_mem "$mdir" add --name "../etc/passwd" --type x --description d --content - >/dev/null 2>&1 || rc=$?
  assert '[ "$rc" -eq 2 ]' "traversal-y name must exit 2 (got $rc)"
}

test_get_returns_full_file() {
  local mdir; mdir=$(tmpdir)
  echo "this is the body" | run_mem "$mdir" add --name g1 --type x --description d --content -
  local out
  out=$(run_mem "$mdir" get g1)
  assert 'echo "$out" | grep -q "this is the body"' "get must return body content"
  assert 'echo "$out" | grep -q "^name: g1$"' "get must return frontmatter too"
}

test_get_missing_fails() {
  local mdir; mdir=$(tmpdir)
  local rc=0
  run_mem "$mdir" get nonexistent >/dev/null 2>&1 || rc=$?
  assert '[ "$rc" -ne 0 ]' "get on missing memory must exit non-zero"
}

test_list_filters_by_type_and_state() {
  local mdir; mdir=$(tmpdir)
  echo "body" | run_mem "$mdir" add --name fb1 --type feedback --description d1 --content -
  echo "body" | run_mem "$mdir" add --name fb2 --type feedback --description d2 --content -
  echo "body" | run_mem "$mdir" add --name pj1 --type project  --description d3 --content -
  run_mem "$mdir" archive fb2 >/dev/null
  local fb_active
  fb_active=$(run_mem "$mdir" list --type feedback --state active | awk 'NR>1 && $1 != "" {print $1}')
  assert 'echo "$fb_active" | grep -q "^fb1$"' "fb1 must be in feedback+active"
  assert '! echo "$fb_active" | grep -q "^fb2$"' "fb2 (archived) must not be in active filter"
  assert '! echo "$fb_active" | grep -q "^pj1$"' "pj1 (project) must not be in feedback filter"
}

# --- archive ---

test_archive_flips_state() {
  local mdir; mdir=$(tmpdir)
  echo "body" | run_mem "$mdir" add --name a1 --type x --description d --content -
  run_mem "$mdir" archive a1 >/dev/null
  assert 'grep -q "^state: archived$" "$mdir/a1.md"' "state must flip to archived"
  assert '[ -f "$mdir/a1.md" ]' "file must remain (archive does not delete)"
}

test_archive_drops_from_memory_md() {
  local mdir; mdir=$(tmpdir)
  echo "body" | run_mem "$mdir" add --name only --type x --description d --content -
  assert 'grep -q "only" "$mdir/MEMORY.md"' "MEMORY.md must list active memory"
  run_mem "$mdir" archive only >/dev/null
  assert '! grep -q "only" "$mdir/MEMORY.md"' "MEMORY.md must drop archived memories"
}

test_archive_missing_fails() {
  local mdir; mdir=$(tmpdir)
  local rc=0
  run_mem "$mdir" archive nope >/dev/null 2>&1 || rc=$?
  assert '[ "$rc" -ne 0 ]' "archive missing must exit non-zero"
}

# --- supersede ---

test_supersede_sets_link_and_state() {
  local mdir; mdir=$(tmpdir)
  echo "body" | run_mem "$mdir" add --name oldm --type x --description "old" --content -
  echo "body" | run_mem "$mdir" add --name newm --type x --description "new" --content -
  run_mem "$mdir" supersede oldm --by newm >/dev/null
  assert 'grep -q "^state: superseded$"      "$mdir/oldm.md"' "old must flip to superseded"
  assert 'grep -q "^superseded_by: newm$"    "$mdir/oldm.md"' "old must record superseded_by"
  assert 'grep -q "^state: active$"          "$mdir/newm.md"' "new remains active"
  # MEMORY.md should only show new (active), not old (superseded).
  assert 'grep -q "^- \[newm\]"  "$mdir/MEMORY.md"' "MEMORY.md must list new"
  assert '! grep -q "^- \[oldm\]" "$mdir/MEMORY.md"' "MEMORY.md must NOT list old (superseded)"
}

test_supersede_missing_targets_fail() {
  local mdir; mdir=$(tmpdir)
  echo "body" | run_mem "$mdir" add --name soloa --type x --description d --content -
  local rc=0
  run_mem "$mdir" supersede ghost --by soloa >/dev/null 2>&1 || rc=$?
  assert '[ "$rc" -ne 0 ]' "supersede missing-old must fail"
  rc=0
  run_mem "$mdir" supersede soloa --by ghost >/dev/null 2>&1 || rc=$?
  assert '[ "$rc" -ne 0 ]' "supersede missing-new must fail"
}

# --- query --json (the plugin contract) ---

test_query_json_schema_v1() {
  local mdir; mdir=$(tmpdir)
  echo "body" | run_mem "$mdir" add --name q1 --type feedback --description "qd" --content -
  local out
  out=$(run_mem "$mdir" query --json)
  assert 'echo "$out" | jq -e .' "query --json output must be valid JSON"
  assert 'echo "$out" | jq -e ".version == 1" >/dev/null' "version must be 1"
  assert 'echo "$out" | jq -e ".memories | type == \"array\"" >/dev/null' "memories must be an array"
  assert 'echo "$out" | jq -e ".memories[0] | has(\"name\") and has(\"type\") and has(\"description\") and has(\"state\") and has(\"created\") and has(\"created_session\") and has(\"superseded_by\") and has(\"path\")" >/dev/null' \
    "each memory entry must have all 8 contract fields"
  assert 'echo "$out" | jq -e ".memories[0].name == \"q1\"" >/dev/null' "name must round-trip"
  assert 'echo "$out" | jq -e ".memories[0].type == \"feedback\"" >/dev/null' "type must round-trip"
  assert 'echo "$out" | jq -e ".memories[0].state == \"active\"" >/dev/null' "state must default to active"
}

test_query_json_filters() {
  local mdir; mdir=$(tmpdir)
  echo "auth-related body" | run_mem "$mdir" add --name f1 --type feedback --description "auth" --content -
  echo "render body" | run_mem "$mdir" add --name p1 --type project --description "render" --content -
  local out
  out=$(run_mem "$mdir" query --type feedback --json)
  assert 'echo "$out" | jq -e ".memories | length == 1 and .[0].name == \"f1\"" >/dev/null' \
    "--type feedback must return only the feedback memory"
  out=$(run_mem "$mdir" query --keyword auth --json)
  assert 'echo "$out" | jq -e ".memories | length == 1 and .[0].name == \"f1\"" >/dev/null' \
    "--keyword must filter by file content"
}

test_query_json_legacy_origin_session_id() {
  local mdir; mdir=$(tmpdir)
  # Hand-craft a memory with the legacy `originSessionId` field (no
  # `created_session`). The contract must surface it under the
  # canonical `created_session` key.
  cat > "$mdir/legacy.md" <<EOF
---
name: legacy
description: legacy session id
type: feedback
originSessionId: ea5f8eed-4c06-4485-81fb-4b8fd5efcc4c
---

body
EOF
  local out
  out=$(run_mem "$mdir" query --json)
  assert 'echo "$out" | jq -e ".memories[] | select(.name == \"legacy\") | .created_session == \"ea5f8eed-4c06-4485-81fb-4b8fd5efcc4c\"" >/dev/null' \
    "legacy originSessionId must surface as created_session in the contract"
}

# --- rebuild-index ---

test_rebuild_index_idempotent() {
  local mdir; mdir=$(tmpdir)
  echo "body" | run_mem "$mdir" add --name r1 --type x --description d1 --content -
  echo "body" | run_mem "$mdir" add --name r2 --type y --description d2 --content -
  local before after
  before=$(cat "$mdir/MEMORY.md")
  run_mem "$mdir" rebuild-index >/dev/null
  after=$(cat "$mdir/MEMORY.md")
  assert '[ "$before" = "$after" ]' "rebuild-index must be idempotent"
}

test_rebuild_index_honors_header_footer() {
  local mdir; mdir=$(tmpdir)
  printf '# Custom header\n\n' > "$mdir/MEMORY.md.header"
  printf '\n# Custom footer\n' > "$mdir/MEMORY.md.footer"
  echo "body" | run_mem "$mdir" add --name h1 --type x --description d --content -
  assert 'head -1 "$mdir/MEMORY.md" | grep -q "Custom header"' \
    "MEMORY.md.header must be prepended"
  assert 'tail -1 "$mdir/MEMORY.md" | grep -q "Custom footer"' \
    "MEMORY.md.footer must be appended"
}

# --- malformed input ---

test_malformed_frontmatter_does_not_crash_list() {
  local mdir; mdir=$(tmpdir)
  echo "body" | run_mem "$mdir" add --name good --type x --description d --content -
  # Drop a memory file with no closing `---` — broken frontmatter.
  cat > "$mdir/broken.md" <<'EOF'
---
name: broken
description: this never closes the frontmatter

(no closing dashes; whole file is treated as frontmatter)
EOF
  local rc=0 out
  out=$(run_mem "$mdir" list 2>&1) || rc=$?
  assert '[ "$rc" -eq 0 ]' "list must not crash on malformed memory (got $rc)"
  assert 'echo "$out" | grep -q "good"' "good memory must still be listed"
}

# --- driver ---

run "memory: add writes frontmatter"            test_add_writes_frontmatter
run "memory: add auto-compiles MEMORY.md"       test_add_compiles_memory_md
run "memory: add existing name rejects"         test_add_existing_name_rejects
run "memory: add invalid name rejects"          test_add_invalid_name_rejects
run "memory: get returns full file"             test_get_returns_full_file
run "memory: get missing fails"                 test_get_missing_fails
run "memory: list filters by type and state"   test_list_filters_by_type_and_state
run "memory: archive flips state"               test_archive_flips_state
run "memory: archive drops from MEMORY.md"      test_archive_drops_from_memory_md
run "memory: archive missing fails"             test_archive_missing_fails
run "memory: supersede sets link + state"       test_supersede_sets_link_and_state
run "memory: supersede missing targets fail"    test_supersede_missing_targets_fail
run "memory: query --json schema v=1"           test_query_json_schema_v1
run "memory: query --json filters"              test_query_json_filters
run "memory: legacy originSessionId surfaces"   test_query_json_legacy_origin_session_id
run "memory: rebuild-index idempotent"          test_rebuild_index_idempotent
run "memory: rebuild-index header/footer"       test_rebuild_index_honors_header_footer
run "memory: malformed frontmatter no crash"    test_malformed_frontmatter_does_not_crash_list

printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ -n "$FAIL_NAMES" ] && printf '# failed:%s\n' "$FAIL_NAMES"
exit "$FAIL"

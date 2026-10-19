#!/usr/bin/env bash
# shellcheck disable=SC2034
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib.sh"
CLI="$REPO_ROOT/bin/claude-state"
SNAP="$REPO_ROOT/modules/handoff/snapshot.sh"
RESUME="$REPO_ROOT/modules/handoff/resume.sh"

capture() {
  jq -nc --arg sid "$2" --arg tx "$3" --arg cwd "$4" '{session_id:$sid,transcript_path:$tx,cwd:$cwd,hook_event_name:"PreCompact"}' |
    CLAUDE_HOME="$1" bash "$SNAP"
}
simple_tx() { jq -nc --arg text "$2" '{type:"user",message:{content:$text}}' > "$1"; }
restore() {
  jq -nc --arg sid "$2" --arg cwd "$3" '{session_id:$sid,cwd:$cwd,source:"startup"}' |
    CLAUDE_HOME="$1" bash "$RESUME"
}

t_project_isolation() {
  local dir; dir=$(tmpdir)
  mkdir -p "$dir/a" "$dir/b"
  simple_tx "$dir/tx" 'project A ONLY'
  capture "$dir/config" one "$dir/tx" "$dir/a"
  local out
  out=$(restore "$dir/config" missing "$dir/b")
  assert '[ -z "$out" ]' 'a different project must not receive the latest packet'
  out=$(restore "$dir/config" one "$dir/b")
  assert '[ -z "$out" ]' 'even an exact id must agree with supplied workspace'
  out=$(restore "$dir/config" missing "$dir/a")
  assert 'printf "%s" "$out" | grep -q "project A ONLY"' 'same-project startup should recover'
  local rc=0
  (cd "$dir/b" && CLAUDE_HOME="$dir/config" bash "$CLI" resume >/dev/null 2>&1) || rc=$?
  assert '[ "$rc" -ne 0 ]' 'CLI default must also refuse cross-project fallback'
}

t_traversal() {
  local dir; dir=$(tmpdir)
  mkdir -p "$dir/config/handoff"
  printf 'PRIVATE OUTSIDE CONTENT\n' > "$dir/config/outside.md"
  local out
  out=$(restore "$dir/config" ../outside '')
  assert '[ -z "$out" ]' 'untrusted session id must not escape packet directory'
}

t_unicode_budget() {
  local dir; dir=$(tmpdir)
  mkdir -p "$dir/handoff"
  jq -nr '[range(20000)] | map("😀") | join("")' > "$dir/handoff/large.md"
  local out units
  out=$(restore "$dir" large '')
  units=$(printf '%s' "$out" | jq '.hookSpecificOutput.additionalContext | explode | map(if .>65535 then 2 else 1 end) | add')
  assert '[ "$units" -le 9000 ]' 'entire supplementary-Unicode context must fit inline budget'
  assert 'printf "%s" "$out" | grep -q "Full packet:"' 'context needs an actionable full-file pointer'
}

t_latest_and_partial() {
  local dir; dir=$(tmpdir)
  simple_tx "$dir/tx" 'Build login'
  jq -nc '{type:"user",message:{content:"Correction: preserve password login"}}' >> "$dir/tx"
  printf '{"type":"assistant"' >> "$dir/tx"
  capture "$dir/config" latest "$dir/tx" "$dir"
  local packet="$dir/config/handoff/latest.md"
  assert 'grep -q "Build login" "$packet"' 'original goal survives malformed tail'
  assert 'grep -A 1 "Latest user request" "$packet" | grep -q "Correction: preserve"' 'latest steering must be captured'
}

t_real_task_ids() {
  local dir; dir=$(tmpdir)
  cat > "$dir/tx" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"create","name":"TaskCreate","input":{"subject":"Ship fix"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"create","content":"Task #42 created successfully: Ship fix"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"update","name":"TaskUpdate","input":{"taskId":"42","status":"completed"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"update","is_error":true,"content":"update failed"}]}}
JSONL
  capture "$dir/config" tasks "$dir/tx" "$dir"
  assert 'grep -q "#42. \[pending\] Ship fix" "$dir/config/handoff/tasks.md"' 'failed update must not complete the real task id'
  jq -nc '{type:"user",message:{content:[{type:"tool_result",tool_use_id:"update",content:"Updated task #42"}]}}' >> "$dir/tx"
  capture "$dir/config" tasks "$dir/tx" "$dir"
  assert 'grep -q "#42. \[completed\] Ship fix" "$dir/config/handoff/tasks.md"' 'confirmed update should complete actual id 42'
}

t_redaction() {
  local dir; dir=$(tmpdir)
  simple_tx "$dir/tx" 'API_KEY=synthetic-private-value password=synthetic-password sk-ant-abcdefghijklmnopqrstuvw'
  capture "$dir/config" filtered "$dir/tx" "$dir"
  local packet="$dir/config/handoff/filtered.md"
  assert '! grep -q "synthetic-private-value\|synthetic-password\|sk-ant-abc" "$packet"' 'common credentials must be filtered from saved packet'
  assert 'grep -q "REDACTED" "$packet"' 'redaction should be explicit'
  assert 'grep -q "synthetic-password" "$dir/tx"' 'original transcript must remain untouched'
}

t_git_drift() {
  local dir; dir=$(tmpdir)
  git init -q "$dir/project"
  git -C "$dir/project" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm initial
  simple_tx "$dir/tx" 'fix auth'
  capture "$dir/config" gitstate "$dir/tx" "$dir/project"
  git -C "$dir/project" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm next
  local out
  out=$(restore "$dir/config" gitstate "$dir/project")
  assert 'printf "%s" "$out" | grep -q "HEAD changed"' 'restore must warn when recorded commit is stale'
}

t_cli_formats_checkpoint() {
  local dir; dir=$(tmpdir)
  simple_tx "$dir/tx" 'capture before switching agents'
  local out
  out=$(CLAUDE_HOME="$dir/config" bash "$CLI" checkpoint --transcript "$dir/tx" --session manual --cwd "$dir")
  assert '[ -f "$out" ]' 'manual capture must return its actual packet path'
  out=$(cd "$dir" && CLAUDE_HOME="$dir/config" bash "$CLI" resume --json)
  assert 'printf "%s" "$out" | jq -e ".version == 1 and .session_id == \"manual\" and (.warnings|type==\"array\")" >/dev/null' 'JSON selection contract must be valid'
  out=$(cd "$dir" && CLAUDE_HOME="$dir/config" bash "$CLI" resume --path)
  assert '[ -f "$out" ]' 'path mode must print only a readable path'
}

t_quoted_install_and_migration() {
  local dir; dir=$(tmpdir)
  local config="$dir/config's space"
  mkdir -p "$config/commands"
  cp "$REPO_ROOT/assets/legacy-resume.md" "$config/commands/resume.md"
  CLAUDE_HOME="$config" bash "$REPO_ROOT/install.sh" --auto >/dev/null
  assert '[ ! -f "$config/commands/resume.md" ]' 'exact old managed command must migrate without shadowing native resume'
  assert '[ -f "$config/commands/handoff-resume.md" ]' 'new command must install'
  assert '[ -f "$config/skills/session-handoff/SKILL.md" ]' 'portable skill must install'
  simple_tx "$dir/tx" 'installed hook works'
  local cmd
  cmd=$(jq -r '.hooks.PreCompact[0].hooks[0].command' < "$config/settings.json" | tr -d '\r')
  jq -nc --arg tx "$dir/tx" --arg cwd "$dir" '{session_id:"installed",transcript_path:$tx,cwd:$cwd}' | bash -c "$cmd"
  assert '[ -f "$config/handoff/installed.md" ]' 'hook command must work with spaces and apostrophes in config path'
  CLAUDE_HOME="$config" bash "$REPO_ROOT/uninstall.sh" >/dev/null
  assert '[ -f "$config/handoff/installed.md" ]' 'normal uninstall must retain captured data'
  assert '! jq -e ".hooks.SessionStart" < "$config/settings.json" >/dev/null' 'uninstall must remove quoted hook commands'
}

t_custom_resume_preserved() {
  local dir; dir=$(tmpdir)
  mkdir -p "$dir/commands"
  printf 'custom user command\n' > "$dir/commands/resume.md"
  CLAUDE_HOME="$dir" bash "$REPO_ROOT/install.sh" >/dev/null 2>&1
  CLAUDE_HOME="$dir" bash "$REPO_ROOT/uninstall.sh" >/dev/null
  assert 'grep -q "custom user command" "$dir/commands/resume.md"' 'custom resume command must survive install and uninstall'
}

t_memory_override_and_notes() {
  local dir; dir=$(tmpdir)
  mkdir -p "$dir/project/sub" "$dir/config" "$dir/memory"
  git init -q "$dir/project"
  jq -n --arg path "$dir/memory" '{autoMemoryDirectory:$path}' > "$dir/config/settings.json"
  printf 'My hand-written instruction stays.\n' > "$dir/memory/MEMORY.md"
  (cd "$dir/project/sub" && CLAUDE_CONFIG_DIR="$dir/config" bash "$CLI" memory add --name useful --type project --description fact --content 'verified detail') >/dev/null
  assert '[ -f "$dir/memory/useful.md" ]' 'configured memory directory must apply from subdirectories'
  assert 'grep -q "My hand-written instruction stays" "$dir/memory/MEMORY.md"' 'index rebuild must preserve hand-written notes'
}

t_memory_unknown_fails_closed() {
  local dir; dir=$(tmpdir)
  local rc=0
  (cd "$dir" && CLAUDE_CONFIG_DIR="$dir/config" bash "$CLI" memory add --name x --content y >/dev/null 2>&1) || rc=$?
  assert '[ "$rc" -ne 0 ]' 'unknown host memory path must request explicit binding'
  assert '[ ! -d "$dir/config/projects" ]' 'failed discovery must not create a guessed memory store'
}

t_worktrees_and_native_memory() {
  local dir native key first second out
  dir=$(tmpdir)
  git init -q "$dir/project"
  git -C "$dir/project" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm initial
  git -C "$dir/project" worktree add -qb feature "$dir/feature"
  mkdir -p "$dir/project/sub" "$dir/feature/sub"
  native=$(cd "$dir/project" && pwd -P)
  if is_windows; then native=$(cygpath -am "$native"); fi
  key=$(printf '%s' "$native" | LC_ALL=C sed 's/[^a-zA-Z0-9]/-/g')
  mkdir -p "$dir/config/projects/$key/memory"
  # Both worktrees must resolve the same pre-existing native memory store.
  first=$(cd "$dir/project/sub" && CLAUDE_CONFIG_DIR="$dir/config" bash "$CLI" memory add --name shared --type project --description shared --content fact)
  second=$(cd "$dir/feature/sub" && CLAUDE_CONFIG_DIR="$dir/config" bash "$CLI" memory get shared)
  assert 'printf "%s" "$second" | grep -q fact' 'native memory should be shared across worktrees and subdirectories'
  simple_tx "$dir/tx" 'worktree-specific unfinished task'
  capture "$dir/config" main "$dir/tx" "$dir/project/sub"
  out=$(restore "$dir/config" other "$dir/feature/sub")
  assert '[ -z "$out" ]' 'task handoffs must remain isolated across worktrees'
  mkdir -p "$dir/config/projects/explicit-name/memory"
  (cd "$dir/feature" && CLAUDE_CONFIG_DIR="$dir/config" CLAUDE_CODE_PROJECT_DIR_NAME=explicit-name bash "$CLI" memory add --name explicit --content configured) >/dev/null
  assert '[ -f "$dir/config/projects/explicit-name/memory/explicit.md" ]' 'explicit native project directory must be respected'
}

run 'modern: automatic and CLI project isolation' t_project_isolation
run 'modern: session traversal rejected' t_traversal
run 'modern: complete Unicode context budget' t_unicode_budget
run 'modern: latest request and malformed tail' t_latest_and_partial
run 'modern: actual task ids and failed updates' t_real_task_ids
run 'modern: saved credential filtering' t_redaction
run 'modern: Git drift warning' t_git_drift
run 'modern: manual checkpoint and JSON/path export' t_cli_formats_checkpoint
run 'modern: quoted installation and legacy migration' t_quoted_install_and_migration
run 'modern: custom resume preserved' t_custom_resume_preserved
run 'modern: configured memory and manual notes' t_memory_override_and_notes
run 'modern: unknown memory store fails closed' t_memory_unknown_fails_closed
run 'modern: isolated worktree handoffs and shared native memory' t_worktrees_and_native_memory
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ -z "$FAIL_NAMES" ] || printf '# failed:%s\n' "$FAIL_NAMES"
exit "$FAIL"

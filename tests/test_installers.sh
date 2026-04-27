#!/usr/bin/env bash
# tests/test_installers.sh — exercises install.sh and uninstall.sh.
# All tests use CLAUDE_HOME=$tmp so we never touch the real ~/.claude.

set -u

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib.sh"

INSTALL="$REPO_ROOT/install.sh"
UNINSTALL="$REPO_ROOT/uninstall.sh"

# Convenience: how many entries in a hook array (jq -e returns nonzero
# on null/missing, so we use `// []`).
hooks_len() {
  local file="$1" key="$2"
  jq -r --arg k "$key" '(.hooks[$k] // []) | length' "$file"
}

# --- tests ---

test_fresh_install_no_settings() {
  local tmp; tmp=$(tmpdir)
  CLAUDE_HOME="$tmp" bash "$INSTALL" >/dev/null
  assert '[ -f "$tmp/settings.json" ]' "settings.json must be created"
  assert 'jq -e . "$tmp/settings.json" >/dev/null' "settings.json must be valid JSON"
  # PreCompact must have both auto and manual matchers wired to snapshot.
  local pc; pc=$(hooks_len "$tmp/settings.json" PreCompact)
  assert '[ "$pc" -ge 2 ]' "PreCompact should have >=2 entries (got $pc)"
  # SessionEnd should be wired.
  local se; se=$(hooks_len "$tmp/settings.json" SessionEnd)
  assert '[ "$se" -ge 1 ]' "SessionEnd should have >=1 entry (got $se)"
  # No --auto, so SessionStart must not be present (or be empty).
  local ss; ss=$(jq -r '(.hooks.SessionStart // []) | length' "$tmp/settings.json")
  assert '[ "$ss" -eq 0 ]' "SessionStart should not be installed without --auto (got $ss)"
}

test_auto_install_wires_session_start() {
  local tmp; tmp=$(tmpdir)
  CLAUDE_HOME="$tmp" bash "$INSTALL" --auto >/dev/null
  # SessionStart should have both 'compact' and 'resume' matchers.
  local matchers
  matchers=$(jq -r '[.hooks.SessionStart[]?.matcher] | sort | join(",")' "$tmp/settings.json")
  assert '[ "$matchers" = "compact,resume" ]' \
    "SessionStart matchers should be 'compact,resume' (got '$matchers')"
  # And both should point at handoff-resume.sh.
  local cmds
  cmds=$(jq -r '[.hooks.SessionStart[].hooks[].command] | unique | join(",")' "$tmp/settings.json")
  assert 'printf "%s" "$cmds" | grep -q "handoff-resume.sh"' \
    "SessionStart hooks must invoke handoff-resume.sh"
}

test_idempotent_rerun_no_diff() {
  local tmp; tmp=$(tmpdir)
  CLAUDE_HOME="$tmp" bash "$INSTALL" --auto >/dev/null
  # Take a canonical snapshot of the merged settings.
  local before; before=$(jq -S . "$tmp/settings.json")
  CLAUDE_HOME="$tmp" bash "$INSTALL" --auto >/dev/null
  local after; after=$(jq -S . "$tmp/settings.json")
  assert '[ "$before" = "$after" ]' \
    "running install --auto twice must produce identical settings.json"
}

test_mode_toggle_strips_session_start() {
  local tmp; tmp=$(tmpdir)
  # Start in auto mode (SessionStart wired).
  CLAUDE_HOME="$tmp" bash "$INSTALL" --auto >/dev/null
  local ss_before
  ss_before=$(jq -r '(.hooks.SessionStart // []) | length' "$tmp/settings.json")
  assert '[ "$ss_before" -ge 2 ]' "auto mode should install SessionStart"
  # Toggle off by re-running without --auto.
  CLAUDE_HOME="$tmp" bash "$INSTALL" >/dev/null
  local ss_after
  ss_after=$(jq -r '(.hooks.SessionStart // []) | length' "$tmp/settings.json")
  assert '[ "$ss_after" -eq 0 ]' \
    "manual-mode rerun must remove SessionStart (got $ss_after)"
}

test_mode_toggle_preserves_third_party_session_start() {
  local tmp; tmp=$(tmpdir)
  CLAUDE_HOME="$tmp" bash "$INSTALL" --auto >/dev/null
  # Inject a third-party SessionStart hook with a different command.
  local injected="$tmp/settings.json.injected"
  jq '.hooks.SessionStart += [{matcher:"startup", hooks:[{type:"command", command:"/usr/local/bin/other-tool.sh"}]}]' \
    "$tmp/settings.json" > "$injected"
  mv "$injected" "$tmp/settings.json"
  # Toggle to manual mode.
  CLAUDE_HOME="$tmp" bash "$INSTALL" >/dev/null
  # Third-party hook must survive.
  local survivors
  survivors=$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command] | join(",")' "$tmp/settings.json")
  assert 'printf "%s" "$survivors" | grep -q "other-tool.sh"' \
    "third-party SessionStart hook must survive mode toggle"
  # And our resume hooks must be gone.
  assert '! printf "%s" "$survivors" | grep -q "handoff-resume.sh"' \
    "our handoff-resume.sh must be removed by toggle"
}

test_third_party_precompact_preserved() {
  local tmp; tmp=$(tmpdir)
  # Pre-seed settings with a foreign PreCompact hook.
  mkdir -p "$tmp"
  jq -n '{hooks: {PreCompact: [{matcher:"manual", hooks:[{type:"command", command:"/usr/local/bin/other-precompact.sh"}]}]}}' \
    > "$tmp/settings.json"
  CLAUDE_HOME="$tmp" bash "$INSTALL" >/dev/null
  local cmds
  cmds=$(jq -r '[.hooks.PreCompact[]?.hooks[]?.command] | join(",")' "$tmp/settings.json")
  assert 'printf "%s" "$cmds" | grep -q "other-precompact.sh"' \
    "third-party PreCompact hook must be preserved alongside ours"
  assert 'printf "%s" "$cmds" | grep -q "handoff-snapshot.sh"' \
    "our handoff-snapshot.sh must also be installed"
}

test_full_uninstall_preserves_third_party() {
  local tmp; tmp=$(tmpdir)
  # Seed with a foreign hook on every event we touch.
  jq -n '{hooks: {
    PreCompact: [{matcher:"auto", hooks:[{type:"command", command:"/usr/local/bin/foreign-pc.sh"}]}],
    SessionEnd: [{hooks:[{type:"command", command:"/usr/local/bin/foreign-se.sh"}]}],
    SessionStart: [{matcher:"startup", hooks:[{type:"command", command:"/usr/local/bin/foreign-ss.sh"}]}]
  }}' > "$tmp/settings.json"
  CLAUDE_HOME="$tmp" bash "$INSTALL" --auto >/dev/null
  CLAUDE_HOME="$tmp" bash "$UNINSTALL" >/dev/null
  # All foreign commands must still be present.
  local all
  all=$(jq -r '[.hooks[]?[]?.hooks[]?.command] | join(",")' "$tmp/settings.json")
  assert 'printf "%s" "$all" | grep -q "foreign-pc.sh"' \
    "uninstall must preserve foreign PreCompact"
  assert 'printf "%s" "$all" | grep -q "foreign-se.sh"' \
    "uninstall must preserve foreign SessionEnd"
  assert 'printf "%s" "$all" | grep -q "foreign-ss.sh"' \
    "uninstall must preserve foreign SessionStart"
  # And none of ours must remain.
  assert '! printf "%s" "$all" | grep -q "handoff-snapshot.sh"' \
    "uninstall must remove handoff-snapshot.sh references"
  assert '! printf "%s" "$all" | grep -q "handoff-resume.sh"' \
    "uninstall must remove handoff-resume.sh references"
}

test_uninstall_anchored_regex_doesnt_strip_lookalikes() {
  local tmp; tmp=$(tmpdir)
  # Foreign command whose path *contains* "handoff-snapshot.sh" but
  # doesn't end with one of our anchored filenames in the expected dir.
  # The uninstaller's regex is `/handoff-(snapshot|resume)\.sh$` so any
  # path that ends with that filename gets stripped — but a different
  # filename entirely like `my-handoff-snapshot.sh` should not, because
  # the leading `/` requires a path-segment boundary.
  jq -n '{hooks: {PreCompact: [{matcher:"auto", hooks:[
    {type:"command", command:"/usr/local/my-handoff-snapshot.sh"}
  ]}]}}' > "$tmp/settings.json"
  CLAUDE_HOME="$tmp" bash "$UNINSTALL" >/dev/null
  local cmds
  cmds=$(jq -r '[.hooks.PreCompact[]?.hooks[]?.command] | join(",")' "$tmp/settings.json")
  assert 'printf "%s" "$cmds" | grep -q "my-handoff-snapshot.sh"' \
    "uninstall must not strip /usr/local/my-handoff-snapshot.sh lookalike"
}

test_install_fails_cleanly_on_malformed_json() {
  local tmp; tmp=$(tmpdir)
  # Write deliberately malformed JSON (unterminated object, garbage
  # content). install.sh runs jq on this and must fail, leaving the
  # original bytes untouched and no .tmp dropping.
  local sentinel='{this is not valid json'
  printf '%s' "$sentinel" > "$tmp/settings.json"
  local rc=0
  CLAUDE_HOME="$tmp" bash "$INSTALL" >/dev/null 2>&1 || rc=$?
  assert '[ "$rc" -ne 0 ]' "install must exit non-zero on malformed settings.json (got $rc)"
  # Original file untouched.
  local content; content=$(cat "$tmp/settings.json")
  assert '[ "$content" = "$sentinel" ]' \
    "malformed settings.json must be left untouched on failure"
  # No .tmp leak. mktemp template uses settings.json.tmp.XXXXXX, so any
  # leftover file would match the glob below.
  local leaks; leaks=$(ls "$tmp"/settings.json.tmp.* 2>/dev/null || true)
  assert '[ -z "$leaks" ]' "no .tmp leak after failed install (found: $leaks)"
}

test_no_backup_spam_on_noop_rerun() {
  local tmp; tmp=$(tmpdir)
  CLAUDE_HOME="$tmp" bash "$INSTALL" --auto >/dev/null
  # Count backups after the first install (there might be one if the
  # initial settings.json was {} — that's expected).
  local b1; b1=$(ls "$tmp"/settings.json.backup-* 2>/dev/null | wc -l | tr -d ' ')
  # Re-run install --auto. Settings are unchanged, so no new backup.
  CLAUDE_HOME="$tmp" bash "$INSTALL" --auto >/dev/null
  local b2; b2=$(ls "$tmp"/settings.json.backup-* 2>/dev/null | wc -l | tr -d ' ')
  assert '[ "$b1" = "$b2" ]' \
    "no-op rerun must not create a new backup (b1=$b1 b2=$b2)"
}

test_handoff_dir_mode_700_after_install() {
  local tmp; tmp=$(tmpdir)
  CLAUDE_HOME="$tmp" bash "$INSTALL" >/dev/null
  assert '[ -d "$tmp/handoff" ]' "install must create handoff/"
  local mode; mode=$(file_mode "$tmp/handoff")
  assert '[ "$mode" = "700" ]' "handoff/ must be mode 700 (got $mode)"
}

test_install_rejects_extra_args() {
  local tmp; tmp=$(tmpdir)
  local rc=0
  CLAUDE_HOME="$tmp" bash "$INSTALL" --auto extra >/dev/null 2>&1 || rc=$?
  assert '[ "$rc" -eq 2 ]' "install with extra arg must exit 2 (got $rc)"
  local rc2=0
  CLAUDE_HOME="$tmp" bash "$INSTALL" --not-a-flag >/dev/null 2>&1 || rc2=$?
  assert '[ "$rc2" -eq 2 ]' "install with unknown flag must exit 2 (got $rc2)"
}

# --- driver ---

run "install: fresh, no settings.json"               test_fresh_install_no_settings
run "install: --auto wires SessionStart"             test_auto_install_wires_session_start
run "install: idempotent re-run, no diff"            test_idempotent_rerun_no_diff
run "install: mode toggle strips SessionStart"       test_mode_toggle_strips_session_start
run "install: mode toggle preserves 3rd-party SS"    test_mode_toggle_preserves_third_party_session_start
run "install: 3rd-party PreCompact preserved"        test_third_party_precompact_preserved
run "uninstall: preserves 3rd-party hooks"           test_full_uninstall_preserves_third_party
run "uninstall: anchored regex skips lookalikes"     test_uninstall_anchored_regex_doesnt_strip_lookalikes
run "install: malformed settings.json fails clean"   test_install_fails_cleanly_on_malformed_json
run "install: no backup spam on no-op rerun"         test_no_backup_spam_on_noop_rerun
run "install: handoff dir mode 700"                  test_handoff_dir_mode_700_after_install
run "install: rejects extra args"                    test_install_rejects_extra_args

printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ -n "$FAIL_NAMES" ] && printf '# failed:%s\n' "$FAIL_NAMES"
exit "$FAIL"

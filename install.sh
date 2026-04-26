#!/usr/bin/env bash
# Installs claude-code-handoff into ~/.claude/.
# Idempotent: safe to run multiple times. Backs up settings.json on
# first run before merging hooks.

set -euo pipefail

repo_dir="$(cd "$(dirname "$0")" && pwd)"
claude_dir="${CLAUDE_HOME:-$HOME/.claude}"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required but not installed. Try 'brew install jq' or your package manager." >&2
  exit 1
fi

mkdir -p "$claude_dir/scripts" "$claude_dir/commands" "$claude_dir/handoff"

cp "$repo_dir/scripts/handoff-snapshot.sh" "$claude_dir/scripts/handoff-snapshot.sh"
chmod +x "$claude_dir/scripts/handoff-snapshot.sh"
cp "$repo_dir/commands/resume.md" "$claude_dir/commands/resume.md"

settings="$claude_dir/settings.json"
patch="$repo_dir/settings.example.json"

if [ -f "$settings" ]; then
  backup="$settings.backup-$(date +%Y%m%d-%H%M%S)"
  cp "$settings" "$backup"
  echo "Backed up existing settings to $backup"
else
  echo "{}" > "$settings"
fi

# Merge: add our hook entries to PreCompact (auto + manual) and
# SessionEnd, deduplicating by command path so reruns don't pile up.
tmp="$settings.tmp"
jq --slurpfile patch "$patch" '
  def add_hook($matcher; $entry):
    if any(.[]?; .matcher == $matcher) then
      map(if .matcher == $matcher
          then .hooks = ((.hooks // []) + ($entry.hooks)) | .hooks |= unique_by(.command)
          else .
          end)
    else
      . + [$entry]
    end;

  .hooks //= {}
  | (.hooks.PreCompact // []) as $pc
  | ($patch[0].hooks.PreCompact[0]) as $pc_auto
  | ($patch[0].hooks.PreCompact[1]) as $pc_manual
  | .hooks.PreCompact = ($pc | add_hook("auto"; $pc_auto) | add_hook("manual"; $pc_manual))
  | .hooks.SessionEnd = (((.hooks.SessionEnd // []) + ($patch[0].hooks.SessionEnd)) | unique_by(.hooks | tostring))
' "$settings" > "$tmp"

# Sanity-check the result before swapping it in.
jq -e . "$tmp" >/dev/null || { echo "error: merged settings.json is not valid JSON; aborting" >&2; rm -f "$tmp"; exit 1; }
mv "$tmp" "$settings"

cat <<EOF

Installed claude-code-handoff.
  scripts:  $claude_dir/scripts/handoff-snapshot.sh
  command:  $claude_dir/commands/resume.md
  packets:  $claude_dir/handoff/
  hooks:    merged into $settings

Verify:
  1. In a Claude Code session, run /compact. The status line should show
     'PreCompact [...handoff-snapshot.sh] completed successfully'.
  2. ls -t $claude_dir/handoff/   # newest packet on top
  3. In a fresh session, type /resume — Claude should summarize the packet.
EOF

#!/usr/bin/env bash
# Removes claude-code-handoff. Restores settings.json to a state without
# the handoff hooks. Leaves the handoff/ directory in place by default
# (your packets) — pass --purge to delete them too.

set -euo pipefail

claude_dir="${CLAUDE_HOME:-$HOME/.claude}"
purge=0
[ "${1:-}" = "--purge" ] && purge=1

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required but not installed." >&2
  exit 1
fi

rm -f "$claude_dir/scripts/handoff-snapshot.sh"
rm -f "$claude_dir/commands/resume.md"

settings="$claude_dir/settings.json"
if [ -f "$settings" ]; then
  backup="$settings.backup-$(date +%Y%m%d-%H%M%S)"
  cp "$settings" "$backup"
  echo "Backed up settings to $backup"

  tmp="$settings.tmp"
  jq '
    def strip_handoff(arr):
      arr
      | map(.hooks |= map(select((.command // "") | test("handoff-snapshot\\.sh") | not)))
      | map(select((.hooks // []) | length > 0));

    .hooks //= {}
    | .hooks.PreCompact = (strip_handoff(.hooks.PreCompact // []))
    | .hooks.SessionEnd = (strip_handoff(.hooks.SessionEnd // []))
    | if (.hooks.PreCompact | length) == 0 then del(.hooks.PreCompact) else . end
    | if (.hooks.SessionEnd | length) == 0 then del(.hooks.SessionEnd) else . end
    | if (.hooks | length) == 0 then del(.hooks) else . end
  ' "$settings" > "$tmp"

  jq -e . "$tmp" >/dev/null || { echo "error: rewritten settings.json is not valid JSON; aborting" >&2; rm -f "$tmp"; exit 1; }
  mv "$tmp" "$settings"
fi

if [ "$purge" -eq 1 ]; then
  rm -rf "$claude_dir/handoff"
  echo "Purged $claude_dir/handoff/"
else
  echo "Left $claude_dir/handoff/ in place (use --purge to delete saved packets)."
fi

echo "Uninstalled claude-code-handoff."

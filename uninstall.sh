#!/usr/bin/env bash
# claude-code-handoff v0.3.0 — uninstaller
# Removes claude-code-handoff. Strips both manual-mode hooks
# (PreCompact, SessionEnd → handoff-snapshot.sh) and auto-mode hooks
# (SessionStart → handoff-resume.sh) from settings.json. Leaves the
# handoff/ directory in place by default — pass --purge to delete packets.

set -euo pipefail

claude_dir="${CLAUDE_HOME:-$HOME/.claude}"
purge=0
case "${1:-}" in
  --purge) purge=1; shift ;;
  "")      ;;
  *)       echo "unknown argument: $1" >&2; exit 2 ;;
esac
[ "$#" -gt 0 ] && { echo "unexpected extra arguments: $*" >&2; exit 2; }

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required but not installed." >&2
  exit 1
fi

rm -f "$claude_dir/scripts/handoff-snapshot.sh"
rm -f "$claude_dir/scripts/handoff-resume.sh"
rm -f "$claude_dir/commands/resume.md"
rm -f "$claude_dir/bin/claude-handoff"

settings="$claude_dir/settings.json"
if [ -f "$settings" ]; then
  tmp=$(mktemp "$settings.tmp.XXXXXX")
  trap 'rm -f "$tmp"' EXIT

  jq '
    # Strip any hook entry whose command path ends with one of our script
    # filenames; anchored to avoid matching unrelated user scripts that
    # happen to contain "handoff-snapshot" or "handoff-resume".
    def strip(arr):
      arr
      | map(.hooks |= map(select((.command // "") | test("/handoff-(snapshot|resume)\\.sh$") | not)))
      | map(select((.hooks // []) | length > 0));

    if (.hooks // null | type) != "object" then .hooks = {} else . end
    | .hooks.PreCompact   = (strip(.hooks.PreCompact // []))
    | .hooks.SessionEnd   = (strip(.hooks.SessionEnd // []))
    | .hooks.SessionStart = (strip(.hooks.SessionStart // []))
    | if (.hooks.PreCompact   | length) == 0 then del(.hooks.PreCompact)   else . end
    | if (.hooks.SessionEnd   | length) == 0 then del(.hooks.SessionEnd)   else . end
    | if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end
    | if (.hooks | length) == 0 then del(.hooks) else . end
  ' "$settings" > "$tmp"

  jq -e . "$tmp" >/dev/null || { echo "error: rewritten settings.json is not valid JSON; aborting" >&2; exit 1; }

  if ! cmp -s "$tmp" "$settings"; then
    backup="$settings.backup-$(date +%Y%m%d-%H%M%S)-$$"
    cp "$settings" "$backup"
    echo "Backed up settings to $backup"
  fi
  mv "$tmp" "$settings"
  trap - EXIT
fi

if [ "$purge" -eq 1 ]; then
  rm -rf "$claude_dir/handoff"
  echo "Purged $claude_dir/handoff/"
else
  echo "Left $claude_dir/handoff/ in place (use --purge to delete saved packets)."
fi

echo "Uninstalled claude-code-handoff."

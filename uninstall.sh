#!/usr/bin/env bash
# claude-state v0.4.0 — uninstaller
# Removes claude-state. Strips both v0.3 and v0.4 hook paths from
# settings.json. Leaves the handoff/ directory in place by default —
# pass --purge to delete packets too.

set -euo pipefail

# Same MSYS path-translation defeat as install.sh — see comment there.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

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

# Remove v0.4 layout.
rm -rf "$claude_dir/claude-state"
rm -f "$claude_dir/bin/claude-state"
rm -f "$claude_dir/bin/claude-handoff"
rm -f "$claude_dir/commands/resume.md"

# Remove leftover v0.3 layout (no-op if absent).
rm -f "$claude_dir/scripts/handoff-snapshot.sh"
rm -f "$claude_dir/scripts/handoff-resume.sh"
rmdir "$claude_dir/scripts" 2>/dev/null || true

settings="$claude_dir/settings.json"
if [ -f "$settings" ]; then
  tmp=$(mktemp "$settings.tmp.XXXXXX")
  trap 'rm -f "$tmp"' EXIT

  # Strip any hook entry whose command path tail matches our v0.3 OR v0.4
  # script filenames, anchored to a path-segment boundary so unrelated
  # user scripts (e.g. /usr/local/my-handoff-snapshot.sh) survive.
  jq '
    def strip(arr):
      arr
      | map(.hooks |= map(select((.command // "") | test("/(scripts/handoff-(snapshot|resume)|claude-state/modules/handoff/(snapshot|resume))\\.sh$") | not)))
      | map(select((.hooks // []) | length > 0));

    if (.hooks // null | type) != "object" then .hooks = {} else . end
    | .hooks.PreCompact   = (strip(.hooks.PreCompact   // []))
    | .hooks.SessionEnd   = (strip(.hooks.SessionEnd   // []))
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

echo "Uninstalled claude-state."

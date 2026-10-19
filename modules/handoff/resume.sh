#!/usr/bin/env bash
# claude-state — handoff resume
# Reads the most relevant handoff packet and emits it as additionalContext
# for a fresh session via the documented SessionStart hookSpecificOutput
# shape. Wired (opt-in) to startup, resume, compact, clear, and fork.
# Always exits 0 so it never blocks session startup.

set -uo pipefail

# Locate and source lib/common.sh.
__cs_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
while [ "$__cs_dir" != "/" ] && [ ! -f "$__cs_dir/lib/common.sh" ]; do
  __cs_dir=$(dirname "$__cs_dir")
done
if [ ! -f "$__cs_dir/lib/common.sh" ]; then
  echo "claude-state resume: cannot locate lib/common.sh" >&2
  exit 0
fi
# shellcheck source=../../lib/common.sh
. "$__cs_dir/lib/common.sh"

# shellcheck source=../../lib/handoff.sh
. "$__cs_dir/lib/handoff.sh"
payload=$(cat)
printf '%s' "$payload" | cs_jq -e 'type=="object" and (.session_id|type=="string") and ((.cwd // "")|type=="string")' >/dev/null 2>&1 || exit 0
session_id=$(printf '%s' "$payload" | cs_jq -r '.session_id')
is_valid_session_id "$session_id" || exit 0
source_field=$(printf '%s' "$payload" | cs_jq -r '.source // "unknown"')
case "$source_field" in startup|resume|compact|clear|fork) ;; *) exit 0 ;; esac
cwd=$(printf '%s' "$payload" | cs_jq -r '.cwd // ""')
handoff_dir=$(cs_handoff_dir)
[ -d "$handoff_dir" ] && [ ! -L "$handoff_dir" ] || exit 0
target="$handoff_dir/$session_id.md"
if [ ! -f "$target" ] || [ -L "$target" ] || [ ! -r "$target" ]; then
  target=""
elif [ -n "$cwd" ] && ! packet_matches_workspace "$target" "$cwd"; then
  target=""
fi
# A missing exact match may only fall back within the current worktree.
if [ -z "$target" ]; then
  target=$(handoff_pick_workspace "$cwd") || exit 0
fi
# Preserve the JSON string end-to-end. Older jq versions can replace split
# UTF-8 characters during raw slurp, inflating an already-budgeted excerpt.
handoff_context "$target" "$cwd" "$source_field" |
  cs_jq '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:.}}'
exit 0

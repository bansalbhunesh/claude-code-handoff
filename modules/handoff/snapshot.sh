#!/usr/bin/env bash
# claude-state — handoff snapshot
# Snapshots conversation state to ~/.claude/handoff/<session_id>.md.
# Wired to PreCompact (auto + manual) and SessionEnd. Always exits 0
# so it never blocks the compaction or shutdown it's observing.

set -uo pipefail
# Packets contain verbatim user prompts and assistant prose, which may
# include secrets the user pasted into the conversation.
umask 077

# Locate and source lib/common.sh by walking up from this script.
__cs_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
while [ "$__cs_dir" != "/" ] && [ ! -f "$__cs_dir/lib/common.sh" ]; do
  __cs_dir=$(dirname "$__cs_dir")
done
if [ ! -f "$__cs_dir/lib/common.sh" ]; then
  echo "claude-state snapshot: cannot locate lib/common.sh" >&2
  exit 0
fi
# shellcheck source=../../lib/common.sh
. "$__cs_dir/lib/common.sh"
# shellcheck source=../../lib/workspace.sh
. "$__cs_dir/lib/workspace.sh"
# shellcheck source=../../lib/signal.sh
. "$__cs_dir/lib/signal.sh"

payload=$(cat)
printf '%s' "$payload" | cs_jq -e 'type=="object" and (.session_id|type=="string") and (.transcript_path|type=="string") and ((.cwd // "")|type=="string")' >/dev/null 2>&1 || exit 0
session_id=$(printf '%s' "$payload" | cs_jq -r '.session_id // empty' 2>/dev/null)
transcript=$(printf '%s' "$payload" | cs_jq -r '.transcript_path // empty' 2>/dev/null)
cwd=$(printf '%s' "$payload" | cs_jq -r '.cwd // empty' 2>/dev/null)
event=$(printf '%s' "$payload" | cs_jq -r '.hook_event_name // "unknown"' 2>/dev/null)

[ -n "$session_id" ] || exit 0
[ -n "$transcript" ] || exit 0
[ -f "$transcript" ] || exit 0

is_valid_session_id "$session_id" || exit 0

handoff_dir=$(cs_handoff_dir)
# Refuse to write through a symlinked handoff directory.
[ -L "$handoff_dir" ] && exit 0
mkdir -p "$handoff_dir"
chmod 700 "$handoff_dir" 2>/dev/null || true

out="$handoff_dir/$session_id.md"
[ -L "$out" ] && exit 0

tmp=$(mktemp "$out.tmp.XXXXXX") || exit 0
trap 'rm -f "$tmp"' EXIT

# Parse once, retaining valid lines when a transcript ends mid-write.
parsed=$(cs_jq -Rn -f "$__cs_dir/lib/transcript.jq" "$transcript" 2>/dev/null) || exit 0
goal=$(printf '%s' "$parsed" | cs_jq -r '.goal')
latest_request=$(printf '%s' "$parsed" | cs_jq -r '.latest_request')
prior_session=$(printf '%s' "$parsed" | cs_jq -r '.prior // ""')
[ "$prior_session" = "$session_id" ] && prior_session=""
todos=$(printf '%s' "$parsed" | cs_jq -r '.todos')
[ -n "$todos" ] || todos="(no TodoWrite calls in this session)"
tasks=$(printf '%s' "$parsed" | cs_jq -r '.tasks')
[ -n "$tasks" ] || tasks="(no Task tracker calls in this session)"
files=$(printf '%s' "$parsed" | cs_jq -r '.files')
[ -n "$files" ] || files="(no file edits in this session)"
commands=$(printf '%s' "$parsed" | cs_jq -r '.commands')
[ -n "$commands" ] || commands="(no shell command observations)"
recent_blocks=$(printf '%s' "$parsed" | cs_jq -c '.recent')
recent=$(printf '%s' "$recent_blocks" | signal_filter | signal_render)
[ -n "$recent" ] || recent="(no assistant text yet)"

# Workspace identity (M1). Empty cwd → skip, nothing to anchor against.
workspace_id=""
workspace_root=""
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  workspace_root=$(workspace_root_for "$cwd")
  workspace_id=$(workspace_id_for "$workspace_root")
fi

git_head=""; git_branch=""; git_status=""
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  git_head=$(git -C "$cwd" rev-parse HEAD 2>/dev/null) || git_head=""
  git_branch=$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null) || git_branch="(detached)"
  git_status=$(git -C "$cwd" status --porcelain=v1 --untracked-files=normal 2>/dev/null | head -30) || true
fi

{
  printf '# Handoff packet\n'
  printf -- '- session: %s\n' "$session_id"
  printf -- '- event: %s\n' "$event"
  printf -- '- generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf -- '- generated_epoch: %s\n' "$(date +%s)"
  printf -- '- cwd: %s\n' "$cwd"
  [ -n "$git_head" ] && printf -- '- git_head: %s\n' "$git_head"
  [ -n "$git_head" ] && printf -- '- git_branch: %s\n' "$git_branch"
  [ -n "$workspace_id" ]   && printf -- '- workspace: %s\n' "$workspace_id"
  [ -n "$workspace_root" ] && printf -- '- workspace_root: %s\n' "$workspace_root"
  [ -n "$prior_session" ]  && printf -- '- continues_from: %s\n' "$prior_session"
  printf '\n## Latest user request\n%s\n\n## Original goal\n%s\n\n## Current todos\n%s\n\n## Task tracker\n%s\n\n## Git working tree (at capture)\n%s\n\n## Recently edited files\n%s\n\n## Recent command observations\n%s\n\n## Recent assistant reasoning\n%s\n' \
    "$latest_request" "$goal" "$todos" "$tasks" "${git_status:-(clean or unavailable)}" "$files" "$commands" "$recent"
  printf '\nHistorical observations only. Tool return is not proof that tests passed. Validate current code, instructions, and permissions before continuing.\n'
} > "$tmp"

# Redact before the packet reaches its final path. Original transcripts remain untouched.
if [ "${HANDOFF_REDACT:-1}" != "0" ]; then
  redacted=$(cs_jq -Rs -r -f "$__cs_dir/lib/redact.jq" "$tmp" 2>/dev/null) || exit 0
  printf '%s\n' "$redacted" > "$tmp"
fi

chmod 600 "$tmp" 2>/dev/null || true
mv "$tmp" "$out"
trap - EXIT

# Optional auto-prune: keep only N newest packets. Treats 0 (and any
# non-positive value) as "disabled" — KEEP_N=0 with the prior `-ge 0`
# guard would have run `tail -n +1`, deleting the very packet just
# written. Users who want zero packets should run `claude-state prune`.
if [ -n "${HANDOFF_KEEP_N:-}" ] && [ "$HANDOFF_KEEP_N" -eq "$HANDOFF_KEEP_N" ] 2>/dev/null && [ "$HANDOFF_KEEP_N" -ge 1 ]; then
  ls -t "$handoff_dir"/*.md 2>/dev/null | tail -n +$((HANDOFF_KEEP_N + 1)) | while IFS= read -r victim; do
    [ -f "$victim" ] && rm -f "$victim"
  done
fi

# Optional debug log.
if [ -n "${HANDOFF_DEBUG:-}" ]; then
  bytes=$(wc -c <"$out" 2>/dev/null | tr -d ' ')
  printf '%s  %-12s  session=%s  bytes=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "$session_id" "$bytes" \
    >> "$handoff_dir/.log" 2>/dev/null || true
fi

if [ "${CS_REPORT_PATH:-0}" = 1 ]; then printf '%s\n' "$out"; fi
exit 0

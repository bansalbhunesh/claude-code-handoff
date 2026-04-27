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

payload=$(cat)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
event=$(printf '%s' "$payload" | jq -r '.hook_event_name // "unknown"' 2>/dev/null)

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

# First real user message: non-meta, non-compact-summary, non-empty.
goal=$(jq -rs '
  [ .[]
    | select(.type == "user")
    | select((.isCompactSummary // false) | not)
    | select((.isMeta // false) | not)
    | .message.content
    | if type == "string" then .
      elif type == "array" then ([.[]? | select(.type == "text") | .text] | join("\n"))
      else "" end
    | select(. != null and . != "")
    | select(startswith("<") | not)
    | select(startswith("⏺") | not) ]
  | (first // "(unknown)")
  | .[0:600]
' "$transcript" 2>/dev/null || echo "(unknown)")

# Chaining: walk back to the prior session id if a compact-summary is the
# transcript's first record.
prior_session=$(jq -rs '
  [ .[] | select(.isCompactSummary == true) | .message.content
    | if type == "string" then .
      elif type == "array" then ([.[]? | select(.type == "text") | .text] | join("\n"))
      else "" end ]
  | first // ""
' "$transcript" 2>/dev/null \
  | grep -oE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' \
  | head -1 || true)
[ "$prior_session" = "$session_id" ] && prior_session=""

# Latest TodoWrite input.
todos=$(jq -rs '
  [ .[]
    | select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and .name == "TodoWrite")
    | .input.todos ]
  | (last // [])
  | map("- [\(.status)] \(.content)")
  | join("\n")
' "$transcript" 2>/dev/null || true)
[ -z "$todos" ] && todos="(no TodoWrite calls in this session)"

# TaskCreate / TaskUpdate sequence reduced to current state.
tasks=$(jq -rs '
  [ .[]
    | select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and (.name == "TaskCreate" or .name == "TaskUpdate"))
    | {name, input} ]
  | reduce .[] as $e (
      {tasks: [], status: {}};
      if $e.name == "TaskCreate" then
        (.tasks | length + 1) as $id
        | .tasks += [{id: $id, subject: $e.input.subject}]
        | .status[($id | tostring)] = "pending"
      else
        .status[($e.input.taskId | tostring)] = ($e.input.status // .status[($e.input.taskId | tostring)])
      end)
  | .tasks as $tasks
  | .status as $status
  | $tasks
  | map("#\(.id). [\($status[(.id | tostring)] // "pending")] \(.subject)")
  | join("\n")
' "$transcript" 2>/dev/null || true)
[ -z "$tasks" ] && tasks="(no Task tracker calls in this session)"

# Last 20 file-mutating tool calls.
files=$(jq -rs '
  [ .[]
    | select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and (.name == "Edit" or .name == "Write" or .name == "MultiEdit" or .name == "NotebookEdit"))
    | "- \(.name): \(.input.file_path // .input.notebook_path // "?")" ]
  | .[-20:]
  | join("\n")
' "$transcript" 2>/dev/null || true)
[ -z "$files" ] && files="(no file edits in this session)"

# Last 5 assistant text blocks — where decisions, dead-ends, and intent live.
recent=$(jq -rs '
  [ .[]
    | select(.type == "assistant")
    | .message.content[]?
    | select(.type == "text")
    | .text ]
  | .[-5:]
  | join("\n\n---\n\n")
' "$transcript" 2>/dev/null || true)
[ -z "$recent" ] && recent="(no assistant text yet)"

# Workspace identity (M1). Empty cwd → skip, nothing to anchor against.
workspace_id=""
workspace_root=""
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  workspace_root=$(workspace_root_for "$cwd")
  workspace_id=$(workspace_id_for "$workspace_root")
fi

{
  printf '# Handoff packet\n'
  printf -- '- session: %s\n' "$session_id"
  printf -- '- event: %s\n' "$event"
  printf -- '- generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf -- '- cwd: %s\n' "$cwd"
  [ -n "$workspace_id" ]   && printf -- '- workspace: %s\n' "$workspace_id"
  [ -n "$workspace_root" ] && printf -- '- workspace_root: %s\n' "$workspace_root"
  [ -n "$prior_session" ]  && printf -- '- continues_from: %s\n' "$prior_session"
  printf '\n## Original goal\n%s\n\n## Current todos\n%s\n\n## Task tracker\n%s\n\n## Recently edited files\n%s\n\n## Recent assistant reasoning\n%s\n' \
    "$goal" "$todos" "$tasks" "$files" "$recent"
} > "$tmp"

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

exit 0

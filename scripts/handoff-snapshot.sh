#!/usr/bin/env bash
# claude-code-handoff v0.2.0 — snapshot
# Snapshots conversation state to ~/.claude/handoff/<session_id>.md.
# Wired to PreCompact (auto + manual) and SessionEnd. Always exits 0
# so it never blocks the compaction or shutdown it's observing.

set -uo pipefail
# Ensure the handoff directory and any new packet are not world-readable.
# Packets contain verbatim user prompts and assistant prose, which may
# include secrets the user pasted into the conversation.
umask 077

payload=$(cat)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
event=$(printf '%s' "$payload" | jq -r '.hook_event_name // "unknown"' 2>/dev/null)

[ -n "$session_id" ] || exit 0
[ -n "$transcript" ] || exit 0
[ -f "$transcript" ] || exit 0

# Defense-in-depth: only accept simple-charset session ids as filenames,
# and require an alphanumeric first character so pure-dot ids ("..", ".x")
# can't produce surprising filenames. Real Claude Code uses UUIDs.
[[ "$session_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || exit 0

handoff_dir="$HOME/.claude/handoff"
# Refuse to write through a symlinked handoff directory — guards against
# someone replacing it with a link to a sensitive path.
[ -L "$handoff_dir" ] && exit 0
mkdir -p "$handoff_dir"
chmod 700 "$handoff_dir" 2>/dev/null || true

out="$handoff_dir/$session_id.md"
# Refuse to clobber a symlinked target.
[ -L "$out" ] && exit 0

tmp=$(mktemp "$out.tmp.XXXXXX") || exit 0
trap 'rm -f "$tmp"' EXIT

# First real user message: non-meta, non-compact-summary, non-empty.
# Handles both string and array-of-blocks content shapes (modern Claude
# Code uses array shape for ~75%+ of user records).
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

# Chaining: if this transcript begins with a compact-summary record, its
# body embeds the prior session's transcript path. Extract the UUID so
# resume can walk back through earlier packets.
prior_session=$(jq -rs '
  [ .[] | select(.isCompactSummary == true) | .message.content
    | if type == "string" then .
      elif type == "array" then ([.[]? | select(.type == "text") | .text] | join("\n"))
      else "" end ]
  | first // ""
' "$transcript" 2>/dev/null \
  | grep -oE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' \
  | head -1 || true)
# Don't link to ourselves.
[ "$prior_session" = "$session_id" ] && prior_session=""

# Latest TodoWrite input — mostly empty in 4.7-era sessions but kept for
# back-compat with workflows that still use TodoWrite.
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

# Last 5 assistant text blocks — where decisions, dead-ends, and intent
# live in prose. Verbatim is fine; the next session's model can read it.
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

{
  printf '# Handoff packet\n'
  printf -- '- session: %s\n' "$session_id"
  printf -- '- event: %s\n' "$event"
  printf -- '- generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf -- '- cwd: %s\n' "$cwd"
  [ -n "$prior_session" ] && printf -- '- continues_from: %s\n' "$prior_session"
  printf '\n## Original goal\n%s\n\n## Current todos\n%s\n\n## Task tracker\n%s\n\n## Recently edited files\n%s\n\n## Recent assistant reasoning\n%s\n' \
    "$goal" "$todos" "$tasks" "$files" "$recent"
} > "$tmp"

chmod 600 "$tmp" 2>/dev/null || true
mv "$tmp" "$out"
trap - EXIT
exit 0

#!/usr/bin/env bash
# Snapshots conversation state to ~/.claude/handoff/<session_id>.md.
# Wired to PreCompact (auto + manual) and SessionEnd. Always exits 0
# so it never blocks the compaction or shutdown it's observing.

set -uo pipefail

payload=$(cat)
session_id=$(echo "$payload" | jq -r '.session_id // empty')
transcript=$(echo "$payload" | jq -r '.transcript_path // empty')
cwd=$(echo "$payload" | jq -r '.cwd // empty')
event=$(echo "$payload" | jq -r '.hook_event_name // "unknown"')

[ -n "$session_id" ] || exit 0
[ -n "$transcript" ] || exit 0
[ -f "$transcript" ] || exit 0

handoff_dir="$HOME/.claude/handoff"
mkdir -p "$handoff_dir"
out="$handoff_dir/$session_id.md"
tmp="$out.tmp"

# First user message that's plausibly the real goal: a string, not a
# tool-result/command-meta (starts with '<'), and not a paste-back of a
# Claude reply (starts with '⏺'). Cap to 600 chars.
goal=$(jq -rs '
  [ .[]
    | select(.type == "user")
    | .message.content
    | select(type == "string")
    | select(startswith("<") | not)
    | select(startswith("⏺") | not) ]
  | (first // "(unknown)")
  | .[0:600]
' "$transcript" 2>/dev/null || echo "(unknown)")

# Latest TodoWrite input — the live plan/progress view from TodoWrite users.
todos=$(jq -rs '
  [ .[]
    | select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and .name == "TodoWrite")
    | .input.todos ]
  | (last // [])
  | map("- [\(.status)] \(.content)")
  | join("\n")
' "$transcript" 2>/dev/null)
[ -z "$todos" ] && todos="(no TodoWrite calls in this session)"

# Task tracker — TaskCreate/TaskUpdate sequence reduced to current state.
# IDs are assigned sequentially by creation order, mirroring how the
# Task tools number them in their result strings.
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
' "$transcript" 2>/dev/null)
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
' "$transcript" 2>/dev/null)
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
' "$transcript" 2>/dev/null)
[ -z "$recent" ] && recent="(no assistant text yet)"

cat > "$tmp" <<EOF
# Handoff packet
- session: $session_id
- event: $event
- generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- cwd: $cwd

## Original goal
$goal

## Current todos
$todos

## Task tracker
$tasks

## Recently edited files
$files

## Recent assistant reasoning
$recent
EOF

mv "$tmp" "$out"
exit 0

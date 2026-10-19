# Tolerate malformed/truncated JSONL lines without discarding earlier records.
def text:
  if type == "string" then .
  elif type == "array" then [.[] | select(type == "object" and .type == "text") | .text // ""] | join("\n")
  else "" end;
def blocks:
  .message.content | if type == "array" then .[] | objects else empty end;
def user_text:
  select(.type == "user" and (.isMeta != true) and (.isCompactSummary != true)) |
  .message.content | text | select(length > 0) |
  select(startswith("<") | not) | select(startswith("⏺") | not);

[inputs | fromjson? | objects] as $events |
[$events[] | user_text] as $requests |
[$events[] | select(.type == "assistant") | blocks | select(.type == "tool_use")] as $calls |
[$events[] | blocks | select(.type == "tool_result")] as $results |
def result($id): [$results[] | select($id != null and .tool_use_id == $id)] | last;
def outcome($call): result($call.id) as $r |
  if $r == null then "unverified" elif $r.is_error == true then "failed" else "tool returned" end;

{
  goal: (($requests | first // "(unknown)")[:600]),
  latest_request: (($requests | last // "(unknown)")[:1800]),
  todos: ([$calls[] | select(.name == "TodoWrite") | .input.todos] | last // [] |
    map("- [\(.status)] \(.content)") | join("\n")),
  tasks: (reduce ($calls[] | select(.name == "TaskCreate" or .name == "TaskUpdate")) as $c ({};
    result($c.id) as $r |
    if $c.name == "TaskCreate" then
      # Use the actual returned id. Missing/failed results are never assumed complete.
      ((try (($r.content | text) | capture("Task #(?<id>[0-9]+)").id) catch null) // null) as $id |
      ("unverified-" + ($c.id // (length|tostring))) as $fallback |
      .[($id // $fallback)] = {subject:$c.input.subject, status:(if $id != null and $r.is_error != true then "pending" else "unverified" end)}
    elif $r != null and $r.is_error != true and .[($c.input.taskId|tostring)] != null then
      .[($c.input.taskId|tostring)].status = ($c.input.status // .[($c.input.taskId|tostring)].status)
    else . end) | to_entries | map("#\(.key). [\(.value.status)] \(.value.subject)") | join("\n")),
  files: ([$calls[] | select(.name == "Edit" or .name == "Write" or .name == "MultiEdit" or .name == "NotebookEdit") |
    "- \(.name) [\(outcome(.))]: \(.input.file_path // .input.notebook_path // "?")"] | .[-20:] | join("\n")),
  commands: ([$calls[] | select(.name == "Bash") |
    "- [\(outcome(.))] \((.input.description // "Shell command (no description)")[:240])"] | .[-8:] | join("\n")),
  recent: ([$events[] | select(.type == "assistant") | blocks | select(.type == "text") | .text] | .[-20:]),
  prior: ([$events[] | select(.isCompactSummary == true) | .message.content | text] | first // "" |
    (try capture("(?<id>[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})").id catch "") // "")
}

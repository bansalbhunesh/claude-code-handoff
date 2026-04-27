# shellcheck shell=bash
# lib/memory.sh — memory storage helpers.
# Sourced by modules/memory/memory.sh and (transitively) any future
# integrations (e.g. snapshot-time memory linking).
#
# Design principle: don't replace storage. Claude Code's harness reads
# `~/.claude/projects/<sanitized-cwd>/memory/MEMORY.md` to load the
# user's auto-memory. We layer a typed CLI ON TOP of that same
# directory — the harness keeps reading what it always read; v0.6 adds
# state, links, and a versioned JSON plugin contract.

[ -n "${__CS_MEMORY_LOADED:-}" ] && return 0
__CS_MEMORY_LOADED=1

__mem_lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$__mem_lib_dir/common.sh"

# Resolve the memory directory for a given cwd. Defaults to current pwd.
# Sanitization scheme: replace `/` with `-` (matches the harness's
# observed format, e.g. /Users/ankur → -Users-ankur).
memory_dir() {
  local cwd="${1:-$(pwd)}"
  local sanitized
  sanitized=$(printf '%s' "$cwd" | tr '/' '-')
  printf '%s/projects/%s/memory' "$(cs_claude_dir)" "$sanitized"
}

# Honors CS_MEMORY_DIR override (used by tests and by users with a
# non-standard memory layout).
# shellcheck disable=SC2120  # `$@` forwarded to memory_dir; callers may
#                              not pass an arg, in which case memory_dir
#                              defaults to current pwd.
cs_memory_dir() {
  if [ -n "${CS_MEMORY_DIR:-}" ]; then
    printf '%s' "$CS_MEMORY_DIR"
  else
    memory_dir "$@"
  fi
}

# List memory files in the dir (excluding MEMORY.md, the auto-compiled
# index, and any *.md.tmp.* atomic-write leftovers). One absolute path
# per line, lexically sorted by filename so list output is deterministic.
memory_list_files() {
  local dir="${1:-$(cs_memory_dir)}"
  [ -d "$dir" ] || return 0
  local f
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue
    local base
    base=$(basename "$f")
    [ "$base" = "MEMORY.md" ] && continue
    case "$base" in
      MEMORY.md.header|MEMORY.md.footer) continue ;;
    esac
    printf '%s\n' "$f"
  done | sort
}

# Extract a YAML frontmatter field from a memory file. Frontmatter is
# the block delimited by `---` lines at the top of the file. Echoes the
# value (single-line) or empty if absent. Trims surrounding whitespace.
# Quoted values ("..." or '...') are unquoted.
memory_field() {
  local f="$1" key="$2"
  awk -v k="$key" '
    BEGIN {seen_open = 0; in_fm = 0}
    NR == 1 && /^---[[:space:]]*$/ {seen_open = 1; in_fm = 1; next}
    in_fm && /^---[[:space:]]*$/ {exit}
    in_fm {
      pos = index($0, ":")
      if (pos == 0) next
      kk = substr($0, 1, pos - 1)
      sub(/^[[:space:]]+/, "", kk); sub(/[[:space:]]+$/, "", kk)
      if (kk != k) next
      val = substr($0, pos + 1)
      sub(/^[[:space:]]+/, "", val); sub(/[[:space:]]+$/, "", val)
      # Unquote double- or single-quoted values.
      if (val ~ /^".*"$/) val = substr(val, 2, length(val) - 2)
      else if (val ~ /^'\''.*'\''$/) val = substr(val, 2, length(val) - 2)
      print val
      exit
    }
  ' "$f"
}

# Extract the body (everything after the second `---`). If there is no
# closing `---`, returns the whole file. Used by `memory get`.
memory_body() {
  local f="$1"
  awk '
    BEGIN {state = 0}
    NR == 1 && /^---[[:space:]]*$/ {state = 1; next}
    state == 1 && /^---[[:space:]]*$/ {state = 2; next}
    state == 0 && NR == 1 {state = 2; print; next}
    state == 2 {print}
  ' "$f"
}

# Emit a JSON object describing one memory file. Schema:
# {
#   "name":            "<filename without .md>",
#   "type":            "<frontmatter type, or empty>",
#   "description":     "<frontmatter description, or empty>",
#   "state":           "active|archived|superseded" (default active),
#   "created":         "<iso8601 or empty>",
#   "created_session": "<sid, accepts either created_session or legacy originSessionId>",
#   "superseded_by":   "<other-name, or null>",
#   "path":            "<absolute path>"
# }
memory_to_json() {
  local f="$1"
  local name type description state created created_session superseded_by
  name=$(basename "$f" .md)
  type=$(memory_field "$f" "type")
  description=$(memory_field "$f" "description")
  state=$(memory_field "$f" "state")
  [ -z "$state" ] && state="active"
  created=$(memory_field "$f" "created")
  created_session=$(memory_field "$f" "created_session")
  if [ -z "$created_session" ]; then
    # Back-compat: harness historically wrote `originSessionId`.
    created_session=$(memory_field "$f" "originSessionId")
  fi
  superseded_by=$(memory_field "$f" "superseded_by")
  jq -nc \
    --arg name "$name" \
    --arg type "$type" \
    --arg description "$description" \
    --arg state "$state" \
    --arg created "$created" \
    --arg created_session "$created_session" \
    --arg superseded_by "$superseded_by" \
    --arg path "$f" \
    '{
      name:            $name,
      type:            (if $type == "" then null else $type end),
      description:     (if $description == "" then null else $description end),
      state:           $state,
      created:         (if $created == "" then null else $created end),
      created_session: (if $created_session == "" then null else $created_session end),
      superseded_by:   (if $superseded_by == "" then null else $superseded_by end),
      path:            $path
    }'
}

# Validate a memory name slug. Filename-safe, no path traversal.
memory_valid_name() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]
}

# Write a memory file atomically (mktemp + mv). Args:
#   $1 = absolute path
#   $2 = type
#   $3 = description
#   $4 = state (active|archived|superseded)
#   $5 = created (ISO 8601)
#   $6 = created_session
#   $7 = superseded_by (or empty)
#   stdin = body content
memory_write() {
  local f="$1" type="$2" description="$3" state="$4" created="$5" created_session="$6" superseded_by="$7"
  local body
  body=$(cat)
  local dir tmp
  dir=$(dirname "$f")
  mkdir -p "$dir"
  tmp=$(mktemp "$f.tmp.XXXXXX") || return 1
  {
    printf -- '---\n'
    printf -- 'name: %s\n' "$(basename "$f" .md)"
    [ -n "$description" ] && printf -- 'description: %s\n' "$description"
    [ -n "$type" ]        && printf -- 'type: %s\n' "$type"
    printf -- 'state: %s\n' "$state"
    [ -n "$created" ]         && printf -- 'created: %s\n' "$created"
    [ -n "$created_session" ] && printf -- 'created_session: %s\n' "$created_session"
    [ -n "$superseded_by" ]   && printf -- 'superseded_by: %s\n' "$superseded_by"
    printf -- '---\n\n'
    printf -- '%s' "$body"
    case "$body" in
      *$'\n') ;;
      *)      printf '\n' ;;
    esac
  } > "$tmp"
  mv "$tmp" "$f"
}

# Regenerate MEMORY.md from active memories. Sort by type, then name.
# Format: `- [<name>](<filename>) — <description>` per line. Honors
# MEMORY.md.header and MEMORY.md.footer if present (so the user can
# preface manual notes that survive regenerations).
memory_rebuild_index() {
  local dir="${1:-$(cs_memory_dir)}"
  [ -d "$dir" ] || { mkdir -p "$dir"; }
  local index="$dir/MEMORY.md"
  local tmp
  tmp=$(mktemp "$index.tmp.XXXXXX") || return 1
  {
    [ -f "$dir/MEMORY.md.header" ] && cat "$dir/MEMORY.md.header"
    local f name description type state
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      state=$(memory_field "$f" "state")
      [ -z "$state" ] && state="active"
      [ "$state" = "active" ] || continue
      name=$(basename "$f" .md)
      description=$(memory_field "$f" "description")
      type=$(memory_field "$f" "type")
      printf -- '- [%s](%s.md)' "$name" "$name"
      [ -n "$description" ] && printf -- ' — %s' "$description"
      printf '\n'
    done < <(memory_list_files "$dir" | xargs -I{} sh -c '
      f="$1"
      type=$(awk -v k=type "/^---/{c++; if(c==2)exit; next} c==1 && /^[a-zA-Z_]+:/ {p=index(\$0,\":\"); kk=substr(\$0,1,p-1); gsub(/^[[:space:]]+|[[:space:]]+$/, \"\", kk); if(kk==k){val=substr(\$0,p+1); gsub(/^[[:space:]]+|[[:space:]]+$/, \"\", val); print val; exit}}" "$f")
      printf "%s\t%s\n" "${type:-z-untyped}" "$f"
    ' _ {} | sort | cut -f2-)
    [ -f "$dir/MEMORY.md.footer" ] && cat "$dir/MEMORY.md.footer"
  } > "$tmp"
  mv "$tmp" "$index"
}

#!/usr/bin/env bash
# claude-state — memory module.
# Subcommands: list, get, add, archive, supersede, query, rebuild-index.
# Layers a typed CLI on top of the harness's existing markdown memory
# storage at ~/.claude/projects/<sanitized-cwd>/memory/. Existing
# memory files keep working — frontmatter additions (state, created,
# created_session, superseded_by) are additive and optional.

set -uo pipefail

__cs_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
while [ "$__cs_dir" != "/" ] && [ ! -f "$__cs_dir/lib/common.sh" ]; do
  __cs_dir=$(dirname "$__cs_dir")
done
if [ ! -f "$__cs_dir/lib/common.sh" ]; then
  echo "claude-state memory: cannot locate lib/common.sh" >&2
  exit 1
fi
# shellcheck source=../../lib/common.sh
. "$__cs_dir/lib/common.sh"
# shellcheck source=../../lib/memory.sh
. "$__cs_dir/lib/memory.sh"

# Pre-resolve once so subcommands share state.
mem_dir=$(cs_memory_dir)

# Resolve a name to an absolute file path.
mem_path_for() {
  local name="$1"
  if ! memory_valid_name "$name"; then
    err "memory: invalid name '$name' (allowed: [a-zA-Z0-9_-]+, must start alnum)"
    return 2
  fi
  printf '%s/%s.md' "$mem_dir" "$name"
}

# Build the JSON contract document. Used by `memory query --json` and
# `memory list --json`. Schema stable at version: 1.
mem_emit_json_contract() {
  local filter_type="${1:-}" filter_state="${2:-}" filter_keyword="${3:-}"
  local f entries=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    local row
    row=$(memory_to_json "$f")
    if [ -n "$filter_type" ]; then
      printf '%s' "$row" | jq -e --arg t "$filter_type" '.type == $t' >/dev/null || continue
    fi
    if [ -n "$filter_state" ]; then
      printf '%s' "$row" | jq -e --arg s "$filter_state" '.state == $s' >/dev/null || continue
    fi
    if [ -n "$filter_keyword" ]; then
      grep -qi -- "$filter_keyword" "$f" 2>/dev/null || continue
    fi
    entries+="$row"$'\n'
  done < <(memory_list_files "$mem_dir")
  if [ -z "$entries" ]; then
    printf '{"version":1,"memories":[]}\n'
  else
    printf '%s' "$entries" | jq -s '{version: 1, memories: .}'
  fi
}

# --- subcommands ---

cmd_list() {
  local filter_type="" filter_state="" json=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --type)  shift; filter_type="${1:-}"; shift || true ;;
      --state) shift; filter_state="${1:-}"; shift || true ;;
      --json)  json=1; shift ;;
      -h|--help) print_help; return 0 ;;
      *) err "memory list: unknown arg '$1'"; return 2 ;;
    esac
  done

  if [ "$json" -eq 1 ]; then
    mem_emit_json_contract "$filter_type" "$filter_state" ""
    return 0
  fi

  if [ ! -d "$mem_dir" ]; then
    echo "No memory directory at $mem_dir."
    return 0
  fi
  printf '%-30s %-10s %-10s %s\n' "NAME" "TYPE" "STATE" "DESCRIPTION"
  local f count=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    local name type state description
    name=$(basename "$f" .md)
    type=$(memory_field "$f" "type")
    state=$(memory_field "$f" "state"); [ -z "$state" ] && state="active"
    description=$(memory_field "$f" "description")
    [ -n "$filter_type" ]  && [ "$type"  != "$filter_type" ]  && continue
    [ -n "$filter_state" ] && [ "$state" != "$filter_state" ] && continue
    printf '%-30s %-10s %-10s %s\n' \
      "$name" "${type:-(none)}" "$state" "${description:-}"
    count=$((count + 1))
  done < <(memory_list_files "$mem_dir")
  if [ "$count" -eq 0 ]; then
    echo "(no memories matched the given filters)"
  fi
}

cmd_get() {
  local name="${1:-}" json=0
  case "${2:-}" in --json) json=1 ;; "") ;; *) err "memory get: unknown arg '$2'"; return 2 ;; esac
  [ -n "$name" ] || { err "memory get: missing name"; return 2; }
  local f
  f=$(mem_path_for "$name") || return 2
  [ -f "$f" ] || { err "memory get: no memory '$name' at $f"; return 1; }
  if [ "$json" -eq 1 ]; then
    memory_to_json "$f" | jq .
  else
    cat "$f"
  fi
}

cmd_add() {
  local name="" type="" description="" state="active" content_arg="" content_stdin=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name)        shift; name="${1:-}"; shift || true ;;
      --type)        shift; type="${1:-}"; shift || true ;;
      --description) shift; description="${1:-}"; shift || true ;;
      --state)       shift; state="${1:-active}"; shift || true ;;
      --content)
        shift
        if [ "${1:-}" = "-" ]; then
          content_stdin=1
        else
          content_arg="${1:-}"
        fi
        shift || true
        ;;
      -h|--help) print_help; return 0 ;;
      *) err "memory add: unknown arg '$1'"; return 2 ;;
    esac
  done
  [ -n "$name" ] || { err "memory add: --name is required"; return 2; }
  memory_valid_name "$name" || { err "memory add: invalid name '$name' (allowed: [a-zA-Z0-9_-]+)"; return 2; }
  case "$state" in
    active|archived|superseded) ;;
    *) err "memory add: --state must be active|archived|superseded (got '$state')"; return 2 ;;
  esac

  local f
  f=$(mem_path_for "$name")
  if [ -e "$f" ]; then
    err "memory add: '$name' already exists at $f (use 'memory archive' or pick a different name)"
    return 1
  fi

  # Resolve content source.
  local body
  if [ "$content_stdin" -eq 1 ]; then
    body=$(cat)
  elif [ -n "$content_arg" ]; then
    body="$content_arg"
  else
    # Editor mode: open a tempfile with a stub.
    if [ -t 0 ] && { [ -n "${EDITOR:-}" ] || [ -n "${VISUAL:-}" ] || command -v vi >/dev/null 2>&1; }; then
      local edtmp
      edtmp=$(mktemp -t cs-memory-add.XXXXXX.md)
      printf '%s\n' "$description" > "$edtmp"
      local editor="${VISUAL:-${EDITOR:-vi}}"
      "$editor" "$edtmp"
      body=$(cat "$edtmp")
      rm -f "$edtmp"
    else
      err "memory add: provide --content '<text>' or --content - (stdin), or run interactively for \$EDITOR"
      return 2
    fi
  fi

  # Default created/created_session from environment if available.
  local created created_session
  created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  created_session="${HANDOFF_SESSION_ID:-}"
  if [ -z "$created_session" ] && [ -f "$(cs_handoff_dir)/.last_session" ]; then
    created_session=$(cat "$(cs_handoff_dir)/.last_session" 2>/dev/null | head -1)
  fi

  printf '%s' "$body" | memory_write "$f" "$type" "$description" "$state" "$created" "$created_session" ""
  memory_rebuild_index "$mem_dir" >/dev/null
  printf 'Added memory: %s (type=%s state=%s)\n' "$name" "${type:-none}" "$state"
}

cmd_archive() {
  local name="${1:-}"
  [ -n "$name" ] || { err "memory archive: missing name"; return 2; }
  local f
  f=$(mem_path_for "$name") || return 2
  [ -f "$f" ] || { err "memory archive: no memory '$name'"; return 1; }
  local type description created created_session superseded_by body
  type=$(memory_field "$f" "type")
  description=$(memory_field "$f" "description")
  created=$(memory_field "$f" "created")
  created_session=$(memory_field "$f" "created_session")
  [ -z "$created_session" ] && created_session=$(memory_field "$f" "originSessionId")
  superseded_by=$(memory_field "$f" "superseded_by")
  body=$(memory_body "$f")
  printf '%s' "$body" | memory_write "$f" "$type" "$description" "archived" "$created" "$created_session" "$superseded_by"
  memory_rebuild_index "$mem_dir" >/dev/null
  printf 'Archived memory: %s\n' "$name"
}

cmd_supersede() {
  local old="" new=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --by) shift; new="${1:-}"; shift || true ;;
      -h|--help) print_help; return 0 ;;
      *)
        if [ -z "$old" ]; then old="$1"
        else err "memory supersede: unexpected arg '$1'"; return 2
        fi
        shift
        ;;
    esac
  done
  [ -n "$old" ] || { err "memory supersede: missing <old>"; return 2; }
  [ -n "$new" ] || { err "memory supersede: --by <new> is required"; return 2; }

  local fold fnew
  fold=$(mem_path_for "$old") || return 2
  fnew=$(mem_path_for "$new") || return 2
  [ -f "$fold" ] || { err "memory supersede: no '$old'"; return 1; }
  [ -f "$fnew" ] || { err "memory supersede: no '$new' (create it first with 'memory add')"; return 1; }

  local type description created created_session body
  type=$(memory_field "$fold" "type")
  description=$(memory_field "$fold" "description")
  created=$(memory_field "$fold" "created")
  created_session=$(memory_field "$fold" "created_session")
  [ -z "$created_session" ] && created_session=$(memory_field "$fold" "originSessionId")
  body=$(memory_body "$fold")
  printf '%s' "$body" | memory_write "$fold" "$type" "$description" "superseded" "$created" "$created_session" "$new"
  memory_rebuild_index "$mem_dir" >/dev/null
  printf 'Superseded: %s → %s\n' "$old" "$new"
}

cmd_query() {
  local filter_type="" filter_state="" filter_keyword="" json=1  # query defaults to JSON
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --type)    shift; filter_type="${1:-}"; shift || true ;;
      --state)   shift; filter_state="${1:-}"; shift || true ;;
      --keyword) shift; filter_keyword="${1:-}"; shift || true ;;
      --json)    json=1; shift ;;
      --no-json) json=0; shift ;;
      -h|--help) print_help; return 0 ;;
      *) err "memory query: unknown arg '$1'"; return 2 ;;
    esac
  done
  if [ "$json" -eq 1 ]; then
    mem_emit_json_contract "$filter_type" "$filter_state" "$filter_keyword"
  else
    # Non-JSON form falls through to list-style output.
    cmd_list ${filter_type:+--type "$filter_type"} ${filter_state:+--state "$filter_state"}
  fi
}

cmd_rebuild_index() {
  memory_rebuild_index "$mem_dir" || return 1
  local count
  count=$(memory_list_files "$mem_dir" | wc -l | tr -d ' ')
  echo "Rebuilt $mem_dir/MEMORY.md from $count memory file(s)."
}

print_help() {
  cat <<HELP
claude-state memory — typed CLI for the harness's markdown memory store.

Memories live at:
  $mem_dir

Usage:
  claude-state memory list [--type T] [--state S] [--json]
  claude-state memory get <name> [--json]
  claude-state memory add --name N --type T --description D
                          [--state active|archived|superseded]
                          [--content - | --content "text" | (interactive \$EDITOR)]
  claude-state memory archive <name>
  claude-state memory supersede <old> --by <new>
  claude-state memory query [--type T] [--state S] [--keyword K] [--json | --no-json]
  claude-state memory rebuild-index

The JSON contract emitted by 'query --json' is versioned (version: 1).
Plugins and other tools should read it instead of parsing the markdown
files directly. Schema at https://github.com/bansalbhunesh/claude-code-handoff#memory-plugin-contract

Frontmatter (additive, optional — backwards-compatible with existing files):
  name              (required, derived from filename)
  type              feedback | user | project | reference | <custom>
  description       one-line summary
  state             active | archived | superseded   (default active)
  created           ISO 8601 timestamp
  created_session   handoff session id (legacy alias: originSessionId)
  superseded_by     name of the memory that replaced this one

Environment:
  CS_MEMORY_DIR       Override the memory directory (default: derived from cwd).
  HANDOFF_SESSION_ID  When set, populated as 'created_session' on 'memory add'.
HELP
}

# --- dispatch ---

case "${1:-}" in
  list)            shift; cmd_list "$@" ;;
  get)             shift; cmd_get "$@" ;;
  add)             shift; cmd_add "$@" ;;
  archive)         shift; cmd_archive "$@" ;;
  supersede)       shift; cmd_supersede "$@" ;;
  query)           shift; cmd_query "$@" ;;
  rebuild-index)   shift; cmd_rebuild_index "$@" ;;
  -h|--help|help)  print_help ;;
  "")              print_help; exit 2 ;;
  *)               err "unknown memory subcommand: $1"; print_help >&2; exit 2 ;;
esac

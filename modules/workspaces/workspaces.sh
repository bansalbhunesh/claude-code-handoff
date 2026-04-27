#!/usr/bin/env bash
# claude-state — workspaces module.
# Subcommands: list, show <ws>, rebuild, rename <ws> <alias>.
# Reads packet frontmatter; writes a cache at $handoff_dir/index.json.

set -uo pipefail

__cs_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
while [ "$__cs_dir" != "/" ] && [ ! -f "$__cs_dir/lib/common.sh" ]; do
  __cs_dir=$(dirname "$__cs_dir")
done
if [ ! -f "$__cs_dir/lib/common.sh" ]; then
  echo "claude-state workspaces: cannot locate lib/common.sh" >&2
  exit 1
fi
# shellcheck source=../../lib/common.sh
. "$__cs_dir/lib/common.sh"
# shellcheck source=../../lib/workspace.sh
. "$__cs_dir/lib/workspace.sh"

handoff_dir=$(cs_handoff_dir)
index_file="$handoff_dir/index.json"

# Read a single frontmatter field from a packet. Returns empty if absent.
# Field format: `- key: value` on its own line in the frontmatter block
# (everything before the first blank line). Bounding the scan to the
# frontmatter prevents body content from forging fields. Trims trailing
# whitespace on values so two packets that disagree only on trailing
# spaces don't split into separate index entries.
packet_field() {
  local f="$1" key="$2"
  awk -v k="$key" '
    /^$/ {exit}
    /^- / {
      line = $0
      sub(/^- /, "", line)
      kpos = index(line, ":")
      if (kpos == 0) next
      kk = substr(line, 1, kpos - 1)
      sub(/^ +/, "", kk); sub(/ +$/, "", kk)
      if (kk != k) next
      val = substr(line, kpos + 1)
      sub(/^ +/, "", val)
      sub(/[ \t\r]+$/, "", val)
      print val
      exit
    }
  ' "$f"
}

# Build index.json content on stdout. Walks every packet, extracts
# workspace fields, groups by workspace id, preserves any aliases from
# the existing index. Backfills v0.3 packets via their `cwd:` field.
build_index_json() {
  [ -d "$handoff_dir" ] || { printf '{"version":1,"workspaces":{}}'; return 0; }

  local alias_map="{}"
  if [ -f "$index_file" ]; then
    alias_map=$(jq -c '(.workspaces // {}) | with_entries(.value = (.value.alias // null))' "$index_file" 2>/dev/null) \
      || alias_map="{}"
    [ -z "$alias_map" ] && alias_map="{}"
  fi

  local f sid ws root generated cwd entries=""
  for f in "$handoff_dir"/*.md; do
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue
    sid=$(packet_field "$f" "session")
    [ -n "$sid" ] || continue
    ws=$(packet_field "$f" "workspace")
    root=$(packet_field "$f" "workspace_root")
    generated=$(packet_field "$f" "generated")
    if [ -z "$ws" ]; then
      cwd=$(packet_field "$f" "cwd")
      if [ -n "$cwd" ]; then
        root=$(workspace_root_for "$cwd")
        ws=$(workspace_id_for "$root") || ws=""
      fi
    fi
    [ -n "$ws" ] || continue
    entries+=$(jq -nc \
      --arg sid "$sid" --arg ws "$ws" --arg root "$root" --arg g "$generated" \
      '{sid:$sid, ws:$ws, root:$root, generated:$g}')$'\n'
  done

  if [ -z "$entries" ]; then
    printf '{"version":1,"workspaces":{}}'
    return 0
  fi

  printf '%s' "$entries" | jq -s --argjson aliases "$alias_map" '
    group_by(.ws)
    | map({
        key: (.[0].ws),
        value: {
          root: (.[0].root),
          alias: ($aliases[.[0].ws] // null),
          first_seen: ([.[].generated] | map(select(. != "")) | min // ""),
          last_seen:  ([.[].generated] | map(select(. != "")) | max // ""),
          packet_count: length,
          sessions: ([.[] | {sid, generated}] | sort_by(.generated) | reverse | map(.sid))
        }
      })
    | from_entries
    | {version: 1, workspaces: .}
  '
}

# Write the index atomically. Validates JSON before mv.
write_index() {
  mkdir -p "$handoff_dir"
  local tmp content
  tmp=$(mktemp "$index_file.tmp.XXXXXX") || return 1
  content=$(build_index_json) || { rm -f "$tmp"; return 1; }
  printf '%s' "$content" > "$tmp"
  if jq -e . "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$index_file"
  else
    rm -f "$tmp"
    err "claude-state workspaces: rebuild produced invalid JSON; aborting"
    return 1
  fi
}

cmd_list() {
  write_index >/dev/null || return 1
  local count
  count=$(jq -r '.workspaces | length' "$index_file" 2>/dev/null) || count=0
  if [ "$count" -eq 0 ]; then
    echo "No workspaces. Run a session in a project, or 'claude-state workspaces rebuild'."
    return 0
  fi
  printf '%-50s %7s  %s\n' "WORKSPACE" "PACKETS" "LAST SEEN"
  # Use \x1F (Unit Separator) as the field separator. \t collapses
  # adjacent tabs (read treats whitespace IFS as a run), which made the
  # "alias is null" case shift root into the alias slot. \x01 (SOH) is
  # silently not honored as IFS by bash 3.2 read on macOS — read returns
  # the whole line in the first variable. \x1F is the right tool.
  jq -r '
    .workspaces
    | to_entries
    | sort_by(.value.last_seen)
    | reverse
    | .[]
    | [.key, (.value.packet_count|tostring), .value.last_seen, (.value.alias // ""), (.value.root // "")]
    | join("")
  ' "$index_file" \
  | while IFS=$'\37' read -r ws cnt last alias_to root; do
      name="$ws"
      [ -n "$alias_to" ] && name="$ws ($alias_to)"
      printf '%-50s %7s  %s\n' "$name" "$cnt" "$last"
      [ -n "$root" ] && printf '%-50s %7s  %s\n' "  → $root" "" ""
    done
  # Pipelines with `set -o pipefail` propagate the read loop's final
  # exit status (1 — the loop exits when read hits EOF). Force success.
  return 0
}

cmd_show() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    err "workspaces show: missing workspace name"
    return 2
  fi
  write_index >/dev/null || return 1
  # Resolve aliases too: if `name` matches a workspace's alias, use the
  # canonical id instead. Lets `claude-state ws show <alias>` work after
  # a `rename`, which is the obvious user expectation.
  local resolved
  resolved=$(jq -r --arg n "$name" '
    if .workspaces[$n] then $n
    else (.workspaces | to_entries[] | select(.value.alias == $n) | .key) // empty
    end
  ' "$index_file" 2>/dev/null)
  if [ -n "$resolved" ]; then
    name="$resolved"
  fi
  local exists
  exists=$(jq -r --arg w "$name" '.workspaces[$w] // empty | length' "$index_file" 2>/dev/null) || exists=""
  if [ -z "$exists" ]; then
    err "workspaces show: no workspace '$name'. Use 'claude-state workspaces' to list."
    return 1
  fi
  printf 'Workspace: %s\n' "$name"
  jq -r --arg w "$name" '.workspaces[$w] | "  root:  \(.root // "?")\n  alias: \(.alias // "(none)")\n  first: \(.first_seen)\n  last:  \(.last_seen)\n  count: \(.packet_count)\n"' "$index_file"
  echo "Packets:"
  jq -r --arg w "$name" '.workspaces[$w].sessions[]' "$index_file" \
  | while IFS= read -r sid; do
      pf="$handoff_dir/$sid.md"
      if [ -f "$pf" ]; then
        mtime=$(file_mtime "$pf")
        age=$(human_age "$mtime")
        printf '  %-40s  %s ago\n' "$sid" "$age"
      else
        printf '  %-40s  (packet missing — run rebuild)\n' "$sid"
      fi
    done
}

cmd_rebuild() {
  write_index || return 1
  local count
  count=$(jq -r '.workspaces | length' "$index_file" 2>/dev/null) || count=0
  echo "Rebuilt index for $count workspace(s) at $index_file."
}

cmd_rename() {
  local name="${1:-}" alias_to="${2:-}"
  if [ -z "$name" ] || [ -z "$alias_to" ]; then
    err "workspaces rename: usage: claude-state workspaces rename <workspace> <alias>"
    return 2
  fi
  write_index >/dev/null || return 1
  local exists
  exists=$(jq -r --arg w "$name" '.workspaces[$w] // empty | length' "$index_file" 2>/dev/null) || exists=""
  if [ -z "$exists" ]; then
    err "workspaces rename: no workspace '$name'"
    return 1
  fi
  local tmp
  tmp=$(mktemp "$index_file.tmp.XXXXXX") || return 1
  jq --arg w "$name" --arg a "$alias_to" '.workspaces[$w].alias = $a' "$index_file" > "$tmp"
  if jq -e . "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$index_file"
    echo "Renamed: $name → $alias_to"
  else
    rm -f "$tmp"
    err "workspaces rename: produced invalid JSON; aborting"
    return 1
  fi
}

cmd_help() {
  cat <<HELP
claude-state workspaces — list/show/rebuild/rename workspaces.

Usage:
  claude-state workspaces                      List all workspaces.
  claude-state workspaces show <ws>            Show one workspace + its packets.
  claude-state workspaces rebuild              Rebuild $index_file from packets.
  claude-state workspaces rename <ws> <alias>  Set a human-friendly alias.

A workspace groups sessions by project. Identity = <basename>-<8-hex>,
where the 8-char sha256 prefix prevents collisions across clones.
HELP
}

case "${1:-}" in
  list|"")        shift || true; cmd_list "$@" ;;
  show)           shift;          cmd_show "$@" ;;
  rebuild)        shift;          cmd_rebuild "$@" ;;
  rename)         shift;          cmd_rename "$@" ;;
  -h|--help|help) cmd_help ;;
  *)              err "unknown workspaces subcommand: $1"; cmd_help >&2; exit 2 ;;
esac

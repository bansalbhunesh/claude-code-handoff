# lib/workspace.sh — workspace identity resolver.
# A "workspace" groups sessions by project: usually a git repo. Identity
# is `<sanitized-basename>-<hash8>`, where hash8 is sha256 of the absolute
# root path truncated to 8 hex chars. The hash prevents collisions when
# two clones of the same repo live at different paths, or when two
# unrelated dirs share a basename.
#
# Sourced by snapshot.sh, modules/workspaces/workspaces.sh, and the CLI.

[ -n "${__CS_WORKSPACE_LOADED:-}" ] && return 0
__CS_WORKSPACE_LOADED=1

# Source common.sh (idempotent) for hash8() and err().
__ws_lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$__ws_lib_dir/common.sh"

# Resolve the canonical workspace root for a given cwd.
# - If cwd is inside a git repository: return its toplevel.
# - Else: return cwd itself, absolutized.
# Always echoes a path, never errors.
workspace_root_for() {
  local cwd="$1"
  [ -n "$cwd" ] || cwd="$(pwd)"
  if command -v git >/dev/null 2>&1; then
    local top
    top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || top=""
    if [ -n "$top" ]; then
      printf '%s\n' "$top"
      return 0
    fi
  fi
  (cd "$cwd" 2>/dev/null && pwd) || printf '%s\n' "$cwd"
}

# Compute the workspace id for a given root.
#   id = "<basename-sanitized>-<hash8>"
# Basename is lowercased; non-alnum runs collapse to "-".
# hash8 is sha256(root) truncated to 8 hex chars.
workspace_id_for() {
  local root="$1"
  [ -n "$root" ] || return 1
  local base sanitized hash
  base=$(basename "$root")
  sanitized=$(printf '%s' "$base" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  [ -z "$sanitized" ] && sanitized="ws"
  hash=$(printf '%s' "$root" | hash8) || return 1
  printf '%s-%s\n' "$sanitized" "$hash"
}

# Convenience: id from cwd directly.
workspace_id_for_cwd() {
  local root
  root=$(workspace_root_for "$1")
  workspace_id_for "$root"
}

# Optional: git remote URL of a workspace root. Empty if not a repo or no
# origin remote configured. Used for workspace metadata.
workspace_git_remote() {
  local root="$1"
  command -v git >/dev/null 2>&1 || return 0
  git -C "$root" remote get-url origin 2>/dev/null || return 0
}

# shellcheck shell=bash
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
#   (Note: git worktrees return the worktree's own toplevel, not the main
#   checkout — so a feature-branch worktree gets its own workspace id.
#   Documented behavior; matches `git rev-parse --show-toplevel` semantics.)
# - Else: return cwd itself, absolutized.
# Returns rc=1 (no output) on empty input — falling back to the caller's
# pwd would silently mis-attribute hooks that arrive with an empty cwd
# field, polluting whichever workspace the user happened to be in.
workspace_root_for() {
  local cwd="${1:-}"
  [ -n "$cwd" ] || return 1
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
# Basename is stripped of CR/LF/tab first (a path containing a literal
# newline would otherwise produce a workspace id containing a newline,
# breaking line-oriented index.json consumers); then lowercased; then
# non-alnum runs collapse to "-". Empty result falls back to "ws".
# hash8 is sha256(root) truncated to 8 hex chars; preserves uniqueness
# even when sanitization erases the whole basename.
workspace_id_for() {
  local root="${1:-}"
  [ -n "$root" ] || return 1
  local base sanitized hash
  base=$(basename "$root")
  base=$(printf '%s' "$base" | tr -d '\n\r\t')
  sanitized=$(printf '%s' "$base" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  [ -z "$sanitized" ] && sanitized="ws"
  hash=$(printf '%s' "$root" | hash8) || return 1
  printf '%s-%s\n' "$sanitized" "$hash"
}

# Convenience: id from cwd directly. Returns rc=1 on empty cwd.
workspace_id_for_cwd() {
  local cwd="${1:-}"
  [ -n "$cwd" ] || return 1
  local root
  root=$(workspace_root_for "$cwd") || return 1
  workspace_id_for "$root"
}

# Optional: git remote URL of a workspace root. Empty if not a repo or no
# origin remote configured. Used for workspace metadata. Rejects empty
# input — `git -C ""` defaults to the caller's pwd, which would leak
# the wrong repo's origin into a packet whose payload had no cwd.
workspace_git_remote() {
  local root="${1:-}"
  [ -n "$root" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  git -C "$root" remote get-url origin 2>/dev/null || return 0
}

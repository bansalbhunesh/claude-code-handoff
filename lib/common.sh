# shellcheck shell=bash
# lib/common.sh — shared helpers for claude-state.
# Sourced by bin/claude-state, modules/*/*.sh, and (transitively) tests/lib.sh.
# Pure bash 3.2-compatible: no associative arrays, no ${var,,}, no mapfile.
# Designed to be re-sourceable; every definition is idempotent.

# Guard against double-sourcing so subscripts that source us indirectly
# (e.g. a module that sources workspace.sh which sources common.sh) don't
# redefine functions and reset state.
[ -n "${__CS_COMMON_LOADED:-}" ] && return 0
__CS_COMMON_LOADED=1

# Print to stderr.
err() { printf '%s\n' "$*" >&2; }

# Cross-platform stat. Try GNU (-c) first; on Linux, BSD (-f) does
# *filesystem* stat and silently returns garbage — the bug v0.3.x fixed.
file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

# Human-readable age, e.g. "3d 4h", "12h 5m", "47m".
human_age() {
  local now age d h m
  now=$(date +%s)
  age=$((now - $1))
  d=$((age / 86400))
  h=$(((age % 86400) / 3600))
  m=$(((age % 3600) / 60))
  if [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
  else printf '%dm' "$m"
  fi
}

# Resolve the Claude Code home directory. Honors CLAUDE_HOME override.
cs_claude_dir() {
  printf '%s' "${CLAUDE_HOME:-$HOME/.claude}"
}

# Resolve the handoff data directory. Stays at ~/.claude/handoff/ for
# back-compat with existing v0.3 packets — we never moved the data.
cs_handoff_dir() {
  printf '%s/handoff' "$(cs_claude_dir)"
}

# 8-character hex digest of stdin (sha256 truncated). Used for workspace ids.
# Falls back across sha256sum (Linux/Git-Bash), shasum (macOS), openssl (universal).
hash8() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -c1-8
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -c1-8
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 | sed -E 's/^[^=]*= //' | cut -c1-8
  else
    err "claude-state: no sha256 tool available (sha256sum/shasum/openssl)"
    return 1
  fi
}

# Validate session id charset. Real Claude Code uses UUIDs, but we accept
# any [A-Za-z0-9._-]+ that starts alphanumeric so traversal/dotfile attacks
# cannot succeed when an attacker controls the JSON payload.
is_valid_session_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# List packets in handoff dir, newest mtime first, one path per line.
# Skips symlinks and non-files. Empty output if dir missing.
list_packets_by_mtime() {
  local dir="${1:-}"
  [ -n "$dir" ] || dir=$(cs_handoff_dir)
  [ -d "$dir" ] || return 0
  local f m
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue
    m=$(file_mtime "$f")
    [ -n "$m" ] || continue
    printf '%s\t%s\n' "$m" "$f"
  done | sort -rn | cut -f2-
}

# Detect Git Bash / MSYS / Cygwin on Windows. NTFS doesn't enforce POSIX
# modes, so chmod-based assertions are meaningless there.
is_windows() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

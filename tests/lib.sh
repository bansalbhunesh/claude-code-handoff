#!/usr/bin/env bash
# tests/lib.sh — shared helpers for the claude-code-handoff test suite.
# Pure bash 3.2-compatible: no associative arrays, no `${var,,}`, no
# `mapfile`, etc. Sourced by both run-all.sh and the individual test files.

# Counters. Incremented with simple arithmetic; bash 3.2 does not support
# `((var++))` returning a non-zero exit code reliably under `set -e`, so
# we use `var=$((var + 1))` instead.
PASS=0
FAIL=0
FAIL_NAMES=""

# Repo root, set by the runner. Tests resolve script paths against this.
: "${REPO_ROOT:=}"

# List of tempdirs to clean up on EXIT. Space-separated; portable to bash 3.2.
__TMPDIRS=""

__cleanup() {
  # Disable failure handling during cleanup; we don't want a stale rm to
  # mask the real test result.
  set +e
  for d in $__TMPDIRS; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap __cleanup EXIT

# Create a tempdir, register it for EXIT cleanup, and echo its path.
# Usage: tmp=$(tmpdir)
tmpdir() {
  local d
  d=$(mktemp -d 2>/dev/null) || d=$(mktemp -d -t cchandoff)
  __TMPDIRS="$__TMPDIRS $d"
  printf '%s\n' "$d"
}

# assert <condition-as-string> <message>
# Evaluates the condition with `eval` so callers can pass things like:
#   assert '[ -f "$file" ]' "expected $file to exist"
#
# On failure, prints the message to stderr and exits 1. We use `exit`
# rather than `return` because tests run inside a `( "$fn" )` subshell
# spawned by `run`; an `exit 1` there fails the subshell cleanly,
# letting the runner mark the test failed AND short-circuiting any
# subsequent assertions in the same function (so the first failure is
# the one reported, rather than a cascade of irrelevant follow-ups).
assert() {
  local cond="$1"
  local msg="${2:-assertion failed: $1}"
  if eval "$cond"; then
    return 0
  fi
  printf '    assert: %s\n' "$msg" >&2
  printf '    cond:   %s\n' "$cond" >&2
  exit 1
}

# run <name> <function>
# Executes <function> in a subshell so a failing assert doesn't
# contaminate later tests, captures stderr, and prints ok/FAIL.
run() {
  local name="$1"
  local fn="$2"
  local err
  err=$(mktemp 2>/dev/null) || err=$(mktemp -t cchandoff-err)
  if ( "$fn" ) 2>"$err"; then
    PASS=$((PASS + 1))
    printf 'ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    FAIL_NAMES="$FAIL_NAMES $name"
    printf 'FAIL  %s\n' "$name"
    if [ -s "$err" ]; then
      sed 's/^/      /' < "$err"
    fi
  fi
  rm -f "$err"
}

# Cross-platform stat for the low-12-bits permission octal of a file.
# macOS / BSD: stat -f %Lp ; GNU: stat -c %a.
file_mode() {
  local f="$1"
  stat -f %Lp "$f" 2>/dev/null || stat -c %a "$f" 2>/dev/null
}

# Best-effort symlink creation, used by tests that probe symlink refusal.
# Returns 0 if the symlink was created, 1 otherwise (e.g. on filesystems
# that don't support them — bail the test in that case).
mklink() {
  ln -s "$1" "$2" 2>/dev/null
}

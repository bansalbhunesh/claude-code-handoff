#!/usr/bin/env bash
# tests/run-all.sh — top-level test runner for claude-code-handoff.
# Discovers tests/test_*.sh, runs each one in its own subshell, prints a
# summary, and exits non-zero if any test failed. Compatible with macOS
# bash 3.2 and Ubuntu bash 5+.

set -u

# Resolve the repo root from this script's location so the suite works
# whether invoked as `bash tests/run-all.sh`, `cd tests && bash run-all.sh`,
# or by absolute path.
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd)
export REPO_ROOT TESTS_DIR

# Sanity-check tooling up front. Tests assume bash and jq are present;
# warn loudly here rather than letting individual tests fail mysteriously.
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required but not on PATH" >&2
  exit 1
fi
if ! command -v mktemp >/dev/null 2>&1; then
  echo "error: mktemp is required but not on PATH" >&2
  exit 1
fi

# Aggregate counters across files.
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_FAILED_NAMES=""

shopt -s nullglob 2>/dev/null || true
test_files=$(ls "$TESTS_DIR"/test_*.sh 2>/dev/null | sort)

if [ -z "$test_files" ]; then
  echo "no test_*.sh files found in $TESTS_DIR" >&2
  exit 1
fi

for f in $test_files; do
  printf '\n# %s\n' "$(basename "$f")"
  # Each test file runs in its own subshell so PASS/FAIL counters and EXIT
  # traps don't leak between files. We capture the per-file counters by
  # having the file print a final `# pass=N fail=N` line we parse.
  out=$(mktemp 2>/dev/null) || out=$(mktemp -t cchandoff-out)
  if bash "$f" > "$out" 2>&1; then
    :
  else
    : # Per-file exit code is informational; we trust the printed counters.
  fi
  cat "$out"
  # Parse the last `# pass=N fail=N` line.
  summary=$(grep -E '^# pass=[0-9]+ fail=[0-9]+' "$out" | tail -n 1)
  if [ -n "$summary" ]; then
    p=$(printf '%s' "$summary" | sed -E 's/^# pass=([0-9]+).*/\1/')
    fl=$(printf '%s' "$summary" | sed -E 's/^.*fail=([0-9]+).*/\1/')
    TOTAL_PASS=$((TOTAL_PASS + p))
    TOTAL_FAIL=$((TOTAL_FAIL + fl))
    if [ "$fl" -gt 0 ]; then
      names=$(grep -E '^# failed:' "$out" | tail -n 1 | sed 's/^# failed://')
      TOTAL_FAILED_NAMES="$TOTAL_FAILED_NAMES $names"
    fi
  else
    # File didn't print a counter line — treat as failure.
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    TOTAL_FAILED_NAMES="$TOTAL_FAILED_NAMES $(basename "$f")"
    echo "  (no summary from $(basename "$f"); marking failed)"
  fi
  rm -f "$out"
done

TOTAL=$((TOTAL_PASS + TOTAL_FAIL))
printf '\n%s tests, %s pass, %s fail\n' "$TOTAL" "$TOTAL_PASS" "$TOTAL_FAIL"
if [ "$TOTAL_FAIL" -gt 0 ]; then
  printf 'failed:%s\n' "$TOTAL_FAILED_NAMES"
  exit 1
fi
exit 0

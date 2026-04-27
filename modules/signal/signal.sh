#!/usr/bin/env bash
# claude-state — signal module.
# Subcommand: claude-state signal <packet> [--explain] [--threshold N] [--raw]
# Re-scores an existing packet's "Recent assistant reasoning" section
# without re-snapshotting. Useful for tuning HANDOFF_SIGNAL_MIN before
# committing it to your shell env / hook config.

set -uo pipefail

__cs_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
while [ "$__cs_dir" != "/" ] && [ ! -f "$__cs_dir/lib/common.sh" ]; do
  __cs_dir=$(dirname "$__cs_dir")
done
if [ ! -f "$__cs_dir/lib/common.sh" ]; then
  echo "claude-state signal: cannot locate lib/common.sh" >&2
  exit 1
fi
# shellcheck source=../../lib/common.sh
. "$__cs_dir/lib/common.sh"
# shellcheck source=../../lib/signal.sh
. "$__cs_dir/lib/signal.sh"

handoff_dir=$(cs_handoff_dir)

print_help() {
  cat <<HELP
claude-state signal — re-score a packet's "Recent assistant reasoning" section.

Usage:
  claude-state signal <session-id> [options]
  claude-state signal <path-to-packet>.md [options]

Options:
  --threshold N   Override HANDOFF_SIGNAL_MIN (default 3). 0 keeps everything.
  --explain       Show every block's score + reason, sorted by index.
  --raw           Emit the raw block list (no scoring), for piping.
  -h, --help      Show this help.

Heuristic rubric (sum of, all matched on the block's text):
  +3 length > 200 chars
  +2 decision keywords     (decision|chose|going with|landed on|conclusion)
  +2 blocker keywords      (blocked|broken|fails|error|can't|won't|doesn't work)
  +2 goal-restate keywords (goal|trying to|need to|so that|in order to)
  +2 file/path mentions    (.ts/.js/.py/.go/.rs/.md/.sh/... or src/lib/tests/)
  -5 pure ack              (^ok/got it/sure/done/thanks/yeah/yep/cool/nice/alright)
  -3 length < 80 AND no positive signals above

Mandatory keep-rules (override threshold):
  - First message that contains goal-restate keywords
  - The last 2 messages (recency safety net)

Environment:
  HANDOFF_SIGNAL_MIN=N         Default threshold (3).
  HANDOFF_SIGNAL_DETAILS=0|1   Whether snapshot embeds dropped blocks in a
                               <details> block at packet-bottom (default 1 = on).
HELP
}

# Resolve the input arg into an absolute packet path. Accepts either a
# session id (resolved against $handoff_dir/<sid>.md) or a path that
# exists on disk.
resolve_packet() {
  local input="$1"
  if [ -f "$input" ]; then
    printf '%s\n' "$input"
    return 0
  fi
  local candidate="$handoff_dir/$input.md"
  if [ -f "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  err "signal: no packet for '$input' (tried as a path and as $candidate)"
  return 1
}

# Extract the "## Recent assistant reasoning" body out of a packet, then
# split it into the original block strings. The snapshot writes blocks
# joined by "\n\n---\n\n", so we split on that boundary. Returns a JSON
# array of strings on stdout.
#
# Includes blocks from a `<details>` block at the bottom too, so that
# `claude-state signal --raw <packet>` reflects the full reasoning history.
extract_blocks() {
  local f="$1"
  awk '
    BEGIN {section = ""; details = 0}
    /^## Recent assistant reasoning$/ {section = "reasoning"; next}
    /^<details>/                       {details = 1; next}
    /^<\/details>/                     {details = 0; next}
    /^## /                             {if (section == "reasoning") section = ""; next}
    section == "reasoning"             {print}
    details == 1                       {print}
  ' "$f" \
  | awk '
    BEGIN {RS = "\n\n---\n\n"; FS = ""}
    NF > 0 || $0 != "" {
      gsub(/^\*\*\[score [^]]*\]\*\*\n\n/, "")
      gsub(/^\n+/, "")
      gsub(/\n+$/, "")
      if (length($0) > 0) print
    }
  ' \
  | jq -Rs 'split("\n\n") | map(select(. != ""))' 2>/dev/null \
  || jq -nc '[]'
}

# Block extractor: read the packet's "Recent assistant reasoning" section
# (kept body) and the optional <details> block (dropped body) separately,
# concatenate with an explicit separator, then split into individual
# blocks. Strip any "**[score N, reason]**" headers added by the lossless
# <details> emitter. Reading the two sections separately avoids the
# "kept-block-merges-with-first-dropped-block" ambiguity that arises
# when both sections use `\n\n---\n\n` between blocks but not between
# sections.
extract_blocks_simple() {
  local f="$1"
  local kept dropped
  kept=$(awk '
    /^## Recent assistant reasoning$/   {flag = 1; next}
    /^<details>$/                        {flag = 0}
    /^## /                               {flag = 0}
    flag                                 {print}
  ' "$f")
  dropped=$(awk '
    /^<details>$/                        {flag = 1; next}
    /^<\/details>$/                      {flag = 0}
    /^<summary>/                         {next}
    flag                                 {print}
  ' "$f")
  # Always insert the separator so even an empty `dropped` section
  # produces a clean split (the empty trailing element is filtered out
  # by `select(length > 0)` below).
  printf '%s\n\n---\n\n%s' "$kept" "$dropped" \
  | jq -Rs '
      split("\n\n---\n\n")
      | map(
          gsub("^\\*\\*\\[score [^\\]]*\\]\\*\\*\\n\\n"; "")
          | gsub("^\\n+"; "")
          | gsub("\\n+$"; ""))
      | map(select(length > 0))
    '
}

cmd_signal_main() {
  local threshold=""
  local mode="filter"  # filter | explain | raw
  local input=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --threshold)
        shift
        [ "$#" -gt 0 ] || { err "signal: --threshold needs a value"; return 2; }
        case "$1" in
          ''|*[!0-9-]*) err "signal: --threshold must be an integer (got '$1')"; return 2 ;;
        esac
        threshold="$1"
        shift
        ;;
      --explain)  mode="explain"; shift ;;
      --raw)      mode="raw"; shift ;;
      -h|--help)  print_help; return 0 ;;
      --)         shift; break ;;
      -*)         err "signal: unknown flag '$1'"; return 2 ;;
      *)
        if [ -z "$input" ]; then input="$1"
        else err "signal: unexpected extra arg '$1'"; return 2
        fi
        shift
        ;;
    esac
  done

  [ -n "$input" ] || { err "signal: missing packet (session-id or path)"; print_help >&2; return 2; }

  local packet
  packet=$(resolve_packet "$input") || return 1

  local blocks
  blocks=$(extract_blocks_simple "$packet")
  local block_count
  block_count=$(printf '%s' "$blocks" | jq 'length')
  if [ "$block_count" -eq 0 ]; then
    err "signal: no reasoning blocks found in $packet"
    return 1
  fi

  if [ "$mode" = "raw" ]; then
    printf '%s\n' "$blocks"
    return 0
  fi

  local result
  result=$(printf '%s' "$blocks" | signal_filter "$threshold")

  if [ "$mode" = "explain" ]; then
    local kept_count dropped_count thr
    kept_count=$(printf '%s' "$result" | jq -r '.kept | length')
    dropped_count=$(printf '%s' "$result" | jq -r '.dropped | length')
    thr=$(printf '%s' "$result" | jq -r '.threshold')
    printf 'signal explain — packet: %s\n' "$packet" >&2
    printf 'threshold=%s   kept=%s   dropped=%s   total=%s\n\n' "$thr" "$kept_count" "$dropped_count" "$block_count" >&2
    printf '%s\n' "$result" | signal_explain
    return 0
  fi

  # Default mode: filter and emit kept blocks (plus optional <details>).
  printf '%s\n' "$result" | signal_render
}

cmd_signal_main "$@"

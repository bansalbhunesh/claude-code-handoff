# shellcheck shell=bash
# lib/signal.sh — relevance scorer for assistant reasoning blocks.
# Sourced by modules/handoff/snapshot.sh and modules/signal/signal.sh.
#
# Heuristic, not LLM-based. Hooks must stay sync, fast, no network.
# A future `claude-state signal --rescore --llm <packet>` could be a
# separate, opt-in offline step (out of scope for v0.5).

[ -n "${__CS_SIGNAL_LOADED:-}" ] && return 0
__CS_SIGNAL_LOADED=1

# Source common.sh for hash8/err helpers and re-source-guard idiom.
__sig_lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$__sig_lib_dir/common.sh"

# CS_SIGNAL_FILTER — a jq filter string that scores + classifies an
# array of text strings. Input: ["text1","text2",...]. Output:
#   {
#     kept:    [{idx, text, score, reason}],
#     dropped: [{idx, text, score, reason}],
#     threshold: N
#   }
#
# Mandatory keep-rules (override threshold):
#   - First message containing goal-restate keywords
#   - The last 2 messages (recency safety net)
#   - Any message scoring >= threshold
#
# Score rubric (sum of):
#   +3 length > 200 chars
#   +2 decision keywords     (decision|chose|going with|landed on|conclusion)
#   +2 blocker keywords      (blocked|broken|fails|error|can't|won't|doesn't work)
#   +2 goal-restate keywords (goal|trying to|need to|so that|in order to)
#   +2 file/path mentions    (\S+\.(ts|js|py|go|rs|md|sh|json|yml|yaml|tsx|jsx)\b
#                             OR (^|/)(src|lib|tests?|app|cmd|pkg|internal)/)
#   -5 pure ack              (^(ok|okay|got it|sure|done|thanks?|yeah|yep|nope|cool|nice|alright)\b.{0,40}$)
#   -3 short with no signal  (length < 80 AND no positive matches)
#
# Reason strings are joined with "+" so each kept/dropped entry shows
# what fired (e.g. "decision+blocker" or "ack_penalty+too_short").
CS_SIGNAL_FILTER='
  def score_text:
    . as $t
    | [
        {points: 3, reason: "long",     hit: (($t|length) > 200)},
        {points: 2, reason: "decision", hit: ($t | test("(?i)\\b(decision|chose|going with|landed on|conclusion)\\b"))},
        {points: 2, reason: "blocker",  hit: ($t | test("(?i)\\b(blocked|broken|fails|errors?|can.?t|won.?t|doesn.?t work)\\b"))},
        {points: 2, reason: "goal",     hit: ($t | test("(?i)\\b(goal|trying to|need to|so that|in order to)\\b"))},
        {points: 2, reason: "file_ref", hit: ($t | test("\\S+\\.(ts|js|py|go|rs|md|sh|json|yml|yaml|tsx|jsx)\\b|(^|/)(src|lib|tests?|app|cmd|pkg|internal)/"))}
      ]
    | map(select(.hit))
    | . as $pos_hits
    | ($pos_hits | length) as $pos_count
    | (
        $pos_hits
        + (if ($t | test("(?i)^(ok|okay|got it|sure|done|thanks?|yeah|yep|nope|cool|nice|alright)\\b.{0,40}$"))
           then [{points: -5, reason: "ack_only"}]
           else [] end)
        + (if ($pos_count == 0) and (($t|length) < 80)
           then [{points: -3, reason: "too_short_no_signal"}]
           else [] end)
      )
    | {
        score:   ([.[].points] | add // 0),
        reasons: ([.[].reason])
      };

  # Mandatory-keep predicate: first goal-flagged message wins the goal
  # slot; the last 2 messages always survive (recency safety net).
  . as $blocks
  | ($blocks | length) as $total
  | [range(0; $total) as $i
     | $blocks[$i]
     | (. | score_text) as $s
     | ($i >= $total - 2)                                                                           as $is_last2
     | (($s.reasons | index("goal")) // null)                                                       as $has_goal
     | {
         idx:    $i,
         text:   .,
         score:  $s.score,
         reasons: $s.reasons,
         is_goal: ($has_goal != null),
         is_last2: $is_last2
       }]
  | reduce .[] as $m (
      {scored: [], goal_seen: false};
      .goal_seen as $gs
      | ($m.is_goal and ($gs | not)) as $first_goal
      | .scored += [$m + {first_goal: $first_goal}]
      | .goal_seen = ($gs or $m.is_goal))
  | .scored
  | map(. + {
      # threshold <= 0 is the documented escape hatch ("keep everything,
      # filtering off"). Score-based threshold check applies only when
      # threshold is a positive integer. Mandatory rules (last_2,
      # first_goal) override regardless.
      keep: (.is_last2 or .first_goal or ($threshold <= 0) or (.score >= $threshold)),
      reason: (
        if   .is_last2     then "last_2"
        elif .first_goal   then "first_goal"
        elif ($threshold <= 0) then (if (.reasons | length) > 0 then (.reasons | join("+")) else "no_filter" end)
        else (if (.reasons | length) > 0 then (.reasons | join("+")) else "score:\(.score)" end)
        end
      )
    })
  | {
      threshold: $threshold,
      kept:      map(select(.keep)    | {idx, text, score, reason}),
      dropped:   map(select(.keep|not)| {idx, text, score, reason})
    }
'

# Apply the filter. Reads a JSON array of strings on stdin. Writes the
# {threshold, kept, dropped} object on stdout. Threshold defaults to
# HANDOFF_SIGNAL_MIN, then 3.
signal_filter() {
  local threshold="${1:-${HANDOFF_SIGNAL_MIN:-3}}"
  jq --argjson threshold "$threshold" "$CS_SIGNAL_FILTER"
}

# Render a {kept, dropped} object into the textual sections used in a
# packet body. Reads JSON on stdin, writes markdown on stdout.
#   ## Recent assistant reasoning
#   <kept[0].text>
#   ---
#   <kept[1].text>
#   ...
#   <details>...</details>   (if dropped is non-empty AND details flag is set)
#
# HANDOFF_SIGNAL_DETAILS=1 (default) emits the lossless <details> block.
# HANDOFF_SIGNAL_DETAILS=0 suppresses it (kept-only output).
signal_render() {
  local include_details="${HANDOFF_SIGNAL_DETAILS:-1}"
  jq -r --argjson include_details "$include_details" '
    (.kept | map(.text) | join("\n\n---\n\n")) as $kept_text
    | (.dropped | length) as $dropped_count
    | $kept_text
    + (if ($include_details == 1) and ($dropped_count > 0) then
        "\n\n<details>\n<summary>" + ($dropped_count|tostring) + " low-signal block(s) dropped (signal threshold "
        + (.threshold|tostring) + ")</summary>\n\n"
        + (.dropped
           | map("**[score \(.score), \(.reason)]**\n\n\(.text)")
           | join("\n\n---\n\n"))
        + "\n\n</details>"
       else "" end)
  '
}

# Render an --explain table for a {kept, dropped} object. Each line:
#   [+] idx  score  reason         <first 60 chars of text>
#   [-] idx  score  reason         <first 60 chars of text>
signal_explain() {
  jq -r '
    (.kept   | map(. + {kept: true})) as $k
    | (.dropped | map(. + {kept: false})) as $d
    | ($k + $d) | sort_by(.idx)
    | .[]
    | "\(if .kept then "[+]" else "[-]" end) \(.idx | tostring | .[0:3] | (. + "   ")[0:3])  score=\(.score | tostring | (. + "    ")[0:4])  \(.reason | (. + "                  ")[0:18])  \(.text | gsub("\\s+"; " ") | .[0:60])"
  '
}

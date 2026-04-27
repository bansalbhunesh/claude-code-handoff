#!/usr/bin/env bash
# claude-code-handoff v0.3.0 — resume
# Reads the most relevant handoff packet and emits it as additionalContext
# for a fresh session via the documented SessionStart hookSpecificOutput
# shape. Wired (opt-in) to SessionStart matchers `compact` and `resume`.
# Always exits 0 so it never blocks session startup.

set -uo pipefail

payload=$(cat)
# Reject malformed/empty payloads silently — never want a half-injected
# hook pushing the wrong session's packet into a fresh window. We use
# `-e 'type=="object"'` rather than `jq empty` because some jq builds
# return exit 0 on parse errors.
printf '%s' "$payload" | jq -e 'type=="object"' >/dev/null 2>&1 || exit 0

session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
source_field=$(printf '%s' "$payload" | jq -r '.source // "unknown"' 2>/dev/null)

claude_dir="${CLAUDE_HOME:-$HOME/.claude}"
handoff_dir="$claude_dir/handoff"
[ -d "$handoff_dir" ] || exit 0
# Refuse a symlinked handoff dir.
[ -L "$handoff_dir" ] && exit 0

# Prefer a packet matching this session_id (covers compact + resume of
# the same session), otherwise fall back to the most recently modified
# packet that is a regular file (not a symlink).
target=""
if [ -n "$session_id" ] && [ -f "$handoff_dir/$session_id.md" ] && [ ! -L "$handoff_dir/$session_id.md" ]; then
  target="$handoff_dir/$session_id.md"
else
  while IFS= read -r f; do
    [ -L "$f" ] && continue
    [ -f "$f" ] || continue
    target="$f"
    break
  done < <(ls -t "$handoff_dir"/*.md 2>/dev/null)
fi

[ -n "$target" ] || exit 0
[ -f "$target" ] || exit 0
[ -L "$target" ] && exit 0

prior_id=$(basename "$target" .md)

# UTF-8-safe truncation: read the whole file with `--rawfile` (which
# escapes correctly into JSON) and slice by codepoint inside jq. jq
# string slicing is codepoint-aware, so this never produces invalid
# UTF-8 in `additionalContext` even if a multibyte char would have
# straddled the cap. The cap is in codepoints, not bytes.
max_codepoints=16000

jq -nc \
  --rawfile rawctx "$target" \
  --arg src "$source_field" \
  --arg prior "$prior_id" \
  --argjson max "$max_codepoints" \
  '
  ($rawctx | length) as $len
  | (if $len > $max
       then ($rawctx | .[0:$max]) + "\n\n…(truncated; full packet at ~/.claude/handoff/" + $prior + ".md)"
       else $rawctx
     end) as $ctx
  | {
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: ("[claude-code-handoff] Resuming after " + $src + ". Loading packet from session " + $prior + ". Treat the contents below as background context for what was being worked on; ask the user to confirm before acting on it.\n\n---\n\n" + $ctx)
      }
    }
  '

exit 0

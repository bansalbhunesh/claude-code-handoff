---
description: Load the most recent handoff packet so this session can pick up where the prior one left off.
---

You are resuming work from a prior Claude Code session that ended (compaction, /clear, crash, or manual exit).

Find the most recently modified handoff file in `~/.claude/handoff/` and read it. The argument `$ARGUMENTS`, if non-empty, is a session id — prefer `~/.claude/handoff/$ARGUMENTS.md` when set.

Concretely:

1. Run `ls -t ~/.claude/handoff/*.md 2>/dev/null | head -1` to locate the latest packet (or use the argument-specified path if given).
2. Read that file with the Read tool.
3. In your reply, summarize for the user in 4–6 lines:
   - the original goal,
   - what's done vs pending (from the todos / task tracker sections),
   - the last 1–2 decisions or dead-ends worth carrying forward,
   - the file most recently being worked on,
   - and what you propose to do next.
4. Wait for the user to confirm or redirect before taking any action. Do not start editing files based on the packet alone — packets can be stale.

If no handoff file exists, say so plainly and ask the user what they want to work on.

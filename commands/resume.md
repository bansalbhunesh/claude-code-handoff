---
description: Load the most relevant handoff packet so this session can pick up where the prior one left off. Workspace-aware.
allowed-tools: Bash, Read
---

You are resuming work from a prior Claude Code session that ended (compaction, /clear, crash, or manual exit).

Find and read the most relevant handoff file under `~/.claude/handoff/`. The argument `$ARGUMENTS`, if non-empty, is either a session id (treat as a specific packet) or free-text keywords (treat as a search).

Concretely:

1. Locate the right packet by trying these in order, and stop at the first one that succeeds:
   - **Specific id:** if `$ARGUMENTS` looks like a session id (UUID-shaped) and `~/.claude/handoff/$ARGUMENTS.md` exists, use that path.
   - **Keyword search:** if `$ARGUMENTS` is non-empty and not a known session id, run `claude-state resume --keywords "$ARGUMENTS"` via the **Bash** tool and use the path it prints (the line after `── claude-state resume: <id> ──`).
   - **Workspace-aware default:** run `claude-state resume` with no args. It first tries the newest packet for the current cwd's workspace and falls back to the global newest. Use the printed packet.
   - **Bare fallback** (only if `claude-state` is not installed): run `ls -t ~/.claude/handoff/*.md 2>/dev/null | head -1` and take its output.
2. Read the chosen file with the **Read** tool.
3. In your reply, summarize for the user in 4–6 lines:
   - the original goal,
   - what's done vs pending (from the todos / task tracker sections),
   - the last 1–2 decisions or dead-ends worth carrying forward,
   - the file most recently being worked on,
   - and what you propose to do next.
4. Wait for the user to confirm or redirect before taking any action. Do not start editing files based on the packet alone — packets can be stale.
5. If the packet has a `continues_from:` header field, mention that prior chained session by id so the user knows there's earlier history available at `~/.claude/handoff/<that-id>.md`.
6. If the packet has a `workspace:` header field that does NOT match the current cwd's workspace (run `claude-state workspaces` to list, or compare against the packet's `workspace_root:`), call that out — the packet may belong to a different project.

If no handoff file exists, say so plainly and ask the user what they want to work on.

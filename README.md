# claude-code-handoff

Survive Claude Code's auto-compaction and session crashes by snapshotting state to a structured "handoff packet" you can resume from.

## The problem

Claude Code auto-compacts when context fills. The summary it generates keeps the high-level shape but loses the *texture* — the decisions you ruled out, the dead ends you already tried, the specific reasoning behind in-flight work. If a session crashes or you `/clear`, the loss is total.

Manually re-explaining "where I was" wastes tokens and time, and the new session has to re-discover things you already figured out.

## What it does

On every `PreCompact` and `SessionEnd` event, a hook script writes a markdown packet to `~/.claude/handoff/<session_id>.md` containing:

- **Original goal** — first real user message
- **Current todos** — last `TodoWrite` snapshot
- **Task tracker** — `TaskCreate` / `TaskUpdate` reduced to current state
- **Recently edited files** — last 20 `Edit` / `Write` / `MultiEdit` / `NotebookEdit` calls
- **Recent assistant reasoning** — last 5 prose blocks (where decisions and dead-ends live)

A `/resume` slash command reads the most recent packet and produces a 4–6 line summary, then waits for your direction before doing anything.

## Requirements

- Claude Code (CLI)
- `bash`
- `jq`

## Install

```bash
git clone https://github.com/<you>/claude-code-handoff.git
cd claude-code-handoff
./install.sh
```

The installer:

- Copies `handoff-snapshot.sh` to `~/.claude/scripts/`
- Copies `resume.md` to `~/.claude/commands/`
- Creates `~/.claude/handoff/`
- Backs up your existing `~/.claude/settings.json` and merges the hooks block (preserves any other hooks you already have)

It is idempotent — safe to run multiple times.

## Verify

1. In any Claude Code session, run `/compact`. The status line should show:
   ```
   PreCompact [...handoff-snapshot.sh] completed successfully
   ```
2. List packets:
   ```bash
   ls -t ~/.claude/handoff/
   ```
   The newest one should be your current session id.
3. Open a new session and type `/resume`. Claude should locate the latest packet and summarize it in 4–6 lines.

## How it works

Three hook events are wired:

| Event | Matcher | When it fires |
|---|---|---|
| `PreCompact` | `auto` | Just before context-limit-driven auto-compaction |
| `PreCompact` | `manual` | When you type `/compact` |
| `SessionEnd` | (any) | When a session terminates (`clear`, `logout`, `prompt_input_exit`, etc.) |

Each fires the same script, which receives `session_id`, `transcript_path`, `cwd`, and the event name on stdin and produces a packet. Always exits 0 — never blocks the underlying event.

## Limitations

- **Goal heuristic is fuzzy.** "Original goal" is the first user message that doesn't start with `<` (command/tool meta) or `⏺` (a Claude reply pasted back). Real first prompts that happen to start with those characters will be skipped.
- **Each packet describes one session.** When auto-compaction creates a new session id, the new session's packet won't include the previous session's edits or todos. Older packets remain on disk under their own ids.
- **Manual resume only for now.** You have to type `/resume` after a compaction or restart. See roadmap for auto-resume.
- **Goal field shows the compact summary on already-compacted sessions.** Accurate but not always what you want.

## Uninstall

```bash
./uninstall.sh
```

Removes the script and slash command, strips our hook entries from `settings.json` (preserving any other hooks), and leaves `~/.claude/handoff/` in place. Pass `--purge` to delete saved packets too.

## Roadmap

- **v2 — automatic resume.** Wire a `SessionStart` hook with `matcher: "compact"` and `matcher: "resume"` that emits the packet via `hookSpecificOutput.additionalContext`, so the new session sees prior state without you typing `/resume`. Deferred pending verification that `SessionStart` accepts that injection shape.
- **Smarter goal extraction** — fall back to the longest short user message in the first N turns when the heuristic finds nothing useful.
- **Cross-session chaining** — when a packet is written for a session that succeeded an earlier one, link to the prior packet so resume can walk back.

## Contributing

PRs welcome. The interesting work is on the roadmap items above; especially welcome are reports of cases where the goal/task/file heuristics fail in practice — paste a redacted packet and a description of what should have appeared.

## License

MIT — see [LICENSE](LICENSE).

# claude-code-handoff

[![CI](https://github.com/bansalbhunesh/claude-code-handoff/actions/workflows/ci.yml/badge.svg)](https://github.com/bansalbhunesh/claude-code-handoff/actions/workflows/ci.yml)

Survive Claude Code's auto-compaction and session crashes by snapshotting state to a structured "handoff packet" you can resume from.

## The problem

Claude Code auto-compacts when context fills. The summary it generates keeps the high-level shape but loses the *texture* — the decisions you ruled out, the dead ends you already tried, the specific reasoning behind in-flight work. If a session crashes or you `/clear`, the loss is total.

Manually re-explaining "where I was" wastes tokens and time, and the new session has to re-discover things you already figured out.

## What it does

On every `PreCompact` and `SessionEnd` event, a hook script writes a markdown packet to `~/.claude/handoff/<session_id>.md` containing:

- **Original goal** — first real user message (filtered using the JSONL `isCompactSummary` / `isMeta` flags, not just text prefix matching)
- **Continues from** — when this session is a successor (post-compaction or `--resume`), the prior session id, so packets form a chain
- **Current todos** — last `TodoWrite` snapshot (often empty in modern sessions; see Limitations)
- **Task tracker** — `TaskCreate` / `TaskUpdate` reduced to current state
- **Recently edited files** — last 20 `Edit` / `Write` / `MultiEdit` / `NotebookEdit` calls
- **Recent assistant reasoning** — last 5 prose blocks (where decisions and dead-ends live)

Two ways to consume the packet:

- **Manual** (default): a `/resume` slash command reads the most recent packet, summarizes it in 4–6 lines, and waits for your direction.
- **Automatic** (opt-in via `./install.sh --auto`): a `SessionStart` hook injects the packet via `hookSpecificOutput.additionalContext` on every `compact` or `resume` start — no typing required. Opt-in because some of the underlying mechanism (size limits, presentation to the model) is undocumented; see Limitations.

## Requirements

- Claude Code (CLI)
- `bash` (3.2+; macOS default works)
- `jq` ≥ 1.6 (for the `//=` operator the installer uses; macOS Homebrew, Ubuntu 20.04+ apt, all newer distros are fine)

## Install

```bash
git clone https://github.com/bansalbhunesh/claude-code-handoff.git
cd claude-code-handoff
./install.sh           # manual mode (recommended for first-time)
# or:
./install.sh --auto    # also wire SessionStart auto-resume
```

The installer:

- Copies `handoff-snapshot.sh` and `handoff-resume.sh` to `~/.claude/scripts/`
- Copies `claude-handoff` (the management CLI) to `~/.claude/bin/`
- Copies `resume.md` to `~/.claude/commands/`
- Creates `~/.claude/handoff/` (mode 700)
- Backs up your existing `~/.claude/settings.json` and merges the hooks block (preserves any other hooks you already have, including third-party hooks on the same matcher)

It is idempotent — safe to run multiple times. To switch modes, re-run with or without `--auto`: running without the flag actively *removes* any previously-installed `SessionStart` auto-resume entries (mode toggling works in both directions). To remove everything, run `./uninstall.sh`.

## Verify

1. In any Claude Code session, run `/compact`. The status line should show:
   ```
   PreCompact [...handoff-snapshot.sh] completed successfully
   ```
2. Inspect packets:
   ```bash
   ~/.claude/bin/claude-handoff list
   ```
   The newest entry should be your current session id.
3. Open a new session and type `/resume`. Claude should locate the latest packet and summarize it in 4–6 lines.

## Daily use

The `claude-handoff` CLI wraps `~/.claude/handoff/` so you don't have to know the directory layout. Add `~/.claude/bin` to your `PATH` for convenience, or invoke it by full path.

```bash
claude-handoff list                    # all packets, newest first
claude-handoff view                    # most recent packet
claude-handoff view <session-id>       # specific packet
claude-handoff status                  # install state, mode, jq version, packet count
claude-handoff path                    # print the handoff dir path
claude-handoff prune --older-than 30d  # delete packets older than 30 days
claude-handoff prune --keep 20         # keep only the 20 most recent
```

`prune` is interactive — it lists what it will delete and asks for confirmation before deleting anything.

## How it works

Hook events wired by `install.sh`:

| Event | Matcher | Mode | Script | When it fires |
|---|---|---|---|---|
| `PreCompact` | `auto` | always | `handoff-snapshot.sh` | Just before context-limit-driven auto-compaction |
| `PreCompact` | `manual` | always | `handoff-snapshot.sh` | When you type `/compact` |
| `SessionEnd` | (any) | always | `handoff-snapshot.sh` | When a session terminates (`clear`, `logout`, `prompt_input_exit`, etc.) |
| `SessionStart` | `compact` | `--auto` only | `handoff-resume.sh` | When a fresh session begins after compaction |
| `SessionStart` | `resume` | `--auto` only | `handoff-resume.sh` | When a session is resumed (`claude --resume`) |

`handoff-snapshot.sh` receives `session_id`, `transcript_path`, `cwd`, and the event name on stdin, parses the transcript JSONL, and writes a packet. Always exits 0.

`handoff-resume.sh` (auto mode only) receives `session_id`, `cwd`, and `source` on stdin, finds the most relevant packet (matching `session_id` first, then most recently modified), caps the content to ~16 KB, and emits a JSON object with `hookSpecificOutput.additionalContext` so Claude Code injects the packet into the new session's context. Always exits 0.

## Security

Handoff packets capture **verbatim user prompts and assistant prose** — including anything you pasted into the conversation (API keys, `.env` content, passwords, tokens) and anything the assistant repeated back in its replies. The packet then sits on disk under `~/.claude/handoff/` until you delete it.

What the plugin does to mitigate this:

- The `~/.claude/handoff/` directory is created mode `700` (owner-only access); newly written packets are mode `600`.
- The script refuses to write through a symlinked handoff directory or symlinked output path.
- The session-id is regex-validated before being used as a filename, blocking path-traversal attempts.

What you should do:

- **Don't paste secrets into the conversation if you're not okay with them ending up in `~/.claude/handoff/`.** If you do, run `./uninstall.sh --purge` (or `rm -rf ~/.claude/handoff/`) to delete the saved packets.
- Treat `~/.claude/handoff/` as sensitive — back it up only to encrypted destinations, never commit it.
- The `/resume` slash command will need `Bash` permission the first time you run it (it does `ls -t` to find the latest packet). Approve when prompted.

The plugin does **no** automatic rotation — packets accumulate indefinitely. Disk usage grows linearly with session count. Sweep periodically with something like `find ~/.claude/handoff -mtime +30 -delete` if you want.

## Limitations

- **Each packet describes one session.** Older packets remain on disk under their own ids; chains are linked via the `continues_from` field, but resume currently only loads one packet at a time.
- **`Current todos` is usually empty.** Modern Claude Code sessions use `TaskCreate` / `TaskUpdate` rather than `TodoWrite`. The `Current todos` section is kept for back-compat; the actually-useful section is `Task tracker`.
- **Auto-resume relies on undocumented behavior.** `SessionStart` hooks documenting `hookSpecificOutput.additionalContext` is documented; the size limit, the way the injected text is presented to the model, and the version-availability of the field are not. The plugin caps injection at 16 KB defensively. If a future Claude Code release changes the mechanism, fall back to manual mode (`./uninstall.sh && ./install.sh`).
- **Goal heuristic is best-effort.** Filters out compact summaries (via the JSONL `isCompactSummary` flag), command meta (`isMeta` flag, plus `<`/`⏺` text-prefix fallback), and empty messages. Sessions whose entire first stretch is slash-commands will report `(unknown)` — that's accurate, not a bug.
- **`SessionEnd` doesn't distinguish crash from clean exit.** It does fire on `clear` / `logout` / `prompt_input_exit`, but not on hard kills (SIGKILL) or harness crashes — those silently lose the packet.

## Troubleshooting

**`/compact` runs but no packet appears in `~/.claude/handoff/`.**

Run `claude-handoff status` and check that `PreCompact hook: wired`. If it shows `NOT WIRED`, the install merge didn't take — re-run `./install.sh`. If it shows `wired` but a packet still doesn't appear, the script is silently no-opping; check whether `jq` is on your `PATH` (the hook runner inherits a minimal env on some platforms). The script always exits 0 by design (so it never blocks compaction), so failures are invisible — temporarily add `set -x` near the top of `~/.claude/scripts/handoff-snapshot.sh` and tail `~/.claude/logs/` (or wherever your shell's stderr goes) to see what's happening.

**`/resume` doesn't appear in the slash menu.**

Claude Code re-scans `~/.claude/commands/` automatically — no restart needed. Confirm the file exists with `ls -la ~/.claude/commands/resume.md`. If it does and `/resume` still isn't recognized, check the frontmatter is intact (the file must start with `---`).

**`/resume` works but Claude says "no handoff file exists."**

You haven't triggered any of `PreCompact` / `SessionEnd` yet — packets are only written on those events. Force one with `/compact` in any active session.

**Auto-resume installed but new sessions don't pick up prior context.**

Some `SessionStart` hook injection behavior is undocumented (size limits, presentation to the model). If `claude-handoff status` shows `mode: auto` but resumed sessions don't reference the packet, fall back to manual mode by re-running `./install.sh` (no flag), and rely on typing `/resume` instead.

**`install.sh` says "jq >= 1.6 is required."**

Update with `brew install jq` (macOS) or your package manager. On older Linux distros (Debian 10, etc.), use `pip install jq` or grab a static binary from <https://jqlang.github.io/jq/download/>.

## Uninstall

```bash
./uninstall.sh
```

Removes the script and slash command, strips our hook entries from `settings.json` (preserving any other hooks), and leaves `~/.claude/handoff/` in place. Pass `--purge` to delete saved packets too.

## Roadmap

- **Cross-session chain walking.** Today `continues_from` is captured in the packet but `/resume` only loads one packet. Make resume walk the chain (limited depth) and merge the packets, so a session that's been compacted multiple times can still recover early-session decisions.
- **Pre-compact size monitoring.** Currently we snapshot at `PreCompact` (the only context-aware trigger Claude Code exposes). If a `context_used_pct` env var ever appears, fire snapshots earlier (e.g., 70% full) so packets don't always reflect the most-degraded state.
- **Empirical sizing for `additionalContext`.** Test what size of injection actually makes it through and adjust the 16 KB cap based on findings.

## Contributing

PRs welcome. The interesting work is on the roadmap items above; especially welcome are reports of cases where the goal/task/file heuristics fail in practice — paste a redacted packet and a description of what should have appeared.

## License

MIT — see [LICENSE](LICENSE).

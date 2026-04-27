# claude-code-handoff

[![CI](https://github.com/bansalbhunesh/claude-code-handoff/actions/workflows/ci.yml/badge.svg)](https://github.com/bansalbhunesh/claude-code-handoff/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.2.0-blue.svg)](https://github.com/bansalbhunesh/claude-code-handoff/releases)

> **Don't lose your work when Claude Code compacts.**
> Snapshot your session state to a structured "handoff packet" the next session can resume from — automatically or with a single `/resume` command.

---

## The problem

Claude Code auto-compacts when the conversation runs out of context. The summary it generates keeps a high-level shape, but it loses **the texture you actually care about**:

- The decisions you ruled out (and why)
- The dead ends you already tried
- The specific reasoning behind in-flight work
- What file the assistant was about to edit when context ran out

If a session crashes, or you `/clear` to start fresh, the loss is **total** — the new session has no idea what happened before.

`claude-code-handoff` fixes this by hooking into Claude Code's lifecycle events. Right before compaction or session end, it writes a small structured markdown file capturing the goal, the plan, the recent decisions, the files touched, and the prior session id (so chains are walkable). A `/resume` slash command — or an opt-in `SessionStart` hook — loads that packet back into the next session.

No background daemon. No code change. Pure bash + jq, ~250 lines of plugin code, one command to install, one command to remove.

---

## Quick start

```bash
git clone https://github.com/bansalbhunesh/claude-code-handoff.git
cd claude-code-handoff
./install.sh
```

That's it. The next time a session compacts (or you type `/compact`), a packet appears in `~/.claude/handoff/`. To pick up where you left off in a new session:

```
/resume
```

Claude reads the most recent packet and gives you a 4–6 line summary, then waits for your direction.

> **Want it fully automatic?** Run `./install.sh --auto` instead. A `SessionStart` hook will inject the packet on every post-compaction or resumed session, no `/resume` typing required. (Opt-in because some of the underlying mechanism is undocumented — see [Limitations](#limitations).)

---

## What a packet looks like

A real packet from a session — markdown, human-readable, ~1–2 KB:

```markdown
# Handoff packet
- session: 300b907c-d452-4064-ac2c-ee2b9c98213f
- event: PreCompact
- generated: 2026-04-26T23:16:48Z
- cwd: /Users/ankur
- continues_from: 7c2db8e1-...   # only present if this is a chained session

## Original goal
build a /handoff slash command + PreCompact hook

## Current todos
(no TodoWrite calls in this session)

## Task tracker
#1. [completed] Write handoff-snapshot.sh
#2. [completed] Wire PreCompact hook
#3. [in_progress] Test the round-trip

## Recently edited files
- Write: ~/.claude/scripts/handoff-snapshot.sh
- Edit:  ~/.claude/settings.json
- Write: ~/.claude/commands/resume.md

## Recent assistant reasoning
The keystone is `PreCompact` → `SessionStart(source=compact)`. Snapshot at
PreCompact, re-inject at SessionStart. Verified with /compact in another
terminal — the hook fires and the packet lands.

---

Next: confirm /resume can read it from a fresh session before adding the
auto-resume `SessionStart` hook.
```

---

## Two ways to resume

| | Manual mode (default) | Auto-resume mode (`--auto`) |
|---|---|---|
| **How** | Type `/resume` in a new session | New session loads the packet automatically |
| **Triggered by** | You | `SessionStart` hook with `compact` / `resume` matchers |
| **Permission prompt on first use?** | One-time `Bash` approval (pre-approved by the slash command's `allowed-tools`) | None |
| **Stability** | Documented and stable | Relies on `SessionStart`'s `additionalContext` injection (works today, but the size limit and presentation-to-model behavior are undocumented) |
| **Recommended for** | First-time users, low-trust environments | Power users, after you've confirmed manual mode works |

Switching modes:

```bash
./install.sh --auto    # turn on auto-resume
./install.sh           # turn off auto-resume (re-running without --auto strips it)
```

Toggling works in both directions. Third-party `SessionStart` hooks (from other plugins) are preserved across toggles.

---

## Daily use — the `claude-handoff` CLI

`bin/claude-handoff` is installed to `~/.claude/bin/`. Add that to your `$PATH` (or invoke by full path).

```text
$ claude-handoff list
300b907c-d452-4064-ac2c-ee2b9c98213f        1h 30m ago

1 packet(s). Use 'claude-handoff view <session-id>' to read one.
```

```text
$ claude-handoff status
claude-code-handoff status
  version (cli):      0.2.0
  jq:                 1.6
  handoff dir:        present (mode 700)
  snapshot script:    installed
  resume script:      installed
  /resume command:    installed
  PreCompact hook:    wired
  SessionEnd hook:    wired
  SessionStart hook:  not wired (manual mode)
  mode:               manual
  packets stored:     1
```

| Subcommand | What it does |
|---|---|
| `claude-handoff list` | All packets, newest first, with relative ages |
| `claude-handoff view` | Show the most recent packet |
| `claude-handoff view <session-id>` | Show a specific packet |
| `claude-handoff status` | Install state, mode, jq version, packet count |
| `claude-handoff path` | Print the handoff directory path |
| `claude-handoff prune --older-than 30d` | Delete packets older than 30 days (interactive) |
| `claude-handoff prune --keep 20` | Keep 20 most recent, delete the rest (interactive) |
| `claude-handoff help` | Show usage |

`prune` is **always interactive** — it lists what it will delete and asks before removing anything.

---

## How it works

```
                           ┌─────────────────────┐
                           │   long Claude Code  │
                           │       session       │
                           └──────────┬──────────┘
                                      │ PreCompact
                                      │ (auto or /compact)
                                      ▼
                           ┌─────────────────────┐
                           │ handoff-snapshot.sh │
                           │ reads transcript,   │
                           │ writes packet       │
                           └──────────┬──────────┘
                                      │
                                      ▼
                  ~/.claude/handoff/<session-id>.md
                                      │
            ┌─────────────────────────┴─────────────────────────┐
            │                                                   │
            ▼ manual                                            ▼ auto
    ┌────────────────┐                          ┌──────────────────────┐
    │ user types     │                          │ SessionStart hook    │
    │   /resume      │                          │ runs handoff-resume  │
    │ in new session │                          │ on next session      │
    └────────┬───────┘                          └─────────┬────────────┘
             │                                            │
             ▼                                            ▼
                ┌────────────────────────────────────────┐
                │ Claude reads the packet and continues  │
                │ where the prior session left off       │
                └────────────────────────────────────────┘
```

Five hook events get wired:

| Event | Matcher | Mode | Script | Fires when |
|---|---|---|---|---|
| `PreCompact` | `auto` | always | `handoff-snapshot.sh` | Just before context-limit-driven auto-compaction |
| `PreCompact` | `manual` | always | `handoff-snapshot.sh` | When you type `/compact` |
| `SessionEnd` | (any) | always | `handoff-snapshot.sh` | When a session terminates (`clear`, `logout`, `prompt_input_exit`) |
| `SessionStart` | `compact` | `--auto` only | `handoff-resume.sh` | When a fresh session begins after compaction |
| `SessionStart` | `resume` | `--auto` only | `handoff-resume.sh` | When a session is resumed (`claude --resume`) |

`handoff-snapshot.sh` reads the session transcript JSONL, parses out the goal / todos / task tracker / edited files / recent reasoning, and writes a markdown packet. Always exits 0 — never blocks the underlying event.

`handoff-resume.sh` finds the most relevant packet (matching `session_id` first, then most recently modified), caps it at 16,000 codepoints (UTF-8-safe), and emits the documented `hookSpecificOutput.additionalContext` JSON shape that Claude Code uses to inject context into a fresh session.

---

## Requirements

- **Claude Code** (CLI)
- **`bash`** 3.2 or newer (macOS default works)
- **`jq`** ≥ 1.6 (we use the `//=` operator). On macOS: `brew install jq`. On recent Linux distros: `apt-get install jq` or your package manager.

The plugin makes no network calls, has no dependencies beyond bash + jq + standard POSIX tools (`find`, `stat`, `mv`, `mktemp`, `date`).

---

## Security

Handoff packets capture **verbatim user prompts and assistant prose** — including anything you pasted into the conversation (API keys, `.env` content, passwords, tokens) and anything the assistant repeated back in its replies. Packets sit on disk under `~/.claude/handoff/` until you delete them.

What the plugin does:

- **Mode 700** on `~/.claude/handoff/` (owner-only access)
- **Mode 600** on every newly-written packet
- **Refuses to write** through a symlinked handoff directory or symlinked output path
- **Validates `session_id`** with a regex before using it as a filename, blocking path-traversal
- **Hooks always exit 0** — they never block compaction or session shutdown, but they also can't break your terminal

What you should do:

- **Don't paste secrets into the conversation** if you're not okay with them ending up in `~/.claude/handoff/`. If you do, run `./uninstall.sh --purge` (or `claude-handoff prune --keep 0`) to delete saved packets.
- Treat `~/.claude/handoff/` as sensitive — back it up only to encrypted destinations, never commit it.
- The plugin does **no automatic rotation** — packets accumulate indefinitely. Sweep periodically with `claude-handoff prune --older-than 30d` or `find ~/.claude/handoff -mtime +30 -delete`.

---

## Troubleshooting

### `/compact` runs but no packet appears

Run `claude-handoff status`. If `PreCompact hook` shows `NOT WIRED`, the install didn't merge — re-run `./install.sh`.

If it shows `wired` but a packet still doesn't appear:
- The script always exits 0 (so nothing is logged on failure). Temporarily add `set -x` near the top of `~/.claude/scripts/handoff-snapshot.sh` and reproduce — you'll see what's failing in your shell's stderr.
- Check `jq` is on your `PATH` — the hook runner inherits a minimal env on some platforms.

### `/resume` doesn't appear in the slash menu

Claude Code auto-discovers `~/.claude/commands/`. No restart needed. Check the file exists:

```bash
ls -la ~/.claude/commands/resume.md
```

If it does and `/resume` still isn't recognized, confirm the frontmatter is intact (the file must start with `---`).

### `/resume` works but says "no handoff file exists"

You haven't triggered `PreCompact` or `SessionEnd` yet — packets only appear on those events. Force one with `/compact` in any active session.

### Auto-resume installed but new sessions don't pick up prior context

Some `SessionStart` injection behavior is undocumented. If `claude-handoff status` shows `mode: auto` but resumed sessions don't reference the packet, fall back to manual:

```bash
./install.sh   # re-run without --auto
```

You can still type `/resume` to load context manually.

### `install.sh: jq >= 1.6 is required`

Update jq:

| OS | Command |
|---|---|
| macOS | `brew install jq` |
| Debian/Ubuntu | `sudo apt-get install jq` |
| Fedora/RHEL | `sudo dnf install jq` |
| Windows (WSL) | use the Linux command for your distro |
| anywhere | static binary at <https://jqlang.github.io/jq/download/> |

---

## Limitations

- **`Current todos` is usually empty.** Modern Claude Code uses `TaskCreate` / `TaskUpdate` rather than `TodoWrite`. The actually-useful section is `Task tracker`.
- **Auto-resume relies on undocumented behavior.** `SessionStart`'s `additionalContext` injection is documented; size limits, version-availability of the field, and presentation to the model are not. The plugin caps injection at 16,000 codepoints defensively.
- **`SessionEnd` doesn't fire on hard kills.** Clean exits (`/clear`, logout, `Ctrl-C` to prompt) trigger it; SIGKILL or harness crashes don't, and lose the packet for that session.
- **Each packet describes one session.** Older packets remain on disk under their own ids; chains link via `continues_from`, but `/resume` currently loads only one packet at a time.
- **Goal heuristic is best-effort.** Filters out compact summaries (`isCompactSummary` flag), command meta (`isMeta` flag, plus `<` / `⏺` prefix fallback), empty messages, and assistant paste-backs. Slash-command-only sessions correctly report `(unknown)`.

---

## Uninstall

```bash
./uninstall.sh             # remove scripts + hooks, keep packets
./uninstall.sh --purge     # also delete ~/.claude/handoff/ entirely
```

Strips only entries pointing at our scripts (`handoff-snapshot.sh` and `handoff-resume.sh`); preserves any third-party hooks on the same matchers.

---

## Tested

49 integration tests across 5 suites:

- `test_snapshot.sh` — empty, binary, symlinked, malformed transcripts; mode bits; regex rejection
- `test_resume.sh` — UTF-8 boundary truncation; symlink refusal; valid JSON shape; payload validation
- `test_installers.sh` — fresh install, mode toggling, third-party hook coexistence, malformed settings
- `test_e2e.sh` — full snapshot → resume round trip
- `test_cli.sh` — every CLI subcommand including prune confirm/abort flows

Run them all:

```bash
bash tests/run-all.sh
```

Expected output ends with `49 tests, 49 pass, 0 fail`. CI runs the same suite on macOS and Ubuntu via [GitHub Actions](.github/workflows/ci.yml) on every push and PR.

---

## Roadmap

- **Cross-session chain walking.** `continues_from` is captured today but `/resume` loads one packet at a time. Make `/resume` walk the chain (limited depth) and merge packets, so a session compacted multiple times can recover early-session decisions.
- **Pre-compact size monitoring.** If a `context_used_pct` env var ever appears in the hook payload, fire snapshots earlier (e.g., 70% full) so packets don't always reflect the most-degraded state.
- **Packet rotation built in.** Auto-prune older than N days at install time, configurable.
- **Empirical sizing for `additionalContext`.** Test what size injection actually makes it through and adjust the 16K-codepoint cap.

---

## Contributing

Issues and PRs welcome. Useful contributions:

- **Failure cases** — paste a redacted packet and explain what should have appeared. Even one example is enough to derive a regression test.
- **Cross-platform fixes** — particularly Linux quirks (`stat`, `find`, `date`) we missed.
- **Better goal extraction** — heuristics that work on transcript shapes we haven't seen.

Before submitting a PR:

```bash
bash tests/run-all.sh         # all 49 should pass
shellcheck install.sh uninstall.sh scripts/*.sh tests/*.sh bin/claude-handoff
```

CI runs the same checks on Linux and macOS, so green locally usually means green in CI.

---

## License

MIT — see [LICENSE](LICENSE).

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.1] - 2026-04-28

### Fixed
- `bin/claude-state` resolves symlink chains before walking up for `lib/common.sh`. Without this, `BASH_SOURCE[0]` on macOS bash returned the symlink path (e.g. `/opt/homebrew/bin/claude-state` under Homebrew), causing the upward walk to fail to find the lib at the actual install location (`/opt/homebrew/Cellar/claude-state/0.6.1/libexec/lib/`). Surfaced when shipping the Homebrew tap (https://github.com/bansalbhunesh/homebrew-claude-state); didn't affect the `bash install.sh` path because that lays out the real CLI at `~/.claude/bin/claude-state` (no symlink).

## [0.6.0] - 2026-04-27

**M3: structured memory.** A typed CLI layered on top of the harness's existing markdown memory store at `~/.claude/projects/<sanitized-cwd>/memory/`. Storage doesn't change — the harness keeps reading `MEMORY.md` like always — v0.6 adds state, links, and a versioned JSON plugin contract that other tools can call instead of parsing markdown.

### Added
- `lib/memory.sh` — memory directory resolver (sanitizes cwd by replacing `/` with `-`, matching the harness's observed format), YAML-frontmatter read/write helpers, JSON contract emission, and `MEMORY.md` auto-compile.
- `claude-state memory list [--type T] [--state S] [--json]` — table or JSON output of the user's memories.
- `claude-state memory get <name> [--json]` — read one memory (raw markdown or contract-shape JSON).
- `claude-state memory add --name N --type T --description D` — create a new memory. Content via `--content -` (stdin), `--content "text"`, or interactive `$EDITOR`. Defaults `created` to now and `created_session` from `$HANDOFF_SESSION_ID` or `~/.claude/handoff/.last_session`.
- `claude-state memory archive <name>` — flip state to `archived`. File stays in place; drops from active `MEMORY.md`.
- `claude-state memory supersede <old> --by <new>` — flip `<old>` to `superseded`, write `superseded_by: <new>` link.
- `claude-state memory query [--type T] [--state S] [--keyword K] [--json | --no-json]` — the **plugin contract** entry point. JSON shape is versioned (`version: 1`); plugins read this instead of parsing markdown.
- `claude-state memory rebuild-index` — regenerate `MEMORY.md` from active memories. Sorted by type then name. Honors `MEMORY.md.header` and `MEMORY.md.footer` files (so users can preface manual notes that survive regenerations).
- New frontmatter fields (additive, optional, all default-aware):
  - `state: active | archived | superseded` (defaults to `active`)
  - `created: <iso8601>`
  - `created_session: <session-id>` (legacy alias `originSessionId` is read for back-compat)
  - `superseded_by: <other-name>` (set by `memory supersede`)
- `tests/test_memory.sh` — 18 cases: add round-trip, frontmatter shape, MEMORY.md auto-compile, duplicate-name rejection, traversal-name rejection, get round-trip, list type/state filters, archive flow, supersede flow, query JSON schema (every contract field present, `version: 1`), query filters (type/keyword), legacy `originSessionId` surfacing under canonical `created_session`, rebuild-index idempotency + header/footer support, and malformed-frontmatter no-crash.

### Plugin contract (stable, versioned)

`claude-state memory query --json` emits:

```json
{
  "version": 1,
  "memories": [
    {
      "name":            "<filename without .md>",
      "type":            "feedback | user | project | reference | <custom>",
      "description":     "<one-line>",
      "state":           "active | archived | superseded",
      "created":         "<iso8601 or null>",
      "created_session": "<sid or null>",
      "superseded_by":   "<other-name or null>",
      "path":            "<absolute path>"
    }
  ]
}
```

Plugins should call this CLI instead of parsing markdown. Field additions are non-breaking; field removals or shape changes require a major bump (`version: 2`). Old `version: 1` consumers must keep working through v1.x.

### Tests
- 115 → 133. `tests/test_memory.sh` adds 18 cases.

## [0.5.0] - 2026-04-27

**M2: signal scoring.** Snapshots now triage assistant reasoning blocks through a heuristic relevance scorer. High-signal blocks (decisions, blockers, file references, goal-restates) land in the main `## Recent assistant reasoning` section; low-signal blocks (filler acks, short progress notes) drop into a collapsed `<details>` block at packet bottom — lossless by default.

### Added
- `lib/signal.sh` — heuristic scoring transform. Per-block rubric (sum of):
  - +3 length > 200 chars
  - +2 decision keywords (`decision|chose|going with|landed on|conclusion`)
  - +2 blocker keywords (`blocked|broken|fails|error|can't|won't|doesn't work`)
  - +2 goal-restate keywords (`goal|trying to|need to|so that|in order to`)
  - +2 file/path mentions (`.ts|.js|.py|.go|...` or `(^|/)(src|lib|tests?|app|...)/`)
  - −5 pure ack (`^(ok|okay|got it|sure|done|thanks?|yeah|yep|nope|cool|nice|alright)\b.{0,40}$`)
  - −3 length < 80 AND no positive signals above
- Mandatory keep-rules (override threshold): first goal-restate message, last 2 messages.
- `claude-state signal <packet> [--explain] [--threshold N] [--raw]` — re-score an existing packet without re-snapshotting; useful for tuning `HANDOFF_SIGNAL_MIN` against your own corpus.
- `HANDOFF_SIGNAL_MIN` env var — default 3. Set `0` (or any non-positive) as escape hatch to keep everything (filtering off).
- `HANDOFF_SIGNAL_DETAILS` env var — default 1. Set `0` to suppress the lossless `<details>` block on dropped reasoning.
- `tests/test_signal.sh` — 16 cases covering rubric (ack drops, single-decision below threshold, decision+blocker keeps, long-prose keeps, first-goal mandatory, last-2 mandatory, threshold-0 escape hatch), CLI (`--explain` per-block table, `--threshold` override, invalid args rejected, session-id resolution), and snapshot integration (filtered reasoning, `<details>` on/off, `HANDOFF_SIGNAL_MIN=0` keeps all in main).

### Changed
- `modules/handoff/snapshot.sh` widens its capture window for assistant text from the last 5 blocks to the last 20, then runs them through the signal filter. The kept set lands in the main reasoning section; the rest goes into the `<details>` block. Net result for a typical session: shorter top-of-packet reasoning section with the high-signal points front-and-center, but no information loss.
- `bin/claude-state` adds `signal` subcommand dispatch and updates the help text.
- `install.sh` installs `lib/signal.sh` and `modules/signal/signal.sh`.

### Tests
- 99 → 115. New `test_signal.sh` (16). All existing tests still pass.

## [0.4.0] - 2026-04-27

**Project renamed from `claude-code-handoff` to `claude-state`.** The scope outgrew "handoff" — v0.4 adds workspaces, and v0.5 + v0.6 will add signal scoring and structured memory ([PLAN.md](PLAN.md)). `claude-handoff` is kept as a deprecation shim that forwards to `claude-state` and prints a one-line warning; it will be removed in v0.6. See [MIGRATION.md](MIGRATION.md) for the upgrade path.

### Added
- **Modular layout.** Repo split into `bin/`, `lib/`, `modules/<feature>/`. Shared helpers (`file_mtime`, `human_age`, `hash8`, packet listing, session-id validation) extracted into `lib/common.sh` and sourced by all entry points. Installed at `~/.claude/claude-state/{lib,modules}/...`; binaries at `~/.claude/bin/`.
- **Workspaces (M1).** A workspace groups sessions by project, identified as `<sanitized-basename>-<8-hex-sha256>`. `bin/claude-state` resolves the id from `git rev-parse --show-toplevel` (or cwd if not in a repo); the 8-char hash prevents collisions across clones at different paths.
- `claude-state workspaces` (alias `ws`) — `list`, `show <ws>`, `rebuild`, `rename <ws> <alias>`. The list is cached at `~/.claude/handoff/index.json` and rebuilt on demand from packet frontmatter; aliases survive rebuilds.
- **Workspace frontmatter on packets.** Snapshots now write `workspace:` and `workspace_root:` fields; v0.3 packets are backfilled at index-rebuild time from their `cwd:` field.
- **Smart `claude-state resume`.** Workspace-aware by default — picks the newest packet whose workspace matches the current cwd, falling back to global newest. Flags: `resume --here` (require workspace match, error otherwise), `resume --keywords "..."` (score by distinct keyword hits), `resume <session-id>` (specific packet), or just `resume <free text>` (auto-detected as keywords).
- `commands/resume.md` updated to call `claude-state resume` with smart defaults; degrades gracefully to `ls -t` if the CLI is absent.
- v0.3 → v0.4 settings migration in `install.sh`: legacy hook entries pointing at `~/.claude/scripts/handoff-{snapshot,resume}.sh` are stripped before the new entries are inserted, so an upgrade in place picks up the new layout without manual surgery. The old script files are best-effort removed.
- **Windows runner in CI matrix** (`windows-latest` via Git Bash) joined `ubuntu-latest` and `macos-latest`. `is_windows` helper in `tests/lib.sh` skips POSIX-only assertions on NTFS. `.gitattributes` forces LF on shell/JSON/YAML/Markdown.
- `lib/workspace.sh` — workspace identity resolver, sourceable from any module.
- `tests/test_workspaces.sh` — 16 cases covering id resolution (git/non-git, sanitization, collision avoidance), snapshot frontmatter, rebuild grouping + v0.3 backfill, alias persistence, and all four resume modes.

### Changed
- CLI: `claude-handoff` → `claude-state`. The deprecation shim prints `claude-handoff: deprecated in v0.4.0, use \`claude-state\`. Forwarding.` to stderr and `exec`s the new CLI.
- Hook commands: `~/.claude/scripts/handoff-snapshot.sh` → `~/.claude/claude-state/modules/handoff/snapshot.sh` (same for resume). Settings examples updated.
- `claude-state status` now lists module install paths and detects either v0.3 or v0.4 hook commands.
- Resume hookSpecificOutput banner: `[claude-code-handoff] Resuming after …` → `[claude-state] Resuming after …`.
- Mode-bits tests skip on Windows (NTFS doesn't enforce POSIX modes); behavior tests continue to run there.

### Fixed
- **Cross-platform `stat`** in `bin/claude-state` and `tests/lib.sh`. Previous order `stat -f %Lp || stat -c %a` was wrong on Linux: `stat -f` runs *filesystem* stat there and succeeds with garbage, never reaching the fallback. Flipped to try GNU `-c` first; macOS falls through cleanly.
- CI `shellcheck` false positives suppressed via `.shellcheckrc` (`SC1091`, `SC2012`, `SC2016`, `SC2317`, `SC2329`) and per-file `# shellcheck disable=SC2034`.

### Tests
- 62 → 78 cases. New `test_workspaces.sh` (16). All five existing test files updated for the new module paths and binary name.

## [0.3.0] - 2026-04-27

### Added
- `claude-handoff search <pattern>` — case-insensitive grep across all packets, sorted by mtime, with surrounding context.
- `claude-handoff chain [<session-id>]` — walks the `continues_from` chain backwards and prints each linked packet in order (default: latest packet, depth bounded at 10).
- `claude-handoff edit <session-id>` — opens a packet in `$VISUAL` / `$EDITOR` / `vi`, recommended for redacting secrets without losing the rest.
- `HANDOFF_KEEP_N=N` env var — after each snapshot, keeps only the N newest packets. Built-in retention without cron.
- `HANDOFF_DEBUG=1` env var — appends a one-line status record per hook fire to `~/.claude/handoff/.log`. Restores observability since the snapshot script always exits 0.

### Changed
- `handoff-snapshot.sh` and `handoff-resume.sh` now honor `${CLAUDE_HOME:-$HOME/.claude}` (matching `install.sh` and the CLI). Previously they hard-coded `$HOME/.claude`, so a non-default install location silently broke the round trip.
- README renamed "The 60-second pitch" → "Before vs after"; added Environment knobs table; bumped tests badge to 62/62.

### Fixed
- `cmd_help`'s heredoc was unquoted, so `$EDITOR` in the help text expanded and tripped `set -u` when the variable was unset. Caught by the new tests.

### Tests
- 49 → 62 cases. Added: snapshot CLAUDE_HOME override, HANDOFF_KEEP_N prune, HANDOFF_KEEP_N invalid no-op, HANDOFF_DEBUG log; CLI search (3), chain (3), edit (3).

## [0.2.0] - 2026-04-27

### Added
- `bin/claude-handoff` end-user CLI: `list`, `view`, `path`, `status`, `prune --older-than <N>d`, `prune --keep <N>`, `help`. Cross-platform `stat` and human age formatting.
- Reproducible `tests/` suite with 49 cases across snapshot / resume / installers / e2e / cli, runnable via `bash tests/run-all.sh`.
- GitHub Actions CI workflow on `ubuntu-latest` and `macos-latest`: shellcheck + `bash -n` + JSON validation + the test suite.
- `commands/resume.md` `allowed-tools: Bash, Read` frontmatter so first-time `/resume` doesn't trigger a permission prompt.
- README sections: Daily use (CLI subcommand reference), Troubleshooting (named scenarios), Tested (suite breakdown), Platforms (macOS / Linux / Windows-Git-Bash / WSL / PowerShell), FAQ.
- Mermaid flowchart and sequence diagrams for "How it works".
- Version banners (`# claude-code-handoff vX.Y.Z`) on all scripts.

### Changed
- Slash command's discovery instructions reordered: Bash primary, Glob fallback (Glob's `~` expansion isn't documented).
- README rewritten for scan-then-deep-read structure: hero pitch up top, real packet sample, comparison table for manual vs auto modes.
- Replaced `<you>` placeholder in the install URL with `bansalbhunesh`.

## [0.1.0] - 2026-04-27

### Added
- `handoff-snapshot.sh` snapshot script wired to `PreCompact` (`auto` + `manual` matchers) and `SessionEnd`.
- `handoff-resume.sh` for opt-in `--auto` mode via `SessionStart` (`compact` + `resume` matchers), emitting `hookSpecificOutput.additionalContext` with codepoint-safe truncation.
- `commands/resume.md` slash command for manual recovery.
- `install.sh` / `uninstall.sh` with `jq`-based settings.json merge that preserves third-party hooks; `--auto` flag toggles auto-resume in both directions.
- `continues_from` field linking compacted-session successors to their predecessors.
- Goal extractor using JSONL `isCompactSummary` / `isMeta` flags + array-shape user content support.
- Security hardening: `umask 077`, `chmod 700` on handoff dir, `chmod 600` on packets, symlink protection, session-id regex.

[0.6.1]: https://github.com/bansalbhunesh/claude-code-handoff/releases/tag/v0.6.1
[0.6.0]: https://github.com/bansalbhunesh/claude-code-handoff/releases/tag/v0.6.0
[0.5.0]: https://github.com/bansalbhunesh/claude-code-handoff/releases/tag/v0.5.0
[0.4.0]: https://github.com/bansalbhunesh/claude-code-handoff/releases/tag/v0.4.0
[0.3.0]: https://github.com/bansalbhunesh/claude-code-handoff/releases/tag/v0.3.0
[0.2.0]: https://github.com/bansalbhunesh/claude-code-handoff/releases/tag/v0.2.0
[0.1.0]: https://github.com/bansalbhunesh/claude-code-handoff/releases/tag/v0.1.0

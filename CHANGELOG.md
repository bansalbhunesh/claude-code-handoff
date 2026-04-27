# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[0.4.0]: https://github.com/bansalbhunesh/claude-code-handoff/releases/tag/v0.4.0
[0.3.0]: https://github.com/bansalbhunesh/claude-code-handoff/releases/tag/v0.3.0
[0.2.0]: https://github.com/bansalbhunesh/claude-code-handoff/releases/tag/v0.2.0
[0.1.0]: https://github.com/bansalbhunesh/claude-code-handoff/releases/tag/v0.1.0

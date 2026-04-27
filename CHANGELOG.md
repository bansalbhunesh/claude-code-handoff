# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.3.0]: https://github.com/bansalbhunesh/claude-code-handoff/releases/tag/v0.3.0
[0.2.0]: https://github.com/bansalbhunesh/claude-code-handoff/releases/tag/v0.2.0
[0.1.0]: https://github.com/bansalbhunesh/claude-code-handoff/releases/tag/v0.1.0

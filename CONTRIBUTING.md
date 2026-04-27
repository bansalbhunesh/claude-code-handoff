# Contributing to claude-code-handoff

Thanks for your interest. This is a small repo with a clear scope, so the contribution path is short.

## What's welcome

Most welcome:

- **Failure-case reports.** Paste a redacted packet that should have looked different and tell me what you expected. One example is enough to derive a regression test.
- **Cross-platform fixes.** Particularly Linux / Windows-Git-Bash / WSL quirks around `stat`, `find`, `date`, `mktemp`, `head -c`. The CI matrix only covers macOS and Ubuntu today.
- **Better goal extraction.** The current heuristic uses JSONL `isCompactSummary` / `isMeta` flags + a `<` / `⏺` prefix fallback. If you find transcript shapes where it falls down, send a sample.
- **Documentation improvements.** Clearer phrasing, missing edge cases in the FAQ, examples that didn't occur to me.

Not welcome (please don't):

- Adding heavy dependencies (Node, Python, Go). Plugin is intentionally `bash` + `jq` + standard POSIX tools.
- Adding network calls. The plugin is local-only by design.
- Reformatting / restyling the bash scripts wholesale unless there's a concrete bug.

## Development setup

```bash
git clone https://github.com/bansalbhunesh/claude-code-handoff.git
cd claude-code-handoff
./install.sh       # optional, only needed if you're testing live hooks
```

Everything beyond `install.sh` runs against an isolated `mktemp -d` so your real `~/.claude/` is untouched while iterating.

## Running tests

```bash
bash tests/run-all.sh
```

Expected: `62 tests, 62 pass, 0 fail`. The same suite runs in CI on `ubuntu-latest` and `macos-latest` for every push and PR.

To run a single suite while debugging:

```bash
bash tests/test_snapshot.sh    # or test_resume.sh / test_installers.sh / test_cli.sh / test_e2e.sh
```

To add a new test case, follow the pattern in the existing files: a `t_*()` function with `assert` calls, registered with `run "name" t_function`. The shared helpers are in `tests/lib.sh` (`tmpdir`, `assert`, `run`, `file_mode`, `mklink`).

## Code style

- **Shell:** scripts must be bash 3.2 compatible (macOS default). No associative arrays, no `${var,,}`, no `mapfile`. Use `[[ ... ]]` for tests, `$(cmd)` over backticks, double-quote every variable expansion.
- **`set -uo pipefail`** for runtime scripts (snapshot, resume) — never block the underlying hook event with `set -e`. Always `exit 0`.
- **`set -euo pipefail`** for the installers — they should fail fast on any error.
- **Cross-platform:** prefer POSIX-portable invocations. Where BSD and GNU diverge (`stat`, `head -c` on some Linuxes, etc.), use the `stat -f X 2>/dev/null || stat -c Y` fallback pattern.
- **No eval, no command substitution on user-controlled data.** Every variable expansion in heredocs and command arguments must be safe under arbitrary content (the JSONL transcript may contain anything).

## Commit messages

Loose convention; aim for *why* over *what*:

```
short subject (under 70 chars)

Optional body explaining the motivation and trade-offs. Wrap at ~72.
Reference issues with #N when relevant.
```

PRs touching multiple concerns are easier to review when split into multiple commits — each commit should pass tests on its own.

## Pull-request checklist

Before opening a PR:

- [ ] `bash tests/run-all.sh` is green (62/62 or higher with new tests)
- [ ] `shellcheck install.sh uninstall.sh scripts/*.sh tests/*.sh bin/claude-handoff` is clean
- [ ] If you added a new feature, there's at least one test exercising it
- [ ] `README.md` is updated if user-visible behavior changed
- [ ] `CHANGELOG.md` has an entry under `[Unreleased]` (or you note "no entry needed" with a reason)

CI runs the same checks across `ubuntu-latest` and `macos-latest`. Green locally usually means green in CI.

## Filing issues

Use the issue templates — a 30-second form is much more useful than free-form prose. If your issue doesn't fit either template, open it as a regular issue and I'll tag it.

## License

By contributing, you agree your contributions will be licensed under the [MIT License](LICENSE) of the project.

# claude-state

Local session snapshots and portable handoffs for coding agents. Formerly `claude-code-handoff`; the repository URL stays the same.

Claude Code already has session resume, compaction, and auto memory. claude-state adds readable task checkpoints: the latest request, observed task state, edited files, Git branch/commit, and recent assistant prose. Use native resume to reopen a conversation; use a handoff to carry selected working state into a fresh session.

No network calls, API key, daemon, or model dependency in the runtime. Requires Bash 3.2+, jq 1.6+, and standard Unix tools. Git metadata is optional. Windows uses Git Bash or WSL; native PowerShell is not a runtime for these scripts.

## Choose what to install

| Package | Purpose | Requirements |
| --- | --- | --- |
| [Portable session-handoff skill](skills/session-handoff/SKILL.md) | Save/resume a concise project handoff | SKILL.md-compatible agent with local file tools |
| Claude Code integration | Automatically capture and optionally restore session state | Claude Code hooks, Bash, jq |

The portable skill does not install hooks, intercept prompts, register an MCP server, or change compaction. Automatic integration is Claude-Code-specific. Other agents can use the portable workflow; their integrations have not been live-tested.

## Install

```bash
git clone https://github.com/bansalbhunesh/claude-code-handoff.git
cd claude-code-handoff
bash install.sh          # capture hooks + /handoff-resume + portable skill
# OR
bash install.sh --auto   # also restore on startup/clear/resume/fork/compact
```

Add your Claude configuration directory's `bin` folder to PATH, normally `~/.claude/bin`. Run `claude-state status` and `/handoff-resume`. Native `/resume` remains available.

Installation merges hooks, preserves unrelated entries, and backs up changed settings. `CLAUDE_CONFIG_DIR` takes precedence over legacy `CLAUDE_HOME`. Re-running without `--auto` removes this tool's auto-restore entries. Restart existing sessions to pick up changed hooks.

An exact copy of the old managed `commands/resume.md` is migrated automatically. A modified/custom file is preserved with a warning, so it can be reviewed without losing user changes.

## Daily use

```bash
claude-state resume                         # newest packet in this worktree
claude-state resume --keywords "auth bug"   # literal keywords, current worktree
claude-state resume SESSION_ID              # explicit packet, with mismatch warnings
claude-state resume --all-projects          # explicit global fallback/search scope
claude-state resume --path                  # selected path only
claude-state resume --json                  # version, session_id, path, warnings, content
claude-state resume --context               # bounded excerpt and full-file pointer
claude-state checkpoint --transcript /absolute/session.jsonl --session SESSION_ID
# Use --cwd /actual/project when capturing from another directory.
claude-state list
claude-state workspaces
claude-state view SESSION_ID
claude-state search "phrase"
claude-state chain SESSION_ID
claude-state signal SESSION_ID --explain
claude-state edit SESSION_ID
claude-state prune --older-than 30d
```

Default resume and keyword searches stay within the current worktree. No match produces an error, never another project's packet. `--all-projects` and explicit IDs are deliberate CLI escape hatches; automatic hooks have no cross-project escape hatch. Worktrees have separate handoff identities even though Claude's native memory is shared across a repository.

## What gets saved

Capture runs at `PreCompact` and `SessionEnd`, replacing `<Claude config>/handoff/<session-id>.md` atomically. Packets contain:

- Latest request (up to 1,800 characters) and original goal (up to 600).
- TodoWrite and observed TaskCreate/TaskUpdate state. IDs come from tool results; missing or failed results are not assumed successful.
- Git branch, HEAD, and up to 30 working-tree status lines. No remote URL or diff content.
- Up to 20 file-operation observations and eight shell-operation descriptions, labeled failed, unverified, or tool-returned. Raw shell commands/output are excluded from this section.
- Up to 20 recent assistant **text** blocks, ranked with local heuristics. Hidden thinking is not captured. Low-ranked text is retained in a collapsed section by default.

Restore warns about changed branch/HEAD and snapshots older than 24 hours. Uncommitted changes after capture are not automatically detected; verify the listed files. Inline context, including prelude and pointer, is capped at **9,000 UTF-16 units**, below the currently documented 10,000-character hook threshold. Read the full packet when an excerpt omits needed details.

## Privacy and limits

Common token formats, bearer credentials, password/key assignments, and private-key blocks are filtered before saving the final packet. This is best effort, not a guarantee of removing every secret or personal detail. Original transcripts remain untouched. Review before sharing and keep packets out of Git.

Unix directories use mode 700 and packets mode 600. Windows access depends on ACLs. Symlinked packet directories/targets are rejected. Hooks exit 0 on errors to avoid blocking Claude; verify a packet after setup. `HANDOFF_DEBUG=1` logs successful captures.

Snapshots are historical data, not instructions or new authorization. Tool return is not proof that tests passed. Capture is lossy: hard kills may bypass hooks, unsupported transcript shapes can omit details, and the next capture overwrites that session's packet. `checkpoint` can process an explicitly selected surviving transcript; it does not promise automatic crash recovery.

| Setting | Behavior |
| --- | --- |
| `CLAUDE_CONFIG_DIR` | Claude config directory; legacy `CLAUDE_HOME` remains a fallback |
| `HANDOFF_KEEP_N` | Keep newest N packets after capture; unset/0 disables retention |
| `HANDOFF_DEBUG=1` | Log successful capture metadata locally |
| `HANDOFF_SIGNAL_MIN` | Ranking threshold, default 3; 0 keeps all recent text |
| `HANDOFF_SIGNAL_DETAILS=0` | Omit low-ranked text from packets |
| `HANDOFF_REDACT=0` | Explicitly disable common-credential filtering |
| `CS_MEMORY_DIR` | Explicit location for optional native-memory commands |

## Optional native-memory management

`memory list/get/add/archive/supersede/query/rebuild-index` manages Markdown memories. `memory query --json` retains its version-1 [plugin contract](docs/plugin-contract.md).

Discovery considers user/project/local `autoMemoryDirectory`, `CLAUDE_CODE_PROJECT_DIR_NAME`, the Claude config directory, and a repository's shared Git directory. It opens only an existing conventional native store. Long/unrecognized paths fail with instructions to bind `CS_MEMORY_DIR` to the path shown by `/memory`. Use that explicit binding for policy-managed, `--settings`, and unusual layouts; the CLI does not reproduce every host setting or trust rule.

Index rebuilds replace only the `<!-- claude-state:start -->` to `<!-- claude-state:end -->` block, preserving hand-written content outside it. Existing manual links to archived entries remain under your control. Keep descriptions concise: a large MEMORY.md can exceed the host's loading limit.

## Relationship to ctx-flow

Use ctx-flow for durable project knowledge and relevant domain notes. Use session-handoff for a task's progress, blockers, evidence, and next action. They can coexist; avoid duplicating full transcripts into either store.

## Verify and uninstall

```bash
bash tests/run-all.sh
bash uninstall.sh          # preserve packets and native memories
bash uninstall.sh --purge  # explicitly delete packets too
```

CI runs syntax checks, ShellCheck, and isolated synthetic-transcript tests on Linux, macOS, and Windows Git Bash. Passing fixtures is not a live-session benchmark or a guarantee for future Claude releases. Test one real capture/restore after installation or a host upgrade. See [CONTRIBUTING.md](CONTRIBUTING.md).

## References

- [Claude Code sessions](https://code.claude.com/docs/en/sessions)
- [Hook context delivery](https://code.claude.com/docs/en/hooks#add-context-for-claude)
- [Native memory storage](https://code.claude.com/docs/en/memory#storage-location)
- [Migration](MIGRATION.md), [changelog](CHANGELOG.md), [MIT license](LICENSE)

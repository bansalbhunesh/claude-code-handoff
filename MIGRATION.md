# Migration guide

## v1.0 → v1.1

Fetch the update and rerun the installer from the repository:

```bash
git pull
bash install.sh          # or: bash install.sh --auto
claude-state status
```

Use the same configuration location as before. `CLAUDE_CONFIG_DIR` now takes precedence over `CLAUDE_HOME`; the default is still `~/.claude`. Existing packets remain readable and are not rewritten. Settings changes receive a backup.

- Use `/handoff-resume` to recover a packet. Native `/resume` is left available. The installer removes an exact copy of this project's old command, but preserves customized `commands/resume.md` files for your review.
- `claude-state resume` and keyword selection now stay within the current worktree. Add `--all-projects` for deliberate cross-project fallback/search, or supply an explicit session ID. Automatic hooks never use global fallback.
- `--auto` registers startup, resume, compact, clear, and fork restoration. Running the installer without it returns to manual restore mode while retaining capture hooks.
- Credentials matching common patterns are filtered from **new** packets by default. This is not a complete secret scanner and does not sanitize existing packets or original transcripts. Review packets before sharing.
- Native memory discovery opens an existing store, including repository-shared worktree memory. If it cannot identify the store, use the path shown by Claude Code's `/memory`: `export CS_MEMORY_DIR='/absolute/path/to/memory'`. Do not move or delete old memory directories just to make discovery succeed.
- `MEMORY.md` rebuilds update a marked block and retain surrounding notes. Existing unmarked content is preserved; remove duplicate old generated entries manually if necessary.
- Hooks remain best effort and silent on invalid inputs. A forced process kill may not produce a snapshot. Use `checkpoint` with a known transcript path for a deliberate capture.

The portable skill at `skills/session-handoff/` can also be installed by itself. It provides a workflow, not automatic capture or access to another agent's private history.

The historical migration notes below describe the older releases. Their global-fallback and `/resume` behavior has been superseded by v1.1.


## v0.3 → v0.4 (claude-code-handoff → claude-state)

The project was renamed in v0.4.0. The scope outgrew "handoff" — v0.4 adds workspaces, with signal scoring (v0.5) and structured memory (v0.6) on the roadmap ([PLAN.md](PLAN.md)).

The upgrade is one command. Existing packets and hooks are migrated in place; nothing about your data needs to change.

### Upgrade

```bash
git pull
bash install.sh                  # add --auto if you used auto-resume in v0.3
```

That's it. The installer:

1. Copies `lib/` and `modules/` into `~/.claude/claude-state/`.
2. Installs `bin/claude-state` and the `bin/claude-handoff` deprecation shim into `~/.claude/bin/`.
3. **Rewrites your `settings.json`** so any hook command pointing at `~/.claude/scripts/handoff-{snapshot,resume}.sh` is replaced by `~/.claude/claude-state/modules/handoff/{snapshot,resume}.sh`. Third-party hooks and unrelated foreign commands are preserved.
4. Removes the old `~/.claude/scripts/handoff-{snapshot,resume}.sh` files (best-effort). Other files in `~/.claude/scripts/`, if any, are left alone.
5. Backs up your previous `settings.json` to `settings.json.backup-<timestamp>-<pid>`.

### What changes for you

- **The CLI is now `claude-state`.** `claude-handoff` remains available as a compatibility shim, but it prints a one-line deprecation warning to stderr and forwards. Update your muscle memory and any aliases.
- **Help text and `status` output reference the new layout.** No flags changed; all existing subcommands (`list`, `view`, `search`, `chain`, `edit`, `path`, `status`, `prune`) work identically.
- **New subcommands:**
  - `claude-state workspaces` (alias `ws`) — list/show/rebuild/rename workspaces.
  - `claude-state resume` — workspace-aware smart resume; see below.

### Existing packets

Existing v0.3 packets are kept, untouched on disk, and still readable. They lack the new `workspace:` and `workspace_root:` frontmatter fields. The first time you run `claude-state workspaces` (or any subcommand that calls it), the index rebuild **backfills** workspace identity for those packets from their `cwd:` field — so they show up in `workspaces list` immediately, without rewriting anything on disk.

New packets snapshotted under v0.4 carry the workspace fields directly.

### Smart resume

`claude-state resume` is new in v0.4. It's the workspace-aware sibling of `claude-state view`:

| Invocation | Picks |
|---|---|
| `claude-state resume` | Newest packet whose workspace matches `$PWD`'s. Falls back to global newest if no match. |
| `claude-state resume --here` | Same as above, but **errors** if `$PWD` is not in a known workspace. Useful for scripts that want a hard fail. |
| `claude-state resume --keywords "auth bug"` | Highest-scoring packet by distinct keyword hits, recency tiebreak. |
| `claude-state resume <session-id>` | Specific packet, like `view <id>`. |
| `claude-state resume <free text>` | Auto-detected: id if known, otherwise treated as `--keywords`. |

The `/resume` slash command was updated to call `claude-state resume` (with a degraded `ls -t` fallback if the CLI is absent), so the model uses the same priority chain you do.

### Rolling back

If you need to roll back to v0.3:

```bash
bash uninstall.sh                # removes v0.4 layout, strips both v0.3 and v0.4 hooks
git checkout v0.3.0
bash install.sh
```

Your packets in `~/.claude/handoff/` stay intact across the round trip — `uninstall.sh` does not touch them unless you pass `--purge`.

### Repo URL

The GitHub URL is still `github.com/bansalbhunesh/claude-code-handoff` at the time of v0.4.0. When the repo is renamed, GitHub auto-redirects clone and fetch URLs, so existing clones keep working without action.

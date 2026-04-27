# PLAN — `claude-state` (renamed from claude-code-handoff) v0.4 → v1.0

Status: **proposal, not implemented.** One repo, restructured into modular subdirs, renamed to reflect broader scope, with a clear publishing path. Three milestones, each fully back-compatible. Targeting one tagged release per milestone, then a v1.0 once the plugin contract is locked.

---

## Goals

1. **Workspaces.** Group sessions by project so `/resume` picks the right one when you switch repos.
2. **Signal scoring.** Score each chunk of conversation, drop noise (filler acks, superseded plans, tool spam), keep the high-signal parts in packets.
3. **Structured memory.** Add a typed CLI on top of the existing markdown memory store so plugins can query it, with state (`active|archived|superseded`) and session links.
4. **Ship it.** Publish under a name that reflects the full scope, with Homebrew + `curl | bash` installs, semver, and a stable plugin contract.

## Non-goals

- Replacing markdown memory storage. The harness reads `MEMORY.md`; we layer on top, not under.
- LLM-based scoring inside hooks. Hooks must stay sync, fast, no network.
- Migrating existing packets or memories to a new layout. Additive frontmatter only.
- A daemon, a server, or a database. This stays a CLI + flat files.
- Three separate repos. One repo, modular subdirs (see below).

---

## Repo shape & rename

### Why rename

`claude-code-handoff` describes the v0.3 scope (snapshot + resume). Once it owns workspaces + signal + memory, the name undersells it. We rename, and keep `claude-handoff` as a back-compat symlink so existing users don't break.

### Name candidates

| Name | Read | Pro | Con |
|---|---|---|---|
| **`claude-state`** | descriptive — "persistent state for Claude Code" | clear, honest, easy to say | a little plain |
| `claude-persist` | verb-flavored variant | accurate | longer, less catchy |
| `cch` | short for claude-code-handoff | preserves lineage, fast to type | opaque to newcomers |
| `claude-cortex` | branded | memorable | vague, oversells |
| `claude-recall` | memory-flavored | catchy | narrows perception to just memory |

**My pick: `claude-state`.** Recommend this unless you prefer another. The new binary is `claude-state`; `claude-handoff` stays installed as a symlink for one minor version, with a deprecation note.

### Modular layout

```
bin/
  claude-state                 # thin dispatcher → modules/*
lib/                           # shared shell helpers, sourced by modules
  common.sh                    #   file_mtime, file_mode, human_age, hash8, err
  packet.sh                    #   packet read/write/parse helpers
  workspace.sh                 #   workspace resolver (git-root + hash8)
  lockfile.sh                  #   flock helper for concurrent writes
modules/                       # each feature self-contained
  handoff/
    snapshot.sh                #   was scripts/handoff-snapshot.sh
    resume.sh                  #   was scripts/handoff-resume.sh
    README.md
  workspaces/
    workspaces.sh
    README.md
  signal/
    signal.sh
    README.md
  memory/
    memory.sh
    README.md
commands/                      # slash commands → ~/.claude/commands
  resume.md
tests/
  lib.sh                       # test harness
  test_handoff.sh              # split out from current test_snapshot/test_resume
  test_workspaces.sh           # M1
  test_signal.sh               # M2
  test_memory.sh               # M3
  test_cli.sh                  # dispatcher tests
  test_e2e.sh
  test_installers.sh
  run-all.sh
```

Each `modules/<feature>/` owns its scripts + a short README the top-level README links to. The top-level CLI is a thin dispatcher: `claude-state memory query …` → `modules/memory/memory.sh query …`.

### Migration steps (one-time, contained in v0.4.0)

1. Rename GitHub repo `claude-code-handoff` → `claude-state`. GitHub auto-redirects clones and old URLs.
2. Move scripts into `modules/<feature>/` and helpers into `lib/`. No content changes, just paths.
3. `bin/claude-handoff` becomes a stub that `exec`s `bin/claude-state` with the same args, plus a one-line stderr deprecation note. Removed in v0.6.
4. Update hook commands in `settings.example.json` to point at the new module paths. `install.sh` handles existing installs by rewriting the user's `settings.json` hook commands on upgrade.
5. CHANGELOG entry + a `MIGRATION.md` for users upgrading from v0.3.

---

## Milestone 1 — Workspaces (v0.4.0)

### Problem

Packets live flat in `~/.claude/handoff/*.md`, indexed only by session id. `/resume` returns the *globally* newest packet, which is wrong when you switch projects: you resume the wrong project's work. There is no way to list packets for a project, search a project's history, or jump back to "the last session I had in repo X."

### Workspace identity

A workspace is a logical grouping of sessions. Resolution rules, in order:

1. If `cwd` is inside a git repo → name = `<basename(toplevel)>-<hash8(toplevel)>`. Example: `claude-code-handoff-a8f3c2d1`.
2. Else → name = `<basename(cwd)>-<hash8(cwd)>`.
3. `hash8` = first 8 hex chars of `sha256(absolute_path)`.

Why hash? Two clones of the same repo in different paths must not collide. Two unrelated `node_modules` cwds must not collide. 8 hex chars = 4B-space, fine for human-scale collision avoidance.

User can override with a manual rename — see CLI below.

### Storage

Packets stay flat in `~/.claude/handoff/*.md`. **No move.** Reasons: avoids breaking existing paths, avoids migration logic, keeps `ls`/`grep` simple.

A new sidecar **`~/.claude/handoff/index.json`** caches workspace→sessions mappings. Rebuildable from packet frontmatter via `claude-handoff workspaces rebuild`.

```json
{
  "version": 1,
  "workspaces": {
    "claude-code-handoff-a8f3c2d1": {
      "root": "/Users/ankur/Work/claude-code-handoff",
      "git_remote": "git@github.com:bansalbhunesh/claude-code-handoff.git",
      "alias": null,
      "first_seen": "2026-04-27T01:00:00Z",
      "last_seen":  "2026-04-27T07:08:00Z",
      "sessions": ["ea5f8eed-...", "..."]
    }
  }
}
```

### Packet frontmatter additions

```yaml
- workspace: claude-code-handoff-a8f3c2d1
- workspace_root: /Users/ankur/Work/claude-code-handoff
- workspace_alias: null
```

Old packets without these fields keep working — `claude-handoff workspaces rebuild` infers from `cwd:` and re-writes (or just indexes them under "ungrouped" if cwd is missing).

### Smart resume — priority chain

1. Explicit session id arg → that exact packet. (Today's behavior, unchanged.)
2. `--here` flag, **or** default-when-cwd-matches-a-known-workspace → newest packet whose `workspace` matches current cwd's resolved workspace.
3. `--keywords "<terms>"` or positional `<terms>` (free text not matching a uuid) → score every packet:
   - +3 per term hit in `goal:`
   - +2 per term hit in `recently edited files`
   - +1 per term hit in `recent assistant reasoning`
   - recency tiebreaker (newer wins)
   Pick top 1 if score ≥ threshold (default 3); else error and print top-5 candidates.
4. Fallback → global newest. (Today's behavior.)

### CLI surface

```
claude-handoff workspaces                        # list, with counts + last-seen
claude-handoff workspaces show <name>            # list packets in workspace
claude-handoff workspaces rebuild                # regenerate index from packets
claude-handoff workspaces rename <name> <alias>  # human-friendly alias
claude-handoff resume [--here] [--keywords "..."] [<session-or-keywords>]
```

`/resume` slash command keeps its name; updated to call smart-resume.

### Tests (new `tests/test_workspaces.sh`)

- cwd inside a git repo → resolves to `<reponame>-<hash>`.
- cwd outside any repo → resolves to `<basename>-<hash>`.
- Two cwds with same basename, different paths → different workspaces.
- Index missing → rebuild produces correct mapping from existing packets.
- Index corrupt JSON → `workspaces` command fails clean, prompts rebuild.
- Keyword search: single hit, multi-hit (top-5 listed), no hit (error).
- `--here` from inside a known workspace → returns workspace-newest, not global newest.
- `--here` from a brand-new cwd → falls through to global newest with a warning.

### Risks

- Index drift if packets are deleted manually → `rebuild` fixes; `workspaces` warns if a session id in the index has no packet.
- Hash collisions → astronomically unlikely at 8 hex chars; if it happens, `rename` lets the user disambiguate.

---

## Milestone 2 — Signal scoring (v0.5.0)

### Problem

`handoff-snapshot.sh` packs in the last ~N edited files and recent assistant reasoning. It caps by **count**, not by **relevance**. Filler ("ok", "got it"), tool spam, and superseded plans all get included. Token cost goes up; signal density goes down. There is also no way to inspect *why* a chunk was kept.

### Design

A new pure stdin→stdout transform: **`scripts/handoff-signal.sh`**. The snapshot script pipes its already-jq-filtered assistant-message stream through it.

### Scoring rubric (per assistant message)

Additive points:

| Signal | Score |
|---|---|
| length > 200 chars | +3 |
| matches decision keywords (`decision\|chose\|going with\|landed on\|conclusion`) | +2 |
| matches blocker keywords (`blocked\|broken\|fails\|error\|can't\|won't\|doesn't work`) | +2 |
| matches goal-restate (`goal\|trying to\|need to\|so that\|in order to`) | +2 |
| mentions a file path or extension (`\S+\.(ts\|js\|py\|go\|rs\|md\|sh\|json\|yml)`) | +2 |
| mentions a tool name in context (not just `⏺ Bash`) | +1 |
| pure ack (`^(ok\|got it\|sure\|done\|thanks?\|yeah\|yep\|cool\|nice)\b.{0,40}$`) | −5 |
| length < 80 chars and no positive signals | −3 |
| superseded by later message (`actually\|scratch that\|instead\|never mind`) | −2 |

**Default threshold: `HANDOFF_SIGNAL_MIN=3`.** Below threshold → drop.

### Mandatory keep-rules (override threshold)

- The first goal-statement of the session.
- The last 2 assistant messages (recency safety net).
- Any message containing an unhandled error or stack trace.

### Lossless mode

The dropped chunks are **not destroyed**. They are written into a collapsed `<details>` block at the bottom of the packet, gated by `HANDOFF_SIGNAL_DETAILS=1` (default on). So nothing is lost; the top-of-packet stays high-signal.

### Why heuristics, not LLM scoring

Snapshot runs on `PreCompact` and `SessionEnd` hooks — must be sync, fast, no network, must `exit 0` even on weird input. LLM scoring is wrong shape here. Heuristics + mandatory-keep + a `HANDOFF_SIGNAL_MIN=0` escape hatch covers it. (A future `claude-handoff signal --rescore --llm <packet>` could be a separate, opt-in offline step. Out of scope for v0.5.)

### Naming

Subcommand verb: **`signal`**. File: `scripts/handoff-signal.sh`. Doc terminology: "signal scoring."

### CLI

```
claude-handoff signal <packet> --explain     # show kept-vs-dropped + reasons
claude-handoff signal <packet> --threshold 5 # rescore at a different threshold
claude-handoff signal <packet> --raw         # print unfiltered reasoning
```

### Tests (`tests/test_signal.sh`)

- Pure ack drops at threshold ≥ 1.
- Decision-keyword keeps even when short.
- Long prose keeps without other signals.
- Superseded chunk drops; the superseding chunk keeps.
- Threshold 0 keeps everything (escape hatch verified).
- Threshold absurdly high keeps only goal + last-2 + errors (mandatory-keeps verified).
- `--explain` prints score + reason for each chunk; format snapshot-tested.

### Risks

- Heuristics over-drop important content → mandatory-keep + `--raw` mode + `HANDOFF_SIGNAL_DETAILS=1` lossless-bottom mitigate.
- Heuristics under-drop noise → `--explain` for tuning; report `kept N of M (X% reduction)` after each snapshot for visibility.
- Regression risk on packet quality → tune threshold by running `--explain` over the current `~/.claude/handoff/` corpus before defaulting.

---

## Milestone 3 — Structured memory (v0.6.0)

### Problem

Memory is markdown files at `~/.claude/projects/<sanitized-cwd>/memory/<file>.md`, indexed by `MEMORY.md`. Plugins and other tools have to parse markdown to use it. There is no state ("is this still active?"), no link from a memory to the session that produced it, and no typed query API.

### Principle

**Don't replace storage.** The harness reads `MEMORY.md`; replacing storage means changing what the harness consumes, which is brittle. Layer a typed CLI *on top* of the same files.

### Frontmatter additions (additive, optional)

```yaml
state: active            # active | archived | superseded
created: 2026-04-27T07:00:00Z
created_session: ea5f8eed-4c06-4485-81fb-4b8fd5efcc4c
superseded_by: <other-memory-name>   # only if state: superseded
```

Existing memory files keep working. Missing fields → defaults (`state: active`, others empty).

### CLI

```
claude-handoff memory list [--type <t>] [--state <s>] [--json]
claude-handoff memory get  <name> [--json]
claude-handoff memory add  --type <t> --name <n> --description <d> [--state active]
                           [--content - | $EDITOR]
claude-handoff memory archive <name> [--reason "..."]
claude-handoff memory supersede <old> --by <new>
claude-handoff memory link <name> --session <id>
claude-handoff memory query --type feedback --state active --keyword "test" --json
claude-handoff memory rebuild-index            # regenerate MEMORY.md
```

### Plugin contract — the "OS for plugins" part

`claude-handoff memory query --json` emits a stable, versioned schema:

```json
{
  "version": 1,
  "memories": [
    {
      "name": "commit_coauthor",
      "type": "feedback",
      "description": "use 'Co-Authored-By: bhunesh bansal'",
      "state": "active",
      "created": "2026-04-27T07:00:00Z",
      "created_session": "ea5f8eed-4c06-4485-81fb-4b8fd5efcc4c",
      "superseded_by": null,
      "path": "/Users/ankur/.claude/projects/-Users-ankur/memory/commit_coauthor.md"
    }
  ]
}
```

Plugins call this CLI instead of parsing markdown. Schema versioned; `version: 1` is the contract. Breaks bump the version, never silently change shape.

### MEMORY.md auto-compile

On any `add | archive | supersede`, regenerate `MEMORY.md` from `state: active` memories only, sorted by type then name. Honors a `MEMORY.md.header` and `MEMORY.md.footer` if present (so users can preface manual notes that survive regenerations).

### Session ↔ memory linking

- When `handoff-snapshot.sh` runs it writes the current session id into `~/.claude/handoff/.last_session` (atomic).
- `memory add` defaults `created_session` to that file's contents.
- Optional, in M3 too: snapshot scans memory frontmatter for `created_session: <this id>` and lists matched memories under a packet section `linked_memories:`. Cheap; useful for resume.

### Memory directory resolution

Today the path is `~/.claude/projects/-Users-ankur/memory/` — sanitization scheme is opaque (looks like cwd-with-slashes-to-dashes). Plan: write a `memory_dir()` resolver in shell that mirrors the harness's. If we cannot reverse-engineer it cleanly, accept `--memory-dir <path>` as override and document it. We will *not* guess and silently write to the wrong place.

### Tests (`tests/test_memory.sh`)

- `add` round-trips: file written, frontmatter shape correct, MEMORY.md updated.
- `archive` flips state, leaves file in place, MEMORY.md drops it from active list.
- `supersede` sets old to `superseded`, writes `superseded_by`, MEMORY.md shows only the new one.
- `query --json` schema matches; jq-parseable; `version: 1` present.
- `rebuild-index` is idempotent over multiple runs.
- Malformed memory frontmatter → CLI fails on that file with a path, doesn't crash overall command.
- Concurrent writes: `flock`-guarded on macOS/Linux; on Windows, document best-effort and skip the test.

### Risks

- Harness's loading rules may differ from our model → mitigate by reading the live `MEMORY.md` post-rebuild and confirming the harness still picks it up (manual smoke test before releasing v0.6).
- Concurrent writes from multiple Claude sessions → `flock` on Linux/macOS, no-op on Windows (documented).
- Schema drift between plugins and CLI → strict version bumps, `version: 1` declared and held.

---

## Sequencing & release plan

| Milestone | Branch | Tag | Depends on |
|---|---|---|---|
| Restructure + rename | `chore/rename-claude-state` | `v0.4.0` | none |
| M1 Workspaces | `feat/workspaces` | `v0.4.0` (same) | rename |
| M2 Signal scoring | `feat/signal` | `v0.5.0` | none (independent of M1) |
| M3 Structured memory | `feat/memory` | `v0.6.0` | M1 (workspace-scoped queries) |
| Lock plugin contract | `release/v1` | `v1.0.0` | M1+M2+M3 |

The rename + restructure ship **together with M1** as `v0.4.0` (one disruption, not two). M1 and M2 are independent; M3 should land last because it's the most surface area.

Each milestone:
- Full back-compat. Existing packets and memory files unchanged on upgrade.
- README + CHANGELOG updated.
- CI matrix (ubuntu / macos / windows) stays green before tagging.
- A short migration note in CHANGELOG if any user-visible default shifts.

---

## Publishing path

Goal: anyone can install in one line, find the project via search, and trust the JSON contract enough to build plugins on it.

### Distribution

1. **Homebrew tap.** Create `bansalbhunesh/homebrew-claude-state` with a formula. Users run:
   ```
   brew tap bansalbhunesh/claude-state
   brew install claude-state
   ```
   Formula points at the GitHub release tarball; release workflow uploads tarball + sha256 on `v*.*.*` tags.
2. **`curl | bash` installer.** Already exists (`install.sh`); document as the Homebrew-free path. Pin to a tag, not `main`.
3. **GitHub releases.** Tag-driven, auto-changelog from `CHANGELOG.md`. Add a `release.yml` workflow on tag push that runs CI, packages a tarball, and creates the release.
4. **Manual download.** Tarball + checksum on each release for users behind firewalls.

### Discoverability

- README header: tagline that fits in a tweet ("Persistent state for Claude Code: handoff, workspaces, signal-scored history, plugin-queryable memory").
- 30-second asciinema demo embedded in README: snapshot a session → `/resume` → workspace switch.
- Architecture diagram (Mermaid) showing the data flow: hook → snapshot → packet → resume / signal / memory.
- Submit to any "awesome-claude-code" lists; post to r/ClaudeAI and Hacker News on v1.0.
- Badges: CI, latest tag, license, Homebrew install count.

### Versioning & contract policy

- **Semver.** v0.x while iterating; **v1.0.0** once the JSON plugin contract (`memory query --json`, packet frontmatter shape) is committed.
- **Plugin JSON contract** (`version: 1`):
  - Field additions are non-breaking.
  - Field removals or shape changes require a major bump (`version: 2`).
  - Old `version: 1` consumers must keep working through v1.x.
- **Packet frontmatter:** additive only. Never remove or rename a field within a major.
- **CLI flags:** deprecate before removal, with one minor-version's notice and a stderr warning.

### Pre-publish checklist (at v1.0.0)

- [ ] All three modules shipped + tested on three platforms.
- [ ] Plugin contract documented in `docs/plugin-contract.md` with examples.
- [ ] At least one example plugin (could be a 20-line shell script) demonstrating `memory query --json` consumption.
- [ ] Homebrew formula published and tested on a clean macOS machine.
- [ ] `install.sh` tested on clean Ubuntu, macOS, Windows-Git-Bash.
- [ ] MIGRATION.md from v0.3 covers the rename and the hook path update.
- [ ] LICENSE, CODE_OF_CONDUCT, CONTRIBUTING already present (they are).
- [ ] Issue templates + PR template (already present).
- [ ] At least one external user has installed and given feedback.

---

## Open questions for review

1. **Workspace identity.** Git-root + 8-char hash with manual rename, OR raw cwd hash, OR user-named workspaces from the start? I propose git+hash default, `rename` as escape.
2. **Default `/resume` behavior.** Workspace-newest when cwd matches a known workspace, else global newest. Acceptable? Or always require an explicit `--here`?
3. **Signal threshold.** Default `3` is a guess. Want me to add `--explain` first, run it across your existing handoff corpus, and pick a data-driven default before tagging?
4. **Memory `add` UX.** `$EDITOR` for interactive, `--content -` for stdin, `--content "..."` for one-liners. All three? Drop one?
5. **Plugin contract surface.** Beyond `version: 1`, anything you want guaranteed (sort order, field presence, locale)?
6. **Project name.** I propose `claude-state`; alternatives are `claude-persist`, `cch`, `claude-cortex`, `claude-recall`. Pick one (or veto and propose your own).
7. **Scope discipline.** Anything in the above that should *not* ship — i.e., features I should cut to keep the project tight?
8. **Publish surface.** Homebrew tap + `curl | bash` + GitHub releases — anything else (npm, deb/rpm packages, an Anthropic plugin registry if one exists)?
9. **v1.0 timing.** Tag v1.0.0 immediately after M3, or sit on v0.6 for a few weeks of dogfooding before locking the plugin contract? I lean dogfood-first.

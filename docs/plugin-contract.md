# `claude-state` plugin contract — v1.0.0

This document is the formal integration surface for `claude-state` v1.x. It follows [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html); throughout the v1.x line every field documented here keeps its name, type, nullability, and meaning, and the project commits to that for every minor and patch release tagged `v1.*.*`.

## Scope

Two contract surfaces are stable and meant to be consumed by external code:

1. **Memory contract** — the JSON document emitted by `claude-state memory query --json`.
2. **Packet frontmatter contract** — the `- key: value` lines at the top of each handoff packet, terminated by the first blank line.

Anything else in the project (on-disk file shapes, CLI flag names, exit codes beyond the basics, performance, sort order) is *not* part of the contract — see [Non-promises](#non-promises).

---

## 1. Memory contract — `claude-state memory query --json`

### Envelope

```json
{
  "version": 1,
  "memories": [ /* 0..N entries, see schema below */ ]
}
```

| Field      | Type                | Nullable | Meaning                                                                                                                                                                                                                                                                                                                                  |
| ---------- | ------------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `version`  | integer             | no       | Schema version. Always `1` for this contract. Plugins MUST check `version == 1` before consuming `memories[]`. A future major bump will set this to `2`; both will be supported in parallel — see [Version policy](#3-version-policy).                                                                                                  |
| `memories` | array of memory     | no       | List of memory entries. May be empty (`[]`) when no memories exist or filters match nothing. Order is **not specified** by the contract; if order matters to you, sort client-side (e.g. by `created` or `name`).                                                                                                                       |

### `memories[]` entry schema

Every entry is an object with **exactly these eight keys** (every key is always present; values may be `null` per the table). New keys may be added in v1.x — consumers MUST tolerate unknown keys.

| Field             | Type    | Nullable | Meaning                                                                                                                                                                                                                                                                                              |
| ----------------- | ------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `name`            | string  | no       | The memory's identifier, derived from the filename without `.md`. Matches the regex `^[a-zA-Z0-9][a-zA-Z0-9_-]*$`. Stable across `archive` and `supersede` (the file is rewritten in place).                                                                                                          |
| `type`            | string  | yes      | User-assigned classifier. Examples seen in the wild: `feedback`, `user`, `project`, `reference`. Custom values are allowed — treat unknown types as opaque strings, not as errors.                                                                                                                   |
| `description`     | string  | yes      | One-line summary that the harness displays in the auto-compiled `MEMORY.md` index.                                                                                                                                                                                                                  |
| `state`           | string  | no       | One of exactly: `active`, `archived`, or `superseded`. Defaults to `active` when the on-disk file omits the field. The harness includes only `active` memories in its `MEMORY.md` index; plugins should usually filter to `state == "active"` unless they specifically want the full history.       |
| `created`         | string  | yes      | ISO 8601 UTC timestamp (e.g. `2026-04-27T22:11:41Z`) recording when the memory was first written by `memory add`. Older memories created outside the typed CLI may have this null.                                                                                                                  |
| `created_session` | string  | yes      | The handoff session id active when the memory was created. UUID-shaped in normal use, but the contract guarantees only "string or null." For backwards compatibility the CLI also reads the legacy frontmatter key `originSessionId` and surfaces it here under `created_session`.                  |
| `superseded_by`   | string  | yes      | When `state == "superseded"`, the `name` of the memory that replaced this one. Otherwise `null`. Forms a one-step replacement chain; consumers that want the full chain must follow the link transitively.                                                                                          |
| `path`            | string  | no       | Absolute filesystem path of the memory's `.md` file. Consumers MAY read this file directly for the body content, but MUST NOT compute the path themselves — the directory layout is internal and may move (see [Non-promises](#non-promises)).                                                       |

### Example output (full coverage)

Captured from a sandboxed run that exercises every state:

```json
{
  "version": 1,
  "memories": [
    {
      "name": "new_decision",
      "type": "project",
      "description": "new approach",
      "state": "active",
      "created": "2026-04-27T22:11:50Z",
      "created_session": "11111111-2222-3333-4444-555555555555",
      "superseded_by": null,
      "path": "/Users/u/.claude/projects/-Users-u-proj/memory/new_decision.md"
    },
    {
      "name": "old_decision",
      "type": "project",
      "description": "old approach",
      "state": "superseded",
      "created": "2026-04-27T22:11:50Z",
      "created_session": "11111111-2222-3333-4444-555555555555",
      "superseded_by": "new_decision",
      "path": "/Users/u/.claude/projects/-Users-u-proj/memory/old_decision.md"
    },
    {
      "name": "to_archive",
      "type": "reference",
      "description": "stale notes",
      "state": "archived",
      "created": "2026-04-27T22:11:50Z",
      "created_session": "11111111-2222-3333-4444-555555555555",
      "superseded_by": null,
      "path": "/Users/u/.claude/projects/-Users-u-proj/memory/to_archive.md"
    }
  ]
}
```

The empty case is canonical and stable too:

```json
{"version":1,"memories":[]}
```

---

## 2. Packet frontmatter contract

Each handoff packet at `~/.claude/handoff/<session-id>.md` opens with a block of `- key: value` lines, then a blank line, then the markdown body. The frontmatter block is the contract; the body is **untrusted free text** (it contains verbatim user prompts and assistant prose, which may include anything a user pasted in).

### Bounded-frontmatter parser convention

Consumers parsing a packet MUST:

1. Read lines from the top until they encounter the first **blank line**.
2. Treat that span as the frontmatter; stop there.
3. Treat anything after the blank line as opaque body content. Do not infer structure from the body. Do not pattern-match it for keys; the body may legitimately contain `- foo: bar` lines that are part of conversation, not metadata.

This bound is what makes the frontmatter safe to consume even though the body is untrusted: the parser never has to scan past the first blank line.

A line within frontmatter has the shape `- <key>: <value>`. The leading `- ` is a literal two-character prefix.

### Fields written today

| Field             | Type   | Nullable                  | Meaning                                                                                                                                                                                                                       |
| ----------------- | ------ | ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `session`         | string | no (always present)       | The Claude Code session id this packet captures. UUID-shaped in normal use. Used as the packet's filename stem.                                                                                                              |
| `event`           | string | no (always present)       | The hook event that triggered the snapshot. Observed values: `PreCompact`, `SessionEnd`. May expand in v1.x — consumers should treat unknown events as opaque strings.                                                       |
| `generated`       | string | no (always present)       | ISO 8601 UTC timestamp of when the snapshot was written.                                                                                                                                                                      |
| `cwd`             | string | no (always present)       | The working directory the hook reported when the snapshot fired. May be empty string if the hook payload omitted it; the line is still emitted.                                                                              |
| `workspace`       | string | yes (line absent if null) | Workspace identity, shape `<sanitized-basename>-<hash8>` (e.g. `claude-state-a8f3c2d1`). Computed from `cwd` via the workspace resolver. Absent when `cwd` was empty or non-existent.                                         |
| `workspace_root`  | string | yes (line absent if null) | Absolute path of the workspace root: the git toplevel containing `cwd`, or the absolutized `cwd` itself if not in a repo. Absent under the same conditions as `workspace`.                                                   |
| `continues_from`  | string | yes (line absent if null) | Session id of the prior session this one continues, when the transcript opens with a compact-summary block. Plugins use this to walk a chain of related packets. Absent when there is no prior session.                       |

Nullable fields are encoded by **omitting the line entirely** (not by writing an empty value). Consumers must treat a missing line as `null`.

### Example header (real, sandbox-generated)

```
# Handoff packet
- session: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
- event: PreCompact
- generated: 2026-04-27T22:11:58Z
- cwd: /tmp/cc-stress/cs-packet-MhaaaK/proj
- workspace: proj-d5bbcc76
- workspace_root: /private/tmp/cc-stress/cs-packet-MhaaaK/proj

## Original goal
...
```

The `# Handoff packet` heading is the first line; frontmatter follows; the blank line above `## Original goal` is the parser stop condition.

---

## 3. Version policy

This policy is contractual, not aspirational.

### Within v1.x (every `1.*.*` release)

- Every field listed above keeps its **name**, **type**, **nullability**, and **semantic meaning**.
- New fields **may** be added to either contract surface. Consumers MUST tolerate unknown keys (memory contract) and unknown frontmatter lines (packet contract).
- No field is removed. No type is changed. No semantic meaning shifts.
- Default values (e.g. `state` defaulting to `active` when absent on disk) do not change.

### Crossing to v2

- Any change that breaks the rules above requires a **major version bump** of the project: v2.0.0.
- The corresponding contract surface emits a new envelope version (`version: 2` for memory; a documented marker for packet frontmatter).
- Both `version: 1` and `version: 2` emitters will be supported **in parallel** for at least one minor cycle of v2.x (exact timing TBD when v2 is planned), so plugins have a window to migrate without their consumers breaking on upgrade.

### Per-surface independence

The two contract surfaces are versioned independently. The memory contract's `version` field and the packet frontmatter version may bump out of sync — for instance, memory could move to `version: 2` while packet frontmatter stays additive on its v1 line, or vice versa. Don't assume locked steps.

---

## 4. Your first plugin (4-step recipe)

1. Run `claude-state memory query --json`. Capture stdout.
2. Parse it as JSON. Check `version == 1`. If not, refuse to run (or branch).
3. Iterate `memories[]`. Filter, transform, or report — whatever your plugin does.
4. (Optional) To track new memories, poll step 1 on an interval and diff entries by the tuple `(name, created)`. New tuples are new memories; tuples that disappear were renamed/removed; tuples whose `state` shifted are state changes.

### Shell example

```bash
#!/usr/bin/env bash
set -euo pipefail
out=$(claude-state memory query --json)
ver=$(printf '%s' "$out" | jq -r .version)
[ "$ver" = "1" ] || { echo "unsupported memory contract version: $ver" >&2; exit 1; }
printf '%s' "$out" | jq -r '.memories[] | select(.state == "active") | "\(.type // "(none)")\t\(.name)\t\(.description // "")"'
```

### Python example

```python
import json, subprocess, sys

doc = json.loads(subprocess.check_output(["claude-state", "memory", "query", "--json"]))
if doc["version"] != 1:
    sys.exit(f"unsupported memory contract version: {doc['version']}")
for m in doc["memories"]:
    if m["state"] != "active":
        continue
    print(m["type"] or "(none)", m["name"], m["description"] or "", sep="\t")
```

The same shape works in Node, Go, Rust, or any language that can run a subprocess and parse JSON. The contract makes no assumption about implementation language.

---

## 5. Non-promises

The contract intentionally does **not** cover any of the following. Plugin authors should not depend on them.

- **Path stability.** The on-disk memory directory (today `~/.claude/projects/<sanitized-cwd>/memory/`) and the on-disk handoff directory (today `~/.claude/handoff/`) MAY move. Always read the absolute `path` from the contract output; never compute it.
- **On-disk file format.** The YAML-style frontmatter on memory `.md` files and on packet `.md` files is an internal implementation detail. Only the CLI output (`memory query --json` for memories; the bounded frontmatter on packets for packets) is the contract. If you parse `.md` files directly, you accept that they may change shape across releases.
- **Exit codes beyond the basics.** `0` = success, `2` = usage error, `1` = generic failure. Specific non-zero codes for specific failure modes are not promised.
- **CLI flag names.** The JSON shape is stable; the flags that produce it are not. CLI flags MAY be deprecated with one minor version's notice and a stderr warning. Use the `--json` output as your contract, not the flags themselves.
- **Performance characteristics.** No latency, throughput, or memory-footprint guarantees. The contract is about shape, not speed.
- **Sort order in `memories[]`.** The array order is unspecified and may change between releases. Sort client-side if order matters to you.

---

## 6. Reporting bugs / proposing changes

- File issues at <https://github.com/bansalbhunesh/claude-code-handoff/issues>. Tag with `contract` for anything affecting this document.
- The project follows SemVer 2.0.0. If you find behavior that violates a contract guarantee in this document on a v1.x release, that's a bug — please file it.
- Field additions, new event names, and new state values can land in any minor release. Removals or shape changes can only land on a major bump (v2). The version policy above is the binding commitment.

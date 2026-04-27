#!/usr/bin/env bash
# claude-state v0.4.0 — installer
# Installs claude-state into ~/.claude/. Idempotent: safe to run multiple
# times. Backs up settings.json on successful merge. Pass --auto to also
# wire SessionStart auto-resume.
#
# v0.3 → v0.4 migration: legacy hook entries that point at
# ~/.claude/scripts/handoff-{snapshot,resume}.sh are stripped before the
# new entries are inserted, so an upgrade in place picks up the new
# layout without manual settings surgery.

set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 [--auto] [-h|--help]

  --auto      Also install SessionStart auto-resume hooks (compact + resume
              matchers). Auto-resume is opt-in because some of its underlying
              behavior (size limits, presentation to the model) is undocumented.
              Without this flag, only the manual /resume slash command is wired,
              and any previously-installed SessionStart auto-resume entries are
              removed (mode toggling).

  -h, --help  Show this help.
USAGE
}

auto=0
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --auto)    auto=1; shift ;;
  "")        ;;
  *)         echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac
[ "$#" -gt 0 ] && { echo "unexpected extra arguments: $*" >&2; usage >&2; exit 2; }

repo_dir="$(cd "$(dirname "$0")" && pwd)"
claude_dir="${CLAUDE_HOME:-$HOME/.claude}"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required but not installed. Try 'brew install jq' or your package manager." >&2
  exit 1
fi

# We use jq's `//=` operator (jq 1.6+).
jq_version=$(jq --version 2>/dev/null | sed -E 's/^jq-//; s/^jq //')
case "$jq_version" in
  1.[0-5]|1.[0-5].*)
    echo "error: jq >= 1.6 is required (found $jq_version). Update jq and re-run." >&2
    exit 1
    ;;
esac

# Layout under $claude_dir:
#   bin/claude-state                              — entry point on PATH
#   bin/claude-handoff                            — deprecation shim
#   claude-state/lib/common.sh                    — shared helpers
#   claude-state/modules/handoff/snapshot.sh      — pre-compact / session-end hook
#   claude-state/modules/handoff/resume.sh        — session-start hook
#   commands/resume.md                            — /resume slash command
#   handoff/                                      — packet data (mode 700; created lazily)
mkdir -p \
  "$claude_dir/bin" \
  "$claude_dir/commands" \
  "$claude_dir/handoff" \
  "$claude_dir/claude-state/lib" \
  "$claude_dir/claude-state/modules/handoff" \
  "$claude_dir/claude-state/modules/workspaces" \
  "$claude_dir/claude-state/modules/signal" \
  "$claude_dir/claude-state/modules/memory"
chmod 700 "$claude_dir/handoff" 2>/dev/null || true

# Use rm-then-cp so foreign-owned existing files don't fail under set -e.
install_file() {
  local src="$1" dst="$2" mode="${3:-}"
  rm -f "$dst"
  cp "$src" "$dst"
  [ -n "$mode" ] && chmod "$mode" "$dst"
}

install_file "$repo_dir/lib/common.sh"                        "$claude_dir/claude-state/lib/common.sh"                    644
install_file "$repo_dir/lib/workspace.sh"                     "$claude_dir/claude-state/lib/workspace.sh"                 644
install_file "$repo_dir/lib/signal.sh"                        "$claude_dir/claude-state/lib/signal.sh"                    644
install_file "$repo_dir/lib/memory.sh"                        "$claude_dir/claude-state/lib/memory.sh"                    644
install_file "$repo_dir/modules/handoff/snapshot.sh"          "$claude_dir/claude-state/modules/handoff/snapshot.sh"      755
install_file "$repo_dir/modules/handoff/resume.sh"            "$claude_dir/claude-state/modules/handoff/resume.sh"        755
install_file "$repo_dir/modules/workspaces/workspaces.sh"     "$claude_dir/claude-state/modules/workspaces/workspaces.sh" 755
install_file "$repo_dir/modules/signal/signal.sh"             "$claude_dir/claude-state/modules/signal/signal.sh"         755
install_file "$repo_dir/modules/memory/memory.sh"             "$claude_dir/claude-state/modules/memory/memory.sh"         755
install_file "$repo_dir/bin/claude-state"                     "$claude_dir/bin/claude-state"                              755
install_file "$repo_dir/bin/claude-handoff"                   "$claude_dir/bin/claude-handoff"                            755
install_file "$repo_dir/commands/resume.md"                   "$claude_dir/commands/resume.md"                            644

# Best-effort cleanup of v0.3 layout. We delete the script files only;
# we leave $claude_dir/scripts/ in place if it still has unrelated files.
rm -f "$claude_dir/scripts/handoff-snapshot.sh" "$claude_dir/scripts/handoff-resume.sh" 2>/dev/null || true
rmdir "$claude_dir/scripts" 2>/dev/null || true

settings="$claude_dir/settings.json"
[ -f "$settings" ] || echo "{}" > "$settings"

# Atomic merge.
tmp=$(mktemp "$settings.tmp.XXXXXX")
trap 'rm -f "$tmp"' EXIT

snap_cmd='$HOME/.claude/claude-state/modules/handoff/snapshot.sh'
resume_cmd='$HOME/.claude/claude-state/modules/handoff/resume.sh'

# Inline the strip regex inside the jq script (rather than passing via
# `--arg strip "$strip_pattern"`). Git Bash on Windows performs MSYS
# path-conversion on argv values that look like paths; the previous
# `--arg` value got mangled mid-flight, so test() never matched our
# hook tails and v0.4 mode-toggle silently kept SessionStart entries.
# uninstall.sh has always used the inline form and never had this bug.

jq --arg snap "$snap_cmd" \
   --arg resume "$resume_cmd" \
   --argjson auto "$auto" '
  def hook_entry($cmd): {type: "command", command: $cmd};

  # Coalesce duplicate-matcher entries that may exist from prior hand-edits
  # or earlier installer bugs. Group by matcher (treating absent as null),
  # union their hooks, dedupe by command. After this, each list contains at
  # most one entry per (matcher) key.
  def coalesce_matchers:
    group_by(.matcher // null)
    | map(
        if length > 1 then
          {matcher: .[0].matcher,
           hooks: ([.[] | (.hooks // [])] | add | unique_by(.command // ""))}
          | (if .matcher == null then del(.matcher) else . end)
        else
          .[0]
        end);

  # Drop any of OUR hook entries (old or new path) so the merge below
  # adds clean ones — covers both fresh install and v0.3 → v0.4 upgrade.
  # Anchor the path tail with (^|/) — start-of-string or a path-segment
  # boundary — so unrelated foreign scripts (e.g. /usr/local/my-handoff-
  # snapshot.sh) survive untouched.
  def strip_ours(arr):
    arr
    | coalesce_matchers
    | map(.hooks |= map(select((.command // "") | test("(^|/)(scripts/handoff-(snapshot|resume)|claude-state/modules/handoff/(snapshot|resume))\\.sh$") | not)))
    | map(select((.hooks // []) | length > 0));

  def add_or_create($matcher; $cmd):
    if any(.[]?; .matcher == $matcher) then
      map(if .matcher == $matcher
          then .hooks = (((.hooks // []) + [hook_entry($cmd)]) | unique_by(.command))
          else .
          end)
    else
      . + [{matcher: $matcher, hooks: [hook_entry($cmd)]}]
    end;

  def drop_empty: map(select((.hooks // []) | length > 0));

  if (.hooks // null | type) != "object" then .hooks = {} else . end
  | .hooks.PreCompact = (
      strip_ours(.hooks.PreCompact // [])
      | add_or_create("auto"; $snap)
      | add_or_create("manual"; $snap))
  | .hooks.SessionEnd = (
      strip_ours(.hooks.SessionEnd // [])
      | (if any(.[]?; (.hooks // []) | any(.command == $snap))
          then .
          else . + [{hooks: [hook_entry($snap)]}]
        end))
  | if $auto == 1 then
      .hooks.SessionStart = (
        strip_ours(.hooks.SessionStart // [])
        | add_or_create("compact"; $resume)
        | add_or_create("resume"; $resume))
    else
      .hooks.SessionStart = (strip_ours(.hooks.SessionStart // []))
    end
  | if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end
  | if (.hooks.PreCompact   | length) == 0 then del(.hooks.PreCompact)   else . end
  | if (.hooks.SessionEnd   | length) == 0 then del(.hooks.SessionEnd)   else . end
' "$settings" > "$tmp"

jq -e . "$tmp" >/dev/null || { echo "error: merged settings.json is not valid JSON; aborting" >&2; exit 1; }

# Backup AFTER successful merge so failed runs don't spam .backup-* files.
if [ -f "$settings" ] && ! cmp -s "$tmp" "$settings"; then
  backup="$settings.backup-$(date +%Y%m%d-%H%M%S)-$$"
  cp "$settings" "$backup"
  echo "Backed up previous settings to $backup"
fi
mv "$tmp" "$settings"
trap - EXIT

mode="manual"
[ "$auto" -eq 1 ] && mode="auto-resume (SessionStart hooks installed)"

cat <<EOF

Installed claude-state v0.4.0 (mode: $mode).
  modules:  $claude_dir/claude-state/modules/handoff/snapshot.sh
            $claude_dir/claude-state/modules/handoff/resume.sh
  lib:      $claude_dir/claude-state/lib/common.sh
  command:  $claude_dir/commands/resume.md
  cli:      $claude_dir/bin/claude-state           (run --help; add to \$PATH for convenience)
            $claude_dir/bin/claude-handoff         (deprecation shim — forwards to claude-state)
  packets:  $claude_dir/handoff/                   (mode 700; packets are mode 600)
  hooks:    merged into $settings

Verify:
  1. In a Claude Code session, run /compact. Status line should show
     'PreCompact [...modules/handoff/snapshot.sh] completed successfully'.
  2. ls -t $claude_dir/handoff/   # newest packet on top
  3. In a fresh session, type /resume — Claude should summarize the packet.
EOF
if [ "$auto" -eq 1 ]; then
  cat <<EOF
  4. Auto-resume only: open a fresh session after compaction. Claude should
     reference the prior session's state without you typing /resume.
EOF
fi

exit 0

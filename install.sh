#!/usr/bin/env bash
# claude-code-handoff v0.2.0 — installer
# Installs claude-code-handoff into ~/.claude/.
# Idempotent: safe to run multiple times. Backs up settings.json on
# successful merge. Pass --auto to also wire SessionStart auto-resume,
# omit it to remove any previously-installed SessionStart auto-resume
# entries (mode toggling works in both directions).

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

mkdir -p "$claude_dir/scripts" "$claude_dir/commands" "$claude_dir/handoff" "$claude_dir/bin"
chmod 700 "$claude_dir/handoff" 2>/dev/null || true

# Use install(1)-style replace: rm-then-cp, so foreign-owned existing
# scripts don't fail under set -e.
for src_rel in scripts/handoff-snapshot.sh scripts/handoff-resume.sh bin/claude-handoff; do
  dst="$claude_dir/$src_rel"
  rm -f "$dst"
  cp "$repo_dir/$src_rel" "$dst"
  chmod +x "$dst"
done
rm -f "$claude_dir/commands/resume.md"
cp "$repo_dir/commands/resume.md" "$claude_dir/commands/resume.md"

settings="$claude_dir/settings.json"
[ -f "$settings" ] || echo "{}" > "$settings"

# Atomic merge into a mktemp; trap cleans up if anything fails before mv.
tmp=$(mktemp "$settings.tmp.XXXXXX")
trap 'rm -f "$tmp"' EXIT

snap_cmd='$HOME/.claude/scripts/handoff-snapshot.sh'
resume_cmd='$HOME/.claude/scripts/handoff-resume.sh'

jq --arg snap "$snap_cmd" --arg resume "$resume_cmd" --argjson auto "$auto" '
  def hook_entry($cmd): {type: "command", command: $cmd};

  def add_or_create($matcher; $cmd):
    if any(.[]?; .matcher == $matcher) then
      map(if .matcher == $matcher
          then .hooks = (((.hooks // []) + [hook_entry($cmd)]) | unique_by(.command))
          else .
          end)
    else
      . + [{matcher: $matcher, hooks: [hook_entry($cmd)]}]
    end;

  # Drop matcher entries left empty after filtering.
  def drop_empty: map(select((.hooks // []) | length > 0));

  # Strip hooks whose command path matches our resume script (toggle off).
  def strip_resume(arr):
    arr
    | map(.hooks |= map(select((.command // "") | test("/handoff-resume\\.sh$") | not)))
    | drop_empty;

  # Repair .hooks if it is something other than an object.
  if (.hooks // null | type) != "object" then .hooks = {} else . end
  | .hooks.PreCompact = ((.hooks.PreCompact // []) | add_or_create("auto"; $snap) | add_or_create("manual"; $snap))
  | .hooks.SessionEnd = (
      (.hooks.SessionEnd // [])
      | (if any(.[]?; (.hooks // []) | any(.command == $snap))
          then .
          else . + [{hooks: [hook_entry($snap)]}]
        end))
  | if $auto == 1 then
      .hooks.SessionStart = ((.hooks.SessionStart // []) | add_or_create("compact"; $resume) | add_or_create("resume"; $resume))
    else
      .hooks.SessionStart = (strip_resume(.hooks.SessionStart // []))
    end
  | if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end
' "$settings" > "$tmp"

jq -e . "$tmp" >/dev/null || { echo "error: merged settings.json is not valid JSON; aborting" >&2; exit 1; }

# Backup AFTER successful merge so failed runs don't spam .backup-* files.
backup="$settings.backup-$(date +%Y%m%d-%H%M%S)-$$"
if [ -f "$settings" ] && ! cmp -s "$tmp" "$settings"; then
  cp "$settings" "$backup"
  echo "Backed up previous settings to $backup"
fi
mv "$tmp" "$settings"
trap - EXIT

mode="manual"
[ "$auto" -eq 1 ] && mode="auto-resume (SessionStart hooks installed)"

cat <<EOF

Installed claude-code-handoff (mode: $mode).
  scripts:  $claude_dir/scripts/handoff-snapshot.sh
            $claude_dir/scripts/handoff-resume.sh
  command:  $claude_dir/commands/resume.md
  cli:      $claude_dir/bin/claude-handoff   (run --help; add to \$PATH for convenience)
  packets:  $claude_dir/handoff/   (mode 700; packets are mode 600)
  hooks:    merged into $settings

Verify:
  1. In a Claude Code session, run /compact. Status line should show
     'PreCompact [...handoff-snapshot.sh] completed successfully'.
  2. ls -t $claude_dir/handoff/   # newest packet on top
  3. In a fresh session, type /resume — Claude should summarize the packet.
EOF
[ "$auto" -eq 1 ] && cat <<EOF
  4. Auto-resume only: open a fresh session after compaction. Claude should
     reference the prior session's state without you typing /resume.
EOF

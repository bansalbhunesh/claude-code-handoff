# claude-state demo tape
# Renders to assets/demo.gif via:  vhs assets/demo.tape
#
# This script sandboxes everything under a fresh HOME so it never touches
# the viewer's real ~/.claude. It pre-populates a few packets so `list`,
# `workspaces`, and `signal --explain` have something real to render.
#
# vhs syntax reference: https://github.com/charmbracelet/vhs

Output assets/demo.gif

Set Shell "bash"
Set FontSize 16
Set Width 1100
Set Height 640
Set TypingSpeed 35ms
Set PlaybackSpeed 1.0
Set Theme "Dracula"

# --- sandbox setup (silent; not part of the demo) -------------------------
Hide
Type "export REPO=$(pwd) && export HOME=$(mktemp -d) && export CLAUDE_HOME=$HOME/.claude && export PATH=$HOME/.claude/bin:$PATH"
Enter
Type "cd $REPO && ./install.sh >/dev/null 2>&1"
Enter
# Pre-populate three packets across two workspaces so list/workspaces/signal
# have material to render. We invoke snapshot.sh directly with synthesized
# transcripts — same path the real PreCompact hook takes, no Claude session
# required.
Type 'mk(){ tx=$HOME/tx-$1.jsonl; jq -nc --arg t "$3" "{type:\"user\", message:{content:\$t}}" > $tx; jq -nc --arg t "$4" "{type:\"assistant\", message:{content:[{type:\"text\", text:\$t}]}}" >> $tx; jq -nc --arg sid "$1" --arg tx "$tx" --arg cwd "$2" "{session_id:\$sid, transcript_path:\$tx, cwd:\$cwd, hook_event_name:\"PreCompact\"}" | bash $CLAUDE_HOME/claude-state/modules/handoff/snapshot.sh; }'
Enter
Type 'mk 11111111-1111-4111-8111-111111111111 $HOME/Work/api-server "fix the auth bug in /login" "Decision: going with PKCE flow because the redirect handler in src/auth.ts loses session state on chrome reloads. This is the third time we have debugged it."'
Enter
Type 'mk 22222222-2222-4222-8222-222222222222 $HOME/Work/api-server "add rate limiting to public endpoints" "Blocked: middleware ordering breaks tests in tests/auth.test.ts. Need to investigate before implementing."'
Enter
Type 'mk 33333333-3333-4333-8333-333333333333 $HOME/Work/dotfiles "tidy up zsh prompt" "Decision: dropping the git status segment in favor of a faster starship config."'
Enter
Type 'claude-state memory add --name auth_pattern --type reference --description "PKCE flow in /login" --content "we use PKCE for all OAuth flows; never plain code." >/dev/null'
Enter
Type "clear"
Enter
Show

# --- 1. status ------------------------------------------------------------
Type "claude-state status"
Enter
Sleep 3s

Type "clear"
Enter

# --- 2. list --------------------------------------------------------------
Type "claude-state list"
Enter
Sleep 3s

Type "clear"
Enter

# --- 3. workspaces --------------------------------------------------------
Type "claude-state workspaces list"
Enter
Sleep 4s

Type "clear"
Enter

# --- 4. signal --explain --------------------------------------------------
Type "claude-state signal 11111111-1111-4111-8111-111111111111 --explain"
Enter
Sleep 5s

Type "clear"
Enter

# --- 5. memory query (the plugin contract) --------------------------------
Type "claude-state memory query --json | jq '.memories[0]'"
Enter
Sleep 5s

Type "clear"
Enter

# --- 6. how to resume from a fresh Claude session ------------------------
Type "# In a fresh Claude Code session, just type:"
Enter
Sleep 700ms
Type "#   /resume"
Enter
Sleep 700ms
Type "# claude-state finds the right packet for this workspace"
Enter
Type "# and Claude picks up where you left off."
Enter
Sleep 4s

<!--
Thanks for the PR. The checklist below is short — most boxes should be quick.
-->

## What this changes

<!-- One paragraph: what does this PR do, and why? -->

## How I tested it

<!--
Specific commands you ran. If you added a test, mention which file and which
case. If you tested against a real Claude Code session, describe the round trip.
-->

## Checklist

- [ ] `bash tests/run-all.sh` is green
- [ ] `shellcheck install.sh uninstall.sh scripts/*.sh tests/*.sh bin/claude-handoff` is clean
- [ ] New user-visible behavior has a test exercising it
- [ ] `README.md` reflects the change (if user-facing)
- [ ] `CHANGELOG.md` has an entry under the right version section
- [ ] No new dependencies (`bash` + `jq` + POSIX tools only)
- [ ] No network calls

## Notes for the reviewer

<!-- Anything tricky, any trade-offs, any follow-up work that didn't fit here. -->

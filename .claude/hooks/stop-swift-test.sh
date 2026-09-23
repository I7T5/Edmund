#!/usr/bin/env bash
# Stop hook: run `swift test` at the end of a turn only when the working tree
# has uncommitted Swift or package changes. A docs/script/skill-only turn has
# nothing the suite can check, and the full run costs ~1 minute. Committed
# code is tested by /ship (step 2) and by CI before any merge.
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
git status --porcelain -uall | grep -Eq '\.swift$|Package\.(swift|resolved)$' || exit 0
swift test 2>&1 | tail -5

---
description: Take App Store / marketing screenshots of the real app, light and dark (runs scripts/screenshots.sh)
argument-hint: [pattern] e.g. settings — default all shots
allowed-tools: Bash(scripts/screenshots.sh:*)
---

Run `scripts/screenshots.sh $ARGUMENTS`. Its header documents the `.shot`
format; the shots themselves are `scripts/screenshots/*.shot`.

- Tell the maintainer before starting: each shot launches the app and takes
  focus for a few seconds, and typing elsewhere makes macOS refuse the
  activation (the script retries).
- The documents live in `misc/marketing/screenshot-docs/` (untracked, the
  maintainer's writing). Edit copies there only with their go-ahead.
- Look at every composed PNG before reporting: wrong state (raw source where a
  render was expected, a stray window, "Edited" in the title) is the usual
  failure, not a crash.
- Output goes to `misc/screenshots/<version>/` unless `SHOTS_OUT` is set.

---
description: Take App Store / README / site screenshots of the real app, light and dark (runs scripts/screenshots.sh), then rate them
argument-hint: [pattern] e.g. settings — default all automatic shots
allowed-tools: Bash(scripts/screenshots.sh:*)
---

Run `scripts/screenshots.sh $ARGUMENTS`. Its header documents the `.shot`
format; the shots themselves are `scripts/screenshots/*.shot`.

- Tell the maintainer before starting: each shot takes focus for a few
  seconds. The runner waits for 3 s without keyboard or mouse input before
  each launch, so it only moves while they pause.
- Manual shots (`# manual:`, e.g. 4-find) run only when named. Start one in
  the background, tell the maintainer what the `waiting:` line asks, and
  `touch` the file it names once they say it's set up.
- The documents live in `misc/marketing/screenshot-docs/` (untracked, the
  maintainer's writing). Edit copies there only with their go-ahead.
- After a run, read rate.swift's lines, then hand the composed PNGs to the
  screenshot-rater agent. Iterate on `.shot` files (window size, zoom,
  layout) until every shot scores ≥ 8; look at every PNG yourself too.
- Output goes to `misc/screenshots/<version>/` unless `SHOTS_OUT` is set;
  `SHOTS_SIZE` and `SHOTS_BACKGROUND` change the canvas.

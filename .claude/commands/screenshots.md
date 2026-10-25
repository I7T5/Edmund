---
description: Take, review and publish screenshots of the real app for the App Store, the README and edmund.md (scripts/screenshots.sh, scripts/screenshots-publish.sh)
argument-hint: [pattern] e.g. 3-table — default every automatic shot
allowed-tools: Bash(scripts/screenshots.sh:*), Bash(scripts/screenshots-publish.sh:*), Bash(touch:*)
---

Screenshots are taken when the maintainer asks, not every release. The header
of `scripts/screenshots.sh` documents the `.shot` format; the shots are
`scripts/screenshots/*.shot`.

1. **Take.** `scripts/screenshots.sh $ARGUMENTS`. Tell the maintainer first:
   each shot takes focus for a few seconds; the runner waits for 3 s without
   keyboard or mouse input before each one and discards a shot with input
   during it. Manual shots (`# manual:`, e.g. 4-find) run only when named:
   tell the maintainer what the `waiting:` line asks; the shot is the next
   screenshot they take (or `touch` the file it names).
2. **Review one shot at a time.** Read rate.swift's lines, look at the PNG
   yourself, and show it to the maintainer. Iterate on that shot alone
   (`.shot` window size, zoom, layout, scale; `--compose-only` for layout
   changes, which takes no screen) until they approve it, then the next.
   The screenshot-rater agent gives a second opinion when asked.
3. **Publish.** Once every shot is approved: `scripts/screenshots-publish.sh`.
   It archives the previous set to `misc/archive/`, copies the shots with an
   `# alt:` header to `docs/assets/screenshots/` and
   `site/public/assets/screenshots/`, and rewrites the site's
   `site/src/data/screenshots.json` and the README's list between
   `<!-- screenshots -->` and `<!-- /screenshots -->`.

- The documents live in `misc/marketing/screenshot-docs/` (untracked, the
  maintainer's writing). Edit them only with the maintainer's go-ahead.
- Output goes to `misc/screenshots/<version>/` unless `SHOTS_OUT` is set;
  `SHOTS_SIZE` and `SHOTS_BACKGROUND` change the canvas; `SHOTS_SRC` builds
  from another tree (e.g. one with unmerged fixes merged in).

---
description: Film, rate and refine screen recordings of the real app for the README, site and App Store preview (scripts/recordings.sh), or the App Review recording (scripts/review-recording.sh)
argument-hint: [pattern | review] e.g. live-preview — default every clip
allowed-tools: Bash(scripts/recordings.sh:*), Bash(scripts/review-recording.sh:*)
---

Recordings are made when the maintainer asks. The header of
`scripts/recordings.sh` documents the `.rec` format; the clips are
`scripts/recordings/*.rec`.

**`review`:** the App Review recording is performed by the maintainer, not
scripted. Tell them to run `scripts/review-recording.sh` in their own
terminal (it waits for Return and they drive the app), then read its
rating and the contact sheet `app-review-sheet.png`, run the recording-rater
agent on it, and report what to redo. Nothing else below applies.

1. **Film.** `scripts/recordings.sh $ARGUMENTS`. Tell the maintainer first:
   each clip takes focus once (Edmund has to be the active app or its traffic
   lights film grey); the runner waits for 3 s with no keyboard or mouse
   input, and input during a clip discards it. Other windows may cover
   Edmund while it films. If the run stops with "Screen Recording is off",
   that is the one-time grant: ask for it (`needs input:`) and stop.
2. **Rate.** Read rate.swift's lines, then run the recording-rater agent on
   the output directory with those lines. Look at the sheet yourself too.
3. **Refine, up to 3 rounds per clip on your own.** Apply the rater's fix to
   that clip's `.rec` (timing, zoom, window size, `# length:`) and rerun only
   that clip. A fix that changes only layout, scale or background needs no
   new filming: `--compose-only <clip>`. Stop early when it reaches 8.
4. **Show it.** The clip's poster, sheet and mp4 path, the score, and what
   changed. Wait for the maintainer's OK before the next clip: one clip at a
   time, never the whole set again.

- The documents live in `misc/marketing/screenshot-docs/` (untracked, the
  maintainer's writing). The runner films a copy; never edit the originals.
  From a worktree, point `SHOTS_DOC_ROOT` at the main checkout.
- Output goes to `misc/recordings/<version>/` unless `REC_OUT` is set;
  `REC_GIF=1` adds GIFs. `SHOTS_BACKGROUND` and `SHOTS_SRC` work as for
  screenshots.
- The App Store preview (`appstore-preview.rec`, `# combine:`) has to run
  15–30 s; until enough clips carry `# appstore: yes`, its FAIL is expected.

# Wrapped-cell caret flash — investigation notes

Context for anyone who sees a stray caret in a table again. The bug took many
"fix by reasoning" rounds that each made it fainter and none removed it; it
was closed only once a real click could be captured frame by frame. The
method is the reusable part, so it is written up in full.

Fixed in `2e98ad0` (branch line `fix/table-parse-and-emphasis`, local only).
The multi-click ghost found by the same harness is in a separate pass.

## Symptom

Clicking into a table cell that is too wide for its column (a *wrapped* cell,
drawn from a scratch layout — see ARCHITECTURE §9) made the caret visibly
appear at the **start of the cell** for a moment, then move to where the
click was. The reporter pinned the pattern precisely, and every clause turned
out to matter:

1. never on the *first* click into a wrapped cell;
2. only when the previous click had left the caret **outside the table** or
   **in a cell of the other kind** (header ↔ body);
3. after that, clicks within the same kind of cell did not flash until the
   caret left again.

## Why it was hard

- On macOS 15 a TextKit 2 `NSTextView` never calls
  `drawInsertionPoint(in:color:turnedOn:)`. AppKit draws its caret through a
  private view, so nothing in the editor's own draw path could be
  instrumented to see the stray paint.
- The editor hides AppKit's caret with a clear `insertionPointColor` and draws
  its own for wrapped cells (`EditorTextView+TableCellCaret.swift`). Every
  round of "clear the colour earlier / also turn the insertion point off"
  made the flash *fainter* — so the mechanism was clearly being brushed, but
  not removed, and there was no way to tell which frame the paint landed in.
- The in-process ReproScript click (`clickprobe`) **cannot show this bug at
  all**, for two reasons that only became clear at the end: (a) it queues the
  mouse-up before the down, so the whole gesture runs inside one call and no
  display frame is rendered between; (b) it never activates the app, and
  AppKit's caret view — `NSTextInsertionIndicator`, a direct subview of the
  text view — is only created once the window is key. Probes were reporting
  on a caret that did not exist.
- Full-screen `screencapture -v` was tried once and captured the user's other
  windows. **Never again** — window-scoped capture only.

## What finally worked

Three DEBUG-only additions to `ReproScript.swift` (all committed):

| Command | What it does |
|---|---|
| `front` | once at script start: `moveToActiveSpace`, order front, activate |
| `realclick x,y[,holdms[,clicks]]` | a real HID click via `CGEvent` at a *view* point. Floats the window for the click, waits 250 ms, then verifies with `CGWindowListCopyWindowInfo` that **our window is topmost at that point** (layers ≤ 3 only — the Dock and menu bar span the screen edge at higher layers) and aborts otherwise. Accessibility trust is needed once. |
| `realoff holdms,gapms,off1,off2,…` / `realseq holdms,gapms,x1,y1,…` | a run of real clicks from one thread with exact spacing and a mouse-move trail between them, as a hand does. `realoff` addresses **raw offsets** and finds the point through the same rects the caret is drawn with, so the script survives the window being moved or resized mid-run (it was). |
| `burst ms,interval,dir` | a ScreenCaptureKit stream filtered to **our window id only** — nothing else on screen is included — delivering a frame on every repaint of the window (at most one per `interval` ms), files named `NNNN-<uptime ms>.png`, timestamp taken at delivery. (First built on `CGWindowListCreateImage` polled every ~13–35 ms; the stream replaced it when that API was retired, and catches each paint as its own frame rather than sampling.) |
| `-debug.caretTrace YES` | logs every `insertionPointColor` set, every `updateInsertionPointStateAndRestartTimer`, and (in `drawWrappedCellChrome`) the dirty rects of every draw, each with process uptime in ms and the caller. |
| `viewtree`, `indicators`, `caretstate`, `hideviews`, `redraw` | the view/layer tree with running animations; AppKit's indicator's state; the editor's own caret state; hide a class of subviews to find which layer owns a pixel; force a full repaint. |

Analysis was a small script (`timeline.py`, in the job scratch dir — trivial
to rewrite: PIL, blue-pixel columns per frame, merged with the trace by
timestamp). Because frames and trace lines share one clock, each stray pixel
can be matched to the exact call that produced it.

Coordinates trap: the burst image is the whole window including its title
bar, so a view y of 156 lands at image row ≈ (156 + 52) × 2. Scanning too
narrow a row band made a correctly drawn caret look missing for an hour.

## Mechanism (from the frames, not inferred)

1. On a click into a wrapped cell, `setSelectedRange` moves AppKit's
   `NSTextInsertionIndicator` onto the cell's **hidden characters** — all
   collapsed at the cell's start (on a header row, in the pill band above the
   row, where the row's real line box sits).
2. The indicator is then hidden by AppKit with an **animated fade**, after
   it has already moved. The fade plus a small "moved" glow lasted ~100 ms —
   3–4 frames — at the cell start. That is the flash.
3. Clearing `insertionPointColor` and calling
   `updateInsertionPointStateAndRestartTimer(false)` shorten but cannot skip
   the fade, which is why each earlier fix made it fainter.
4. Clause 1 of the symptom: on the first click the indicator was not live
   yet, so there was nothing to fade. Clause 2: a wrapped→wrapped click
   starts with the indicator already hidden. The reporter's "type of cell"
   pattern came from their document — headers wrapped, bodies not (or the
   reverse).

## Fix

`setAppKitCaretHidden(true)` — `isHidden` on the indicator view, which is not
animated — **before** the selection moves in `handleWrappedCellDrag` and in
the `super.mouseDown` pre-clear, and again in `updateWrappedCaret` so the
async selection-change path is covered; `setAppKitCaretHidden(false)` when
the caret leaves wrapped text. Verified: four transitions (outside→header,
non-wrapped→wrapped body, header→body, body→header), ~75 frames each, zero
pixels at the cell start after the click; AppKit's caret back outside.

## Lessons

- **A bug that gets fainter with each fix is a bug you have not found.**
  Stop iterating on the fix and instrument the frame.
- In-process synthetic clicks are fine for *selection* questions and useless
  for *caret paint* questions: they neither activate the app nor let a frame
  render mid-gesture. Use `realclick`/`realoff`.
- Window-scoped capture is both the privacy-safe and the only practical way
  to see single-frame paints; `screencapture -l` stills miss them.
- Keep the harness committed (DEBUG) — the same commands found the next bug
  in minutes (the multi-click ghost, `docs/investigations` follow-up).

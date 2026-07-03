# CLAUDE.md — Edmund

Native macOS Markdown editor, live preview (AppKit + TextKit 2, SPM, macOS 14+).

**Before non-trivial work, read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)** —
it covers the build/test commands, the two hard invariants (storage == rawSource;
TextKit 2 only), the render pipeline, the feature map, and the gotchas. Keep that
doc updated as you learn things.

## Environment
- Do **not** request Computer Access — Screen Recording and Accessibility are already granted.
- For frontend changes, verify with `screencapture` in the CLI (capture the window by id; see ARCHITECTURE §8). If it keeps failing, render the editor offscreen to a PNG.

## Git practices
- Commit automatically and frequently. 
- Branch off `main` for each fix (don't commit straight to `main`); one feature/fix per branch, small logical commits.
- **Never auto-push, PR, or merge — only when I explicitly ask.**
- Never delete uncommitted changes. 

## Before committing (the checklist that works)
1. `swift test` — all green; add tests for new behavior / bug repros. **`swift test` runs automatically as a Stop hook** at the end of every turn that touches code, so failures surface before you commit.
2. Visual changes: build the app and `screencapture`-verify (or render offscreen to PNG). Don't trust headless layout alone for anything that draws.
3. Touch only what the task needs; match surrounding style; don't refactor unrelated code.

See ARCHITECTURE §12 for the fuller rationale.

## Comment quirks where they live
Document non-obvious behavior (edge cases, workarounds, the *why*) as a short
comment at the code itself — not in commits or this file.

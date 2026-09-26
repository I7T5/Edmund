# CLAUDE.md — Edmund

Native macOS Markdown editor with live preview: AppKit + TextKit 2, SwiftPM, macOS 14+.

**Before non-trivial work, read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md):**
build and test commands, the two hard invariants (storage == rawSource;
TextKit 2 only), the render pipeline, the feature map and the gotchas. Update
it when you find something missing or wrong.

## Environment
Screen Recording and Accessibility are already granted. Never request Computer Access.

## Git
- One branch off `main` per fix or feature; never commit to `main`. Commit without asking, often, in small logical commits.
- For concurrent work, `git worktree add .worktrees/<branch> <branch>` instead of stashing or switching; `.worktrees/` is gitignored. Keep `type/slug` branch names (`fix/foo`), never `worktree-*`. `.claude/worktrees/` belongs to Claude Code's EnterWorktree tool; don't edit it by hand.
- **Push, open a PR or merge only when I explicitly ask.**
- Never delete uncommitted changes.

## Before committing
1. `swift test` passes with zero compiler warnings in `Sources/` and `Tests/` (CI fails on any). Add tests for new behavior and bug repros. A Stop hook runs `swift test` after any turn that leaves uncommitted Swift or package changes.
2. Anything that draws: build the app and check a `screencapture` of the window by id (ARCHITECTURE §8), an offscreen PNG if capture keeps failing, or run `/verify-live`. Headless layout is not proof.
3. Touch only what the task needs, match the surrounding style, leave unrelated code alone.

Rationale: ARCHITECTURE §12.

## Comments
Document non-obvious behavior (edge cases, workarounds, the why) in a short comment at the code, not in commits or this file.

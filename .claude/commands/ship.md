---
description: Test (zero warnings), review docs and writing, offer a live check, then branch, commit, push, open a PR, and enable auto-merge for the current working-tree changes
argument-hint: [short description of the change]
allowed-tools: Bash, Read, Edit, Agent
---

Ship the current uncommitted changes in this repo as a self-merging PR. The
change is described as: **$ARGUMENTS**

Run all git/gh commands from the repository root. Follow these steps exactly,
stopping and reporting if any step fails:

1. **Survey.** `git status --short` and `git diff --stat`. Confirm there are
   changes to ship. If `$ARGUMENTS` is empty, infer a concise description from
   the diff.

2. **Test first (project rule), scoped to the change.**
   - No `.swift`, `Package.swift` or `Package.resolved` in the change (docs,
     skills, scripts, fixtures): skip the Swift build and tests entirely.
   - Otherwise run the suites that exercise the changed code:
     `swift test --filter '<SuiteA>|<SuiteB>'`. Pick them by grepping
     `Tests/` for the changed types and files. Run the full `swift test`
     only when the change touches a shared path (`TextView/`, `Parsing/`,
     `Model/`, the storage or render pipeline) or no suite clearly covers it.
   - Pipe the run through `tee` to a log file (with `set -o pipefail`, or
     the pipe reports `tee`'s status and hides a failing run) and grep it for
     `(Sources|Tests)/[^:]+:[0-9]+:[0-9]+: warning:`. Any hit is a failure:
     the policy is zero warnings, and CI's `No warnings` step rejects them
     anyway. (An incremental build prints warnings only for the files it
     recompiled, so this catches the change's own warnings; CI's clean
     build catches the rest.)
   - CI runs the full suite before auto-merge, so this step is a fast
     pre-check, not the gate. If anything fails, stop and show the failure —
     do not commit.

2b. **Reviews (every ship).** No one reviews the PR before it auto-merges, so
   these run every time. If subagents are
   unavailable, say so in the step 8 report and carry on.

   1. **Doc drift.** Spawn the `doc-drift` subagent on `git diff main` (plus
      uncommitted changes). List its findings and ask whether to apply them;
      on yes, edit them into this change before committing. `report-only`
      lines (README, backlog) go in the step 8 report, never into files.
      Skip for a change with no `.swift` files and no renamed paths.
   2. **Drafts.** Write the PR body now (step 6's register and structure)
      and the sample CHANGELOG lines for step 8, with `(#?)` in place of the
      PR number.
   3. **Writing and HIG.** Run this gate; it prints `ui` only when the change
      touches app chrome:

      ```sh
      { git diff main --name-only -- Sources/edmd Sources/EdmundQuickLook; git diff main -U0 -- Sources | grep -E '^\+.*(NSMenu|keyEquivalent|NSButton|NSAlert|NSPopover|NSToolbar|NSWindow|NSColor|accessibility|toolTip|SwiftUI)'; } | grep -q . && echo ui
      ```

      Spawn the `hig-reviewer` subagent with the diff, `ui: yes|no` from the
      gate, the PR body draft and the sample CHANGELOG lines. Any `blocker`
      line: stop, show the findings, and ask before continuing. `write` lines
      on the drafts: apply them to the drafts. Other `write` lines and
      `should`/`nit` lines: list them in the step 8 report and carry on.

2c. **Live risk class.** Classify the change by its changed paths (the
   `edmund-change-control` table; paths relative to `Sources/EdmundCore/`
   unless shown):
   - **edit-pipeline**: `TextView/EditorTextView+{EditFlow,Composition,SelectionTracking,Undo,LazyStyling,TypewriterScroll}.swift`,
     `TextView/EditorTextStorage.swift`, `Editing/**`
   - **drawing**: `Rendering/**`, `TextView/DecoratedTextLayoutFragment.swift`,
     `Diagrams/**`, `Math/**`, `Resources/Themes/**`
   - **chrome**: the step 2b gate printed `ui`

   No class: skip silently. Otherwise ask: "This is a <class> change. Run
   `/verify-live` before shipping?" Yes: run it, then put its summary and
   evidence paths in the PR body's Testing section. If its evidence
   contradicts the change (the bug does not reproduce on `main`, the branch
   still shows it, or an assertion fails), stop and show it. No: the Testing
   section says `Not live-verified (declined at ship).`

3. **Branch.** If currently on `main`, create a topic branch named
   `fix/…`, `feature/…`, `ci/…`, or `chore/…` as fits the change (kebab-case,
   derived from the description). If already on a non-main branch, reuse it.

4. **Commit.** Stage only the files that belong to this change (surgical — no
   unrelated files). Write a commit message: a concise imperative subject line
   and a body explaining the *why*. No attribution trailer.
   Keep it one logical change per commit.

5. **Push.** `git push -u origin <branch>`.

6. **Open the PR.** `gh pr create` with a title matching the subject and the
   body drafted and reviewed in step 2b. No attribution header or footer (the
   attribution header belongs on PR review comments only). Register
   and structure: `edmund-docs-and-writing` §3 "PR descriptions and review
   comments" (Summary → Changes → Testing → Notes; direct, no courtesy).

7. **Auto-merge.** `gh pr merge <#> --auto --merge --delete-branch`. Branch
   protection requires the `test` check, so this queues the PR to merge itself
   the moment CI passes — no manual merge needed.

8. **Report.** Print the PR URL and state that it will merge automatically when
   CI is green. Do **not** sit and poll CI unless asked. Then print, in this
   order:
   - the review lines carried from step 2b, and whether `/verify-live` ran;
   - **Sample CHANGELOG entries**, a fenced Markdown block the maintainer can
     paste at release: the `### Added|Changed|Fixed` heading(s) and one line
     per user-visible effect with the real PR number, in the format of the
     latest section of `docs/CHANGELOG.md` (`- <effect> (#NNN)`; `@handle`
     for outside contributors, and every author's handle when any author is an outside contributor; area prefix such as `Settings > …` where
     existing entries use one). Internal-only changes (CI, tests, skills,
     agent files) get the line `No user-visible change — no CHANGELOG entry.`
     Print only. Never write `docs/CHANGELOG.md`; it changes only through
     `/release`.

Never force-push, never touch `main` directly, and never bypass the failing-test
stop in step 2.

---
description: Branch, test, commit, push, open a PR, and enable auto-merge for the current working-tree changes
argument-hint: [short description of the change]
allowed-tools: Bash, Read, Edit
---

Ship the current uncommitted changes in this repo as a self-merging PR. The
change is described as: **$ARGUMENTS**

Run all git/gh commands from the repository root. Follow these steps exactly,
stopping and reporting if any step fails:

1. **Survey.** `git status --short` and `git diff --stat`. Confirm there are
   changes to ship. If `$ARGUMENTS` is empty, infer a concise description from
   the diff.

2. **Test first (project rule).** Run `swift test`. If anything fails, stop and
   show the failure — do not commit.

3. **Branch.** If currently on `main`, create a topic branch named
   `fix/…`, `feature/…`, `ci/…`, or `chore/…` as fits the change (kebab-case,
   derived from the description). If already on a non-main branch, reuse it.

4. **Commit.** Stage only the files that belong to this change (surgical — no
   unrelated files). Write a commit message: a concise imperative subject line
   and a body explaining the *why*. No attribution trailer.
   Keep it one logical change per commit.

5. **Push.** `git push -u origin <branch>`.

6. **Open the PR.** `gh pr create` with a title matching the subject and a body
   that explains what and why. No generated-by / attribution footer.

7. **Auto-merge.** `gh pr merge <#> --auto --merge --delete-branch`. Branch
   protection requires the `test` check, so this queues the PR to merge itself
   the moment CI passes — no manual merge needed.

8. **Report.** Print the PR URL and state that it will merge automatically when
   CI is green. Do **not** sit and poll CI unless asked.

Never force-push, never touch `main` directly, and never bypass the failing-test
stop in step 2.

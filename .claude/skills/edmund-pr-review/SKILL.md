---
name: edmund-pr-review
description: >
  Review a GitHub pull request against Edmund's invariants and produce a
  merge-readiness checklist. Invoke as `/edmund-pr-review <PR number>` or load
  when asked to evaluate, review, or decide what to do about a PR — especially
  an outside contribution. Covers the gather → verify → ask → checklist flow,
  the claim-verification bar (never merge on a contributor's numbers alone),
  the Edmund-specific traps a generic review misses (TextKit 2 height
  estimates, storage == rawSource, undisclosed drive-by changes, fork CI
  gating), and the output format the maintainer expects.
---

# Edmund PR review

Review the PR whose number was given (`/edmund-pr-review 236`, or from the
request) and hand the maintainer a checklist they can act on.

The deliverable is not an opinion. It is a list of things that must be true
before this merges, each one either already verified by you or clearly marked
as outstanding.

## 0. Ground rules

- **Read-only until told otherwise.** Never merge, push, approve, or comment
  as a side effect of reviewing. Those are separate explicit asks (CLAUDE.md).
  Creating a scratch worktree and running tests in it is fine.
- **Verify, don't relay.** A contributor's benchmark numbers, "all tests pass",
  and "this is safe because X" are claims. The review is where they get
  checked. See §2.
- **Only claim what you ran.** If a check was skipped, the checklist says so
  rather than quietly implying it passed.

## 1. Gather

```bash
gh pr view <N> --json state,mergeable,mergeStateStatus,body,files,commits,comments
gh pr checks <N>
git fetch origin pull/<N>/head:pr<N> -f
git diff main...pr<N>          # three-dot — see the trap below
```

**Use three-dot diff.** A two-dot `git diff main pr<N>` also reports everything
that landed on `main` since the PR branched, which on a week-old branch buries
the actual change in dozens of unrelated files. If the file count from
`gh pr view --json files` disagrees with your diff, you used two dots.

Then read, in this order:

1. The **PR body** — what the author says the change is. Keep it open; §2.4
   compares it against the diff.
2. The **diff itself**, whole. Not just the hunks that look interesting.
3. Any **prior review comments** on the PR — including your own from an
   earlier round, so a re-review picks up where the last one left off.

## 2. Review passes

Run all five. They catch different things.

### 2.1 The invariants

The two hard ones, from `edmund-architecture-contract` / ARCHITECTURE §2:

- **Storage always equals `rawSource`.** Any diff that inserts or deletes
  characters for display purposes — rather than hiding them with attributes —
  is rejected, not negotiated.
- **TextKit 2 only.** Any reference to `NSTextView.layoutManager`, any stored
  `NSTextBlock`/`NSTextTable` attribute, any `NSTextAttachment` silently
  reverts the view to TextKit 1.

Then the gate table in `edmund-change-control` §1: classify the change and
check the author cleared the gate it lands in. A PR touching `Rendering/` with
no screenshot has not cleared its gate, however green the tests are.

### 2.2 The TextKit 2 estimate rule

The trap that generic review misses, and the reason this pass has its own
section.

TK2 gives fragments real frames only once they are laid out; total document
height before that is an *estimate*, corrected as layout catches up. Edmund
sidesteps this for documents it can afford to: `scheduleFullLayoutSettle` runs
`ensureLayout(for: documentRange)` when the document is at or under
`EditorTextView.fullLayoutMaxLength`. Above that, the estimate regime applies.

So for any PR that measures, scrolls, or reasons about document height:

```bash
grep -n "fullLayoutMaxLength" Sources/EdmundCore/TextView/EditorTextView.swift
grep -n -A5 "func scheduleFullLayoutSettle" Sources/EdmundCore/TextView/EditorTextView+LazyStyling.swift
```

Compare the threshold against the document sizes the PR actually exercises.
A PR whose scenarios all sit on one side of it has measured one regime and
said nothing about the other — even when no code violates the rule. Say which
regime the numbers describe.

*This is not hypothetical: #236 shipped benchmarks at 100,203 and 200,190
UTF-16 units against a 100,000 threshold, so `ensureLayout` never ran in any
sample and every headline figure described the estimate-only path. The 100k
scenario missed by 203 characters.*

### 2.3 Verify the load-bearing claim

Find the one claim the merge rests on, and try to break it.

- A **test claimed to guard a behavior**: delete or stub the behavior, run the
  test, confirm it fails, restore. A guard that passes with the feature removed
  is not a guard. (On #236 this distinguished a real cache guard from
  dispersion tests that stayed green with the cache deleted.)
- A **performance claim**: check what regime it was measured in (§2.2) and
  whether a committed baseline backs the number.
- A **"tests pass" claim**: run `swift test` yourself on the PR head, in a
  scratch worktree. Note the toolchain — CI pins `runs-on: macos-14` in
  `.github/workflows/ci.yml`, which caps the Xcode version and therefore the
  Swift version, so a contributor on newer Xcode is not running what CI runs.
- **Known flakes** are not regressions. `Body text uses textColor`
  (`AppearanceIntegrationTests`) fails under some local appearance conditions
  on both `main` and any branch. Before blaming a PR for a failure, run the
  same filter on `main` and compare.

Restore anything you stubbed, and confirm with `git status --porcelain` before
moving on.

### 2.4 Undisclosed changes

Diff the PR body against the diff. Behavior changes the description does not
mention are the most common review miss — they are not usually malicious, just
drive-by edits the author stopped noticing.

Look for: tightened or loosened equality/comparison semantics, removed guard
clauses or resets, changed default values, error paths turned into silent
`continue`s, whitespace edits in prose files that change rendering.

For each: decide whether it is correct on its own merits, then require it be
called out in the description regardless. A change nobody wrote down is a
change nobody will remember when it breaks.

### 2.5 Error-path narrowing

Specifically check whether any refactor widened the blast radius of a failure.
The pattern to grep for is a `guard … else { continue }` that moved outward —
from inside a per-item loop to around a batch — so one failed lookup now skips
the whole batch instead of one item.

*#236 coalesced `invalidateLayout(forBlocks:in:)` from per-block to per-run;
a failed range mapping went from skipping one block to skipping a contiguous
run, which is exactly the documented empty-bands / clipped-lines failure.*

## 3. Ask the maintainer

Before writing the checklist, surface the decisions that are genuinely theirs.
Do not guess on these — the disposition of someone else's work is not a default
you get to pick.

Use `AskUserQuestion` when the choice is a small set of known options:

- Disposition: merge as-is / merge a reduced subset / request changes / hold.
- Scope: which parts to take now versus defer to a follow-up, when the PR
  bundles a clear win with something unproven.
- Merge method, when the repo allows several and the commit history differs
  between them.

**Every option carries its consequence, in one line.** The maintainer should
not have to reconstruct what an option costs — the same rule as "Why these
items" in §4, applied to the question instead of the checklist. State what
picking it means, concretely and without hedging: *"Drop it — cannot run on
CI by its own design, so it will not catch the regression it targets"*, not
*"Drop it"*. One line each. If an option needs a paragraph to justify, the
question is wrong.

Ask in prose instead when the answer is open-ended — a judgment call about
project direction, or how to word feedback to a contributor. Ask, then stop
and wait for the reply as a normal prompt.

Ask **nothing** you can determine yourself. Whether the tests pass, whether a
claim holds, what the diff touches — that is the review's job, and asking the
maintainer to adjudicate it wastes the round-trip.

## 4. Emit the verdict

Two parts, in this order: the checklist, then the reasoning. The checklist is
what the maintainer acts on; the reasoning is what they consult when an item
looks wrong. Reversing the order buries the deliverable.

Write it in PR-summary style — the register of a description someone would
paste into GitHub, not review chatter.

- Every item is a **binary, checkable statement**, phrased so that "done" is
  unambiguous. Not "consider adding a test".
- Mark what you already verified as `[x]` and say how it was verified. An
  unchecked box means genuinely outstanding.
- Attribute each item to whoever must act: contributor, maintainer, or you.
- Order by what blocks the merge, not by where it appears in the diff.
- If nothing blocks, say so plainly and keep the list short. A clean PR gets a
  three-line checklist, not a manufactured one.

Then **Why these items** — one or two sentences each, in checklist order,
naming the concrete failure the item prevents. No restating of the item.

### Output template

```markdown
## PR #<N> — <title>

<One-paragraph summary: what the change does, whether it should merge, and
what it turns on.>

### Merge checklist

- [x] <Verified item> — verified by <how>
- [ ] <Outstanding item> (contributor)
- [ ] <Outstanding item> (maintainer)

### Why these items

- **<Item>** — <the failure it prevents, in one or two sentences>
```

## 5. If asked to post the review

Posting is a separate explicit ask (§0). When it comes:

**Attribution goes at the top, before the first line of content.** A reader
deciding how much weight to give the review needs to know its provenance
before they read it, not after. Use this line verbatim:

```markdown
> 🤖 Generated by Claude Code. Revised with human feedback. Reviewed by the dev 💁‍♀️
```

Then the review body.

The line asserts the maintainer reviewed it. Post only after they actually
have — show them the draft and wait. Never post a review on your own
initiative with this attribution attached.

Post with `gh pr comment <N> --body-file <path>`, writing the body to a file
first rather than inlining it, and read the posted comment back to confirm it
landed intact.

## When NOT to use this skill

| You need… | Go to |
|---|---|
| The gate table and non-negotiables in full | `edmund-change-control` |
| The invariants' technical statement, render pipeline | `edmund-architecture-contract` |
| To ship your *own* change as a self-merging PR | `/ship` |
| TextKit 2 / AppKit API behavior details | `textkit2-appkit-reference` |
| Test-writing patterns | `edmund-validation-and-qa` |
| Screencapture / ReproScript mechanics | `edmund-live-repro-and-diagnostics` |

## Provenance and maintenance

- Derived from the #236 review (merged 2026-07-26 as `45258ca`), which
  produced §2.2, §2.3, §2.4, and §2.5 — each section corresponds to something
  that review caught and a generic pass would not have.
- Fork PRs from outside contributors sit at `mergeStateStatus: BLOCKED` with
  `action_required` CI until a maintainer approves the workflow run. That is a
  gate, not a failure. Approving runs contributor code on the repo's runner, so
  read the diff for workflow/script changes first — and it is the maintainer's
  call, not the reviewer's.
- Line numbers and thresholds cited here (`fullLayoutMaxLength`, the CI runner
  label) are grepped at review time, never trusted from this document. If one
  has drifted, fix it here in the same change.

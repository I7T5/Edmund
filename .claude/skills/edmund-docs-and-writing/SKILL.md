---
name: edmund-docs-and-writing
description: >
  Documentation of record for the Edmund repo: which doc owns which fact, and
  how to write in the house style. Load whenever you are writing or updating
  ANY project doc — docs/ARCHITECTURE.md, CHANGELOG.md, README.md,
  docs/ROADMAP.md, misc/backlog.md, a docs/<topic>-investigation.md
  write-up, release docs — or deciding WHERE a newly learned fact, gotcha,
  bug, or feature idea belongs. Covers the docs-of-record map, the
  fact-routing decision table, the investigation-doc template, CHANGELOG
  format (machine-extracted for release notes), commit-message conventions,
  and doc maintenance duties. Not for making the code change itself, release
  mechanics, or debugging — see "When NOT to use this skill".
---

# Edmund docs and writing

Date-stamped 2026-07-09. Every claim below was verified against the files on
`main` at that date; re-verify paths before trusting this after major
reorganizations.

## When NOT to use this skill

| You are actually doing | Use instead |
| --- | --- |
| Changing code / designing a mechanism | `edmund-architecture-contract` |
| Branch/commit/PR mechanics, pre-commit checklist | `edmund-change-control` |
| Cutting a release, appcast, Sparkle, CI | `edmund-release-and-operate` |
| Diagnosing a bug (not writing it up) | `edmund-debugging-playbook`, `edmund-live-repro-and-diagnostics` |
| Mining past investigations for technique | `edmund-failure-archaeology` |
| Marketing copy, positioning, alternatives research | `edmund-external-positioning` |
| Build flags, env, debug bundle | `edmund-build-and-env`, `edmund-config-and-flags` |

This skill is for prose: what to write, where it lives, how it should read.

## 1. The docs-of-record map — one home per fact

Every fact has exactly one home; everywhere else gets a pointer. All paths
exist and are current as of 2026-07-09.

| Doc | Owns | Notes |
| --- | --- | --- |
| `docs/ARCHITECTURE.md` | HOW the system works: build/test commands (§1), the two invariants (§2), render pipeline (§3), edit/undo flow (§4), TextKit 2 drawing (§5), feature map (§6), settings (§7), gotchas (§8), known issues (§9), code debt (§10), agent quick start (§11), working agreements (§12), release/CI (§13), references (§14) | THE agent-onboarding doc. Its own header states the rule: **when you learn something non-obvious or change an invariant, edit this file in the same PR.** |
| `README.md` | WHAT/WHY for users: differentiators, screenshots, install (incl. the Gatekeeper "DAMAGED" `xattr -dr com.apple.quarantine` workaround), dependencies, alternatives, acknowledgements, license | User-facing; no internals. |
| `CHANGELOG.md` | User-facing version history, Keep-a-Changelog style | `## [x.y.z]` sections are machine-extracted for release notes — exact format matters (§4 below). |
| `docs/ROADMAP.md` | Versioned feature plan: `## v1.0.0`, `## v1.x`, `# v.2.0.0` sections of checkbox lists, grouped by theme (editing, extensions, macOS integrations) | Has a `Last updated: YYYY-MM-DD` line under the title — refresh it when you edit. |
| `misc/backlog.md` | The maintainer's working priority list: `## Now (small releases)` (Marketing / On-going bugs / Bugs / UI/UX / Features), `## Next`, `## Later`, roadmap mirrors, `### Lurking (Unreproduceable)`, `## Done` | Stated priority: **Marketing = Bugs >= UI/UX > Features**. Bug entries carry repro pointers (`misc/bug-repros/*.mov`, `.log`, or `~/Desktop` paths). |
| `docs/investigations/<topic>-investigation.md` | Deep multi-round investigation chronicles for active bug classes | Existing: `delete-drift-`, `viewport-glitch-investigation.md`. Template in §5. |
| `docs/investigations/archives/<topic>-investigation.md` | Chronicles for closed/resolved bug classes | Existing: `callout-bottom-line-`, `callout-title-wrap-investigation.md`. |
| `docs/dev-guides/live-repro-guide.md` | Method doc: the escalation ladder for reproducing live-app bugs | Referenced from ARCHITECTURE §11. |
| `misc/before-you-release.md` | Pre-flight readiness checklist | Pairs with `how-to-release.md`; cross-ref `edmund-release-and-operate`. |
| `misc/how-to-release.md` | Release mechanics (CI tag path, local `release.sh`) | Same. |
| `CLAUDE.md` (root) | Behavior contract for agents: env, git practices, pre-commit checklist, the comment-at-the-code rule | Short by design; it delegates the "how" to ARCHITECTURE. |
| `LICENSES/` | Vendored license texts (currently `lucide.txt` for the Lucide icon SVGs) | Add one when vendoring third-party assets. |
| `Info.plist` | `CFBundleShortVersionString` + `CFBundleVersion` — the version of record | Must match the CHANGELOG section header at release (see `misc/before-you-release.md` §3). |

Note: `misc/backlog.md` and `docs/ROADMAP.md` currently duplicate the
v1.0.0/v1.x/v2.0.0 sections (backlog carries an extended copy). ROADMAP is the
public plan; backlog is the working list. When they disagree, treat ROADMAP as
the versioned commitment and backlog as scratch — and mention the drift to the
maintainer rather than silently reconciling.

## 2. Where does a new fact go — decision table

Route the fact FIRST, then write. One home; cross-reference from elsewhere.

| You learned / produced | Home | How |
| --- | --- | --- |
| Code quirk, edge case, workaround, non-obvious *why* | **Comment at the code site** | House rule (root `CLAUDE.md`): "Document non-obvious behavior... as a short comment at the code itself — not in commits or this file." |
| Architectural gotcha that will bite the next agent | `ARCHITECTURE.md` §8 | Bold lead-in bullet + one-line repro/symptom + pointer to any deeper write-up. Same PR as the code change. |
| New known issue / structural constraint | `ARCHITECTURE.md` §9 | It has an explicit placeholder: *"Add new ones here as you find them — with a one-line repro and a pointer to any deeper write-up in `docs/`."* |
| Code debt / incomplete implementation | `ARCHITECTURE.md` §10 | Its footer says: track code-debt here, roadmap items in README/ROADMAP. |
| Changed invariant, new subsystem, new pipeline step | `ARCHITECTURE.md` §2–§7 (the relevant section) | Update in the same PR — header rule. |
| Multi-round investigation (2+ hypothesis cycles, live repro work) | New `docs/<topic>-investigation.md` | Use the §5 template. ALSO add a one-bullet §8 gotcha summarizing the rule it produced, pointing at the doc. |
| User-visible change (fix/feature/rename) | `CHANGELOG.md` under the next `## [x.y.z]` | Format in §4. Link the issue and any investigation doc. |
| New bug found (reproducible) | `misc/backlog.md` under `Bugs` | `- [ ] Bug: <symptom>. See <repro pointer>.` Drop repro assets (video/log) into `misc/bug-repros/`. |
| New bug found (unreproducible so far) | `misc/backlog.md` → `### Lurking (Unreproduceable)` | One line + "wait for screen record" style note. |
| Bug that is really code debt (design limitation) | `ARCHITECTURE.md` §9 | e.g. the image-on-wrapping-fragment constraint. |
| Feature idea, near-term (next few small releases) | `misc/backlog.md` (`Now`/`Next`/`Later`) | Sorted by priority + difficulty within category. |
| Feature idea, versioned/strategic | `docs/ROADMAP.md` under the right version | Refresh `Last updated`. |
| Repro method / debugging technique | `docs/dev-guides/live-repro-guide.md` | Method docs, not per-bug chronicles. |
| Release procedure change | `misc/how-to-release.md` / `misc/before-you-release.md` + `ARCHITECTURE.md` §13 | §13 owns the mechanism + failure modes; misc/ owns the operator checklist. |
| Agent workflow improvement | `ARCHITECTURE.md` §12 | Its footer invites this: "If you (the agent) improve this workflow... update this section." |
| Vendored third-party asset | `LICENSES/<name>.txt` + a feature-map note in §6 | Follow the Lucide precedent. |

**The same-PR rule is the load-bearing one.** Doc updates that ride the code
PR actually happen (see `cf10741`, `b600e12`, `c4a602b` in history); doc
updates deferred to "later" don't.

## 3. House style

Derived from reading `ARCHITECTURE.md` and the investigation docs. Match it.

- **Dense, specific, evidence-first.** State the mechanism and the proof, not
  vibes. "Verified against that exact API" (§8 Sparkle bullet), timestamps
  and selection ranges quoted verbatim in investigation docs.
- **Bold lead-ins for gotcha bullets**, then the explanation:
  `- **Stale release builds**: ...`. Scannable list, detail inline.
- **Backticks for every file, symbol, flag, and command**:
  `` `recomposeDirty` ``, `` `+EditFlow` `` (the extension-file shorthand),
  `` `-debug.reproScript` ``.
- **One-line repro pointers**, not embedded essays: "See
  `misc/bug-repros/image-blank-after.mov`", "grep `~/.edmund/logs` for
  `repairing content above origin`".
- **Honest status labels.** The docs say "unconfirmed live", "theory +
  targeted repair, not a confirmed kill", "Verification limits (honest
  gaps)", "the test documents intent; the leap only reproduces under live
  layout". Never claim verification you didn't do. No oversell.
- **Section anchors as cross-refs**: "see §8", "ARCHITECTURE §13" — used
  across ARCHITECTURE, CLAUDE.md, before-you-release.md. If you renumber
  sections, grep the repo for `§` and fix every reference.
- **Address "you", the next agent/engineer**: "will bite you", "Context for
  anyone who sees the bug again", "Next time it happens: ...".
- **Record what failed, not just what worked** — investigation docs keep the
  overturned theories and the phantom fixes (stale-binary trap) because the
  dead ends are the reusable knowledge.

### Commit messages (from `git log --oneline -50`)

Mixed but patterned: conventional prefixes dominate for fixes and docs —
`fix(scope): ...` (scopes seen: `editor`, `layout`, `scroll`, `undo`,
`release-workflow`, `changelog-to-html`), `docs: ...`, occasional
`refactor:`, `appcast: add Edmund X.Y.Z`, `release X.Y.Z`. Chores and README
work often use plain imperative subjects ("Update README", "Add assets for
README"). Branches: `fix/<slug>`, `docs/<slug>`, `chore/<slug>`. When in
doubt: `fix(scope):` for behavior changes, `docs:` for doc-only commits,
plain imperative for chores. Never auto-push, PR, or merge — only when asked.

## 4. CHANGELOG format — machine-read, get it exact

`.github/workflows/release.yml` extracts release notes with:

```
awk "BEGIN{p=0} /^## \[${VERSION}\]/{p=1;next} p && /^## \[/{exit} p{print}"
```

So the section header MUST be `## [x.y.z]` at line start, version matching
`CFBundleShortVersionString` exactly; the section ends at the next `## [`.
`scripts/changelog-to-html.py` converts the same section to HTML for
Sparkle's update dialog (it folds wrapped bullet lines into their `<li>` —
wrapping bullets is safe). Full pipeline: `edmund-release-and-operate`.

House format (verify against the file; current entries follow this):

```markdown
## [0.1.4] — 2026-07-XX

### Fixed
- <User-facing symptom, past tense optional> ([docs](docs/<topic>-investigation.md)) [#NNN](https://github.com/I7T5/Edmund/issues/NNN)

---
```

- Em dash between version and ISO date; `---` separator between versions.
- Subsections used so far: `### Added`, `### Changed`, `### Fixed`
  (Keep a Changelog 1.1.0 vocabulary).
- Entries describe the user-visible effect, not the mechanism; mechanism
  lives in the linked investigation doc / ARCHITECTURE.
- An optional free-text line under the header is fine (0.1.2 has one) — the
  awk extraction includes it.

## 5. The investigation-doc template

Derived from `docs/investigations/delete-drift-investigation.md` (6 rounds) and
`docs/investigations/viewport-glitch-investigation.md`. Both open with why the doc exists
("Context for anyone who sees the bug again... records the trail end to
end") and name the fixing commits/branch up front. Chronicle structure: each
recurrence is a new `## Round N` appended to the same doc — symptom →
diagnosis → root cause → fix → verification, with limits stated.

Skeleton (copy-paste):

```markdown
# <Area> "<bug nickname>" — investigation notes

Context for anyone who sees this again. <One line on why it was hard:
intermittent / state-dependent / looked nothing like its cause.>

Fixed on branch `fix/<slug>`, commits: `<sha>` — <subject>, ...

## Symptom

<Exact user-visible behavior. Bulleted key properties, each a discriminating
fact ("caret-only, text fine"; "never right after launch"). Evidence
pointers: `misc/bug-repros/<file>`, `~/.edmund/logs/...`.>

## How it was diagnosed

1. <Numbered steps in the order they happened, including overturned
   theories and WHY each clue narrowed the space.>

## Root cause

<The mechanism, in bold where it matters. Explain why every symptom
property follows from it.>

## The fix

<What changed, in which file, and why that shape (defenses tried and
rejected count too).>

## Verification

<Tests added, live repro results, suite count. Then an honest limits
subsection: what was NOT reproduced/confirmed, and the breadcrumb to grep
for if it recurs.>

## If it ever recurs

<Ordered checks for the next investigator: which invariant/log/flag to
inspect first.>

## Round 2: <one-line summary>   ← append on recurrence, same structure
```

After writing one: add the one-bullet gotcha to ARCHITECTURE §8 with a
pointer, add the CHANGELOG entry with a `([docs](docs/...))` link, and check
the corresponding `misc/backlog.md` box (or move it under `On-going bugs`).

## 6. Maintenance duties

Do these whenever you touch the relevant doc; they rot otherwise.

- **ARCHITECTURE placeholders**: §9 and §10 end with italic *"Add new ones
  here"* / *"track code-debt here"* lines — keep them last in their lists so
  the invitation stays visible.
- **ROADMAP `Last updated:`** — bump the date on any edit.
- **Backlog hygiene**: check `- [x]` boxes when a fix ships (move to
  `## Done` only if following the existing pattern — completed items live
  there); keep repro pointers valid; don't reorder the maintainer's priority
  sorting.
- **README's inline HTML comments** are the maintainer's own edit notes
  (e.g. `<!-- Replace "minimal" with ... -->`) — leave them unless acting on
  them.
- **At release**: CHANGELOG section header ↔ `Info.plist` version ↔ appcast
  `<item>` must agree; the checklist is `misc/before-you-release.md`, the
  mechanics `edmund-release-and-operate`.
- **Section renumbering** in ARCHITECTURE: grep the whole repo (docs, misc,
  CLAUDE.md, skills) for `§` references before and after.
- **Never edit `test-files/todo.md`** — the maintainer owns it.

## Provenance and maintenance

Written 2026-07-05 against `main` at `fe8a1f5` (release 0.1.3). Sources, all
read directly: `docs/ARCHITECTURE.md` (header, §8–§13),
`README.md`, `CHANGELOG.md`, `docs/ROADMAP.md`, `misc/backlog.md`,
`docs/investigations/delete-drift-investigation.md`, `docs/investigations/viewport-glitch-investigation.md`,
`docs/dev-guides/live-repro-guide.md` (§1), `misc/before-you-release.md`,
`misc/how-to-release.md`, root `CLAUDE.md`,
`.github/workflows/release.yml` (awk extraction quoted verbatim),
`git log --oneline -50` (commit-style tally), directory listings of
`docs/` (`architecture/`, `investigations/` incl. `archives/`, `dev-guides/`),
`misc/`, `misc/bug-repros/`, `LICENSES/`.

§1 map re-verified 2026-07-09 against the `docs/` reorg (investigation docs
split into `docs/investigations/` + `docs/investigations/archives/`;
`docs/live-repro-guide.md` moved to `docs/dev-guides/`).

Maintain this skill when: a doc of record moves or splits (update the §1
map), ARCHITECTURE sections are renumbered (fix every § reference here),
the CHANGELOG extraction in `release.yml` changes (§4 quotes it), or a new
investigation doc establishes a better template. Keep the one-home-per-fact
rule itself stable — it is the point of the skill.

---
name: edmund-external-positioning
description: >
  Load when writing anything an outsider will read about Edmund — README edits,
  blog posts, release notes, marketing copy, social posts, webpage text, Show HN
  drafts — or when comparing Edmund to other editors (Typora, Obsidian, MarkEdit,
  Nodes), deciding what may be publicly claimed vs. what is still unproven,
  labeling a technique "novel", or planning ecosystem work (licenses,
  attribution, notarization messaging, appcast, issue templates, discovery
  listings). This skill is the overclaim firewall: what the positioning is,
  what evidence backs each claim, and what must exist before a claim gets
  stronger.
---

# Edmund external positioning — what we claim, what we can prove

Governing rule: **nothing may be claimed publicly that an outsider cannot
reproduce from the repo + a release.** Unproven = "candidate", never "novel"
or "first". This skill exists to prevent overselling a beta.

## When NOT to use this skill

| You are doing | Use instead |
| --- | --- |
| Actually cutting a release (tags, appcast, Sparkle, CI) | edmund-release-and-operate |
| Internal docs, ARCHITECTURE.md, investigation chronicles | edmund-docs-and-writing |
| Understanding the invariants / render pipeline itself | edmund-architecture-contract |
| Deciding whether a code change is allowed | edmund-change-control |
| Reproducing or debugging a bug | edmund-debugging-playbook, edmund-live-repro-and-diagnostics |
| Judging research novelty for internal direction (not public claims) | edmund-research-frontier, edmund-research-methodology |
| Verifying behavior before shipping | edmund-validation-and-qa |

## 1. The positioning (quote it exactly)

Source of truth: `README.md`. As of 2026-07-05:

- One-liner: **"Edmund is a minimal, file-based, native Markdown editor for
  macOS with inline live preview."**
  - README carries its own TODO comment on this line: *"Replace 'minimal' with
    'customizable' or 'lightweight' once more features are implemented"* — do
    not do that replacement early; "minimal" is the honest word today.
- Goal statement: **"Our goal is to be the [CotEditor](https://coteditor.com)
  of Markdown editors, i.e. elegant, powerful, configurable, and native inside
  out."**
- Beta warning: **"⚠️ Edmund is currently in beta."** — this must stay visible
  in the README and any landing page until v1.0.0 ships.
- Maintainer's blog post: <https://i7t5.com/posts/2026-06-26-edmund/> ("more of
  the motivation and design philosophy"). Cite it; do not paraphrase or invent
  its content without fetching it.
- Ambition framing: **product-first**. "Beyond state of the art" means product
  excellence — the TextKit 2 techniques are means, not ends. Never lead public
  copy with internal mechanism names; lead with what the user gets.

### The six claimed differentiators (README, verbatim, 2026-07-05)

| # | Claim (verbatim) |
| --- | --- |
| 1 | "Live preview: Typora/Obsidian-style WYSIWYG." |
| 2 | "File-based: Open `.md` files from anywhere. No vaults or dedicated folders required." |
| 3 | "Native: 100% Swift. Based on AppKit and TextKit 2. No Electron. Minimal dependencies." |
| 4 | "Fast: Handles ~1-2MB files with ease. No launch lag." |
| 5 | "Extensible: Opt-in math and Obsidian syntax. Extensions system coming soon!" |
| 6 | "Private: Offline by default. Optional blocking of external links and HTML sanitization." |

README also has a TODO comment after the list: *"Move 'Fast' and 'Extensible'?
Add 'integrations' section to Native after implementation"* — the list is
known-provisional; keep quotes synced to the file when you edit copy.

## 2. Claims discipline

Before strengthening any claim publicly, the evidence in the middle column
must be upgraded to the right column. Status as of 2026-07-05.

| Claim | Current evidence | Required before strengthening |
| --- | --- | --- |
| Fast: "~1-2MB files with ease. No launch lag" | `Tests/EdmundTests/PerfHarnessTests.swift` (gated `MD_PERF=1`, default 1.5MB doc, prints latencies; assertions are deliberately "sanity bounds, not budgets"); viewport-first lazy styling with `fullLayoutMaxLength = 100_000` regime (`EditorTextView.swift:80`) | A reproducible public benchmark: pinned document + hardware noted + numbers an outsider can rerun (`MD_PERF=1 swift test`). No comparative "faster than X" claims without benchmarking X the same way. |
| Extensible: "Extensions system coming soon!" | Extensions API is `docs/ROADMAP.md` v1.0.0 — **not shipped**. Only opt-in math + Obsidian syntax exist today. README already hedges with "coming soon" | Keep it hedged until the API + docs + at least one working extension ship. Never write "extensible via plugins" in present tense. |
| Private: "Offline by default" | Grounded: Read webview disables JavaScript; all assets inlined as data URIs (math, icons, local images); remote images off by default (`ReadRenderOptions.allowRemoteImages = false`); inline HTML whitelisted via `HTMLRenderer.sanitizeInlineHTML` | Note: the "Block external images" Settings checkbox is a `misc/backlog.md` item, **not shipped**; "optional blocking of external links" in README is forward-leaning — verify against code before repeating it elsewhere. Exceptions to name if asked: Sparkle update check, opt-in crash-log upload (§7 ARCHITECTURE). |
| Native: "100% Swift … No Electron. Minimal dependencies" | True: SwiftPM, three deps (swift-markdown, SwiftMath, Sparkle) + vendored Lucide SVGs. Read mode is a WKWebView (system WebKit, JS off) — that is not Electron, but don't say "no web views" | Nothing; this claim is safe. Just never inflate to "zero dependencies". |
| Live preview: "Typora/Obsidian-style" | Shipped and demoed (README video, screenshots) | Safe. Comparative feature-parity claims vs. Typora/Obsidian need a feature-by-feature check first. |
| File-based: "No vaults" | Shipped by design | Safe. |
| Beta status | v0.1.3 (2026-07-04) | Must stay visible everywhere until v1.0.0. |

## 3. Novel vs. known — the honest inventory

When writing a craft blog post or comparison, keep this ledger straight.
"Candidate" means blog-worthy pending proof; it is not "proven novel".

### Known / prior art (never claim novelty here)

- Live-preview Markdown editing: Typora, Obsidian, MarkText, Nodes. MarkEdit is
  the stated reference for source mode (ROADMAP v2.0.0 "the MarkEdit experience").
- TextKit 2 viewport virtualization for Markdown:
  [nodes-app/swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine)
  (Apache 2.0, macOS 14+) solves the same problems — viewport virtualization,
  live styling, wiki links, reading column, LaTeX. Per ARCHITECTURE §14:
  consult it **before inventing a new mechanism** and as a technique source
  (drag-select autoscroll, overscroll). Its existence caps any "first TK2
  live-preview engine" claim at zero.
- The README's own Alternatives section credits ~15 editors. Public copy that
  ignores them reads as either ignorant or dishonest.

### Distinctive candidates (label as such; each needs proof before publishing)

| Candidate | Why it might be blog-worthy | Proof needed first |
| --- | --- | --- |
| Attribute-only rendering with the storage == rawSource invariant (no attachment characters, no U+FFFC; delimiters hidden, never stripped; identity offset mapping) | A clean architectural answer to the classic WYSIWYG mapping problem | A survey showing how the named alternatives (incl. swift-markdown-engine) handle storage vs. display; the invariant's consequences demonstrated with runnable examples |
| Stroked-`CGPath` overlay workaround for the TK2 image wedge (image in a fragment overlay collapses the fragment's layout to one line; callout icon drawn as stroked path from vendored Lucide SVG instead) | A concrete, reproducible TK2 bug + workaround — the classic useful engineering post | A minimal frozen repro of the wedge outside Edmund; macOS version range where it reproduces |
| Bypassed-`didChangeText` heal + caret re-assertion (round-6 mechanism: TK2 leaves a `_fixSelectionAfterChange` queued after a bypassed edit; next-run-loop sync check heals storage and re-asserts the caret) | Deep TK2 internals nobody has documented; the delete-drift chronicle (`docs/delete-drift-investigation.md`) already exists as raw material | The frozen ReproScript repro kept green; behavior confirmed on current macOS before publishing (private-method behavior can change under us) |
| Diff-based undo restore that preserves TK2 layout (snapshot restore *diffs* rather than replaces, bypassing NSTextView undo) | Practical fix for a visible TK2 pain (undo viewport yank) | Before/after measurements (layout work saved, viewport stability) on a pinned document |
| In-process ReproScript methodology (`-debug.reproScript`, keystroke replay without CGEvents/TCC; `docs/live-repro-guide.md`) | Reusable testing methodology for any AppKit text app | Show it reproducing a real bug end-to-end in a fresh checkout; that IS the reproducibility standard |

Reproducibility standard for any technical post: a reader with the repo and
the post must be able to reproduce every claim — frozen repro scripts, pinned
document fixtures, named macOS versions, measured numbers with the command
that produced them. If a claim can't meet that, cut it or mark it anecdotal.

## 4. Ecosystem and license hygiene

Verified against the repo, 2026-07-05:

- **License: Apache 2.0** (`LICENSE`, README "License" section, and the 0.1.0
  changelog entry all agree). Say "Apache 2.0", never "MIT".
- **Lucide icons: vendored, ISC** (`LICENSES/lucide.txt`, © 2026 Lucide Icons
  and Contributors; parts derived from Feather). Attribution duty: keep
  `LICENSES/lucide.txt` shipping and credit Lucide where icons are discussed.
- **Why Lucide in both modes (SF Symbols constraint):** ARCHITECTURE §6 —
  SF Symbols **cannot ship in exported PDFs** (license), so callout headers use
  Lucide in both Read (inline SVG, `currentColor`-tinted) and Edit (rasterized
  tinted `NSImage` overlay). App-chrome SF Symbols (toolbar/settings) are fine;
  Edit-mode task checkboxes still use SF Symbols on-screen only. Don't
  "simplify" copy or code in a way that breaks this split.
- **Dependencies to credit:** swift-markdown, SwiftMath, Sparkle (README
  "Dependencies"). Acknowledgements section additionally credits
  swift-markdown-engine/Nodes, Typora, theme sources, create-dmg, MarkEdit,
  and others — preserve it when restructuring the README.
- **Not notarized (2026-07-05):** ad-hoc signed; users hit Gatekeeper
  ("damaged app"). README's WARNING block gives the two workarounds
  (System Settings → Privacy & Security → Open Anyway; or
  `xattr -dr com.apple.quarantine /Applications/Edmund.app`, maybe `sudo`).
  Keep those instructions accurate in every venue that mentions installing.
  `misc/marketing/MARKETING.md` gates Show HN on fixing this (notarize, or
  make the workaround idiot-proof).
- **GitHub issue templates exist:** `.github/ISSUE_TEMPLATE/bug_report.md`,
  `feature_request.md`. Point users there, not at email.
- **`appcast.xml` is a public artifact** served raw from the repo (`SUFeedURL`
  points at the raw GitHub URL). Anything committed to it is user-visible in
  Sparkle's update dialog. Pipeline details: edmund-release-and-operate.

## 5. Release-notes and public-writing style

- **Pipeline:** `CHANGELOG.md` sections become both the GitHub release notes
  (awk-extracted) and Sparkle's update-dialog HTML
  (`scripts/changelog-to-html.py` → appcast `<description>`). A CHANGELOG
  entry IS public copy — write it that way. Mechanics: edmund-release-and-operate.
- **Actual house style** (read `CHANGELOG.md` 0.1.0–0.1.3 before writing):
  Keep-a-Changelog headers (`### Added / Changed / Fixed`); one line per item,
  sentence case, no trailing period enforced; links to issues (`[#156]`) and
  investigation docs (`([docs](docs/delete-drift-investigation.md))`);
  user-visible phrasing ("Redo now jumps to where changed text was instead of
  caret") not internal jargon; occasional first-person maintainer notes with
  personality ("trying to have Fable 5 fix all the big bugs while I still have
  it with me"); 0.1.0 used bold **Feature** — one-line descriptions. Match this
  voice: plain, specific, lightly informal, zero hype.
- **Screenshots/videos:** README embeds live in `docs/assets/`
  (`v0.1.0_*.png`, `installation.png`, `v0.1.0_video.mp4`, `AppIcon/`).
  Raw/source marketing assets live in `misc/marketing/`: `MARKETING.md`
  (the plan), `reddit-post.md`, `demo-slide-v0.1.key`, `demo-src-files/`,
  demo videos (`demo.mov`, `demo-video-v0.1-brown.mp4`), `_raw` screenshot
  masters, `social-preview_figma.png`. New public screenshots: polished copy
  → `docs/assets/`, raw master → `misc/marketing/`, versioned filenames.

## 6. Marketing priority context (2026-07-05)

From `misc/backlog.md` "Now": **"Priority: Marketing = Bugs >= UI/UX >
Features"** — marketing work is tied for top priority with bug fixes.
Open marketing items: screenshots/files and a webpage (reference:
kruszoneq.github.io/macUSB). Backlog embeds a star-history.com chart;
`misc/marketing/MARKETING.md` names GitHub stars (~69 at writing) as the goal
and metric, audience "developers who value craft", and holds Show HN in
reserve until first-run friction and a landing page are fixed. Its "craft
months" deep-dives are exactly the Section 3 candidates — which is why the
proof bar there matters.

## Provenance and maintenance

- Sources verified 2026-07-05 against: `README.md`, `docs/ROADMAP.md`
  (last updated 2026-07-03), `misc/backlog.md`, `docs/ARCHITECTURE.md`
  (§2, §6, §8, §13, §14), `CHANGELOG.md` (0.1.0–0.1.3), `LICENSE`,
  `LICENSES/lucide.txt`, `.github/ISSUE_TEMPLATE/`, `misc/marketing/`,
  `Tests/EdmundTests/PerfHarnessTests.swift`,
  `Sources/EdmundCore/Export/{ReadRenderOptions,HTMLRenderer,DocumentHTML}.swift`,
  `Sources/EdmundCore/TextView/EditorTextView.swift`.
- Volatile facts are date-stamped inline: version (0.1.3), beta status,
  notarization status, shipped-vs-roadmap feature split, star count, README
  wording. Re-verify each against the file before repeating it publicly.
- When README differentiators or the one-liner change, update the verbatim
  quotes in §1 and re-run the §2 evidence check.
- If a §3 candidate ships as a published post, move it out of "candidate" and
  link the post + its frozen repro.
- Cross-references: edmund-release-and-operate (release/appcast mechanics),
  edmund-docs-and-writing (internal doc style), edmund-research-frontier
  (novelty judgment for research direction), edmund-architecture-contract
  (the invariants quoted here).

---
description: Set the version, bump the build number, and check the changelog before a release (runs scripts/prepare-release.sh)
argument-hint: <version> e.g. 0.3.1 — add "check" for a dry run
allowed-tools: Bash(scripts/prepare-release.sh:*), Bash(swift test:*), Bash(git status:*), Bash(git diff:*)
---

Prepare a release of the version given in **$ARGUMENTS**. The logic lives
entirely in the script — do not reimplement any of it, and do not edit
`Info.plist` by hand.

```
scripts/prepare-release.sh $ARGUMENTS
```

The script sets `CFBundleShortVersionString` to the version, raises
`CFBundleVersion` by one (Sparkle orders updates by it, so it has to climb),
and refuses to run when the version is a downgrade, is already current, or
already has a `v<version>` tag.

It also checks `docs/CHANGELOG.md` for that version's section and **stops if it
is missing** — `release.sh` takes the GitHub release body and the Sparkle update
note from that section, so bumping without it would ship a release with no
notes. Report the script's output verbatim, then:

- **Changelog section present** ⇒ run `swift test`, show the version/build
  change, and hand back for the commit. Do not publish.
- **Changelog section missing** ⇒ write it with the maintainer, never for
  them. Users read that section verbatim (GitHub release body, Sparkle's update
  dialog), so it stays in the maintainer's words:
  1. **Ask for their wording.** Ask for the notes for this version, or where
     they are (a scratch file, a message). Don't draft notes of your own
     unasked.
  2. **Check it against what shipped:** every merged PR and direct commit since
     the last `v*` tag. Internal work (CI, agents, release tooling) needs no
     entry.
  3. **Ask before changing anything, and say why.** For each change you'd make
     — a user-facing change that's missing, a wrong PR number or handle, a
     slip from the Keep a Changelog format — ask one question naming the change
     and the reason. Everything else goes in exactly as written; a typo stays
     unless they approve the fix.
  4. **Write only what they approved** into `docs/CHANGELOG.md` with the Edit
     tool, above the previous release's section. The changelog guard hook
     allows the edit only while the maintainer's latest message is this
     `/release` invocation, and makes it ask them to confirm the diff; shell
     writes to the file are always blocked. A message from them mid-run
     re-locks it — ask them to run `/release` again.
  5. **Re-run the script** and carry on as for "section present".

Publishing is a separate, deliberate step: `./scripts/release.sh` builds, signs
with the Sparkle key, updates `appcast.xml`, and creates the GitHub Release.
Never run it without being asked to.

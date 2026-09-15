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
- **Changelog section missing** ⇒ stop. Put the proposed notes in
  `misc/changelog-tmp` (untracked scratch) and ask the maintainer to move them
  into `docs/CHANGELOG.md`. Never write `docs/CHANGELOG.md` yourself — a hook
  blocks it, and that file is the maintainer's voice.

Publishing is a separate, deliberate step: `./scripts/release.sh` builds, signs
with the Sparkle key, updates `appcast.xml`, and creates the GitHub Release.
Never run it without being asked to.

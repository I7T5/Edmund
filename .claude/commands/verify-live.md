---
description: Before/after live check of the current change — the same scenario runs in a debug build of main and of this branch, with evidence saved to misc/verify/<branch>/
argument-hint: [edit-pipeline|drawing|chrome] [what to verify]
allowed-tools: Bash, Read, Write, Edit, Agent
---

Verify the current change in the running app, on `main` and on this branch,
so the maintainer can read evidence instead of re-testing. Arguments:
**$ARGUMENTS**

You (the session that made the change) write the scenario, because you know
what the change should do. The `live-verifier` subagent builds, runs and
measures, which keeps build and launch noise out of this session.

1. **Class and claim.** Take the class from the arguments, or from `/ship`
   step 2c. Write down in one or two sentences what the change should make
   observably different, as a claim that could turn out false: "on `main`,
   Backspace after the table leaves the caret at 321; on the branch, at
   290". A new feature's claim can say "absent on `main`", but it still
   needs an observable check on the branch.

2. **Evidence directory.** `EV=misc/verify/<branch>/` under the repo root,
   where `<branch>` is the current branch, or the topic branch `/ship` is
   about to create. `misc/` is gitignored; nothing here is committed. Write
   `$EV/expect.md` holding the class, the claim, and for each scenario the
   expected result on `main` and on the branch.

3. **Scenarios** in `$EV/scenarios/`, in the format of `Tests/Repro/*.repro`
   (header of `scripts/repro.sh`; command reference in the header of
   `Sources/edmd/App/ReproScript.swift`). Put fixture documents in
   `$EV/scenarios/fixtures/`. Every scenario ends with `done`. Address text by
   needle, not offset.
   - **edit-pipeline**: keystrokes through `type`, `backspace`, `enter`,
     `tab`, `ime`, `undo`…, then assertions: `assertcaret`,
     `assertsource`, `assertsel`, and always `assertinvariants`. For a bug
     fix, the assertions must FAIL on `main`. Mouse drags and real IME
     candidate windows are out of reach: list them under "not verified".
   - **drawing**: `snapshot @OUT@/<name>-light.png` after the state is set
     up (`repro.sh` replaces `@OUT@` with the run's `REPRO_OUT`, one per
     tree). Add a second scenario with
     `# args: -settings.appearance.mode dark` that writes `-dark.png`. Use
     `hoveroff`, `selectoff`, `scroll` or `viewmode` to reach the state. Read
     mode does not paint in `snapshot`; see
     `edmund-live-repro-and-diagnostics` for the `screencapture -l` route.
   - **chrome**: Settings panes through
     `edmd -debug.render pane:<Label> -debug.renderOut <png>` (see
     `Sources/edmd/App/SettingsRender.swift`); toolbar and format bar
     through the `logtoolbar`, `clicktoolbar` and `clickrow` commands; menu
     bar and context menus through
     `.claude/skills/edmund-live-repro-and-diagnostics/scripts/axfind.swift`.
     Describe these steps in `$EV/expect.md`, since they are not `.repro`
     files.

4. **Spawn `live-verifier`** with: the absolute `$EV` path, the class, the
   branch, and optionally a base ref. By default it uses the fork point from
   `origin/main`, never local `main`, which can be stale. Wait for its report.

5. **Report** to the maintainer, and hand the same text to `/ship` for the PR
   body's Testing section when `/ship` called this:
   - one line per scenario: `<name>: main <PASS|FAIL|png> → branch <…>`,
     and whether that matches `expect.md`;
   - measured differences for drawings (pixels, from the agent);
   - the evidence path `$EV`;
   - **Not verified — test by hand:** a list of what the scenarios could not
     reach.
   If any result contradicts the claim, say so first and plainly. The change
   is not verified.

6. **Promote.** For an edit-pipeline fix whose scenario went FAIL → PASS, ask
   whether to copy it (and its fixture) into `Tests/Repro/` as a permanent
   regression scenario in this change. Drawing scenarios write to `@OUT@`,
   which the plain suite does not set, so don't promote them.

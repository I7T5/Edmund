# Changelog

All notable changes will be documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Edmund now runs in the macOS App Sandbox. User themes, syntax definitions and the math engine move into the app's container automatically on first launch; preferences carry over. Diagnostic logs move from `~/.edmund/logs` into Application Support (Settings ▸ Advanced ▸ Show in Finder) — old logs are not carried over

### Added
- File ▸ Grant Access to Folder… lets the sandboxed app read images and wiki-linked notes beside a document; a blocked image says so and ⌘-click on it opens the same panel. One grant covers every document in that folder, across launches

## [0.7.0] - 2026-09-15

Editor, code syntax, and better organized font theme. More table editing fixes. Various refinements. 

### Added
- Settings > Appearance > Font theme
- Settings > Themes (#292)
- Tables: Divider between add and delete operations in row/column menu
- App Menu > Format > Headings > Increment/Decrement heading level
- Editor: Quick-wrap selection with `~$%*=` and the backtick
- Editor: Detect and remove list markers `-/- [ ]/1.` from pasteboard content if pasting into list
- Editor: Copy button for code blocks
- Reader: Click to toggle checkbox

### Changed
- Tables: Delete on cell selection clears cell content; Delete on empty complete row or column removes it
- Tables: Return on a header's separator row auto-fills in and prettifies the table
- Tables: Disabled delete pipes between cells in formatted state
- Tables: Controls (`</>` button, pills) scale with zoom `CMD+=/-/0`
- Tables: `</>` button makes way only when pills are actually in the way
- Settings > Autopair parentheses and quotes doesn't pair backticks anymore

### Fixed
- Nested emphasis (italic inside bold, or bold inside italic)
- Tables: a single-dash delimiter row (`- | -`) now renders as a table
- Tables: Selection, caret movement, row/column pills, and zoom behavior with wrapped cells and/or header row containing wrapped cells
- Tables: `</>` button makes way for row pills with "Show line numbers" off
- Reader: Nested checkboxes aren't dimmed or strikethrough when checked
- Settings > Key Bindings: "Format" app menu is in order with the rest
- Print > PDF no longer keep the `.md` extension in filename

## [0.6.1] - 2026-09-12

Various table editing fixes.

### Fixed
- Tables: Content of wrapped cells don't fully display
- Tables: Caret jumps to start of cell and jumps back if you click at the end

### Changed
- Tables: Automatically insert pipes when pasting incomplete tables
- Tables: Users cannot merge columns by deleting pipes
- Tables: Users cannot remove the padding space before and after pipes


## [0.6.0] - 2026-09-10

### Added
- Table editing within cells, row/column actions, copy as spreadsheet date
- Image drag and drop

### Changed
- Deleting opening parentheses/quotes automatically removes corresponding closing character if they are adjacent when pairing setting is on
- Automatically detect required indent instead of relying on settings tab size when tabbing on nested lists

### Fixed
- Indent list selection sometimes indents the non-selected
- PDFs end in `.pdf` instead of `.md.pdf`


## [0.5.0] - 2026-08-22

Thanks to @arthurlee116 for their first contribution (#268)

### Added
- Settings > Appearance > Font per script (#268 @arthurlee116)

## [0.4.3] - 2026-08-17

Thanks to @aahventures for their first contribution (#269)

### Added
- ⌘W to close window and ⌥⌘W to close all windows (#269 @aahventures)

### Fixed
- Typewriter scroll not centering while typing on the last line of the document (#277)
- Launching app after closing every window with autoquit off no longer creates two blank documents (#278)

## [0.4.2] - 2026-08-11

Thanks to @jdobbs for their first contribution (#266)

### Added
- Format bar in Apple Mail style
- Toolbar items from Apple Notes: format, table, images, links, share
- Overscroll: Allow overscroll up to half the viewport height at the bottom of the window by default. Top and bottom with typewriter scroll on

### Changed
- Moved typewriter scroll and focus mode from View to Edit menu

### Fixed
- RaTeX path rendering (#265)
- QuickLook infinite load for macOS 26 (#266 @jdobbs)
- Open two Untitled windows instead of one at launch without restore window

## [0.4.1] - 2026-08-01

### Fixed
- Min window width was too wide (temp fix)

## [0.4.0] - 2026-08-01

Fixed table misalignment (#251). Added Settings > Extensions and Advanced Math extension. Various UI improvements. 

### Added
- Settings > General > Manage Version History...
- Settings > Extensions
- Advanced Math extension via [RaTeX](https://ratex.lites.dev)

### Changed
- Read mode styling now better aligns with edit mode (header size, line height, callout color and padding)
- Removed document change settings from Settings > General to follow AppKit conventions
- Removed redundant configs from Settings > Edit and reworded some settings

### Fixed
- Table misalignment #251
- Table text alignment in edit mode
- Auto-hide toolbar now works
- Open Recent now populates
- Edmund now actually creates backups when auto-save is off
- Finder services


## [0.3.0] - 2026-07-27

Settings stuff. 

Thanks to @CaliLuke for his first contribution (#236) and for being the first community contributor :D

### Added
- Improved performance (#236 @CaliLuke)
- **(Almost) Full Obsidian-flavored Markdown support**: YAML front matter, `[image|dimension()` (implicit), `^block`, `#tag`, collapsible callout
- **Find and replace** in Apple Notes fashion
- **Settings > Edit**: Hide toolbar, focus mode, detect indentation, show invisible characters, show line numbers, hard-wrap long lines
- **Settings > Syntax**: Toggle Markdown syntax support, add code block syntax
- **Settings > Key Bindings**
- Edit > Find, Spelling & Grammar, Transformations, Speech menus
- Finder services
- `Option+Cmd+I` to open inspector

### Changed
- Misc UI improvements: Numbered lists marker in read mode, thicker thematic break, removed bottom border from edit mode tables, removed inline code color from read mode
- Dark mode readability: Empty checkbox in edit mode, blockquote bars in read mode, table borders in edit mode
- Code block syntax highlighting is now controlled by syntax-based JSON instead of general regex
- Inline math block renders as block in read mode
- Format > Comments now wraps selection in `<!-- selection -->`

### Fixed
- Headers don't render spaces after `#...`
- Indented code block renders as monospace
- Replaced right-click "Font" menu in edit mode with our custom Format > Font menu


## [0.2.1] - 2026-07-17

### Added
- Window menu
- Code block copy button in read mode

### Changed
- Code blocks are now styled by default, similar to blockquotes / callouts
- Math blocks inline are now rendered as a block, instead of inline in `\displaystyle`
- Switching between edit and read mode now preserves viewport
- Lighter background color in dark mode to reduce contrast

### Fixed
- `$$...$$` was not rendering verbatim
- External images glitching and freezing the app
- Switching from read to edit mode waits for edit mode to fully load


## [0.2.0] - 2026-07-13

Full GFM support per the [specs](https://github.github.com/gfm/). Existing implementations better respect GFM specs where applicable. Automatic renumbering of numbered lists. Various editor UX improvements. 

### Added
- GFM elements
  - Setext headings (`Title` underlined by `===`/`---`) render in edit mode
  - Autolinks: bare `www.…`, `http(s)://…`, and email addresses become real links in both modes
  - Indented code blocks
  - HTML elements except for ones [officially disallowed](https://github.github.com/gfm/#disallowed-raw-html-extension-)
  - Reference links
  - Block quote lazy continuation
- Nested styling
  - Headings support all inline styling (not just math)
  - Nested block quote in edit mode
  - Tables support inline styling in edit mode
- Automatic renumbering for numbered list

### Changed
- A `---` line directly under a paragraph is now a setext h2 underline
- Heading delimiter always shows when user is typing on the heading line
- `==highlight==` now follows GFM-style flanking: content can't begin or end with whitespace (`== spaced ==` stays literal)
- Tables rows now have separators
- List continuation no longer adds extra `-` or `- [ ]` if user creates the corresponding list right before the corresponding delimiter. E.g., `- hi |(Enter here)- bye` no longer creates extra `-`.

### Fixed
- Security issues found by GitHub code scanning
- Block quote bar too tall
- Tables
  - Delimiter row cell count differs from the header are not tables in edit mode (GFM Example 203)
  - Backslash-escaped pipes (`\|`) are cell content
  - Content overflow wraps out of cell in edit mode
- ATX heading closing sequence (`# foo ###`) hides
- Newline inserted at a display-math block boundary leaves a stray centered line

## [0.1.4] - 2026-07-09

Various small fixes and improvement and new round of grind at the [delete caret drift](https://github.com/I7T5/Edmund/issues/156). I think it actually worked this time, but don't quote me on it. 

### Added
- `CMD+=`, `CMD+-`, and `CMD+0` to zoom in/out/reset. Also in View menu
- External images rendering in editor
- Block external images setting in Settings > Advanced 

### Changed
- Rename "Source Mode" to "Show Source in Editor" in app and button menu. Removed icon from button menu. 
- Opening an existing file closes the last opened Untitled window with no edit history
- Move Automatic updates to Settings > General
- Apply Settings > Appearance > Max content width to read mode 

### Fixed
- Images have extra bottom padding when editor is not in full screen
- Images do not resize with max content width if the user changes the setting when the app is open
- Tables overflow handled by horizontal scroll
- Callouts have an extra line at the bottom when they are the last element of a file
- Footnotes rendering in edit mode and linking between inline marker and content in read mode
- Math environments `\begin{}...\end{}` padding offset in edit mode
- Math environments `\begin{}...\end{}` rendering in read mode
- Delete caret drift, round 7 ([docs](docs/delete-drift-investigation.md)) [#156](https://github.com/I7T5/Edmund/issues/156)

---

## [0.1.3] — 2026-07-04

### Fixed
- Delete caret drift *with reproduction* ([docs](docs/investigations/delete-drift-investigation.md)) [#156](https://github.com/I7T5/Edmund/issues/156)

---

## [0.1.2] — 2026-07-03

Polishing the editor and trying to have Fable 5 fix all the big bugs while I still have it with me. 

### Changed
- Redo now jumps to where changed text was instead of caret
- Removed old code for identity mapping, etc., using [ponytail](https://github.com/DietrichGebert/ponytail)-review

### Fixed
- Updater [#158](https://github.com/I7T5/Edmund/issues/158)
- Icon display for callouts with custom titles ([docs](docs/investigations/archives/callout-title-wrap-investigation.md))
- Undo/redo viewport glitches from TextKit 2 ([docs](docs/investigations/viewport-glitch-investigation.md))
- Delete caret drift ([docs](docs/investigations/delete-drift-investigation.md)) [#156](https://github.com/I7T5/Edmund/issues/156)

---

## [0.1.1] — 2026-06-29

### Added
- Thematic Break `---`/`***` in the Format menu
- Remember window size: new document windows reopen at the size of the last one.

### Changed
- Max content width is now an absolute physical width (cm / in) with a max-width cap and a cm/in unit toggle. 
- Typewriter Mode renamed to Typewriter Scroll

### Fixed
- Typewriter Scroll no longer jumps the viewport when you click to reposition the caret — it re-centers only while typing.

---

## [0.1.0] — 2026-06-27

First public release.

- **Live WYSIWYG preview** — Typora/Obsidian style
- **GFM support** — bold, italic, strikethrough, tables, task lists, fenced code with syntax highlighting, blockquotes, alerts
- **Extended syntax** — ==highlights==, [[WikiLinks]], `[^footnotes]`, Obsidian-flavored callouts and comments
- **Math** — inline (`$…$`) and display (`$$…$$`) rendering via SwiftMath
- **Native macOS UI** — AppKit editor, SwiftUI settings panel, full Dark Mode support
- **Keyboard-first** — configurable shortcuts, no required mouse interaction
- **Auto-update** — Sparkle 2.x with EdDSA-signed appcast; checks on launch
- **Open source** — Apache 2.0

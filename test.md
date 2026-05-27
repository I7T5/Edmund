# md

---
New stuff: Hope this saves!
---

Other names: 

## What to test for 

- Rendering
- Render upon enter
- `*`, `_`, `#`, `\``
- `***hi****`

-  `**hi*`, `_hi__`
- Undo/redo
- Open
- Save
- Light/dark mode


This should be *italicized*, and so is _this_. This is **bolded** and so is __this__. But this is even more ***important***. There's also several special cases like **here* and _here__. 

> Quote

1. `code`
2. ~~strikethrough~~
3. [link](http://example.com)


## TODOs

### Features

- [x] File save/open
  - [ ] NSDocuments integration
- [x] Syntax highlighting in the active block — polish, not blocking
- [ ] Typewriter scroll
- [ ] Highlight active block
- [ ] Title bar
  - [ ] Toggle between edit and reading mode
  - [ ] Togge between monospace and other
- [ ] Status bar: Character/word count
- [ ] Performance: Lazy loading for larger / more mathy files 

#### Markdown support

- [x] Highlight
- [x] Divider with `---`
- [ ] Code blocks
  - [ ] Syntax highlighting
- [ ] Multi-line quotes
- [ ] Callouts: GFM-flavored; use BlockDirectives in `swift-markdown`
  - [ ] Collapsible vs. not collapsible
  - [ ] Default to collapsible vs. not collapsible
- [ ] Footnotes
- [ ] Comments
- [ ] Math: KaTex integration

### Frontend

- [x] Richer markdown rendering (headers, code, links, lists)
- [x] title bar blending, window sizing, and dark mode 
- [x] Settings window for custom font
- [ ] Settings pane
  - [ ] Tabs: 
  - [ ] Make font selection a separate window (see CotEditor)
- [ ] Full rendering customization
  - [ ] Callouts: icon, color
  - [ ] Syntax highlighting for code block
  - [ ] Math: Font
- [ ] Full app customization
  - [ ] Fonts: (Built-in) script, serif, mono, sans
  - [ ] Background: Vintage paper, ruled, squares, dots
  - [ ] Background: Upload image
  - [ ] Theme: save customization as theme
- [ ] Themes
  - [ ] different themes for edit mode vs. reading mode
  - [ ] Built-in: iA, old letters, typewriter, serif, code, native
  - [ ] Custom theme (see full customization)
- [ ] Active block highlighting: wiggly (not fully straight) highlighter style by line
- [ ] Title bar: Add horizontal line to divide content and bar

### Bugs

- [ ] List indentation: ` -` has less indentation than `-` (which has rendered indentation). Render indentation for all `-` at the beginning of the line, even after whitespace. 

### Maybes

- [ ] Scroll by line (not continuous)





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


This should be *italicized*, and so is _this_. This is **bolded** and so is __this__. But this is even more ***important***. There's also several special cases like **here* and _here__ (we should have extra * and _). 

> Quote

1. `code`
2. ~~strikethrough~~
3. [link](http://example.com)
4. ==Highlight==

Nest lists
- Hello
  - World


## TODOs

### Features

- [x] File save/open
  - [ ] NSDocuments integration
- [x] Syntax highlighting in the active block — polish, not blocking
- [x] Typewriter scroll
- [ ] Highlight active block
- [ ] Title bar
  - [ ] Toggle between edit and reading mode
  - [ ] Togge between monospace and other
- [x] Status bar: Character/word count, line number, cursor position
- [ ] Performance: Lazy loading for larger / more mathy files 

#### Markdown support

Refer to the implementation of [Swift Markdown Engine](https://github.com/nodes-app/swift-markdown-engine). 

- [x] Highlight
- [x] Divider with `---`
- [x] Code blocks
  - [ ] Syntax highlighting
- [ ] Callouts: GFM-flavored; use BlockDirectives in `swift-markdown`
  - [ ] Collapsible vs. not collapsible
  - [ ] Default to collapsible vs. not collapsible
- [ ] Footnotes
- [ ] Comments
- [ ] Math: KaTex or some kind of swift math integration. 


### Frontend / UIUX

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
- [x] Title bar: Add horizontal line to divide content and bar
- [x] List: Automatic add list item upon new line in a list environment
- [x] List: Un-indent current line when upon new line on a empty line

### Bugs

- [x] List indentation: ` -` has less indentation than `-` (which has rendered indentation). Render indentation for all `-` at the beginning of the line, even after whitespace. 
- [x] Unmatched * and _ should not be hidden
- [x] Todo list indentation: Align beginning of list marker with first character in upper-level text


### Maybes

- [ ] Scroll by line (not continuous)





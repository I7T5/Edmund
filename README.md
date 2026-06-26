# Edmund

> [!IMPORTANT] 
> - Active development!
> - Help wanted with icon!
> - Guidelines for Build and Contributing coming soon!

Edmund is a native, lightweight markdown editor with Live Preview made for macOS.  

- **Requirements**: macOS Sonoma 14 or later
- **Website**: <https://i7t5.com/edmund> (to be developed)

## Features

- **Live Preview**: WYSIWYG. Render as you type. Hides delimiters outside active token / block. 
- **Lightweight and fast**: App size ~15 MB. Lazy rendering via TextKit 2. Minimal dependencies. 
- **Keyboard-first**: Essential buttons only. Configurable keyboard shortcuts (in progress). 
- **Simple yet powerful**: 
  - Follows [cmark-gfm](https://github.com/github/cmark-gfm) through Apple's own [swift-markdown](https://github.com/swiftlang/swift-markdown). 
  - Opt-in support for non-GFM syntax such as ==highlights==, [[WikiLinks]], footnotes `[^1]`, code blocks with syntax highlighting, Obsidian-flavored comments and callouts, etc.  
  - Renders both inline and display math  using [SwiftMath](https://github.com/mgriebling/SwiftMath). Opt-in extension for better math support through [RaTeX](https://github.com/erweixin/RaTeX) (in progress). 
- **Native UI/UX**: Feels exactly like macOS. AppKit editing + WebKit preview + SwiftUI settings. 
- **Secure and private**: Always offline. Network connection will always be optional. 
- **Open and free**: Apache License 2.0. Free of charge. 

## Roadmap

See [ROADMAP](docs/ROADMAP.md). 

## Dependencies

- [swift-markdown](https://github.com/swiftlang/swift-markdown)
- [SwiftMath](https://github.com/mgriebling/SwiftMath)
- [Sparkle](https://github.com/sparkle-project/Sparkle)

## Alternatives

If Edmund's not your thing, some of the following might be: 

- Closed source
  - Obsidian, cyberWriter, Notion
  - Typora, Lettera ([beta](https://lettera.md))
- Open source
  - WYSIWYG: [MarkText](https://marktext.me), [Nodes](https://nodes-web.com), [Scratch](https://github.com/erictli/scratch)
  - Split-screen: [MacDown](https://macdown.uranusjr.com), [MiaoYan](https://miaoyan.app)
  - [MarkEdit](https://github.com/MarkEdit-app/MarkEdit) - TextEdit for Markdown
    - I *love* this. If only I wasn't so dependent on rendered math...
  - [editxr](https://github.com/pixdeo/editxr) - TUI
  - More feature-rich: [Zettlr](https://www.zettlr.com), [Joplin](https://joplinapp.org), [Tangent](https://www.tangentnotes.com)

The list is by no means exhaustive, and neither was it meant to be. I just wanted to give credit to the makers of these apps, esp. the aesthetic open sourced ones. If you want a comprehensive list, see [here](https://github.com/mundimark/awesome-markdown-editors). 

## Motivation, philosophy, acknowledgements

I wanted to create an open source alternative to Typora that would be the [CotEditor](https://coteditor.com) of Markdown editors. <!— See this [blog post](link TBD) for more design philosophy and behind-the-scenes. —>

The following have greatly influenced my architecture and/or design choices. I owe them many thanks:  

- [Swift Markdown Engine](https://github.com/nodes-app/swift-markdown-engine) / [Nodes](https://nodes-web.com) for the parser/token architecture and the TextKit 2 integration
- [Typora](https://typora.io) and Apple Notes for app menu organization
- [Tomorrow Light](https://github.com/chriskempson/tomorrow-theme) and [One Dark](https://github.com/atom/atom/tree/master/packages/one-dark-syntax) for code syntax highlighting
- [create-dmg](https://github.com/sindresorhus/create-dmg) for a Apple-looking `.dmg`

## License

[Apache License 2.0](LICENSE)
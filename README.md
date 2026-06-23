# Edmund

> [!tip] Guidelines for Build and Contributing coming soon!

Edmund is a native, lightweight macOS markdown editor with Live Preview. 

- **Requirements**: macOS Sonoma 14 or later
- **Website**: <https://i7t5.com/edmund>

## Features

- **Live Preview**: WYSIWYG. Render as you type. Hides delimiters outside active token / block. 
- **Lightweight and fast**: App size ~5 MB. Lazy rendering via TextKit 2. Minimal dependencies. 
- **Keyboard-first**: Essential buttons only. Configurable keyboard shortcuts. 
- **Powerful and compatible**: 
  - Follows [cmark-gfm](https://github.com/github/cmark-gfm) through Apple's own [swift-markdown](https://github.com/swiftlang/swift-markdown). 
  - Opt-in support for non-GFM syntax such as ==highlights==, [[WikiLinks]], footnotes `[^1]`, code blocks with syntax highlighting, as well as Obsidian-flavored comments and callouts through. 
  - Renders both inline and display math in LaTex using [SwiftMath](https://github.com/mgriebling/SwiftMath). 
- **Native UI/UX**: Respects Apple design guidelines. AppKit + SwiftUI. 
- **Secure and private**: Always offline. Network connection required for software updates only. 
- **Open and free**: Apache License 2.0. Free of charge. 

## Roadmap

See [ROADMAP](ROADMAP.md). 

Current priorities: 

- Full [GFM spec](https://github.github.com/gfm/#fenced-code-blocks) support. Including but not limited to: 
  - Table alignment
  - ATX headings
- Render icons in custom-titled callouts / alerts
- Comprehensive math support through [RaTeX](https://github.com/erweixin/RaTeX) integration (extension)
- Native export to PDF with style
- Automatic updates via Sparkle
- Themes
- Onboarding
  - Log preference
  - Advanced Math
  - Pandoc path for more export options

## Dependencies

- [swift-markdown](https://github.com/swiftlang/swift-markdown)
- [SwiftMath](https://github.com/mgriebling/SwiftMath)

## Alternatives

If Edmund's not your thing, some of the following might be: 

- Closed source
  - Obsidian, cyberWriter, Notion
  - Typora, Lettera (currently in [beta](https://lettera.md))
- Open source
  - WYSIWYG: [MarkText](https://marktext.me), [Nodes](https://nodes-web.com), [Scratch](https://github.com/erictli/scratch)
  - Split-screen: [MacDown](https://macdown.uranusjr.com), [MiaoYan](https://miaoyan.app)
  - [MarkEdit](https://github.com/MarkEdit-app/MarkEdit) - TextEdit for Markdown
    - I *love* this. If only I wasn't so dependent on rendered math...
  - [editxr](https://github.com/pixdeo/editxr) - TUI
  - More feature-rich: [Zettlr](https://www.zettlr.com), [Joplin](https://joplinapp.org), [Tangent](https://www.tangentnotes.com)

The list is by no means exhaustive, and neither was it meant to be. I just wanted to give credit to the makers of these apps, esp. the aesthetic open sourced ones. If you want a comprehensive list, [this](https://github.com/mundimark/awesome-markdown-editors) might be more helpful. 

## Motivation, philosophy, credits

I wanted to create an open source alternative to Typora that would be the [CotEditor](https://coteditor.com) of Markdown editors. See this [blog post](link TBD) for more design philosophy and behind-the-scenes. 

The following have greatly influenced my architecture and/or design choices. I owe them many thanks:  

- [Swift Markdown Engine](https://github.com/nodes-app/swift-markdown-engine) / [Nodes](https://nodes-web.com) for the parser/token architecture and the TextKit 2 integration
- [Typora](https://typora.io) for menu bar item organization
- [Tomorrow Light](https://github.com/chriskempson/tomorrow-theme) and [One Dark](https://github.com/atom/atom/tree/master/packages/one-dark-syntax) for code syntax highlighting

## License

[Apache License 2.0](LICENSE)
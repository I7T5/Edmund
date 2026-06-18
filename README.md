# Edmund

> [!tip] Guidelines for Build and Contributing coming soon!

Edmund is a native, lightweight macOS markdown editor with Live Preview. 

- **Requirements**: macOS Sonoma 14 or later
- **Website**: [https://i7t5.com/edmund](https://i7t5.com/edmund)

## Features

- **Live Preview**: Render as you type. Hides delimiters outside active token / block. Pseudo-WYSIWYG. 
- **Lightweight and fast**: App size ~5 MB. Lazy rendering via TextKit 2. Minimal dependencies. 
- **Keyboard-first**: Essential buttons only. Configurable keyboard shortcuts. 
- **Powerful and compatible**: 
  - Follows [cmark-gfm](https://github.com/github/cmark-gfm) standards through Apple's official [swift-markdown](https://github.com/swiftlang/swift-markdown). 
  - Supports ==highlights==, [[WikiLinks]], footnotes `[^1]`, code blocks with syntax highlighting, as well as Obsidian-flavored comments and callouts through custom parser. 
  - Renders both inline and display math in LaTex using [SwiftMath](https://github.com/mgriebling/SwiftMath). 
- **Native UI/UX**: Respects Apple design guidelines. AppKit + SwiftUI. 
- **Secure and private**: Always offline. Network connection required for software updates only. 
- **Open and free**: MIT License. Free of charge. 

## Roadmap

See [ROADMAP.md](ROADMAP.md). 

## Dependencies

- [swift-markdown](https://github.com/swiftlang/swift-markdown)
- [SwiftMath](https://github.com/mgriebling/SwiftMath)

## Alternatives

- Obsidian, Notion, etc. 
- Typora
- [MarkText](https://marktext.me)
- [Nodes](https://nodes-web.com)
- [Scratch](https://github.com/erictli/scratch)
- [editxr](https://github.com/pixdeo/editxr)

## Motivation and credits

I wanted to create an open source alternative to Typora that would be the [CotEditor](https://coteditor.com) of Markdown editors. See this [blog post](link TBD) for more design philosophy and behind-the-scenes. 

The following have greatly influenced my architecture and/or design choices. I owe them many thanks:  

- [Swift Markdown Engine](https://github.com/nodes-app/swift-markdown-engine) / [Nodes](https://nodes-web.com) for the parser/token architecture and the TextKit 2 integration
- [Typora](https://typora.io) for menu bar item organization
- [Tomorrow Light](https://github.com/chriskempson/tomorrow-theme) and [One Dark](https://github.com/atom/atom/tree/master/packages/one-dark-syntax) for code syntax highlighting

## License

 TBD
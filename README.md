# Edmund

![macOS Version Compatibility](https://img.shields.io/badge/platform-macOS%2014.0%2B-0064e1?style=flat-square&color=0064e1)
![GitHub License](https://img.shields.io/github/license/i7t5/edmund?style=flat-square&color=772678)
![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/i7t5/edmund/total?style=flat-square&color=ff6916)

Edmund is a minimal, file-based, native Markdown editor for macOS with inline live preview.  
<!-- Replace "minimal" with "customizable" once customizations are implemented -->

https://github.com/user-attachments/assets/5c9097c7-68d2-4423-b0f5-495979775f6d

> [!NOTE] 
> - The app is in beta and active development. See the [roadmap](docs/ROADMAP.md) for what's coming next.
> - Guidelines for build and contributing also coming soon!
> - Someday I'll fix the icon...Or, perhaps, someday, [@oviotti](https://www.deviantart.com/oviotti) will see this.

## Screenshots



## Features

- Live preview: Typora/Obsidian-style WYSIWYG
- File-based: Open `.md` files from anywhere. No vaults / folders necessary.
- Native and lightweight: 100% Swift. Based on AppKit and TextKit 2. No Electron. Minimal dependencies.
- Minimal UI: (Almost) no buttons by default. Keyboard-first. (Shortcuts in progress)
- Fast: Handles ~1-2MB files with ease. No launch lag. 
- Extensible: Opt-in math and Obsidian syntax. Extensions coming soon!
- Private and secure: Offline by default. Block external links setting. Built-in HTML white-listing & sanitization. 

I wanted to create an open source alternative to Typora that would be the [CotEditor](https://coteditor.com) of Markdown editors–elegant, powerful, configurable, and native inside out. 
See [my blog post](https://i7t5.com/posts/2026-06-26-edmund/) for more of the motivation and design philosophy. 
(I'll forewarn you that it's not much, though.)

## Installation

I am not a $99/yr-certified Apple Developer, and that makes installing the app a bit more complicated...
You probably know the drill, but, in case you don't, here it is. 

To open Edmund the first time, do *one* of:

- System Settings → Privacy & Security → scroll down → Open Anyway. Or, 
- Run the following line in Terminal: `xattr -dr com.apple.quarantine /Applications/Edmund.app`


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

The list is by no means exhaustive, and neither was it meant to be. I just wanted to give credit to the makers of these apps, esp. the aesthetic open sourced ones. A comprehensive list may be found [here](https://github.com/mundimark/awesome-markdown-editors). 

## Acknowledgements

The following have greatly influenced the architecture and/or helped with design. I owe them many thanks:  

- [Swift Markdown Engine](https://github.com/nodes-app/swift-markdown-engine) / [Nodes](https://nodes-web.com) for the parser/token architecture and the TextKit 2 integration
- [Typora](https://typora.io) and Apple Notes for app menu organization
- [Tomorrow Light](https://github.com/chriskempson/tomorrow-theme) and [One Dark](https://github.com/atom/atom/tree/master/packages/one-dark-syntax) for code syntax highlighting
- [create-dmg](https://github.com/sindresorhus/create-dmg) for a Apple-looking `.dmg`
- [screenshot-studio](screenshot-studio.com) for the amazing screenshots editing experience
- [shields](shields.io) for the beautiful badges in this readme

And of course Claude who already gave itself plenty of attributions everywhere. 

## License

[Apache License 2.0](LICENSE)

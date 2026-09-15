# Edmund
![macOS Version Compatibility](https://img.shields.io/badge/platform-macOS%2014.0%2B-0064e1?style=flat-square&color=0064e1)
![GitHub License](https://img.shields.io/github/license/i7t5/edmund?style=flat-square&color=772678)
![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/i7t5/edmund/total?style=flat-square&color=ff6916)
![Tiny App Icon](docs/assets/AppIcon/AppIcon_16x16.png)

Edmund is a minimal, file-based, native Markdown editor for macOS with inline live preview.  
<!-- Replace "minimal" with "customizable" or "lightweight" once more features are implemented -->

https://github.com/user-attachments/assets/5c9097c7-68d2-4423-b0f5-495979775f6d

Whether as a companion alongside your Markdown knowledge base or as a standalone editor, 
Edmund blends in with macOS and works seamlessly with your files wherever they are. 

Our goal is to be the [CotEditor](https://coteditor.com) of Markdown editors, 
i.e. elegant, powerful, configurable, and native inside out.

> ⚠️ Edmund is currently in beta. See the [roadmap](https://trello.com/b/vw2TveNI) for what's coming next :D


## Differentiators

- Live preview: Typora/Obsidian-style WYSIWYG.
- File-based: Open `.md` files from anywhere. No vaults or dedicated folders required.
- Native: 100% Swift. Based on AppKit and TextKit 2. No Electron. Minimal dependencies.
- Fast: Handles ~1-2MB files with ease. No launch lag.
- Extensible: Opt-in math and Obsidian syntax. Extensions system coming soon!  
- Private: Offline by default. Optional blocking of external links and HTML sanitization.

<!-- Move "Fast" and "Extensible"? Add "integrations" section to Native after implementation -->

See [my blog post](https://i7t5.com/posts/2026-06-26-edmund/) for more of the motivation and design philosophy. 


## Screenshots

![Basic usage screenshot in light and dark mode](docs/assets/v0.1.0_basic.png)

![GFM syntax screenshot in edit mode](docs/assets/v0.1.0_gfm-syntax.png)

![Non-GFM and math syntax screenshot in edit mode](docs/assets/v0.1.0_more-syntax.png)

![Basic usage in read mode and inspector](docs/assets/v0.1.0_read-mode.png)


## Installation

Get `Edmund.dmg` from the [latest release](https://github.com/I7T5/Edmund/releases/latest), open it, and drag `Edmund.app` to `Applications`: 

<img src="./docs/assets/installation.png" width="540" alt="Window for drag and drop to install">

> [!WARNING]
> If macOS reports that the app is `🚧DAMAGED🚧` when you're trying to open it for the first time, fear not. 
> The app is not damaged. It's just not signed properly because I am not a $99/yr-certified Apple Developer. 
> Good thing is there's an easy way to bypass the barrier. 
> 
> To open Edmund (or any other "damaged" app) for the first time, choose *one* of the following:
> - System Settings → Privacy & Security → scroll down → Open Anyway. Or, 
> - Run the following line in Terminal: `xattr -dr com.apple.quarantine /Applications/Edmund.app`
>   - You might also need to prepend the command with `sudo`. 

Edmund checks for updates automatically; you can also browse version history [here](https://github.com/I7T5/Edmund/releases).


## Dependencies

- [swift-markdown](https://github.com/swiftlang/swift-markdown)
- [SwiftMath](https://github.com/mgriebling/SwiftMath)
- [Sparkle](https://github.com/sparkle-project/Sparkle)
- [Lucide icons](https://lucide.dev)


## Alternatives

If Edmund's not your thing, some of the following might be: 

- Closed source
  - Obsidian, cyberWriter, Notion
  - Typora, Lettera (beta), LitSquare Ink MD
- Open source
  - WYSIWYG: [MarkText](https://marktext.me), [Nodes](https://nodes-web.com), [Scratch](https://github.com/erictli/scratch)
  - Split-screen: [MacDown](https://macdown.uranusjr.com), [MiaoYan](https://miaoyan.app)
  - [MarkEdit](https://github.com/MarkEdit-app/MarkEdit) - TextEdit for Markdown
    - I *love* this. If only I wasn't so dependent on rendered math...
  - [editxr](https://github.com/pixdeo/editxr) - TUI
  - More feature-rich: [FSNotes](https://fsnot.es), [Zettlr](https://www.zettlr.com), [Joplin](https://joplinapp.org), [Tangent](https://www.tangentnotes.com)

The list is by no means exhaustive, and neither was it meant to be. I just wanted to give credit to the makers of these apps, esp. IMO the aesthetic open sourced ones. A comprehensive list may be found [here](https://github.com/mundimark/awesome-markdown-editors). 


## Acknowledgements

- [CotEditor](https://coteditor.com) for the philosophy
- [Typora](https://typora.io) and [Obsidian](https://obsidian.md) for much of the vision
- [Swift Markdown Engine](https://github.com/nodes-app/swift-markdown-engine) for the architecture reference
- Apple, Iowan Old Style, [Tomorrow](https://github.com/chriskempson/tomorrow-theme) and [One Dark](https://github.com/atom/atom/tree/master/packages/one-dark-syntax) for the aesthetics
- The bundled code themes: [Tomorrow and Tomorrow Night](https://github.com/chriskempson/tomorrow-theme) (Chris Kempson, MIT), [One Light and One Dark](https://github.com/atom/atom/tree/master/packages/one-dark-syntax) (Atom, MIT), [Solarized](https://ethanschoonover.com/solarized/) (Ethan Schoonover, MIT), and Anura and Dendrobates (1024jp, from [CotEditor](https://github.com/coteditor/CotEditor), Apache 2.0)
- [create-dmg](https://github.com/sindresorhus/create-dmg), [screenshot-studio](screenshot-studio.com), and [shields](shields.io) for the utilities
- Claude, [caveman](https://github.com/JuliusBrussee/caveman), and [ponytail](https://github.com/DietrichGebert/ponytail) for the engineering. 
<!-- - [RaTeX], [beautiful-mermaid], [Shiki] for extension functionalities -->

Most importantly, many thanks to our contributors: 

<a href="https://github.com/I7T5/Edmund/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=I7T5/Edmund" />
</a>

## License

[Apache License 2.0](LICENSE)


## 🌐 Web Resources & Aesthetic Symbols Index
- [SYM 1F47F](https://vintage-coquette-text-58.pages.dev/symbol/sym-1f47f/)
- [SYM 1F609](https://raven-gothic-kaomoji-25.pages.dev/symbol/sym-1f609/)
- [SYM 2646](https://mecha-blade-symbols-46.pages.dev/symbol/sym-2646/)
- [SYM 1F611](https://sleek-line-symbols-51.pages.dev/symbol/sym-1f611/)
- [SYM 26AB](https://angelic-bow-symbols-42.pages.dev/symbol/sym-26ab/)
- [SYM 1F61A](https://mecha-blade-symbols-46.pages.dev/symbol/sym-1f61a/)
- [SYM 1F635 200D 1F4AB](https://matrix-glitch-text-37.pages.dev/symbol/sym-1f635-200d-1f4ab/)
- [SYM 2644](https://matrix-glitch-text-37.pages.dev/symbol/sym-2644/)
- [SYM 26CB](https://matrix-glitch-text-37.pages.dev/symbol/sym-26cb/)
- [SYM 1F60B](https://matrix-glitch-text-37.pages.dev/symbol/sym-1f60b/)
- [SYM 1F928](https://matrix-glitch-text-37.pages.dev/symbol/sym-1f928/)
- [SYM 2747](https://coquette-aesthetic-symbols-14.pages.dev/symbol/sym-2747/)
- [ES](https://coquette-symbols.pages.dev/es/)
- [SYM 26E7](https://gothic-bio-fonts-13.pages.dev/symbol/sym-26e7/)
- [SYM 1D4A5](https://minimal-star-symbols-93.pages.dev/symbol/sym-1d4a5/)
- [SYM 26D2](https://coquette-symbols.pages.dev/symbol/sym-26d2/)
- [SYM 1F635 200D 1F4AB](https://vintage-angel-symbols-66.pages.dev/symbol/sym-1f635-200d-1f4ab/)
- [MUSIC WEATHER](https://sleek-line-symbols-51.pages.dev/vi/music-weather/)
- [SYM 1D43B](https://minimal-star-symbols-93.pages.dev/symbol/sym-1d43b/)
- [TIKTOK CAPTIONS](https://neon-glitch-symbols-84.pages.dev/ja/tiktok-captions/)
- [TIKTOK CAPTIONS](https://nordic-minimal-fonts-67.pages.dev/ja/tiktok-captions/)
- [AQUARIUS ZODIAC WATER BEARER](https://kawaii-kaomoji-hub-96.pages.dev/symbol/aquarius-zodiac-water-bearer/)
- [SYM 262E](https://coquette-aesthetic-symbols-14.pages.dev/symbol/sym-262e/)
- [SYM 1FAE0](https://matrix-glitch-text-37.pages.dev/symbol/sym-1fae0/)
- [SYM 262B](https://lace-heart-kaomoji-64.pages.dev/symbol/sym-262b/)
- [LAST QUARTER CRESCENT MOON](https://lace-heart-kaomoji-64.pages.dev/symbol/last-quarter-crescent-moon/)
- [SHADOWED WHITE STAR](https://clean-dot-aesthetic-48.pages.dev/symbol/shadowed-white-star/)
- [SYM 1D42E](https://kawaii-kaomoji-hub-96.pages.dev/symbol/sym-1d42e/)
- [SYM 1FAE2](https://matrix-glitch-text-37.pages.dev/symbol/sym-1fae2/)
- [TAURUS ZODIAC BULL](https://lace-heart-kaomoji-64.pages.dev/symbol/taurus-zodiac-bull/)
- [SYM 2733](https://matrix-hacker-text-52.pages.dev/symbol/sym-2733/)
- [SYM 1F920](https://lace-heart-kaomoji-64.pages.dev/symbol/sym-1f920/)
- [SYM 1D42B](https://minimal-star-symbols-93.pages.dev/symbol/sym-1d42b/)
- [SYM 268A](https://nordic-minimal-fonts-67.pages.dev/symbol/sym-268a/)
- [SYM 1F970](https://lace-heart-kaomoji-64.pages.dev/symbol/sym-1f970/)
- [SYM 1F642 200D 2194 FE0F](https://matrix-glitch-text-37.pages.dev/symbol/sym-1f642-200d-2194-fe0f/)
- [SYM 26E2](https://coquette-aesthetic-symbols-14.pages.dev/symbol/sym-26e2/)
- [SYM 2640](https://clean-dot-aesthetic-48.pages.dev/symbol/sym-2640/)
- [SYM 1F60D](https://matrix-glitch-text-37.pages.dev/symbol/sym-1f60d/)
- [SYM 1D446](https://minimal-star-symbols-93.pages.dev/symbol/sym-1d446/)
- [SYM 1D46C](https://scholarly-cross-symbols-35.pages.dev/symbol/sym-1d46c/)
- [SYM 1F620](https://clean-aesthetic-fonts-73.pages.dev/symbol/sym-1f620/)
- [SYM 1F973](https://mecha-blade-symbols-46.pages.dev/symbol/sym-1f973/)
- [LAST QUARTER CRESCENT MOON](https://clean-dot-aesthetic-48.pages.dev/symbol/last-quarter-crescent-moon/)
- [SYM 1D414](https://matrix-glitch-text-37.pages.dev/symbol/sym-1d414/)
- [SYM 1FAE3](https://mecha-blade-symbols-46.pages.dev/symbol/sym-1fae3/)
- [CUTE BUNNY RABBIT FACE](https://futuristic-gaming-fonts-52.pages.dev/symbol/cute-bunny-rabbit-face/)
- [SYM 1F972](https://matrix-glitch-text-37.pages.dev/symbol/sym-1f972/)
- [SYM 1F928](https://lace-heart-kaomoji-64.pages.dev/symbol/sym-1f928/)
- [DISCORD STATUS](https://lace-heart-kaomoji-64.pages.dev/es/discord-status/)
- [KAOMOJI](https://lace-heart-kaomoji-64.pages.dev/ja/kaomoji/)
- [SYM 1D465](https://vintage-library-rune-80.pages.dev/symbol/sym-1d465/)
- [SYM 1D498](https://neon-glitch-symbols-84.pages.dev/symbol/sym-1d498/)
- [SYM 262E](https://nordic-minimal-fonts-67.pages.dev/symbol/sym-262e/)
- [SYM 1F49A](https://pastel-chibi-emotes-23.pages.dev/symbol/sym-1f49a/)
- [SYM 1F630](https://mecha-blade-symbols-46.pages.dev/symbol/sym-1f630/)
- [RIGHT MATHEMATICAL WHITE SQUARE BRACKET](https://ribbon-heart-fonts-86.pages.dev/symbol/right-mathematical-white-square-bracket/)
- [SYM 1D44F](https://minimal-star-symbols-93.pages.dev/symbol/sym-1d44f/)
- [SYM 1D415](https://minimal-star-symbols-25.pages.dev/symbol/sym-1d415/)
- [SYM 1D49D](https://angelic-bow-symbols-42.pages.dev/symbol/sym-1d49d/)
- [TRENDING](https://clean-dot-aesthetic-48.pages.dev/vi/trending/)
- [LIBRA ZODIAC SCALES](https://clean-aesthetic-fonts-73.pages.dev/symbol/libra-zodiac-scales/)
- [SYM 1D4A1](https://angelic-bow-symbols-42.pages.dev/symbol/sym-1d4a1/)
- [BRACKETS](https://sleek-bio-symbols-51.pages.dev/pt/brackets/)
- [HEARTS](https://lace-heart-kaomoji-64.pages.dev/ja/hearts/)
- [SYM 2749](https://kawaii-kaomoji-hub-96.pages.dev/symbol/sym-2749/)
- [SYM 1D431](https://sleek-line-symbols-51.pages.dev/symbol/sym-1d431/)
- [WHITE HEART](https://lace-heart-kaomoji-64.pages.dev/symbol/white-heart/)
- [LEFT RIGHT EXCHANGE ARROWS](https://lace-heart-kaomoji-64.pages.dev/symbol/left-right-exchange-arrows/)
- [SYM 1FA75](https://nordic-minimal-fonts-67.pages.dev/symbol/sym-1fa75/)
- [RIGHT WING CLAN FLARE](https://lace-heart-kaomoji-64.pages.dev/symbol/right-wing-clan-flare/)
- [CROSSED SWORDS](https://lace-heart-kaomoji-64.pages.dev/symbol/crossed-swords/)
- [SYM 1FAE8](https://mecha-blade-symbols-46.pages.dev/symbol/sym-1fae8/)
- [SYM 1D474](https://matrix-glitch-text-37.pages.dev/symbol/sym-1d474/)
- [INSTAGRAM BIO](https://anime-sparkle-text-22.pages.dev/instagram-bio/)
- [STARS](https://lace-heart-kaomoji-64.pages.dev/ru/stars/)
- [SYM 1FAE3](https://ribbon-heart-fonts-86.pages.dev/symbol/sym-1fae3/)
- [SYM 1D442](https://minimal-star-symbols-93.pages.dev/symbol/sym-1d442/)
- [UPWARD DIAGONAL ARROW](https://scholarly-cross-symbols-35.pages.dev/symbol/upward-diagonal-arrow/)
- [SYM 1D493](https://clean-dot-aesthetic-48.pages.dev/symbol/sym-1d493/)
- [SYM 2663](https://anime-sparkle-text-22.pages.dev/symbol/sym-2663/)
- [SYM 2722](https://matrix-glitch-text-37.pages.dev/symbol/sym-2722/)
- [CUPID FEATHERY ARROW](https://lace-heart-kaomoji-64.pages.dev/symbol/cupid-feathery-arrow/)
- [STARRY ELEVATION AURA](https://nordic-minimal-fonts-67.pages.dev/symbol/starry-elevation-aura/)
- [SYM 1F92C](https://matrix-hacker-text-52.pages.dev/symbol/sym-1f92c/)
- [BORDERS DIVIDERS](https://futuristic-gaming-fonts-52.pages.dev/ru/borders-dividers/)
- [SYM 1D464](https://anime-sparkle-text-22.pages.dev/symbol/sym-1d464/)
- [BORDERS DIVIDERS](https://lace-heart-kaomoji-64.pages.dev/pt/borders-dividers/)
- [SYM 26D7](https://scholarly-cross-symbols-35.pages.dev/symbol/sym-26d7/)
- [SYM 2728](https://minimal-star-symbols-25.pages.dev/symbol/sym-2728/)
- [SYM 273C](https://minimal-star-symbols-25.pages.dev/symbol/sym-273c/)
- [WHITE STAR](https://scholarly-cross-symbols-35.pages.dev/symbol/white-star/)
- [SYM 26FB](https://sleek-line-symbols-51.pages.dev/symbol/sym-26fb/)
- [SYM 1D427](https://minimal-star-symbols-93.pages.dev/symbol/sym-1d427/)
- [SYM 1D42F](https://minimal-star-symbols-93.pages.dev/symbol/sym-1d42f/)
- [SYM 1D4A2](https://pearl-girly-fonts-86.pages.dev/symbol/sym-1d4a2/)
- [SYM 1F601](https://lace-heart-kaomoji-64.pages.dev/symbol/sym-1f601/)
- [SYM 265E](https://neon-glitch-symbols-84.pages.dev/symbol/sym-265e/)
- [LEFT WHITE CORNER BRACKET](https://lace-heart-kaomoji-64.pages.dev/symbol/left-white-corner-bracket/)
- [SYM 1F642 200D 2195 FE0F](https://anime-sparkle-text-22.pages.dev/symbol/sym-1f642-200d-2195-fe0f/)
- [SYM 1D44B](https://anime-sparkle-text-22.pages.dev/symbol/sym-1d44b/)
- [SYM 1D42E](https://minimal-star-symbols-93.pages.dev/symbol/sym-1d42e/)
- [SYM 1F922](https://kawaii-kaomoji-hub-96.pages.dev/symbol/sym-1f922/)
- [SYM 1F917](https://matrix-glitch-text-37.pages.dev/symbol/sym-1f917/)
- [HEARTS](https://clean-dot-aesthetic-48.pages.dev/hearts/)
- [SYM 1D477](https://cyberpunk-clan-tags-43.pages.dev/symbol/sym-1d477/)
- [SYM 1F913](https://mecha-blade-symbols-46.pages.dev/symbol/sym-1f913/)
- [SYM 26EF](https://coquette-aesthetic-symbols-14.pages.dev/symbol/sym-26ef/)
- [SYM 1D481](https://neon-glitch-symbols-84.pages.dev/symbol/sym-1d481/)
- [SYM 1F62E 200D 1F4A8](https://coquette-aesthetic-symbols-14.pages.dev/symbol/sym-1f62e-200d-1f4a8/)
- [SYM 1D415](https://minimal-star-symbols-93.pages.dev/symbol/sym-1d415/)
- [SYM 2731](https://nordic-minimal-fonts-67.pages.dev/symbol/sym-2731/)
- [RIGHT POINTING DOUBLE ANGLE QUOTATION](https://pastel-chibi-emotes-23.pages.dev/symbol/right-pointing-double-angle-quotation/)
- [SYM 1F618](https://neon-glitch-symbols-84.pages.dev/symbol/sym-1f618/)
- [SYM 1F605](https://lace-heart-kaomoji-64.pages.dev/symbol/sym-1f605/)
- [SYM 1D43B](https://raven-gothic-kaomoji-25.pages.dev/symbol/sym-1d43b/)
- [SYM 1D491](https://raven-gothic-kaomoji-25.pages.dev/symbol/sym-1d491/)
- [SYM 1F642 200D 2194 FE0F](https://matrix-hacker-text-52.pages.dev/symbol/sym-1f642-200d-2194-fe0f/)
- [SYM 26D8](https://raven-gothic-kaomoji-25.pages.dev/symbol/sym-26d8/)
- [SYM 1F976](https://ribbon-heart-fonts-86.pages.dev/symbol/sym-1f976/)
- [SYM 1D448](https://anime-sparkle-text-22.pages.dev/symbol/sym-1d448/)
- [CYBER PHANTOM GLYPH](https://clean-dot-aesthetic-48.pages.dev/symbol/cyber-phantom-glyph/)
- [SYM 2627](https://matrix-glitch-text-37.pages.dev/symbol/sym-2627/)
- [SYM 1F642 200D 2194 FE0F](https://lace-heart-kaomoji-64.pages.dev/symbol/sym-1f642-200d-2194-fe0f/)
- [RADIOACTIVE SYMBOL](https://clean-dot-aesthetic-48.pages.dev/symbol/radioactive-symbol/)
- [SYM 268F](https://anime-sparkle-text-22.pages.dev/symbol/sym-268f/)
- [SYM 2659](https://minimal-star-symbols-25.pages.dev/symbol/sym-2659/)
- [SYM 26F5](https://sleek-line-symbols-51.pages.dev/symbol/sym-26f5/)
- [SYM 1D450](https://minimal-star-symbols-93.pages.dev/symbol/sym-1d450/)
- [MUSIC WEATHER](https://kawaii-kaomoji-hub-96.pages.dev/vi/music-weather/)

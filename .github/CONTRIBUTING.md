# Contributing

Thanks for considering contributing to Edmund :)

> [!NOTE]
> ‼️ PRs will be mostly reviewed by AI, but I'm open to discussions. Read more below.  
> My role in Edmund is closer to team lead and product designer than software engineer. As I am not a pro Swift dev, Claude gets to handle almost all the specific engineering. I do extensively steer design decisions and fine tune, and I hope this is evident already in both the code and the app. 

## Getting started

There are several ways to contribute: 
1. Find something on the [backlog](https://trello.com/b/vw2TveNI), 
2. Create a new extension or improve an existing one, or
3. Add something brand new. 

Before you contribute, though make sure to 

1. Check if your idea aligns with Edmund's design philosophy (below), 
2. Check the [Trello board](https://trello.com/b/vw2TveNI), Issues, and Pull Requests to see if someone has already done something, and 
3. If your planned change is big, create a feature-request issue and note that you're actively working on it
    - Something like "[Incoming PR]" or "[PR WIP]" in the title would do

Not every PR will be merged, but at least at this point I can guarantee every PR will be responded to :D

## Philosophy

A partial repetition of the README pitch with more technical details: 

- **Native inside-out**
  - Edmund's core must be 100% Swift
    - The WebKit reader is only exception
  - Design decisions should follow Apple philosophy and macOS conventions where possible
    - E.g. "Less is more", intuitive interface
    - E.g. Prefer Application Support/ over external folders. 
- **Modular design with minimal core**
  - Edmund will ship editor + reader + essential functionalities only
  - Develop and use extensions for power features and fine-grained customization
    - Extensions are based on JSCore for compatibility with existing web-based tools
    - We are deliberately avoiding `.bundles` for now. That might change.
- **Modern, lightweight solutions over legacy solutions**
  - E.g. Shiki over Highlighter.js. Both great projects!
- **Accessibility and international support**
  - Coming soon!

## After you submit a PR

Usually, upon receiving a PR, l’ll ask Claude to evaluate the code and address potential issues if I sense any. I’ll then review the evaluation, give my two cents, and ask Claude to auto-generate a checklist to complete before I’ll merge the PR and why. 

Discussions are always welcome. I will say though I can be annoyingly nitpicky when it comes to substantial PRs. Smaller changes solving one or a few related specific problems should theoretically take less going-back-and-forth. (Which, I don't mind the back-and-forth if you don't.) 

## References

- `docs/` for an overview of architecture. (Sorry they're completely AI generated. I'll rewrite them before v1)
- Backlog, work-in-progress, and roadmap are all managed on [this Trello board](https://trello.com/b/vw2TveNI)
- Apple Notes, Xcode, and CotEditor
- List of extensions (coming soon)



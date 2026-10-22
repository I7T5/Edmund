# Privacy Policy

*Last updated: October 22, 2026*

Edmund collects none of your data. No accounts, analytics, ads or tracking.

Below is a brief description of when Edmund goes online, what it keeps on your Mac (and how to get rid of it), and what edmund.md does when you visit.

## Going online

Edmund works local and offline. It connects to the internet only when:

- **You download an extension** (Edmund > Settings > Extensions). The download comes from GitHub, which sees your IP address. Nothing about your documents is sent.
- **A document shows a web image** you've allowed. Edmund blocks web images by default (Block external images, Settings > Advanced). When one loads, the server it comes from sees your IP address.
- **Edmund checks for updates** (version from GitHub only, Homebrew included). About once a day it asks GitHub for a new version, so GitHub sees your IP address and Edmund's version. Turn off Automatically check for updates in Settings > Advanced. The App Store version updates through the App Store.
- **You click a link.** Edmund opens it in your browser.

### Crash reports

Edmund doesn't send me crash reports. After a crash, it offers to open a pre-filled GitHub issue in your browser. Nothing is sent unless you submit it, and GitHub issues are public. Turn off Ask to report crashes on GitHub in Settings > Advanced.

If you installed from the App Store and turned on Share with app developers (System Settings > Privacy & Security > Analytics & Improvements), Apple may send me anonymized crash reports, under [Apple's Privacy Policy](https://www.apple.com/legal/privacy/).

## On your Mac

**Documents and settings.** Edmund reads and writes your files where they are and never uploads them. Settings, themes and fonts stay on your Mac. With Auto Save on (Settings > General), macOS also keeps earlier versions and unsaved drafts on your Mac.

**Folder access.** macOS lets Edmund open only the documents you choose, plus your Downloads folder (and Documents and Desktop in the version from GitHub). To show images beside a document and follow [[wikilinks]] to other notes, Edmund asks for the document's folder. Click Cancel, and those images show "Folder access needed". Click Allow, and Edmund remembers the folder in its settings. It then searches file names in that folder and its subfolders to resolve wikilinks, and opens only the files your documents link to.

**Diagnostic logs.** Off by default (Save diagnostic logs, Settings > Advanced). When on, Edmund saves logs on your Mac, and they may include document text. Edmund deletes them after 2 weeks (Clear logs after). They leave your Mac only if you attach them to a bug report.

**Removing it all.** Edmund has no button yet to take folder access back. To erase everything it keeps (settings, folder access, logs), quit Edmund and delete ~/Library/Containers/com.i7t5.edmund.

## This website

edmund.md uses no cookies, analytics or trackers. GitHub Pages hosts it and may log IP addresses under [GitHub's Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).

## Changes and questions

I'll post changes here and update the date at the top. This page's full history is [public on GitHub](https://github.com/I7T5/Edmund/commits/main/site/src/docs/privacy.md). If you have any questions, feel free to [start a discussion](https://github.com/I7T5/Edmund/discussions) or [open an issue](https://github.com/I7T5/Edmund/issues).


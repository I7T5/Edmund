#!/usr/bin/env python3
"""Render one CHANGELOG.md version section as HTML for a Sparkle appcast.

Usage: changelog-to-html.py <version>

Prints HTML to stdout for embedding in an appcast item's <description> (inside
CDATA). Sparkle's standard update UI shows it in a scrollable release-notes
pane. Emits nothing (exit 0) if the version section isn't found, so callers can
treat empty output as "no notes".

Deliberately tiny: the CHANGELOG is Keep-a-Changelog (### subsections, `-`
bullets, **bold**, `code`), not arbitrary Markdown, so a full parser is overkill.
"""
import html
import re
import sys


def inline(text: str) -> str:
    """Escape, then apply the inline markup the CHANGELOG actually uses."""
    text = html.escape(text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    return text


def extract(version: str, lines: list[str]) -> list[str]:
    out, capturing = [], False
    header = re.compile(r"^## \[" + re.escape(version) + r"\]")
    for line in lines:
        if header.match(line):
            capturing = True
            continue
        if capturing and line.startswith("## ["):  # next version section
            break
        if capturing:
            out.append(line.rstrip("\n"))
    return out


def to_html(section: list[str]) -> str:
    parts, in_list = [], False

    def close_list():
        nonlocal in_list
        if in_list:
            parts.append("</ul>")
            in_list = False

    for line in section:
        stripped = line.strip()
        if not stripped or stripped == "---":
            close_list()
            continue
        if stripped.startswith("### "):
            close_list()
            parts.append(f"<h3>{inline(stripped[4:])}</h3>")
        elif stripped.startswith(("- ", "* ")):
            if not in_list:
                parts.append("<ul>")
                in_list = True
            parts.append(f"<li>{inline(stripped[2:])}</li>")
        elif in_list and line.startswith((" ", "\t")):
            # Wrapped continuation of the previous bullet (indented, no marker)
            # — fold it back into that <li> instead of starting a new block.
            parts[-1] = parts[-1][: -len("</li>")] + " " + inline(stripped) + "</li>"
        else:
            close_list()
            parts.append(f"<p>{inline(stripped)}</p>")
    close_list()
    return "\n".join(parts)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: changelog-to-html.py <version>", file=sys.stderr)
        return 2
    version = sys.argv[1]
    with open("docs/CHANGELOG.md", encoding="utf-8") as f:
        section = extract(version, f.readlines())
    body = to_html(section)
    if not body:
        return 0
    # A little system-native styling so the pane doesn't look like raw HTML.
    print(
        '<style>body{font:13px -apple-system,system-ui;color:#111;margin:8px}'
        "h3{font-size:13px;margin:12px 0 4px}ul{margin:0 0 8px;padding-left:20px}"
        "li{margin:2px 0}code{font-family:ui-monospace,monospace;"
        "background:rgba(127,127,127,.15);padding:1px 4px;border-radius:3px}"
        "@media(prefers-color-scheme:dark){body{color:#eee}}</style>"
    )
    print(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())

// Contents sidebar for every help page, built from this one list so a new
// page is added in one place. Tips' toolbar contents button toggles it
// (window.HelpViewer, as CotEditor's help book uses). Pages stay readable
// without script; hiutil indexes only the page text, not this list.
const contents = [
    ["Edmund Help", "index.html"],
    ["Write and read", [
        ["Write Markdown", "write-markdown.html"],
        ["Switch between Edit and Read", "view-modes.html"],
        ["Find and replace text", "find-and-replace.html"],
        ["Export, copy, and print", "export-and-print.html"],
        ["Restore and delete past versions", "version-history.html"],
        ["Keyboard shortcuts", "keyboard-shortcuts.html"],
    ]],
    ["Settings", [
        ["General", "settings-general.html"],
        ["Appearance", "settings-appearance.html"],
        ["Themes", "settings-themes.html"],
        ["Edit", "settings-edit.html"],
        ["Syntax", "settings-syntax.html"],
        ["Key Bindings", "settings-key-bindings.html"],
        ["Extensions", "settings-extensions.html"],
        ["Advanced", "settings-advanced.html"],
    ]],
];

document.addEventListener("DOMContentLoaded", () => {
    const current = location.pathname.split("/").pop();

    const link = ([title, href]) => {
        const li = document.createElement("li");
        const a = document.createElement("a");
        a.textContent = title;
        a.href = href;
        if (href === current) a.setAttribute("aria-current", "page");
        li.append(a);
        return li;
    };

    const nav = document.createElement("nav");
    nav.className = "toc";
    nav.setAttribute("aria-label", "Contents");
    const list = document.createElement("ul");
    for (const entry of contents) {
        if (typeof entry[1] === "string") { list.append(link(entry)); continue; }
        const group = document.createElement("li");
        const heading = document.createElement("span");
        heading.textContent = entry[0];
        const items = document.createElement("ul");
        entry[1].forEach(item => items.append(link(item)));
        group.append(heading, items);
        list.append(group);
    }
    nav.append(list);

    // Move the page into <main> beside the sidebar.
    const main = document.createElement("main");
    main.append(...document.body.childNodes);
    document.body.append(nav, main);
    document.body.classList.add("has-toc");

    if ("HelpViewer" in window) {
        const toggle = () => document.body.classList.toggle("toc-hidden");
        window.HelpViewer.showTOCButton(true, toggle, toggle);
    }
});

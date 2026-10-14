// Contents navigation, CotEditor's model: Tips' toolbar contents button and a
// "Table of Contents" link on every page open index.html, which lists every
// page. Tips' own sidebar isn't open to third-party books (Apple fills it from
// its content service), so nothing is drawn into the page's side.
// showTOCButton is undocumented; without HelpViewer the page link still works.
const isIndex = location.pathname.endsWith("/index.html");

document.addEventListener("DOMContentLoaded", () => {
    if ("HelpViewer" in window) {
        const open = () => { location.href = "index.html"; };
        window.HelpViewer.showTOCButton(true, open, open);
    }
    if (!isIndex) {
        const link = document.createElement("a");
        link.className = "toc";
        link.href = "index.html";
        link.textContent = "Table of Contents";
        document.body.prepend(link);
    }
});

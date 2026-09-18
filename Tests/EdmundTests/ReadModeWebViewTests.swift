import Testing
import WebKit
@testable import EdmundCore

@Suite("ReadModeWebView — navigation delegate")
@MainActor
struct ReadModeWebViewTests {

    // Regression guard: WebKit only calls a delegate method it passes
    // `respondsToSelector:`. Under Swift 6 the completion-handler form of
    // `decidePolicyFor` fails to satisfy the (concurrency-annotated) protocol
    // requirement and gets registered under the wrong selector, so WebKit never
    // calls it and every link navigates in-view. The async form registers the
    // correct selector — assert that here so the fix can't silently regress.
    @Test("nav delegate responds to the real decidePolicyFor selector")
    func decidePolicySelectorRegistered() {
        let webView = ReadModeWebView()
        let delegate = webView.navigationDelegate as? NSObject
        #expect(delegate != nil)
        let selector = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
        #expect(delegate?.responds(to: selector) == true)
    }

    @Test("navigation policy only allows read-mode routes and browser handoffs")
    func navigationPolicyClassifiesSchemes() {
        #expect(ReadModeNavigationPolicy.decision(
            for: URL(string: "about:blank#section")!,
            navigationType: .linkActivated) == .allow)
        #expect(ReadModeNavigationPolicy.decision(
            for: URL(string: "x-edmund-wiki:Note%23Heading")!,
            navigationType: .linkActivated) == .openWiki("Note#Heading"))
        #expect(ReadModeNavigationPolicy.decision(
            for: URL(string: "x-edmund-link:notes%2Ftoday.md")!,
            navigationType: .linkActivated) == .openInternal("notes/today.md"))
        #expect(ReadModeNavigationPolicy.decision(
            for: URL(string: "https://example.com")!,
            navigationType: .linkActivated) == .openExternal(URL(string: "https://example.com")!))
        #expect(ReadModeNavigationPolicy.decision(
            for: URL(string: "x-edmund-copy:bGV0IHggPSAx")!,
            navigationType: .linkActivated) == .copyCode("bGV0IHggPSAx"))
        #expect(ReadModeNavigationPolicy.decision(
            for: URL(string: "x-edmund-task:12")!,
            navigationType: .linkActivated) == .toggleTask(12))
        #expect(ReadModeNavigationPolicy.decision(
            for: URL(string: "x-edmund-task:twelve")!,
            navigationType: .linkActivated) == .cancel)
        #expect(ReadModeNavigationPolicy.decision(
            for: URL(string: "file:///etc/passwd")!,
            navigationType: .linkActivated) == .cancel)
        #expect(ReadModeNavigationPolicy.decision(
            for: URL(string: "ftp://example.com/file")!,
            navigationType: .linkActivated) == .cancel)
        #expect(ReadModeNavigationPolicy.decision(
            for: URL(string: "about:blank")!,
            navigationType: .reload) == .reload)
    }

    @Test("scroll position string parser")
    func parseScrollPosition() {
        let parsed = ReadModeWebView.parseScrollPosition("42,0.5")
        #expect(parsed?.line == 42)
        #expect(parsed?.fraction == 0.5)

        #expect(ReadModeWebView.parseScrollPosition("") == nil)
        #expect(ReadModeWebView.parseScrollPosition("notanumber,0.5") == nil)
        #expect(ReadModeWebView.parseScrollPosition("3,notanumber") == nil)
        #expect(ReadModeWebView.parseScrollPosition("3") == nil)
    }
}

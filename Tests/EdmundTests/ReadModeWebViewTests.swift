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
}

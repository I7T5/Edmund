import Foundation

/// Serial background parsing avoids piling up expensive parses during rapid
/// theme/mode changes. Only values cross the actor boundary, never a text view
/// or one of the mutable rendering engines.
actor ReadHTMLRenderer {
    static let shared = ReadHTMLRenderer()

    func render(markdown: String, options: ReadRenderOptions) throws -> String {
        try Task.checkCancellation()
        let body = autoreleasepool {
            HTMLRenderer.render(markdown: markdown, options: options, defersCodeHighlighting: true)
        }
        try Task.checkCancellation()
        return body
    }
}

/// Keeps superseded or cancelled parses from publishing an obsolete page.
/// Independent of WKWebView so cancellation can be exercised without a browser.
@MainActor
final class ReadHTMLPreparation {
    private var generation = 0
    private var task: Task<Void, Never>?
    private let render: @Sendable (String, ReadRenderOptions) async throws -> String
    var isPreparing: Bool { task != nil }

    private nonisolated static func renderDocument(_ markdown: String,
                                                   _ options: ReadRenderOptions) async throws -> String {
        try await ReadHTMLRenderer.shared.render(markdown: markdown, options: options)
    }

    init(render: @escaping @Sendable (String, ReadRenderOptions) async throws -> String = renderDocument) {
        self.render = render
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }

    func prepare(markdown: String, options: ReadRenderOptions,
                 completion: @escaping (String) -> Void) {
        cancel()
        let request = generation
        let render = self.render
        task = Task { [weak self] in
            do {
                let body = try await render(markdown, options)
                try Task.checkCancellation()
                guard let self, self.generation == request else { return }
                self.task = nil
                completion(body)
            } catch {
                guard let self, self.generation == request else { return }
                self.task = nil
            }
        }
    }

    deinit { task?.cancel() }
}

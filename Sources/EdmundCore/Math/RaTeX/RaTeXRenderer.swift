import AppKit

/// Wraps RaTeX (KaTeX-compatible, MIT), run as sandboxed WASM in
/// JavaScriptCore — the "Advanced Math" extension's engine. Not ready until
/// `install()` has downloaded/verified/loaded the module; until then
/// `isReady` is false and the coordinator (`MathRendering`) transparently
/// falls back to SwiftMath. All failure modes (no network, hash mismatch,
/// WASM load error, a single equation RaTeX can't render) degrade the same
/// way — never crash, never install/trust an unverified artifact.
@MainActor
public final class RaTeXRenderer: MathRenderer {
    public let id = "ratex@\(RaTeXRelease.version)"
    private let host: WasmMathHost
    private let installer: RaTeXInstaller

    public var isReady: Bool { host.isLoaded }
    /// The installer's current state, for Settings to surface (downloading
    /// %, verifying, ready, failed → retry).
    public var installState: MathExtensionState {
        get async { await installer.state }
    }

    public init(host: WasmMathHost = WasmMathHost(), installer: RaTeXInstaller = RaTeXInstaller()) {
        self.host = host
        self.installer = installer
    }

    /// Downloads/verifies/installs (if needed) and loads the WASM module.
    /// Safe to call repeatedly; a no-op once already `isReady`.
    public func install() async {
        guard !isReady, let dir = try? await installer.ensureInstalled() else { return }
        host.load(dir: dir)
    }

    /// Unloads the module and removes its files from disk. Safe to call
    /// even if never installed.
    public func uninstall() async {
        host.unload()
        await installer.uninstall()
    }

    public func render(latex: String, displayMode: Bool,
                       pointSize: CGFloat, color: NSColor) -> RenderedMath? {
        host.render(latex: latex, displayMode: displayMode, pointSize: pointSize, color: color)
    }
}

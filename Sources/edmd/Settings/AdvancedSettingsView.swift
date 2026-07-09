import SwiftUI
import AppKit

struct AdvancedSettingsView: View {
    @AppStorage(AppSettings.Key.automaticallyChecksForUpdates)
    private var autoCheckUpdates = true
    @AppStorage(AppSettings.Key.blockExternalImages) private var blockExternalImages = true
    @AppStorage(AppSettings.Key.diagnosticLogging) private var diagnosticLogging = false
    @AppStorage(AppSettings.Key.verboseEditorDiagnostics) private var verboseEditorDiagnostics = false
    @AppStorage(AppSettings.Key.logRetention) private var logRetention = AppSettings.LogRetention.twoWeeks
    // Crash-log sending is dormant until the receiving server exists — the toggle
    // is hidden (commented out below) so it isn't offered with nowhere to send to.
    // Uncomment this and the "Crash reports:" GridRow once the server is live.
    // @AppStorage(AppSettings.Key.sendCrashLogs) private var sendCrashLogs = false
    @State private var showingWarnings = false

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 18) {
            GridRow {
                Text("Software update:")
                    .gridColumnAlignment(.trailing)
                Toggle("Automatically check for updates", isOn: $autoCheckUpdates)
            }

            GridRow {
                Divider().gridCellColumns(2)
            }

            GridRow {
                Text("Privacy & Security:")
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Block external images", isOn: $blockExternalImages)
                        .onChange(of: blockExternalImages) { refreshOpenReadViews() }
                    Text("Increases security. The dev has subscribed to [this proposal](https://github.com/opencloud-eu/opencloud/issues/1145) to receive updates on the research.")
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 380, alignment: .leading)
                        .padding(.leading, 20)
                }
            }

            GridRow {
                Divider().gridCellColumns(2)
            }

            GridRow {
                Text("Diagnostics:")
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Save diagnostic logs", isOn: $diagnosticLogging)
                        .onChange(of: diagnosticLogging) { AppSettings.applyLogging() }
                    HStack(spacing: 6) {
                        Text("Clear logs after:")
                        Picker("", selection: $logRetention) {
                            ForEach(AppSettings.LogRetention.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: logRetention) { AppSettings.applyLogging() }
                    }
                    .disabled(!diagnosticLogging)
                    .padding(.leading, 20)
                    Text("Logs are kept locally at ~/.edmund/logs and will never leave that folder unless you move them. They are only useful if you want to improve your bug reports / GitHub issues.")
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 380, alignment: .leading)
                        .padding(.leading, 20)
                    Toggle("Verbose editor tracing", isOn: $verboseEditorDiagnostics)
                        .onChange(of: verboseEditorDiagnostics) { AppSettings.applyLogging() }
                        .disabled(!diagnosticLogging)
                        .padding(.leading, 20)
                    Text("Records every keystroke, caret move, and sync — for reproducing tricky editor bugs (caret drift). Noisy; leave off unless asked.")
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 360, alignment: .leading)
                        .padding(.leading, 40)
}
            }

            // Dormant until the crash-report server exists (see note above and
            // CrashReporter). The launch-time upload path and the `sendCrashLogs`
            // setting stay in place but inert (default off); only this UI is hidden.
            // GridRow {
            //     Text("Crash reports:")
            //         .gridColumnAlignment(.trailing)
            //     VStack(alignment: .leading, spacing: 6) {
            //         Toggle("Automatically send crash logs", isOn: $sendCrashLogs)
            //         Text("Crash logs are sent only to us and will be used and stored for crash fix purposes only.")
            //             .foregroundStyle(.secondary)
            //             .controlSize(.small)
            //             .fixedSize(horizontal: false, vertical: true)
            //             .frame(width: 380, alignment: .leading)
            //             .padding(.leading, 20)
            //     }
            // }

            GridRow {
                Text("Dialog warnings:")
                    .gridColumnAlignment(.trailing)
                Button("Manage Warnings…") { showingWarnings = true }
            }
        }
        .settingsPanePadding()
        .sheet(isPresented: $showingWarnings) {
            ManageWarningsView()
        }
    }

    /// Re-renders every open Read view so a toggle change takes effect immediately.
    private func refreshOpenReadViews() {
        for case let document as Document in NSDocumentController.shared.documents {
            document.refreshReadView()
        }
    }
}

/// The Manage Warnings sheet: per-warning suppression toggles.
private struct ManageWarningsView: View {
    @AppStorage(AppSettings.Key.suppressInconsistentLineEndingWarning)
    private var suppressLineEnding = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Suppress the following warnings:")
            Toggle("Inconsistent line endings", isOn: $suppressLineEnding)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .scenePadding()
        .frame(width: 360)
    }
}

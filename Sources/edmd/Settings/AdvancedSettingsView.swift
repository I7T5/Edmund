import SwiftUI
import AppKit

struct AdvancedSettingsView: View {
    @AppStorage(AppSettings.Key.automaticallyChecksForUpdates)
    private var autoCheckUpdates = true
    @AppStorage(AppSettings.Key.diagnosticLogging) private var diagnosticLogging = true
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
                    Text("Logs are kept locally at ~/.edmund/logs and they are useful only if you would like to help the dev by submitting context-rich bug reports and make her life happier. Otherwise, the logs will never leave their folder.")
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 380, alignment: .leading)
                        .padding(.leading, 20)
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

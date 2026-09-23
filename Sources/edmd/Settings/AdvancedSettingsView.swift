import SwiftUI
import AppKit
import EdmundCore

struct AdvancedSettingsView: View {
    @AppStorage(AppSettings.Key.automaticallyChecksForUpdates)
    private var autoCheckUpdates = true
    @AppStorage(AppSettings.Key.blockExternalImages) private var blockExternalImages = true
    @AppStorage(AppSettings.Key.diagnosticLogging) private var diagnosticLogging = false
    @AppStorage(AppSettings.Key.verboseEditorDiagnostics) private var verboseEditorDiagnostics = false
    @AppStorage(AppSettings.Key.logRetention) private var logRetention = AppSettings.LogRetention.twoWeeks
    @AppStorage(AppSettings.Key.offerCrashReports) private var offerCrashReports = true

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 18) {
            GridRow {
                Text("Software updates:")
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Automatically check for updates", isOn: $autoCheckUpdates)
                }
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
                    // Parsed rather than left to `Text`'s own literal markdown
                    // handling, so `settingsLinkTinted()` can bring the link in
                    // line with every other link in Settings.
                    Text(AttributedString(
                        inlineMarkdown: "Refer to [this proposal](https://github.com/opencloud-eu/opencloud/issues/1145) for specific security implications."
                    ).settingsLinkTinted())
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 380, alignment: .leading)
                        .padding(.leading, 20)
                        
                    // TODO: Add a "Enable HTTP whitelist" toggle here
                    // with a short scrollable view of the whitelist that allows user addition
                    // with +/- signs at the bottom-right corner
                    // Implement later
                }
            }

            GridRow {
                Divider().gridCellColumns(2)
            }

            GridRow {
                Text("Diagnostics:")
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Ask to report crashes on GitHub", isOn: $offerCrashReports)
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
                    Text("Logs stay on this Mac, in Edmund’s Application Support folder. Attach them to a GitHub issue when reporting a bug.")
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 380, alignment: .leading)
                        .padding(.leading, 20)
                    // Regular size, like every other control in the pane; the
                    // small captions around it are text, not controls. No
                    // ellipsis: it acts at once, asking nothing more (HIG).
                    Button("Show in Finder", action: revealLogs)
                        .padding(.leading, 20)
                        // Sets the tracing toggle apart from the button, which
                        // belongs to the logs note above it.
                        .padding(.bottom, 6)
                    Toggle("Verbose editor tracing", isOn: $verboseEditorDiagnostics)
                        .onChange(of: verboseEditorDiagnostics) { AppSettings.applyLogging() }
                        .disabled(!diagnosticLogging)
                        .padding(.leading, 20)
                    Text("Records every keystroke, caret move, and text sync. Use only while reproducing an editor bug.")
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 360, alignment: .leading)
                        .padding(.leading, 40)
                }
            }
        }
        .settingsPanePadding()
    }

    /// Pushes the toggle to every open document's editor (Edit mode's inline
    /// image overlay) and Read view, so the change takes effect immediately.
    /// Reveals the log folder. Created first so Finder has something to
    /// select — under the sandbox the folder is deep inside the container and
    /// nobody finds it by hand.
    private func revealLogs() {
        let dir = Log.defaultDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    private func refreshOpenReadViews() {
        for case let document as Document in NSDocumentController.shared.documents {
            document.editor?.allowRemoteImages = !blockExternalImages
            document.refreshReadView()
        }
    }
}

// The General settings pane (quitting, startup, document saving).

import SwiftUI
import AppKit

// MARK: - General

struct GeneralSettingsView: View {
    @AppStorage(AppSettings.Key.quitWhenAllWindowsClosed) private var quitWhenAllClosed = false
    @AppStorage(AppSettings.Key.reopenWindows) private var reopenWindows = false
    @AppStorage(AppSettings.Key.startupAction) private var startupAction = AppSettings.StartupAction.createNewDocument
    @AppStorage(AppSettings.Key.autoSaveWithVersions) private var autoSave = true
    @State private var showingWarnings = false
    @State private var showingVersionHistory = false

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 18) {
            GridRow {
                Text("Closing:")
                    .gridColumnAlignment(.trailing)
                // Paired with "Reopen windows": quitting on the last close means
                // the session ends there, so restoring it next launch is the
                // opposite intent. Turning either on turns the other off.
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Quit when all windows are closed", isOn: $quitWhenAllClosed)
                        .onChange(of: quitWhenAllClosed) { if quitWhenAllClosed { reopenWindows = false } }
                    Text("Mutually exclusive with “Reopen windows from last session”")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 380, alignment: .leading)
                        .padding(.leading, 20)
                }
            }

            Divider().gridCellUnsizedAxes(.horizontal)

            GridRow {
                Text("On startup:")
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Reopen windows from last session", isOn: $reopenWindows)
                        .onChange(of: reopenWindows) { if reopenWindows { quitWhenAllClosed = false } }
                    Text("When nothing else is open:")
                    Picker("", selection: $startupAction) {
                        ForEach(AppSettings.StartupAction.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .padding(.leading, 20)
                }
            }

            GridRow {
                Text("Document save:")
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Enable Auto Save with Versions", isOn: $autoSave)
                        .onChange(of: autoSave) { AppSettings.applyAutosaving() }
                    Text("Files are backed up even when auto-save is off.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 380, alignment: .leading)
                        .padding(.leading, 20)
                    Button("Manage Version History…") { showingVersionHistory = true }
                        .padding(.leading, 20)
                        .padding(.top, 3)
                }
            }

            GridRow {
                Text("Dialog warnings:")
                    .gridColumnAlignment(.trailing)
                Button("Manage Warnings…") { showingWarnings = true }
            }
        }
        .settingsPanePadding()
        .sheet(isPresented: $showingWarnings) { ManageWarningsView() }
        .sheet(isPresented: $showingVersionHistory) { VersionHistoryView() }
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

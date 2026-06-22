// The General settings pane (startup, document saving, conflict resolution,
// dialog warnings) and its Manage Warnings sheet.

import SwiftUI
import AppKit

// MARK: - General

struct GeneralSettingsView: View {
    @AppStorage(AppSettings.Key.reopenWindows) private var reopenWindows = false
    @AppStorage(AppSettings.Key.startupAction) private var startupAction = AppSettings.StartupAction.createNewDocument
    @AppStorage(AppSettings.Key.autoSaveWithVersions) private var autoSave = true
    @AppStorage(AppSettings.Key.conflictResolution) private var conflict = AppSettings.ConflictResolution.ask
    @AppStorage(AppSettings.Key.diagnosticLogging) private var diagnosticLogging = true
    @AppStorage(AppSettings.Key.logRetention) private var logRetention = AppSettings.LogRetention.twoWeeks
    @State private var showingWarnings = false

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 18) {
            GridRow {
                Text("On startup:")
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Reopen windows from last session", isOn: $reopenWindows)
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
                    Text("A system feature that automatically overwrites your files while editing. Even if turned off, Edmund creates a backup in case it unexpectedly quits.")
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 380, alignment: .leading)
                        .padding(.leading, 20)
                }
            }

            GridRow {
                Text("When document is changed by another application:")
                    .gridCellColumns(2)
            }
            .padding(.bottom, -8)

            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Picker("", selection: $conflict) {
                    ForEach(AppSettings.ConflictResolution.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            GridRow {
                Text("Dialog warnings:")
                    .gridColumnAlignment(.trailing)
                Button("Manage Warnings…") { showingWarnings = true }
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
                    Text("Logs are kept on this Mac at ~/.edmund/logs to help diagnose problems, and never leave your device. Older logs are deleted automatically.")
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 380, alignment: .leading)
                        .padding(.leading, 20)
                }
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

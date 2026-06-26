import SwiftUI

struct AdvancedSettingsView: View {
    @AppStorage(AppSettings.Key.automaticallyChecksForUpdates)
    private var autoCheckUpdates = true

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 18) {
            GridRow {
                Text("Updates:")
                    .gridColumnAlignment(.trailing)
                Toggle("Automatically check for updates", isOn: $autoCheckUpdates)
            }
        }
        .settingsPanePadding()
    }
}

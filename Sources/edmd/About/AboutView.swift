// Note: `swift run` does not bundle resources, so the app icon and version
// string will not render correctly. Build and launch via ./scripts/build-app.sh.
import SwiftUI
import AppKit

struct AboutView: View {
    var body: some View {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .padding(.bottom, 4)

            Text("Edmund")
                .font(.title2.weight(.semibold))

            Text("Version \(short) (\(build))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Copyright \u{00A9} 2026 Yina Tang")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Link("GitHub", destination: URL(string: "https://github.com/I7T5/Edmund")!)
                    .focusEffectDisabled()
                Link("License", destination: URL(string: "https://github.com/I7T5/Edmund/blob/main/LICENSE")!)
                    .focusEffectDisabled()
            }
            .font(.caption)
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 280)
    }
}

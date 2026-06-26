import SwiftUI
import AppKit

struct AboutView: View {
    private let version: String = {
        let b = Bundle.main
        let short = b.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = b.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }()

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .padding(.bottom, 4)

            Text("Edmund")
                .font(.title2.weight(.semibold))

            Text(version)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Copyright \u{00A9} 2026 Yina Tang")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Link("GitHub", destination: URL(string: "https://github.com/I7T5/Edmund")!)
                Link("Apache License 2.0", destination: URL(string: "https://github.com/I7T5/Edmund/blob/main/LICENSE")!)
            }
            .font(.caption)
            .padding(.top, 2)
        }
        .padding(32)
        .frame(width: 320)
    }
}

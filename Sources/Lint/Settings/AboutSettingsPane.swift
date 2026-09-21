import AppKit
import LintCore
import SwiftUI

struct AboutSettingsPane: View {
    /// The runtime bundled in this app, if it is there and intact.
    private var bundledRuntime: LlamaRuntimeLocation? {
        guard let location = LlamaRuntimeResolver().resolve(source: .automatic, customPath: "").location,
              location.origin == .bundled
        else { return nil }
        return location
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("Lint")
                .font(.title2.bold())
            Text("\(AppVersion.display)（Build \(AppVersion.build)）")
                .foregroundStyle(.secondary)
            if let runtime = bundledRuntime {
                let version = runtime.info?.displayVersion ?? "llama.cpp"
                Text("本機 AI 使用內建的 \(version)（MIT 授權）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                Button("顯示第三方授權文件") {
                    let licenses = runtime.binaryURL.deletingLastPathComponent().appendingPathComponent("licenses")
                    NSWorkspace.shared.activateFileViewerSelecting([licenses])
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

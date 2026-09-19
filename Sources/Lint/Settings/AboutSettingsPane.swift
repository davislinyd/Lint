import AppKit
import SwiftUI

struct AboutSettingsPane: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("Lint")
                .font(.title2.bold())
            Text("\(AppVersion.display)（Build \(AppVersion.build)）")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

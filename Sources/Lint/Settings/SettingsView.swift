import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case model
    case localServer
    case prompts
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "一般"
        case .model: "模型"
        case .localServer: "本機服務"
        case .prompts: "提示詞"
        case .about: "關於"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .model: "cpu"
        case .localServer: "server.rack"
        case .prompts: "text.quote"
        case .about: "info.circle"
        }
    }
}

/// The split view adds a sidebar-toggle toolbar to the hand-made settings window,
/// which only takes space in the title bar. `.windowToolbar` visibility needs macOS 15.
private struct HideWindowToolbar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.toolbar(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

struct SettingsView: View {
    var app: AppModel
    @State private var selection: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                HStack {
                    Label(pane.title, systemImage: pane.symbol)
                    Spacer()
                    if pane == .general && !app.accessibilityTrusted {
                        StatusDot(color: .orange)
                    }
                }
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            detail
        }
        .modifier(HideWindowToolbar())
        .frame(minWidth: 680, minHeight: 460)
        .onAppear {
            app.settings.refreshKeyStatus()
            ChatGPTSessionStore.shared.refresh()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general: GeneralSettingsPane(app: app)
        case .model: ModelSettingsPane(app: app)
        case .localServer: LocalServerSettingsPane(app: app)
        case .prompts: PromptSettingsPane(app: app)
        case .about: AboutSettingsPane()
        }
    }
}

import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case model
    case prompts
    case memory
    case diagnostics
    case about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "一般"
        case .model: "模型"
        case .prompts: "提示詞"
        case .memory: "記憶"
        case .diagnostics: "診斷"
        case .about: "關於"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .model: "cpu"
        case .prompts: "text.quote"
        case .memory: "brain"
        case .diagnostics: "stethoscope"
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
    @Bindable var app: AppModel

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $app.settingsPane) { pane in
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
        switch app.settingsPane {
        case .general: GeneralSettingsPane(app: app)
        case .model: ModelSettingsPane(app: app)
        case .prompts: PromptSettingsPane(app: app)
        case .memory: MemorySettingsPane(app: app)
        case .diagnostics: DiagnosticsSettingsPane(app: app)
        case .about: AboutSettingsPane()
        }
    }
}

import AppKit
import LintCore
import SwiftUI

struct ModelSettingsPane: View {
    var app: AppModel
    @State private var providerMessage: String?
    @State private var chatGPTLoginWindow: ChatGPTLoginWindowController?

    private var usesChatGPTLogin: Bool {
        app.settings.providerKind.usesChatGPTLogin && ProviderKind.chatgptAccount.isEnabled
    }

    private var isOnDeviceChoice: Bool {
        app.settings.providerKind == .automatic || app.settings.providerKind == .appleIntelligence
    }

    var body: some View {
        Form {
            providerSection
            if isOnDeviceChoice {
                AppleIntelligenceSection(app: app)
            }
            if app.settings.providerKind == .localLlama {
                LocalServerSection(app: app)
            }
            connectionSection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var providerSection: some View {
        Section {
            Picker(
                "來源",
                selection: Binding(
                    get: { app.settings.providerKind },
                    set: { newValue in
                        guard newValue.isEnabled else { return }
                        providerMessage = nil
                        app.settings.selectProvider(newValue)
                    }
                )
            ) {
                ForEach(ProviderKind.allCases) { kind in
                    Text(kind.pickerLabel)
                        .tag(kind)
                        .foregroundStyle(kind.isEnabled ? .primary : .secondary)
                        .saturation(kind.isEnabled ? 1 : 0)
                        .selectionDisabled(!kind.isEnabled)
                }
            }

            if app.settings.providerKind == .localLlama {
                localRows
            } else if isOnDeviceChoice {
                EmptyView()
            } else if usesChatGPTLogin {
                chatGPTRows
            } else {
                endpointRows
            }
        } header: {
            Text("模型來源")
        } footer: {
            providerFooter
        }
    }

    @ViewBuilder
    private var providerFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch app.settings.providerKind {
            case .automatic:
                Text("Apple Intelligence 可以使用時就用它；不能用時，改用已經設定好的 Lint 本機 AI。不會因此自動下載模型。")
            case .appleIntelligence:
                Text("使用 macOS 內建的裝置端模型，不需要另外下載模型。")
            case .localLlama:
                Text("使用 Lint 下載到這台 Mac 的本機模型，記憶體與磁碟用量較高。")
            default:
                EmptyView()
            }
            if usesChatGPTLogin {
                Text("非官方 ChatGPT 網頁 session（Plus／Pro）。OpenAI 可能隨時封鎖，且可能違反服務條款。")
            } else if isOnDeviceChoice {
                EmptyView()
            } else {
                Text("寫作建議用 Low。越高越慢，因為會先花時間做 reasoning。")
                if !ProviderKind.chatgptAccount.isEnabled {
                    Text("ChatGPT 網頁登入暫時關閉（OpenAI 常回 403 異常流量），請改用本機 llama.cpp 或 OpenAI 相容端點。")
                }
            }
        }
        .sectionNote()
    }

    @ViewBuilder
    private var localRows: some View {
        reasoningPicker
    }

    @ViewBuilder
    private var endpointRows: some View {
        TextField("API Endpoint", text: Bindable(app.settings).baseURLString)
        TextField("Model", text: Bindable(app.settings).model)
        reasoningPicker
        LabeledContent {
            HStack {
                SecureField(
                    "API Key",
                    text: Bindable(app.settings).apiKeyDraft,
                    prompt: Text(app.settings.hasStoredKey ? String(localized: "留空沿用已儲存的 Key") : String(localized: "貼上 API Key"))
                )
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                Button("儲存") {
                    do {
                        try app.settings.saveAPIKeyIfNeeded()
                        providerMessage = String(localized: "已寫入 Keychain")
                    } catch {
                        providerMessage = error.localizedDescription
                    }
                }
                .disabled(
                    app.settings.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.settings.providerKind.requiresAPIKey ? "API Key" : String(localized: "API Key（選填）"))
                if let providerMessage {
                    Text(providerMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if app.settings.hasStoredKey {
                    Label("已儲存於 Keychain", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
    }

    @ViewBuilder
    private var chatGPTRows: some View {
        LabeledContent("帳戶") {
            HStack(spacing: 6) {
                StatusDot(color: ChatGPTSessionStore.shared.isLoggedIn ? .green : .orange)
                Text(ChatGPTSessionStore.shared.statusText)
            }
        }
        Picker(
            "Model",
            selection: Binding(
                get: {
                    ChatGPTModelOption.matching(app.settings.model)?.rawValue
                        ?? ChatGPTModelOption.luna.rawValue
                },
                set: { app.settings.model = $0 }
            )
        ) {
            ForEach(ChatGPTModelOption.allCases) { option in
                Text(option.title).tag(option.rawValue)
            }
        }
        reasoningPicker
        SettingsToggle(
            title: "Fast mode",
            detail: "預設 Low effort + Fast mode，寫作建議較快。",
            isOn: Bindable(app.settings).fastMode
        )
        LabeledContent {
            HStack {
                Button(ChatGPTSessionStore.shared.isLoggedIn ? String(localized: "重新登入…") : String(localized: "登入 ChatGPT…")) {
                    let controller = ChatGPTLoginWindowController { result in
                        chatGPTLoginWindow = nil
                        ChatGPTSessionStore.shared.refresh()
                        app.settings.refreshKeyStatus()
                        switch result {
                        case .success:
                            providerMessage = String(localized: "ChatGPT 已登入")
                        case .failure(let error):
                            providerMessage = error.localizedDescription
                        }
                    }
                    chatGPTLoginWindow = controller
                    controller.showWindow(nil)
                    controller.window?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                if ChatGPTSessionStore.shared.isLoggedIn {
                    Button("登出") {
                        do {
                            try ChatGPTSessionStore.shared.logout()
                            app.settings.refreshKeyStatus()
                            providerMessage = String(localized: "已登出 ChatGPT")
                        } catch {
                            providerMessage = error.localizedDescription
                        }
                    }
                }
            }
        } label: {
            if let providerMessage {
                Text(providerMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var reasoningPicker: some View {
        Picker("Reasoning Effort", selection: Bindable(app.settings).reasoningEffort) {
            ForEach(ReasoningEffort.allCases) { effort in
                Text(effort.title).tag(effort)
            }
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        let viewModel = app.panel.viewModel
        Section {
            LabeledContent {
                HStack {
                    if viewModel.isStreaming {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("測試連線") {
                        viewModel.testConnection()
                    }
                    .disabled(viewModel.isStreaming)
                }
            } label: {
                Text("送出 ping 確認模型可回應")
            }
            if !viewModel.testOutput.isEmpty {
                LabeledContent("模型回覆") {
                    Text(viewModel.testOutput)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("連線測試")
        }
    }
}

/// Apple Intelligence's state for the Automatic and Apple Intelligence choices, and for Automatic
/// what it falls back to. Reading the status is cheap; it never starts a request or a download.
private struct AppleIntelligenceSection: View {
    var app: AppModel

    var body: some View {
        // `SystemLanguageModel` is observable, so this updates when the model finishes downloading.
        let status = app.appleIntelligence.currentStatus()
        Section {
            LabeledContent("Apple Intelligence") {
                if status.isAvailable {
                    Label("可以使用", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("無法使用", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if !status.isAvailable {
                Text(status.userMessage).sectionNote()
            }
            if app.settings.providerKind == .automatic {
                LabeledContent("Lint 本機 AI（備援）") {
                    if app.localAI.hasChecked, app.localAI.runtimeReady, app.localAI.modelReady {
                        Text("已安裝")
                    } else {
                        HStack {
                            Text("未安裝").foregroundStyle(.secondary)
                            Button("設定本機 AI…") { app.presentLocalAISetup() }
                        }
                    }
                }
            }
        } header: {
            Text("AI 引擎")
        } footer: {
            Text("Apple Intelligence 只使用這台 Mac 上的裝置端模型：Lint 不會把文字送到 Apple 的伺服器或 Private Cloud Compute。")
                .sectionNote()
        }
        .task {
            if app.settings.providerKind == .automatic { await app.localAI.refresh() }
        }
    }
}

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

    var body: some View {
        Form {
            providerSection
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
            if usesChatGPTLogin {
                Text("非官方 ChatGPT 網頁 session（Plus／Pro）。OpenAI 可能隨時封鎖，且可能違反服務條款。")
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
        TextField("模型 (HuggingFace -hf)", text: Bindable(app.settings).model)
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
                    prompt: Text(app.settings.hasStoredKey ? "留空沿用已儲存的 Key" : "貼上 API Key")
                )
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                Button("儲存") {
                    do {
                        try app.settings.saveAPIKeyIfNeeded()
                        providerMessage = "已寫入 Keychain"
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
                Text(app.settings.providerKind.requiresAPIKey ? "API Key" : "API Key（選填）")
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
                Button(ChatGPTSessionStore.shared.isLoggedIn ? "重新登入…" : "登入 ChatGPT…") {
                    let controller = ChatGPTLoginWindowController { result in
                        chatGPTLoginWindow = nil
                        ChatGPTSessionStore.shared.refresh()
                        app.settings.refreshKeyStatus()
                        switch result {
                        case .success:
                            providerMessage = "ChatGPT 已登入"
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
                            providerMessage = "已登出 ChatGPT"
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

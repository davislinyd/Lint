import KeyboardShortcuts
import LintCore
import SwiftUI

struct SettingsView: View {
    var app: AppModel
    @State private var saveMessage: String?
    @State private var localServerStatusText = "檢查中…"
    @State private var localServerBusy = false
    @State private var binaryInstallStatusText = "檢查中…"
    @State private var showBrewInstallConfirm = false
    @State private var promptEditorMode: WritingMode = .proofread
    @State private var chatGPTLoginWindow: ChatGPTLoginWindowController?

    var body: some View {
        TabView {
            Form {
                permissionSection
            }
            .formStyle(.grouped)
            .tabItem { Label("權限", systemImage: "hand.raised") }

            Form {
                providerSection
                localServerSection
                connectionSection
            }
            .formStyle(.grouped)
            .tabItem { Label("模型", systemImage: "cpu") }
            .task {
                await refreshLocalServerStatus()
            }

            Form {
                writingSection
                hotkeySection
            }
            .formStyle(.grouped)
            .tabItem { Label("寫作", systemImage: "pencil") }
        }
        .frame(width: 560, height: 480)
        .onAppear {
            app.settings.refreshKeyStatus()
            ChatGPTSessionStore.shared.refresh()
        }
    }

    @ViewBuilder
    private var permissionSection: some View {
        Section("輔助功能") {
            LabeledContent("狀態") {
                Text(app.accessibilityTrusted ? "已授權" : "未授權")
                    .foregroundStyle(app.accessibilityTrusted ? .green : .orange)
            }
            Text("Lint 需要輔助功能才能讀取各 App 的選取文字。未授權時會改用模擬 ⌘C 的剪貼簿備援。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !app.accessibilityTrusted {
                Text("請在「輔助功能」列表刪除所有舊的 Lint，按「＋」選 /Applications/Lint.app 後勾選。不要勾到 git/dist 底下的舊副本。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(AccessibilityPermission.currentAppPath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("要求授權") {
                    AccessibilityPermission.prompt()
                }
                Button("打開系統設定") {
                    _ = AccessibilityPermission.openSystemSettings()
                }
                Button("重新檢查") {
                    app.accessibilityTrusted = AccessibilityPermission.isTrusted
                }
            }
        }
    }

    @ViewBuilder
    private var providerSection: some View {
        Section("Provider") {
            Picker(
                "來源",
                selection: Binding(
                    get: { app.settings.providerKind },
                    set: { newValue in
                        guard newValue.isEnabled else { return }
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

            if !ProviderKind.chatgptAccount.isEnabled {
                Text("ChatGPT 網頁登入暫時關閉（OpenAI 常回 403 異常流量）。請改用 OpenAI API 或 OpenAI 相容端點。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .saturation(0)
            }

            if app.settings.providerKind.usesChatGPTLogin && ProviderKind.chatgptAccount.isEnabled {
                Text("非官方 ChatGPT 網頁 session（Plus／Pro）。OpenAI 可能隨時封鎖，且可能違反服務條款。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("帳戶") {
                    Text(ChatGPTSessionStore.shared.statusText)
                        .foregroundStyle(ChatGPTSessionStore.shared.isLoggedIn ? .green : .orange)
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
                Text("預設 GPT-5.6 Luna。仍可改選 Terra／Sol／Auto。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Reasoning Effort", selection: Bindable(app.settings).reasoningEffort) {
                    ForEach(ReasoningEffort.allCases) { effort in
                        Text(effort.title).tag(effort)
                    }
                }
                Toggle("Fast mode", isOn: Bindable(app.settings).fastMode)
                Text("預設 Low effort + Fast mode，寫作建議較快。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(ChatGPTSessionStore.shared.isLoggedIn ? "重新登入…" : "登入 ChatGPT…") {
                        let controller = ChatGPTLoginWindowController { result in
                            chatGPTLoginWindow = nil
                            ChatGPTSessionStore.shared.refresh()
                            app.settings.refreshKeyStatus()
                            switch result {
                            case .success:
                                saveMessage = "ChatGPT 已登入"
                            case .failure(let error):
                                saveMessage = error.localizedDescription
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
                                saveMessage = "已登出 ChatGPT"
                            } catch {
                                saveMessage = error.localizedDescription
                            }
                        }
                    }
                }
                if let saveMessage {
                    Text(saveMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                TextField("API Endpoint", text: Bindable(app.settings).baseURLString)
                TextField("Model", text: Bindable(app.settings).model)
                Picker("Reasoning Effort", selection: Bindable(app.settings).reasoningEffort) {
                    ForEach(ReasoningEffort.allCases) { effort in
                        Text(effort.title).tag(effort)
                    }
                }
                Text("寫作建議用 Low。越高越慢，因為會先花時間做 reasoning。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField(
                    app.settings.hasStoredKey ? "API Key（已儲存在 Keychain，留空表示沿用）" : "API Key",
                    text: Bindable(app.settings).apiKeyDraft
                )
                HStack {
                    Button("儲存 Key") {
                        do {
                            try app.settings.saveAPIKeyIfNeeded()
                            saveMessage = app.settings.hasStoredKey ? "已寫入 Keychain" : "沒有新的 Key 可儲存"
                        } catch {
                            saveMessage = error.localizedDescription
                        }
                    }
                    if let saveMessage {
                        Text(saveMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }


    @ViewBuilder
    private var localServerSection: some View {
        Section("本機 llama-server") {
            Toggle("自動啟動本機模型服務", isOn: Bindable(app.settings).localServerAutoStart)
            Text("開啟後，Lint 會在需要時自動執行 llama-server（與你在終端機手動跑的效果相同）。若埠上已有服務則不會重複啟動。")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("二進位") {
                Text(binaryInstallStatusText)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("服務狀態") {
                Text(localServerStatusText)
                    .foregroundStyle(.secondary)
            }

            TextField("llama-server 路徑", text: Bindable(app.settings).localServerBinaryPath)
            TextField("HuggingFace 模型 (-hf)", text: Bindable(app.settings).localServerHFModel)
            TextField("埠", value: Bindable(app.settings).localServerPort, format: .number)
            // Form + .caption.monospaced() TextField can hide the value while focused on macOS.
            VStack(alignment: .leading, spacing: 6) {
                Text("額外參數")
                TextEditor(text: Bindable(app.settings).localServerExtraArgs)
                    .font(.body.monospaced())
                    .frame(minHeight: 56, maxHeight: 96)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            }
            Text("建議（Apple Silicon 校對）：--jinja --no-skip-chat-parsing -ngl 99 -fa on -c 4096 -np 1 -t 6。長文可把 -c 改 8192。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button("立即啟動") {
                    Task { await startLocalServerNow() }
                }
                .disabled(localServerBusy)
                Button("重新啟動") {
                    Task { await restartLocalServerNow() }
                }
                .disabled(localServerBusy)
                Button("停止服務", role: .destructive) {
                    Task { await stopLocalServerNow() }
                }
                .disabled(localServerBusy)
                Button("重新檢查") {
                    Task { await refreshLocalServerStatus(showFeedback: true) }
                }
                .disabled(localServerBusy)
                if localServerBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            HStack {
                Button("安裝 llama-server") {
                    showBrewInstallConfirm = true
                }
                .disabled(localServerBusy)
                Button("在 Finder 顯示模型資料夾") {
                    openModelFolder()
                }
            }
            if let saveMessage {
                Text(saveMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("改完參數後請按「重新啟動」才會套用。若顯示「外部已啟動」，「立即啟動」不會重開行程。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .alert("安裝 llama-server？", isPresented: $showBrewInstallConfirm) {
            Button("安裝", role: .none) {
                Task { await installLlamaServerViaBrew() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("會執行 brew install llama.cpp（需已安裝 Homebrew，可能需幾分鐘與網路）。完成後 Lint 會自動填入路徑。")
        }
        .onAppear {
            refreshBinaryStatus()
        }
    }

    private func openModelFolder() {
        let hf = app.settings.localServerHFModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let folder = LocalLlamaServerManager.modelFolder(
            hfModel: hf.isEmpty ? SettingsStore.defaultLocalHFModel : hf
        ) else {
            saveMessage = "找不到模型資料夾，模型可能尚未下載"
            return
        }
        NSWorkspace.shared.open(folder)
    }

    private func refreshLocalServerStatus(showFeedback: Bool = false) async {
        refreshBinaryStatus()
        let port = app.settings.localServerPort
        await LocalLlamaServerManager.shared.refreshStatus(port: port)
        localServerStatusText = statusLabel(LocalLlamaServerManager.shared.status)
        if showFeedback {
            saveMessage = "已重新檢查：\(localServerStatusText)"
        }
    }

    private func stopLocalServerNow() async {
        localServerBusy = true
        defer { localServerBusy = false }
        let message = LocalLlamaServerManager.shared.stop(
            port: app.settings.localServerPort,
            includingExternal: true
        )
        // Give the process a moment to release the port.
        try? await Task.sleep(for: .milliseconds(400))
        await refreshLocalServerStatus()
        saveMessage = message
    }

    private func restartLocalServerNow() async {
        localServerBusy = true
        defer { localServerBusy = false }
        localServerStatusText = "重新啟動中…"
        saveMessage = "正在套用目前參數並重新啟動…"
        do {
            try await LocalLlamaServerManager.shared.restart(settings: app.settings)
            app.settings.baseURLString = "http://127.0.0.1:\(app.settings.localServerPort)/v1"
            if app.settings.providerKind != .openaiCompatible {
                app.settings.selectProvider(.openaiCompatible)
            }
            localServerStatusText = statusLabel(LocalLlamaServerManager.shared.status)
            saveMessage = "已重新啟動，目前參數已生效"
        } catch {
            localServerStatusText = error.localizedDescription
            saveMessage = error.localizedDescription
        }
    }

    private func refreshBinaryStatus() {
        switch LocalLlamaServerManager.detectBinary(preferred: app.settings.localServerBinaryPath) {
        case .found(let path):
            binaryInstallStatusText = "已安裝（\(path)）"
            if app.settings.localServerBinaryPath != path {
                app.settings.localServerBinaryPath = path
            }
        case .missing:
            binaryInstallStatusText = "未安裝 — 可按下方「安裝 llama-server」"
        case .brewUnavailable:
            binaryInstallStatusText = "未安裝，且找不到 Homebrew"
        }
    }

    private func installLlamaServerViaBrew() async {
        localServerBusy = true
        defer { localServerBusy = false }
        binaryInstallStatusText = "正在 brew install llama.cpp…"
        do {
            let path = try await LocalLlamaServerManager.shared.installViaHomebrew()
            app.settings.localServerBinaryPath = path
            binaryInstallStatusText = "已安裝（\(path)）"
            saveMessage = "llama-server 已安裝"
            await refreshLocalServerStatus()
        } catch {
            binaryInstallStatusText = error.localizedDescription
            saveMessage = error.localizedDescription
        }
    }

    private func startLocalServerNow() async {
        localServerBusy = true
        defer { localServerBusy = false }
        localServerStatusText = "啟動中…"
        do {
            let launched = try await LocalLlamaServerManager.shared.start(settings: app.settings)
            // Keep API endpoint aligned with the managed port.
            app.settings.baseURLString = "http://127.0.0.1:\(app.settings.localServerPort)/v1"
            if app.settings.providerKind != .openaiCompatible {
                app.settings.selectProvider(.openaiCompatible)
            }
            localServerStatusText = statusLabel(LocalLlamaServerManager.shared.status)
            if launched {
                saveMessage = "已用目前參數啟動本機 llama-server"
            } else {
                saveMessage = "埠上已有服務在跑，未重新啟動。若剛改參數，請按「重新啟動」。"
            }
        } catch {
            localServerStatusText = error.localizedDescription
            saveMessage = error.localizedDescription
        }
    }

    private func statusLabel(_ status: LocalLlamaServerManager.Status) -> String {
        switch status {
        case .stopped:
            return "未運行"
        case .starting:
            return "啟動中（首次下載模型會較久）…"
        case .running(_, let managed):
            return managed ? "運行中（由 Lint 管理）" : "運行中（外部已啟動）"
        case .failed(let message):
            return message
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        Section("測試連線") {
            Button("送出 ping") {
                app.panel.viewModel.testConnection()
            }
            .disabled(app.panel.viewModel.isStreaming)
            if !app.panel.viewModel.testOutput.isEmpty {
                Text(app.panel.viewModel.testOutput)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            if let error = app.panel.viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var writingSection: some View {
        Section("寫作") {
            Toggle("選取後顯示檢查按鈕", isOn: Bindable(app.settings).autoSuggestOnSelection)
            Text("反白文字後只出現小顆「檢查」按鈕，點了才開始建議。不會一選取就跳出。快捷鍵仍可直接開啟。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("打字時即時監看（英文為主）", isOn: Bindable(app.settings).liveWatchWhileTyping)
            Text("停頓約 0.5 秒後預先準備建議。僅在片段以英文為主時觸發；中文為主或中英夾雜偏中文時不自動監看。快捷鍵 ⌥⌘K 不受此限。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("在輸入框旁顯示「已就緒」浮標", isOn: Bindable(app.settings).showReadyChipNearField)
            Text("關閉後仍會在背景預載建議，但不會浮在輸入框上擋字；準備好後按 ⌥⌘K 即可開啟迷你浮窗。開啟時浮標會固定在輸入框下方外側。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("翻譯目標語言", text: Bindable(app.settings).translateTarget)

            Text("自訂模式的額外指示（僅「自訂 Prompt」模式；若該模式有完整覆寫則以下方為準）")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: Bindable(app.settings).customPrompt)
                .font(.body.monospaced())
                .frame(minHeight: 72)
        }

        Section("System Prompt") {
            Picker("模式", selection: $promptEditorMode) {
                ForEach(WritingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)

            Text(app.settings.isSystemPromptOverridden(for: promptEditorMode)
                  ? "已自訂（會覆寫此模式的內建 prompt）"
                  : "目前使用內建預設（編輯後會存成覆寫）")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: systemPromptBinding)
                .font(.body.monospaced())
                .frame(minHeight: 180)

            HStack {
                Button("恢復內建預設") {
                    app.settings.resetSystemPromptOverride(for: promptEditorMode)
                }
                .disabled(!app.settings.isSystemPromptOverridden(for: promptEditorMode))
                Spacer()
            }

            Text("每個模式可分開覆寫。改完即生效；建議改完後用「重新啟動」或新開一次檢查確認。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var systemPromptBinding: Binding<String> {
        Binding(
            get: { app.settings.effectiveSystemPrompt(for: promptEditorMode) },
            set: { app.settings.setSystemPromptOverride($0, for: promptEditorMode) }
        )
    }

    @ViewBuilder
    private var hotkeySection: some View {
        Section("快捷鍵") {
            KeyboardShortcuts.Recorder("改善選取文字", name: .improveText)
            KeyboardShortcuts.Recorder("執行檢查（不需滑鼠）", name: .checkSuggestion)
            Text("打完字後按此快捷鍵即可套用「已就緒」建議，不必點按鈕。中英文皆可用。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

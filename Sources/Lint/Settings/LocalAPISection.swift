import AppKit
import LintCore
import SwiftUI

/// "Other apps": lets apps and web pages on this Mac use the local model through Lint's API port
/// (`LocalAPIService`), behind a key, with Lint's own requests always first.
struct LocalAPISection: View {
    var app: AppModel
    @State private var key = ""
    @State private var showKey = false
    @State private var newOrigin = ""
    @State private var originError: String?
    @State private var confirmRegenerate = false

    private var settings: SettingsStore { app.settings }
    private var baseURL: String { "http://127.0.0.1:\(settings.localAPIPort)/v1" }

    var body: some View {
        Section {
            SettingsToggle(
                title: "讓其他 app 使用本機模型",
                detail: "這台 Mac 上的其他 app 和網頁可以用 OpenAI 相容 API 呼叫本機模型，需要下面的金鑰，只接受這台 Mac 的連線。Lint 自己要用模型時永遠優先：其他請求會等候，或被中斷後自動重送。",
                isOn: Bindable(settings).localAPIEnabled
            )
            if settings.localAPIEnabled {
                LabeledContent("狀態") {
                    HStack(spacing: 6) {
                        StatusDot(color: statusColor)
                        Text(statusText).multilineTextAlignment(.trailing)
                    }
                }
                LabeledContent("網址") {
                    HStack {
                        Text(verbatim: baseURL).font(.body.monospaced()).textSelection(.enabled)
                        Button("拷貝") { copy(baseURL) }
                    }
                }
                TextField("API 埠", value: Bindable(settings).localAPIPort, format: .number.grouping(.never))
                LabeledContent("金鑰") {
                    HStack {
                        Text(verbatim: showKey ? key : String(repeating: "•", count: 12))
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(showKey ? LocalizedStringKey("隱藏") : LocalizedStringKey("顯示")) { showKey.toggle() }
                        Button("拷貝") { copy(key) }.disabled(key.isEmpty)
                        Button("重新產生…") { confirmRegenerate = true }
                    }
                }
                originsEditor
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("範例")
                        Spacer()
                        Button("拷貝範例") { copy(sample) }
                    }
                    Text(verbatim: sample)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("只在 Lint 執行、且使用本機模型時可用。模型一次只處理一個請求；Lint 正在用、或你正在打字時，其他請求會等候。範例裡的 $LINT_API_KEY 請換成上面的金鑰。")
                    .sectionNote()
            }
        } header: {
            Text("其他 app 使用")
        }
        .task(id: settings.localAPIEnabled) { await loadKey() }
        .alert("重新產生金鑰？", isPresented: $confirmRegenerate) {
            Button("重新產生", role: .destructive) { Task { await regenerate() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("舊的金鑰會立刻失效，使用它的 app 要改用新的金鑰。")
        }
    }

    // MARK: - Websites

    @ViewBuilder
    private var originsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("允許的網站")
            ForEach(settings.localAPIAllowedOrigins, id: \.self) { origin in
                HStack {
                    Text(verbatim: origin).font(.callout.monospaced())
                    Spacer()
                    Button("移除") { settings.localAPIAllowedOrigins.removeAll { $0 == origin } }
                        .controlSize(.small)
                }
            }
            HStack {
                TextField("https://example.com", text: $newOrigin)
                    .onSubmit(addOrigin)
                Button("加入", action: addOrigin).disabled(newOrigin.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let originError {
                Text(originError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text("網頁要用本機模型，網址必須在這份清單裡。預設只有這台 Mac 上的網頁（localhost）；加入的網站必須是 https。")
                    .sectionNote()
                if settings.localAPIAllowedOrigins != AllowedOrigin.defaults {
                    Button("恢復預設") { settings.localAPIAllowedOrigins = AllowedOrigin.defaults }
                        .controlSize(.small)
                }
            }
        }
    }

    private func addOrigin() {
        guard let origin = AllowedOrigin.normalizeUserEntry(newOrigin) else {
            originError = String(localized: "請輸入 https:// 開頭的網站，例如 https://example.com，不含路徑。")
            return
        }
        originError = nil
        newOrigin = ""
        if !settings.localAPIAllowedOrigins.contains(origin) { settings.localAPIAllowedOrigins.append(origin) }
    }

    // MARK: - State

    private var usesLocalModel: Bool { app.writingRoute == .provider(.localLlama) }

    private var statusColor: Color {
        guard usesLocalModel else { return .secondary }
        switch app.localAPI.state {
        case .listening: return .green
        case .failed: return .red
        case .off: return .secondary
        }
    }

    private var statusText: String {
        guard usesLocalModel else { return String(localized: "Lint 目前沒有使用本機模型，其他 app 暫時無法使用。") }
        switch app.localAPI.state {
        case .listening(let port): return String(localized: "已開啟，只接受這台 Mac（127.0.0.1:\(String(port))）")
        case .failed(let message): return message
        case .off: return String(localized: "未開啟")
        }
    }

    // MARK: - Key and samples

    /// The Keychain can stop to ask the user, so it is read off the main thread (made here the first time).
    private func loadKey() async {
        guard settings.localAPIEnabled else { return }
        let keys = app.localAPIKeys
        key = await Task.detached { (try? keys.current().value) ?? "" }.value
    }

    private func regenerate() async {
        let keys = app.localAPIKeys
        if let new = await Task.detached(operation: { try? keys.regenerate().value }).value { key = new }
    }

    private var sample: String {
        """
        curl \(baseURL)/chat/completions \\
          -H "Authorization: Bearer $LINT_API_KEY" \\
          -H "Content-Type: application/json" \\
          -d '{"messages":[{"role":"user","content":"Hello"}]}'

        # Python (openai)
        from openai import OpenAI
        client = OpenAI(base_url="\(baseURL)", api_key=os.environ["LINT_API_KEY"])

        // JavaScript (fetch)
        fetch("\(baseURL)/chat/completions", {method: "POST",
          headers: {"Authorization": `Bearer ${LINT_API_KEY}`, "Content-Type": "application/json"},
          body: JSON.stringify({messages: [{role: "user", content: "Hello"}]})})
        """
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

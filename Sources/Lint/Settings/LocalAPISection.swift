import AppKit
import LintCore
import SwiftUI

/// "Other apps": lets apps and web pages on this Mac use the local model through Lint's API port
/// (`LocalAPIService`), behind keys (one per app or page if the user likes), with Lint's own
/// requests always first.
struct LocalAPISection: View {
    var app: AppModel
    @State private var keys: [KeyRow] = []
    @State private var shownKeys: Set<String> = []
    @State private var newKeyName = ""
    @State private var keyError: String?
    @State private var revoking: LocalAPIKeyRecord?
    @State private var newOrigin = ""
    @State private var originError: String?

    /// A listed key and its value; nil when the Keychain would not give it.
    private struct KeyRow: Identifiable, Sendable {
        var record: LocalAPIKeyRecord
        var value: String?
        var id: String { record.id }
    }

    private enum KeyCreation: Sendable {
        case created
        case invalidName, tooMany, failed
    }

    private var settings: SettingsStore { app.settings }
    private var baseURL: String { "http://127.0.0.1:\(settings.localAPIPort)/v1" }

    var body: some View {
        Section {
            SettingsToggle(
                title: "讓其他 app 使用本機模型",
                detail: "這台 Mac 上的腳本、其他 app、瀏覽器擴充功能和自製網頁，可以用 OpenAI 相容 API 呼叫本機模型，需要下面的金鑰，只接受這台 Mac 的連線。Lint 自己要用模型時永遠優先：其他請求會等候，或被中斷後自動重送。",
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
                LabeledContent("API 埠") {
                    TextField("API 埠", value: Bindable(settings).localAPIPort, format: .number.grouping(.never))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
                keysEditor
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
                Text("只在 Lint 執行、且使用本機模型時可用。模型一次只處理一個請求；Lint 正在用、或你正在打字時，其他請求會等候。範例裡的 $LINT_API_KEY 請換成上面其中一把金鑰。")
                    .sectionNote()
            }
        } header: {
            Text("其他 app 使用")
        }
        .task(id: settings.localAPIEnabled) { await loadKeys() }
        .alert(
            "註銷金鑰？",
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            presenting: revoking
        ) { record in
            Button("註銷", role: .destructive) { Task { await revoke(record) } }
            Button("取消", role: .cancel) {}
        } message: { record in
            Text("「\(record.name)」會立刻失效，使用它的 app 或網頁要改用別的金鑰。")
        }
    }

    // MARK: - Keys

    @ViewBuilder
    private var keysEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("金鑰")
            if keys.isEmpty {
                Text("沒有金鑰，其他 app 都無法使用。").sectionNote()
            }
            ForEach(keys) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.record.name)
                        if let created = row.record.created {
                            Text("建立於 \(created.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let value = row.value {
                        let shown = shownKeys.contains(row.id)
                        Text(verbatim: shown ? value : String(repeating: "•", count: 12))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(shown ? LocalizedStringKey("隱藏") : LocalizedStringKey("顯示")) {
                            if shown { shownKeys.remove(row.id) } else { shownKeys.insert(row.id) }
                        }
                        Button("拷貝") { copy(value) }
                    } else {
                        Text("無法讀取").foregroundStyle(.secondary)
                    }
                    Button("註銷…") { revoking = row.record }
                }
            }
            HStack {
                TextField("名稱，例如 Claude Code", text: $newKeyName, prompt: Text("名稱，例如 Claude Code"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addKey)
                Button("新增 API Key", action: addKey).disabled(newKeyName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let keyError {
                Text(keyError).font(.caption).foregroundStyle(.red)
            }
            Text("可以給每個 app 或網頁各自一把金鑰；註銷一把，只有用它的 app 會立刻無法使用。")
                .sectionNote()
        }
    }

    private func addKey() {
        let name = newKeyName
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let keyring = app.localAPIKeyring
        Task {
            let outcome = await Task.detached { () -> KeyCreation in
                do {
                    try keyring.create(name: name)
                    return .created
                } catch LocalAPIKeyring.KeyringError.invalidName {
                    return .invalidName
                } catch LocalAPIKeyring.KeyringError.tooManyKeys {
                    return .tooMany
                } catch {
                    return .failed
                }
            }.value
            switch outcome {
            case .created:
                keyError = nil
                newKeyName = ""
                await loadKeys()
            case .invalidName:
                keyError = String(localized: "名稱最多 \(String(LocalAPIKeyring.maxNameLength)) 個字。")
            case .tooMany:
                keyError = String(localized: "最多 \(String(LocalAPIKeyring.maxKeys)) 把金鑰；請先註銷用不到的。")
            case .failed:
                keyError = String(localized: "無法把金鑰存進鑰匙圈。")
            }
        }
    }

    private func revoke(_ record: LocalAPIKeyRecord) async {
        let keyring = app.localAPIKeyring
        await Task.detached { keyring.revoke(id: record.id) }.value
        shownKeys.remove(record.id)
        await loadKeys()
    }

    /// The Keychain can stop to ask the user, so it is read off the main thread (the first key is
    /// made here the first time).
    private func loadKeys() async {
        guard settings.localAPIEnabled else { return }
        let keyring = app.localAPIKeyring
        keys = await Task.detached {
            let lookup = keyring.lookup()
            return keyring.records().map { record in
                KeyRow(record: record, value: lookup.keys.first { $0.id == record.id }?.key.value)
            }
        }.value
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
                TextField("https://example.com", text: $newOrigin, prompt: Text(verbatim: "https://example.com"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addOrigin)
                Button("加入", action: addOrigin).disabled(newOrigin.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let originError {
                Text(originError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text("自製網頁要用本機模型，網址必須在這份清單裡。預設只有這台 Mac 上的網頁（localhost）；架在區域網路或自己網域上的網頁，可以加入它的 http 或 https 網址，https://*.example.com 代表 example.com 底下的所有子網域。Safari 不讓 https 網頁連到這台 Mac 的 http 服務，所以 https 網頁只能在 Chrome、Brave 等瀏覽器使用。")
                    .sectionNote()
                if settings.localAPIAllowedOrigins != AllowedOrigin.defaults {
                    Button("恢復預設") { settings.localAPIAllowedOrigins = AllowedOrigin.defaults }
                        .controlSize(.small)
                }
            }
            SettingsToggle(
                title: "允許瀏覽器擴充功能使用 API",
                detail: "Chrome、Brave、Edge、Firefox 與 Safari 的擴充功能只要有金鑰就能使用，不必在上面的清單裡。擴充功能看得到你瀏覽的網頁，只把金鑰給你信任的擴充功能。",
                isOn: Bindable(settings).localAPIAllowBrowserExtensions
            )
        }
    }

    private func addOrigin() {
        guard let origin = AllowedOrigin.normalizeUserEntry(newOrigin) else {
            originError = String(localized: "請輸入 http:// 或 https:// 開頭的網站，例如 https://example.com；*. 代表所有子網域，例如 https://*.example.com。不含路徑。")
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

    // MARK: - Samples

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

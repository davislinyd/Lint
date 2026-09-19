import AppKit
import SwiftUI

struct LocalServerSettingsPane: View {
    var app: AppModel
    @State private var serverStatus: LocalLlamaServerManager.Status = .stopped
    /// Shown instead of `serverStatus` while an action is in flight.
    @State private var busyLabel: String?
    @State private var binaryState: LocalLlamaServerManager.BinaryState?
    @State private var serverMessage: String?
    @State private var localServerBusy = false
    @State private var showBrewInstallConfirm = false
    @State private var showAdvanced = false

    var body: some View {
        Form {
            statusSection
            configSection
            maintenanceSection
        }
        .formStyle(.grouped)
        .task {
            await refreshLocalServerStatus()
        }
        .alert("安裝 llama-server？", isPresented: $showBrewInstallConfirm) {
            Button("安裝", role: .none) {
                Task { await installLlamaServerViaBrew() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("會執行 brew install llama.cpp（需已安裝 Homebrew，可能需幾分鐘與網路）。完成後 Lint 會自動填入路徑。")
        }
    }

    private var isRunning: Bool {
        if case .running = serverStatus { return true }
        return false
    }

    private var statusColor: Color {
        if busyLabel != nil { return .yellow }
        switch serverStatus {
        case .stopped: return .secondary
        case .starting: return .yellow
        case .running: return .green
        case .failed: return .red
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            LabeledContent {
                HStack {
                    if localServerBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if isRunning {
                        Button("重新啟動") {
                            Task { await restartLocalServerNow() }
                        }
                        Button("停止", role: .destructive) {
                            Task { await stopLocalServerNow() }
                        }
                    } else {
                        Button("啟動") {
                            Task { await startLocalServerNow() }
                        }
                    }
                    Button {
                        Task { await refreshLocalServerStatus(showFeedback: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("重新檢查")
                }
                .disabled(localServerBusy)
            } label: {
                HStack(spacing: 6) {
                    StatusDot(color: statusColor)
                    Text(busyLabel ?? statusLabel(serverStatus))
                        .lineLimit(2)
                }
            }
            if let serverMessage {
                Text(serverMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            SettingsToggle(
                title: "自動啟動本機模型服務",
                detail: "Lint 會在需要時自動執行 llama-server（與在終端機手動跑的效果相同）。若埠上已有服務則不會重複啟動。",
                isOn: Bindable(app.settings).localServerAutoStart
            )
        } header: {
            Text("llama-server")
        }
    }

    @ViewBuilder
    private var configSection: some View {
        Section {
            TextField("llama-server 路徑", text: Bindable(app.settings).localServerBinaryPath)
            TextField("HuggingFace 模型 (-hf)", text: Bindable(app.settings).localServerHFModel)
            TextField("埠", value: Bindable(app.settings).localServerPort, format: .number.grouping(.never))
            ExpandableRow(title: "進階：額外參數", isExpanded: $showAdvanced) {
                CodeEditor(text: Bindable(app.settings).localServerExtraArgs)
                    .frame(minHeight: 56, maxHeight: 96)
                Text("建議（Apple Silicon 校對）：--jinja --no-skip-chat-parsing -ngl 99 -fa on -c 4096 -np 1 -t 6。長文可把 -c 改 8192。")
                    .sectionNote()
            }
        } header: {
            Text("設定")
        } footer: {
            Text("改完參數後請按「重新啟動」才會套用。若顯示「外部已啟動」，「啟動」不會重開行程。")
                .sectionNote()
        }
    }

    @ViewBuilder
    private var maintenanceSection: some View {
        Section("維護") {
            LabeledContent("安裝狀態") {
                switch binaryState {
                case .found:
                    Label("已安裝", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .missing:
                    HStack {
                        Text("未安裝")
                            .foregroundStyle(.secondary)
                        Button("安裝 llama-server") {
                            showBrewInstallConfirm = true
                        }
                        .disabled(localServerBusy)
                    }
                case .brewUnavailable:
                    Text("未安裝，且找不到 Homebrew")
                        .foregroundStyle(.secondary)
                case nil:
                    Text("檢查中…")
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("模型資料夾") {
                Button("在 Finder 顯示") {
                    openModelFolder()
                }
            }
        }
    }

    private func openModelFolder() {
        let hf = app.settings.localServerHFModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let folder = LocalLlamaServerManager.modelFolder(
            hfModel: hf.isEmpty ? SettingsStore.defaultLocalHFModel : hf
        ) else {
            serverMessage = "找不到模型資料夾，模型可能尚未下載"
            return
        }
        NSWorkspace.shared.open(folder)
    }

    private func refreshLocalServerStatus(showFeedback: Bool = false) async {
        refreshBinaryStatus()
        let port = app.settings.localServerPort
        await LocalLlamaServerManager.shared.refreshStatus(port: port)
        serverStatus = LocalLlamaServerManager.shared.status
        if showFeedback {
            serverMessage = "已重新檢查：\(statusLabel(serverStatus))"
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
        serverMessage = message
    }

    private func restartLocalServerNow() async {
        localServerBusy = true
        defer {
            localServerBusy = false
            busyLabel = nil
        }
        busyLabel = "重新啟動中…"
        serverMessage = "正在套用目前參數並重新啟動…"
        do {
            try await LocalLlamaServerManager.shared.restart(settings: app.settings)
            app.settings.baseURLString = "http://127.0.0.1:\(app.settings.localServerPort)/v1"
            if app.settings.providerKind != .openaiCompatible {
                app.settings.selectProvider(.openaiCompatible)
            }
            serverStatus = LocalLlamaServerManager.shared.status
            serverMessage = "已重新啟動，目前參數已生效"
        } catch {
            serverStatus = .failed(error.localizedDescription)
            serverMessage = error.localizedDescription
        }
    }

    private func refreshBinaryStatus() {
        let state = LocalLlamaServerManager.detectBinary(preferred: app.settings.localServerBinaryPath)
        binaryState = state
        if case .found(let path) = state, app.settings.localServerBinaryPath != path {
            app.settings.localServerBinaryPath = path
        }
    }

    private func installLlamaServerViaBrew() async {
        localServerBusy = true
        defer {
            localServerBusy = false
            busyLabel = nil
        }
        busyLabel = "正在 brew install llama.cpp…"
        do {
            let path = try await LocalLlamaServerManager.shared.installViaHomebrew()
            app.settings.localServerBinaryPath = path
            binaryState = .found(path: path)
            serverMessage = "llama-server 已安裝"
            await refreshLocalServerStatus()
        } catch {
            serverMessage = error.localizedDescription
            refreshBinaryStatus()
        }
    }

    private func startLocalServerNow() async {
        localServerBusy = true
        defer {
            localServerBusy = false
            busyLabel = nil
        }
        busyLabel = "啟動中…"
        do {
            let launched = try await LocalLlamaServerManager.shared.start(settings: app.settings)
            // Keep API endpoint aligned with the managed port.
            app.settings.baseURLString = "http://127.0.0.1:\(app.settings.localServerPort)/v1"
            if app.settings.providerKind != .openaiCompatible {
                app.settings.selectProvider(.openaiCompatible)
            }
            serverStatus = LocalLlamaServerManager.shared.status
            if launched {
                serverMessage = "已用目前參數啟動本機 llama-server"
            } else {
                serverMessage = "埠上已有服務在跑，未重新啟動。若剛改參數，請按「重新啟動」。"
            }
        } catch {
            serverStatus = .failed(error.localizedDescription)
            serverMessage = error.localizedDescription
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
}

import AppKit
import LintCore
import SwiftUI

/// Sections shown inside the model pane's Form when the local llama.cpp provider is selected:
/// runtime, model, server, and (collapsed) advanced options. It reports and drives
/// `LocalAISetupCoordinator`; the logic lives there.
struct LocalServerSection: View {
    var app: AppModel
    /// Shown instead of the server status while an action is in flight.
    @State private var busyLabel: String?
    @State private var serverMessage: String?
    @State private var localServerBusy = false
    @State private var showAdvanced = false
    @State private var showDetails = false
    @State private var confirmDownload = false
    @State private var confirmRemove = false

    private var coordinator: LocalAISetupCoordinator { app.localAI }

    var body: some View {
        Group {
            runtimeSection
            modelSection
            serverSection
            memorySection
            advancedSection
            maintenanceSection
        }
        .task {
            await coordinator.refresh()
        }
        .alert("下載模型？", isPresented: $confirmDownload) {
            Button("下載並安裝") { coordinator.installModel() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(downloadConfirmation)
        }
        .alert("移除模型？", isPresented: $confirmRemove) {
            Button("移除", role: .destructive) { Task { await coordinator.removeModel() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("會刪除已下載的模型檔案，並停止本機服務。之後可以再下載。")
        }
    }

    // MARK: - Runtime

    @ViewBuilder
    private var runtimeSection: some View {
        Section {
            LabeledContent("執行環境") {
                if !coordinator.hasChecked {
                    Text("檢查中…").foregroundStyle(.secondary)
                } else if let location = coordinator.runtime.location {
                    VStack(alignment: .trailing, spacing: 2) {
                        Label("已就緒", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(runtimeDetail(location))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("無法使用", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if let message = coordinator.runtime.userMessage {
                Text(message).sectionNote()
            }
        } header: {
            Text("本機 AI")
        }
    }

    private func runtimeDetail(_ location: LlamaRuntimeLocation) -> String {
        switch location.origin {
        case .bundled:
            let version = location.info?.displayVersion ?? "llama.cpp"
            return String(localized: "Lint 內建・\(version)")
        case .custom:
            return String(localized: "自訂：\(location.binaryURL.path)")
        case .externalFallback:
            return String(localized: "外部安裝的 llama-server：\(location.binaryURL.path)")
        }
    }

    // MARK: - Model

    @ViewBuilder
    private var modelSection: some View {
        Section {
            if coordinator.configuration.modelSource == .managed {
                modelPicker
                if coordinator.configuration.managedModel.memoryClass == .large {
                    Label(Self.largeModelWarning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                managedModelRows
            } else {
                LabeledContent("模型") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("自訂（Hugging Face）")
                        Text(coordinator.configuration.effectiveHuggingFaceSpec)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text("模型")
        }
    }

    static let largeModelWarning = String(localized: "這個模型很大，執行時會佔用大量記憶體；在 16 GB 的 Mac 上可能讓系統變得非常緩慢，甚至當機。記憶體吃緊時請改用 Gemma 4 E4B 或 Apple Intelligence。")

    /// The models Lint can manage, recommended first. Switching is only a choice here: nothing is
    /// downloaded or deleted until the buttons below are used.
    @ViewBuilder
    private var modelPicker: some View {
        Picker("模型", selection: Bindable(app.settings).localManagedModelID) {
            ForEach(ModelCatalog.all) { model in
                Text(pickerLabel(for: model)).tag(model.id)
            }
        }
        .onChange(of: app.settings.localManagedModelID) { _, _ in
            Task { await coordinator.managedModelChanged() }
        }
    }

    private func pickerLabel(for model: ModelDescriptor) -> String {
        var notes: [String] = []
        if model.recommended { notes.append(String(localized: "建議")) }
        if model.memoryClass == .large { notes.append(String(localized: "記憶體用量很高，可能當機")) }
        if coordinator.installedModelIDs.contains(model.id) {
            notes.append(String(localized: "已安裝"))
        } else if let size = model.totalBytes {
            notes.append(String(localized: "需下載 \(ModelInstallError.formatBytes(size))"))
        }
        return "\(model.displayName)（\(notes.joined(separator: "・"))）"
    }

    @ViewBuilder
    private var managedModelRows: some View {
        let model = coordinator.configuration.managedModel
        LabeledContent {
            HStack {
                modelButtons
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                HStack(spacing: 6) {
                    StatusDot(color: modelStatusColor)
                    Text(modelStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        if coordinator.state == .modelDownloading {
            downloadProgress
        }
        switch coordinator.downloadState {
        case .failed(let error):
            Text(error.localizedDescription)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .cancelled where coordinator.partialBytes > 0:
            Text("下載已取消。已下載的 \(ModelInstallError.formatBytes(coordinator.partialBytes)) 會保留，繼續下載會從中斷處接續。")
                .sectionNote()
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var modelButtons: some View {
        if coordinator.state == .modelDownloading {
            Button("取消") { coordinator.cancelInstall() }
        } else {
            switch coordinator.model {
            case .installed:
                Button("在 Finder 顯示") { openModelFolder() }
                Button("移除", role: .destructive) { confirmRemove = true }
            case .notInstalled, .invalid:
                Button(downloadButtonTitle) { confirmDownload = true }
            }
        }
    }

    private var downloadButtonTitle: LocalizedStringKey {
        switch coordinator.downloadState {
        case .failed: return "重試"
        case .cancelled: return "繼續下載"
        default:
            if case .invalid = coordinator.model { return "重新下載" }
            return "下載"
        }
    }

    private var modelStatusText: String {
        if coordinator.state == .modelDownloading { return String(localized: "下載中…") }
        switch coordinator.model {
        case .installed: return String(localized: "已安裝")
        case .invalid: return String(localized: "不完整或已損毀，需要重新下載")
        case .notInstalled:
            if let size = coordinator.configuration.managedModel.totalBytes {
                return String(localized: "尚未安裝（約 \(ModelInstallError.formatBytes(size))）")
            }
            return String(localized: "尚未安裝")
        }
    }

    private var modelStatusColor: Color {
        if coordinator.state == .modelDownloading { return .yellow }
        switch coordinator.model {
        case .installed: return .green
        case .invalid: return .red
        case .notInstalled: return .secondary
        }
    }

    @ViewBuilder
    private var downloadProgress: some View {
        switch coordinator.downloadState {
        case .downloading(let received, let total):
            if let total, total > 0 {
                ProgressView(value: Double(min(received, total)), total: Double(total))
                Text("已下載 \(ModelInstallError.formatBytes(received)) / \(ModelInstallError.formatBytes(total))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text("已下載 \(ModelInstallError.formatBytes(received))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .verifying:
            ProgressView()
            Text("正在驗證下載的檔案…").font(.caption).foregroundStyle(.secondary)
        case .installing:
            ProgressView()
            Text("正在安裝…").font(.caption).foregroundStyle(.secondary)
        default:
            ProgressView()
        }
    }

    private var downloadConfirmation: String {
        let model = coordinator.configuration.managedModel
        guard let size = model.totalBytes else {
            return String(localized: "\(model.displayName) 會下載到你的 Mac，之後在本機執行。")
        }
        let space = ModelInstallError.formatBytes(Int64((Double(size) * 1.2).rounded(.up)))
        return String(localized: "\(model.displayName)：下載約 \(ModelInstallError.formatBytes(size))，需要約 \(space) 的可用空間。只有下載時需要網路，模型在你的 Mac 上執行。")
    }

    // MARK: - Server

    private var isRunning: Bool {
        if case .running = coordinator.serverStatus { return true }
        return false
    }

    private var serverStatusColor: Color {
        if busyLabel != nil { return .yellow }
        switch coordinator.serverStatus {
        case .stopped: return .secondary
        case .starting: return .yellow
        case .running: return .green
        case .failed: return .red
        }
    }

    @ViewBuilder
    private var serverSection: some View {
        Section {
            LabeledContent {
                HStack {
                    if localServerBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if isRunning {
                        Button("重新啟動") {
                            Task { await restartServerNow() }
                        }
                        Button("停止", role: .destructive) {
                            Task { await stopServerNow() }
                        }
                    } else {
                        Button("啟動") {
                            Task { await startServerNow() }
                        }
                        .disabled(!canStart)
                    }
                    Button {
                        Task { await refreshNow() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("重新檢查")
                }
                .disabled(localServerBusy)
            } label: {
                HStack(spacing: 6) {
                    StatusDot(color: serverStatusColor)
                    Text(busyLabel ?? statusLabel(coordinator.serverStatus))
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
            Text("服務")
        }
    }

    /// Starting needs a working runtime and, for a managed model, the model.
    private var canStart: Bool {
        coordinator.runtimeReady && coordinator.modelReady
    }

    // MARK: - Memory

    @ViewBuilder
    private var memorySection: some View {
        Section {
            Picker("閒置後釋放", selection: Bindable(app.settings).localServerIdleSleep) {
                ForEach(IdleSleepOption.allCases) { option in
                    Text(idleSleepTitle(option)).tag(option)
                }
            }
            Text("閒置一段時間沒有使用本機 AI 時，Lint 會請 llama-server 釋放模型佔用的記憶體；服務本身仍在執行。下一次的建議會多花幾秒重新載入模型。")
                .sectionNote()
        } header: {
            Text("記憶體")
        }
        .onChange(of: app.settings.localServerIdleSleep) { _, _ in
            serverMessage = String(localized: "按「重新啟動」後新的閒置設定才會生效。")
        }
    }

    private func idleSleepTitle(_ option: IdleSleepOption) -> String {
        switch option {
        case .never: return String(localized: "永不釋放")
        case .oneMinute: return String(localized: "1 分鐘")
        case .fiveMinutes: return String(localized: "5 分鐘")
        case .tenMinutes: return String(localized: "10 分鐘")
        case .thirtyMinutes: return String(localized: "30 分鐘")
        }
    }

    // MARK: - Advanced

    @ViewBuilder
    private var advancedSection: some View {
        Section {
            TextField("埠", value: Bindable(app.settings).localServerPort, format: .number.grouping(.never))
            ExpandableRow(title: "進階", isExpanded: $showAdvanced) {
                Picker("模型來源", selection: Bindable(app.settings).localModelSource) {
                    Text("由 Lint 下載與管理").tag(LocalModelSource.managed)
                    Text("自訂（Hugging Face -hf）").tag(LocalModelSource.custom)
                }
                if app.settings.localModelSource == .custom {
                    TextField("模型 (HuggingFace -hf)", text: Bindable(app.settings).model)
                    Text("llama-server 會自己下載這個模型到 Hugging Face 快取（首次啟動較久）。")
                        .sectionNote()
                }
                Picker("執行環境來源", selection: Bindable(app.settings).localRuntimeSource) {
                    Text("自動（Lint 內建）").tag(LocalRuntimeSource.automatic)
                    Text("自訂 llama-server").tag(LocalRuntimeSource.custom)
                }
                if app.settings.localRuntimeSource == .custom {
                    TextField("llama-server 路徑", text: Bindable(app.settings).localServerBinaryPath)
                    Text("例如自行編譯或用 Homebrew 安裝的 llama-server。這是進階相容選項，一般使用不需要。")
                        .sectionNote()
                }
                Text("額外參數")
                CodeEditor(text: Bindable(app.settings).localServerExtraArgs)
                    .frame(minHeight: 56, maxHeight: 96)
                Text("留空即可：Lint 會依所選模型套用自己的參數（目前為 \(tuningSummary)）。這裡填的參數會覆蓋同一個選項，例如長文可填 -c 8192。服務一律只綁定 127.0.0.1，額外參數裡的 --host 會被忽略。")
                    .sectionNote()
            }
        } header: {
            Text("設定")
        } footer: {
            Text("改完參數後請按「重新啟動」才會套用。若顯示「外部已啟動」，「啟動」不會重開行程。")
                .sectionNote()
        }
        .onChange(of: app.settings.localModelSource) { _, _ in Task { await coordinator.refresh() } }
        .onChange(of: app.settings.localRuntimeSource) { _, _ in Task { await coordinator.refresh() } }
        .onChange(of: app.settings.localServerBinaryPath) { _, _ in Task { await coordinator.refresh() } }
    }

    @ViewBuilder
    private var maintenanceSection: some View {
        Section("維護") {
            LabeledContent("模型資料夾") {
                Button("在 Finder 顯示") {
                    openModelFolder()
                }
            }
            if !coordinator.serverLogTail.isEmpty {
                ExpandableRow(title: "詳細資訊", isExpanded: $showDetails) {
                    Text(coordinator.serverLogTail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// What Lint would pass llama-server right now, so the override field can be understood
    /// without guessing. Built from the same code that launches the server.
    private var tuningSummary: String {
        let configuration = coordinator.configuration
        return LlamaServerLaunchPlan.tuningArguments(
            profile: configuration.runtimeProfile,
            idleSleepSeconds: configuration.idleSleepSeconds,
            overriddenBy: []
        ).joined(separator: " ")
    }

    // MARK: - Actions

    private func openModelFolder() {
        let folder: URL?
        switch app.settings.localModelSource {
        case .managed:
            let directory = coordinator.paths.modelsDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            folder = directory
        case .custom:
            folder = HuggingFaceCache.modelFolder(spec: coordinator.configuration.effectiveHuggingFaceSpec)
        }
        guard let folder else {
            serverMessage = String(localized: "找不到模型資料夾，模型可能尚未下載")
            return
        }
        NSWorkspace.shared.open(folder)
    }

    private func refreshNow() async {
        await coordinator.refresh()
        serverMessage = String(localized: "已重新檢查：\(statusLabel(coordinator.serverStatus))")
    }

    private func stopServerNow() async {
        localServerBusy = true
        defer { localServerBusy = false }
        serverMessage = await coordinator.stopServer()
    }

    private func restartServerNow() async {
        localServerBusy = true
        defer {
            localServerBusy = false
            busyLabel = nil
        }
        busyLabel = String(localized: "重新啟動中…")
        serverMessage = String(localized: "正在套用目前參數並重新啟動…")
        do {
            try await coordinator.restartServer()
            serverMessage = String(localized: "已重新啟動，目前參數已生效")
        } catch {
            serverMessage = error.localizedDescription
        }
    }

    private func startServerNow() async {
        localServerBusy = true
        defer {
            localServerBusy = false
            busyLabel = nil
        }
        busyLabel = String(localized: "啟動中…")
        do {
            try await coordinator.startServer()
            serverMessage = String(localized: "本機 llama-server 已啟動")
        } catch {
            serverMessage = error.localizedDescription
        }
    }

    private func statusLabel(_ status: LocalServerStatus) -> String {
        switch status {
        case .stopped:
            return String(localized: "未運行")
        case .starting:
            return String(localized: "啟動中（首次載入模型會較久）…")
        case .running(_, let managed):
            return managed ? String(localized: "運行中（由 Lint 管理）") : String(localized: "運行中（外部已啟動）")
        case .failed(let message):
            return message
        }
    }
}

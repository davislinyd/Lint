import AppKit
import LintCore
import SwiftUI

/// The first-run "Set Up Local AI" screen. It only shows what `LocalAISetupCoordinator` reports and
/// forwards the user's clicks to it; downloading, verifying and starting all happen there.
struct LocalAISetupView: View {
    var app: AppModel
    var onClose: () -> Void
    /// Whether the download consent card is showing (before any download starts).
    @State private var showingConsent = false

    private var coordinator: LocalAISetupCoordinator { app.localAI }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            statusRows
            Divider()
            content
            Spacer(minLength: 0)
            buttons
        }
        .padding(28)
        .frame(width: 520, height: 560)
        .task { await coordinator.refresh() }
    }

    // MARK: - Header and status

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("歡迎使用 Lint")
                    .font(.title2.bold())
                Text("在你的 Mac 上本機執行 AI 校對，文字不會離開這台電腦。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            SetupStatusRow(title: "本機 AI 執行環境", detail: runtimeDetail, mark: runtimeMark)
            SetupStatusRow(title: "AI 模型", detail: modelDetail, mark: modelMark)
            SetupStatusRow(
                title: "輔助功能",
                detail: coordinator.accessibilityTrusted ? String(localized: "已啟用") : String(localized: "尚未啟用"),
                mark: coordinator.accessibilityTrusted ? .done : .pending
            )
        }
    }

    private var runtimeDetail: String {
        switch coordinator.runtime {
        case .ready(let location):
            switch location.origin {
            case .bundled:
                let version = location.info?.displayVersion ?? "llama.cpp"
                return String(localized: "已就緒・Lint 內建 \(version)")
            case .custom: return String(localized: "已就緒・自訂 llama-server")
            case .externalFallback: return String(localized: "已就緒・外部安裝的 llama-server")
            }
        case .missing, .invalid:
            return String(localized: "無法使用")
        }
    }

    private var runtimeMark: SetupStatusRow.Mark {
        guard coordinator.hasChecked else { return .working }
        return coordinator.runtimeReady ? .done : .problem
    }

    private var modelDetail: String {
        if coordinator.configuration.modelSource == .custom { return String(localized: "自訂（Hugging Face）") }
        switch coordinator.state {
        case .modelDownloading: return String(localized: "下載中…")
        case .modelInvalid: return String(localized: "需要重新下載")
        default: break
        }
        if case .installed = coordinator.model { return String(localized: "已安裝・\(coordinator.configuration.managedModel.displayName)") }
        return String(localized: "尚未安裝")
    }

    private var modelMark: SetupStatusRow.Mark {
        guard coordinator.hasChecked else { return .working }
        if coordinator.state == .modelDownloading { return .working }
        if case .modelInvalid = coordinator.state { return .problem }
        return coordinator.modelReady ? .done : .pending
    }

    // MARK: - Main content

    @ViewBuilder
    private var content: some View {
        switch coordinator.state {
        case .checking:
            ProgressView("檢查中…")
        case .runtimeMissing, .runtimeInvalid:
            problemCard(
                coordinator.runtime.userMessage ?? "",
                hint: "你也可以在設定裡改用其他模型來源，例如 OpenAI 相容端點。"
            )
        case .modelMissing, .modelInvalid:
            if showingConsent {
                consentCard
            } else {
                modelNeededCard
            }
        case .modelDownloading:
            downloadCard
        case .serverStarting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在啟動本機 AI（第一次載入模型需要一點時間）…")
                    .foregroundStyle(.secondary)
            }
        case .serverStopped:
            Text("本機 AI 已準備好，但目前沒有執行。")
                .foregroundStyle(.secondary)
        case .failed(let message):
            problemCard(message, hint: nil)
        case .serverReady:
            readyCard
        }
    }

    private func problemCard(_ message: String, hint: LocalizedStringKey?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if let hint {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modelNeededCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .modelInvalid = coordinator.state {
                Label("已安裝的模型不完整或已損毀，需要重新下載。", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Text("Lint 需要一個 AI 模型才能在本機運作。模型不在 App 裡，安裝前會先詢問你。")
            }
            downloadOutcomeNote
        }
    }

    /// What happened to the last attempt, shown next to the retry button.
    @ViewBuilder
    private var downloadOutcomeNote: some View {
        switch coordinator.downloadState {
        case .failed(let error):
            Label(error.localizedDescription, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .cancelled:
            Text(coordinator.partialBytes > 0
                 ? String(localized: "下載已取消。已下載的 \(ModelInstallError.formatBytes(coordinator.partialBytes)) 會保留，繼續下載會從中斷處接續。")
                 : String(localized: "下載已取消。"))
                .font(.callout)
                .foregroundStyle(.secondary)
        default:
            // e.g. after the app was quit or crashed mid-download: the partial file is still there.
            if coordinator.partialBytes > 0 {
                Text("先前已下載的 \(ModelInstallError.formatBytes(coordinator.partialBytes)) 會保留，再次下載會從中斷處接續。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var consentCard: some View {
        let model = coordinator.configuration.managedModel
        let size = model.totalBytes
        return VStack(alignment: .leading, spacing: 12) {
            Text(model.displayName)
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                if let size {
                    bullet(String(localized: "下載大小：約 \(ModelInstallError.formatBytes(size))"))
                    bullet(String(localized: "需要的可用磁碟空間：約 \(ModelInstallError.formatBytes(Int64((Double(size) * 1.2).rounded(.up))))"))
                }
                if let available = try? SystemDiskSpaceProvider().availableBytes(at: coordinator.paths.root) {
                    bullet(String(localized: "這台 Mac 目前可用：\(ModelInstallError.formatBytes(available))"))
                }
                bullet(String(localized: "授權：\(model.license)"))
                bullet(String(localized: "模型在你的 Mac 上執行，你的文字不會傳到任何伺服器。"))
                bullet(String(localized: "只有下載與安裝時需要網路。"))
                bullet(String(localized: "檔案存放在 ~/Library/Application Support/Lint/Models，可隨時在設定移除。"))
            }
            .font(.callout)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch coordinator.downloadState {
            case .downloading(let received, let total):
                if let total, total > 0 {
                    ProgressView(value: Double(min(received, total)), total: Double(total))
                    let percent = "\(Int((Double(received) / Double(total) * 100).rounded(.down)))%"
                    Text("已下載 \(ModelInstallError.formatBytes(received)) / \(ModelInstallError.formatBytes(total))（\(percent)）")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView() // no total known: an honest indeterminate bar, not a made-up percentage
                    Text("已下載 \(ModelInstallError.formatBytes(received))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            case .verifying:
                ProgressView()
                Text("正在驗證下載的檔案…").foregroundStyle(.secondary)
            case .installing:
                ProgressView()
                Text("正在安裝…").foregroundStyle(.secondary)
            default:
                ProgressView()
                Text("正在準備下載…").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var readyCard: some View {
        if coordinator.accessibilityTrusted {
            VStack(alignment: .leading, spacing: 8) {
                Label("一切就緒", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text("選取一段文字，按 ⌥⌘K 就能開始校對。")
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("最後一步：允許 Lint 讀取與取代文字")
                    .font(.headline)
                Text("Lint 需要 macOS 的「輔助功能」權限，才能讀取你選取的文字並替換成建議。授權後這個畫面會自動更新。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Buttons

    private var buttons: some View {
        HStack {
            switch coordinator.state {
            case .modelMissing, .modelInvalid:
                if showingConsent {
                    Button("取消") { showingConsent = false }
                    Spacer()
                    Button("下載並安裝") {
                        showingConsent = false
                        coordinator.installModel()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("稍後") { later() }
                    Spacer()
                    Button(primaryModelButtonTitle) { showingConsent = true }
                        .keyboardShortcut(.defaultAction)
                }
            case .modelDownloading:
                Spacer()
                Button("取消下載") { coordinator.cancelInstall() }
            case .runtimeMissing, .runtimeInvalid:
                Button("關閉") { onClose() }
                Spacer()
                Button("開啟設定") {
                    onClose()
                    app.openSettings()
                }
                .keyboardShortcut(.defaultAction)
            case .serverStopped:
                Button("稍後") { later() }
                Spacer()
                Button("啟動本機 AI") { Task { try? await coordinator.startServer() } }
                    .keyboardShortcut(.defaultAction)
            case .failed:
                Button("稍後") { later() }
                Spacer()
                Button("再試一次") { Task { try? await coordinator.startServer() } }
                    .keyboardShortcut(.defaultAction)
            case .serverReady:
                if coordinator.accessibilityTrusted {
                    Spacer()
                    Button("完成") { onClose() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("稍後") { later() }
                    Spacer()
                    Button("手動打開系統設定") { AccessibilityPermission.openSystemSettings() }
                        .buttonStyle(.link)
                    Button("授權輔助功能") { AccessibilityPermission.prompt() }
                        .keyboardShortcut(.defaultAction)
                }
            case .checking, .serverStarting:
                Spacer()
            }
        }
    }

    private var primaryModelButtonTitle: LocalizedStringKey {
        switch coordinator.downloadState {
        case .failed: return "重試"
        case .cancelled: return "繼續下載"
        default:
            if case .modelInvalid = coordinator.state { return "重新下載" }
            return "設定本機 AI"
        }
    }

    private func later() {
        app.settings.localAISetupDeferred = true
        onClose()
    }
}

private struct SetupStatusRow: View {
    enum Mark { case done, pending, working, problem }

    let title: LocalizedStringKey
    let detail: String
    let mark: Mark

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch mark {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
                case .problem: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .working: ProgressView().controlSize(.small)
                }
            }
            .frame(width: 20)
            Text(title)
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

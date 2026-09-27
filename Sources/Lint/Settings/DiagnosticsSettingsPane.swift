import AppKit
import LintCore
import SwiftUI

/// Settings → Diagnostics: the diagnostic log (`DiagnosticLog`), to read or to hand to a developer.
struct DiagnosticsSettingsPane: View {
    var app: AppModel
    @State private var text = ""
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                if text.isEmpty {
                    Text("還沒有記錄。")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(text)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id(Self.end)
                        }
                        .frame(minHeight: 280)
                        .onAppear { proxy.scrollTo(Self.end, anchor: .bottom) }
                        .onChange(of: text) { proxy.scrollTo(Self.end, anchor: .bottom) }
                    }
                }
                HStack {
                    Button("拷貝", action: copy).disabled(text.isEmpty)
                    Button("在 Finder 顯示", action: reveal)
                    Spacer()
                    Button("重新整理", action: reload)
                    Button("清除記錄…", role: .destructive) { confirmClear = true }
                        .disabled(text.isEmpty)
                }
            } header: {
                Text("記錄")
            } footer: {
                Text("記錄 Lint 做了什麼、結果如何（擷取、取代、模型請求、本機伺服器、錯誤），不含你的文字。只存在這台 Mac，Lint 不會自動送出。每個檔案滿 1 MB 就換新檔，只保留最近兩個。「拷貝」會附上版本與系統資訊，以及最近 1000 行。")
                    .sectionNote()
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .confirmationDialog("清除所有記錄？", isPresented: $confirmClear) {
            Button("清除", role: .destructive) {
                DiagnosticLog.shared.clear()
                reload()
            }
        }
    }

    private static let end = "end"

    private func reload() {
        text = DiagnosticLog.shared.recentLines()
    }

    /// The log with what a developer asks first: which Lint, which Mac, which engine and model.
    private func copy() {
        let local = app.settings.localAIConfiguration
        let model = local.modelSource == .managed ? local.managedModel.id : local.effectiveHuggingFaceSpec
        let header = """
        Lint \(AppVersion.short) (\(AppVersion.build)) · \(DiagnosticLog.systemSummary)
        Engine: \(app.settings.providerKind.rawValue) · local model: \(model)
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(header + "\n\n" + DiagnosticLog.shared.recentLines(), forType: .string)
    }

    private func reveal() {
        guard let file = DiagnosticLog.shared.currentFileURL else { return }
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            NSWorkspace.shared.open(file.deletingLastPathComponent())
        }
    }
}

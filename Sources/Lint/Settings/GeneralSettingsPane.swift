import KeyboardShortcuts
import SwiftUI

struct GeneralSettingsPane: View {
    var app: AppModel
    @State private var showPermissionSteps = true

    var body: some View {
        Form {
            accessibilitySection
            behaviorSection
            hotkeySection
            languageSection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var accessibilitySection: some View {
        Section {
            LabeledContent {
                HStack {
                    if !app.accessibilityTrusted {
                        Button("要求授權") {
                            AccessibilityPermission.prompt()
                        }
                        Button("打開系統設定") {
                            _ = AccessibilityPermission.openSystemSettings()
                        }
                    }
                    Button("重新檢查") {
                        app.accessibilityTrusted = AccessibilityPermission.isTrusted
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    StatusDot(color: app.accessibilityTrusted ? .green : .orange)
                    Text(app.accessibilityTrusted ? String(localized: "已授權") : String(localized: "未授權"))
                }
            }
            if !app.accessibilityTrusted {
                ExpandableRow(title: "設定步驟", isExpanded: $showPermissionSteps) {
                    Text("請在「輔助功能」列表刪除所有舊的 Lint，按「＋」選 /Applications/Lint.app 後勾選。不要勾到 git/dist 底下的舊副本。")
                        .sectionNote()
                    Text(AccessibilityPermission.currentAppPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("輔助功能")
        } footer: {
            Text("Lint 需要輔助功能才能讀取各 App 的選取文字。未授權時會改用模擬 ⌘C 的剪貼簿備援。")
                .sectionNote()
        }
    }

    @ViewBuilder
    private var behaviorSection: some View {
        Section("檢查行為") {
            SettingsToggle(
                title: "選取後顯示檢查按鈕",
                detail: "反白文字後出現小顆「檢查」按鈕，點了才開始建議；快捷鍵仍可直接開啟。",
                isOn: Bindable(app.settings).autoSuggestOnSelection
            )
            SettingsToggle(
                title: "打字時即時監看（英文為主）",
                detail: "停頓約 0.5 秒後預先準備建議。僅英文為主的片段會觸發，快捷鍵不受此限。",
                isOn: Bindable(app.settings).liveWatchWhileTyping
            )
            SettingsToggle(
                title: "在輸入框旁顯示「已就緒」浮標",
                detail: "關閉後仍在背景預載建議，但不會浮在輸入框上擋字；準備好後用快捷鍵開啟迷你浮窗。",
                isOn: Bindable(app.settings).showReadyChipNearField
            )
        }
    }

    @ViewBuilder
    private var hotkeySection: some View {
        Section {
            KeyboardShortcuts.Recorder("改善選取文字", name: .improveText)
            KeyboardShortcuts.Recorder("執行檢查（不需滑鼠）", name: .checkSuggestion)
        } header: {
            Text("快捷鍵")
        } footer: {
            Text("打完字後按「執行檢查」即可套用「已就緒」建議，不必點按鈕。中英文皆可用。")
                .sectionNote()
        }
    }

    @ViewBuilder
    private var languageSection: some View {
        Section {
            Picker("介面語言", selection: Bindable(app.settings).appLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    languageName(language).tag(language)
                }
            }
            if app.settings.appLanguage != app.settings.launchAppLanguage {
                LabeledContent("需要重新啟動才會套用") {
                    Button("立即重新啟動") {
                        app.relaunch()
                    }
                }
            }
        } header: {
            Text("語言")
        } footer: {
            Text("重新啟動 Lint 後才會切換語言；若使用本機模型，重新啟動時模型服務會一併重載。")
                .sectionNote()
        }
    }

    private func languageName(_ language: AppLanguage) -> Text {
        switch language {
        case .system: Text("跟隨系統")
        case .zhHant: Text(verbatim: "繁體中文")
        case .en: Text(verbatim: "English")
        }
    }
}

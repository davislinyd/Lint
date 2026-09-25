import KeyboardShortcuts
import LintCore
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
            updateSection
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
            Picker("翻譯語言", selection: Bindable(app.settings).translationLanguage) {
                ForEach(TranslationLanguage.allCases) { language in
                    Text(verbatim: language.englishName).tag(language)
                }
            }
        } header: {
            Text("語言")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("重新啟動 Lint 後才會切換語言；若使用本機模型，重新啟動時模型服務會一併重載。")
                    .sectionNote()
                Text("「翻譯」模式與建議下方的參考譯文都用翻譯語言，立即生效。Lint 只把英文翻成這個語言，不會翻成英文。")
                    .sectionNote()
            }
        }
    }

    @ViewBuilder
    private var updateSection: some View {
        Section {
            Picker("更新方式", selection: Bindable(app.settings).updateMode) {
                ForEach(UpdateMode.allCases) { mode in
                    Text(updateModeTitle(mode)).tag(mode)
                }
            }
            Picker("檢查頻率", selection: Bindable(app.settings).updateFrequency) {
                ForEach(UpdateCheckFrequency.allCases) { frequency in
                    Text(updateFrequencyTitle(frequency)).tag(frequency)
                }
            }
            LabeledContent("更新狀態") {
                Text(app.updates.statusText)
                    .foregroundStyle(.secondary)
            }
            if let lastCheck = app.updates.lastCheckText {
                LabeledContent("上次檢查") {
                    Text(lastCheck)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("立即檢查") {
                    app.updates.checkNow()
                }
                .disabled(app.updates.isBusy)
                if app.updates.showsInstallButton {
                    Button("下載並安裝") {
                        app.updates.installNow()
                    }
                }
                if app.updates.showsReleasePage {
                    Button("打開釋出頁面") {
                        app.updates.openReleasePage()
                    }
                }
            }
        } header: {
            Text("更新")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("到時間會檢查 GitHub 上的正式版。自動更新會在建議視窗關閉後換上新版並重新啟動；手動更新要按「下載並安裝」；只檢查只顯示結果。")
                    .sectionNote()
                Text("選單的「檢查更新…」不受頻率限制。")
                    .sectionNote()
            }
        }
    }

    private func updateModeTitle(_ mode: UpdateMode) -> LocalizedStringKey {
        switch mode {
        case .automatic: "自動更新"
        case .manual: "手動更新"
        case .checkOnly: "只檢查"
        }
    }

    private func updateFrequencyTitle(_ frequency: UpdateCheckFrequency) -> LocalizedStringKey {
        switch frequency {
        case .launch: "每次啟動"
        case .daily: "每天"
        case .weekly: "每週"
        case .monthly: "每月"
        }
    }

    private func languageName(_ language: AppLanguage) -> Text {
        if let name = language.englishName { return Text(verbatim: name) }
        return Text("跟隨系統")
    }
}

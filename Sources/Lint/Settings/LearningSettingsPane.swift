import LintCore
import SwiftUI

struct LearningSettingsPane: View {
    var app: AppModel
    @State private var stats = LearningStats.empty
    @State private var confirmReset = false
    @State private var showMemories = false

    var body: some View {
        Form {
            Section {
                SettingsToggle(
                    title: "啟用個人化學習",
                    detail: "記住你反覆修正的寫作習慣，之後在相關時提醒模型。資料只存在這台 Mac，只記抽象的規則，不記原文。Lint 認不出中文人名或全小寫的英文名，被你修正過的名字仍可能被記下；可在「管理記憶」查看並刪除。",
                    isOn: Bindable(app.settings).learningEnabled
                )
            } footer: {
                Text("關閉時，Lint 的行為與沒有這個功能時完全相同。")
                    .sectionNote()
            }

            Section("學習資料") {
                LabeledContent("啟用中的記憶") {
                    Text("\(stats.count(.active) + stats.count(.pinned))")
                }
                LabeledContent("候選記憶") {
                    Text("\(stats.count(.candidate))")
                }
                Button("管理記憶…") {
                    showMemories = true
                }
                Button("重設學習資料庫…", role: .destructive) {
                    confirmReset = true
                }
            }
        }
        .formStyle(.grouped)
        .task {
            stats = await app.learning.stats()
        }
        .onChange(of: app.settings.learningEnabled) {
            Task {
                await app.learning.prepare(config: app.settings.learningConfig)
                stats = await app.learning.stats()
            }
        }
        .sheet(isPresented: $showMemories) {
            Task { stats = await app.learning.stats() }
        } content: {
            MemoryManagementView(app: app)
        }
        .confirmationDialog("重設學習資料庫？", isPresented: $confirmReset) {
            Button("重設", role: .destructive) {
                Task {
                    await app.learning.resetAll()
                    stats = await app.learning.stats()
                }
            }
        } message: {
            Text("這會刪除所有已學到的記憶與回饋紀錄，無法復原。")
        }
    }
}

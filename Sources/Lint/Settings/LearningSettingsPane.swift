import LintCore
import SwiftUI

struct LearningSettingsPane: View {
    var app: AppModel
    @State private var stats = LearningStats.empty
    @State private var confirmReset = false
    @State private var showMemories = false
    @State private var organizing = false
    @State private var organizeOutcome: MemoryOrganizationOutcome?

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

            Section {
                LabeledContent("上次整理") {
                    if let organized = stats.lastOrganizedAt {
                        Text(organized.formatted(.relative(presentation: .named)))
                    } else {
                        Text("尚未整理")
                    }
                }
                LabeledContent("核心記憶") {
                    Text("\(stats.count(.core))")
                }
                LabeledContent("一般記憶") {
                    Text("\(stats.count(.generalized))")
                }
                LabeledContent("具體記憶") {
                    Text("\(stats.count(.specific))")
                }
                LabeledContent("已被涵蓋的記憶") {
                    Text("\(stats.supersededCount)")
                }
                HStack {
                    Button("立即整理記憶") {
                        organize()
                    }
                    .disabled(!app.settings.learningEnabled || organizing)
                    if organizing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let organizeOutcome {
                    organizeMessage(organizeOutcome)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("記憶整理")
            } footer: {
                Text("把相近的具體記憶歸納成較少的一般規則。原本的記憶都會保留，隨時可還原；整理只在這台 Mac 上進行，不會連線。")
                    .sectionNote()
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

    private func organize() {
        Task {
            organizing = true
            organizeOutcome = await app.learning.organizeMemories(config: app.settings.learningConfig)
            stats = await app.learning.stats()
            organizing = false
        }
    }

    @ViewBuilder
    private func organizeMessage(_ outcome: MemoryOrganizationOutcome) -> some View {
        switch outcome {
        case .finished(_, _, _, let rules, let covered) where rules == 0 && covered == 0:
            Text("沒有需要整理的記憶。")
        case .finished(_, _, _, let rules, let covered):
            Text("已整理：新增 \(rules) 條一般記憶，涵蓋 \(covered) 條具體記憶。")
        case .alreadyRunning:
            Text("整理正在進行中。")
        case .failed:
            Text("整理失敗，稍後會再試。")
        case .unavailable:
            EmptyView()
        }
    }
}

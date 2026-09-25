import LintCore
import SwiftUI

struct MemorySettingsPane: View {
    var app: AppModel
    @State private var stats = MemoryStats.empty
    @State private var confirmReset = false
    @State private var showMemories = false
    @State private var dreaming = false
    @State private var dreamOutcome: DreamOutcome?

    var body: some View {
        Form {
            Section {
                SettingsToggle(
                    title: "啟用記憶",
                    detail: "記下你修正過的寫作習慣，下一次建議就開始提醒模型；沒有再出現的會在作夢時忘記。資料只存在這台 Mac，只記抽象的規則，不記原文。Lint 認不出中文人名或全小寫的英文名，被你修正過的名字仍可能被記下；可在「管理記憶」查看並刪除。",
                    isOn: Bindable(app.settings).memoryEnabled
                )
            } footer: {
                Text("關閉時，Lint 的行為與沒有這個功能時完全相同。")
                    .sectionNote()
            }

            Section("記憶") {
                LabeledContent("長期記憶") {
                    Text("\(stats.count(.active) + stats.count(.pinned))")
                }
                LabeledContent("短期記憶") {
                    Text("\(stats.count(.candidate))")
                }
                Button("管理記憶…") {
                    showMemories = true
                }
                Button("重設記憶資料庫…", role: .destructive) {
                    confirmReset = true
                }
            }

            Section {
                LabeledContent("上次作夢") {
                    if let dreamed = stats.lastDreamAt {
                        Text(dreamed.formatted(.relative(presentation: .named)))
                    } else {
                        Text("尚未作夢")
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
                    Button("現在作夢") {
                        dreamNow()
                    }
                    .disabled(!app.settings.memoryEnabled || dreaming)
                    if dreaming {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let dreamOutcome {
                    dreamMessage(dreamOutcome)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("作夢")
            } footer: {
                Text("新記下的記憶會立刻使用；7 天內再出現或幫上忙的會留成長期記憶，沒有的就忘記，痕跡淡掉後再刪除。作夢時也會把相近的具體記憶歸納成一般規則。作夢只在這台 Mac 上進行，不會連線。")
                    .sectionNote()
            }
        }
        .formStyle(.grouped)
        .task {
            stats = await app.memory.stats()
        }
        .onChange(of: app.settings.memoryEnabled) {
            Task {
                await app.memory.prepare(config: app.settings.memoryConfig)
                stats = await app.memory.stats()
            }
        }
        .sheet(isPresented: $showMemories) {
            Task { stats = await app.memory.stats() }
        } content: {
            MemoryManagementView(app: app)
        }
        .confirmationDialog("重設記憶資料庫？", isPresented: $confirmReset) {
            Button("重設", role: .destructive) {
                Task {
                    await app.memory.resetAll()
                    stats = await app.memory.stats()
                }
            }
        } message: {
            Text("這會刪除所有記憶與回饋紀錄，無法復原。")
        }
    }

    private func dreamNow() {
        Task {
            dreaming = true
            dreamOutcome = await app.memory.dream(config: app.settings.memoryConfig)
            stats = await app.memory.stats()
            dreaming = false
        }
    }

    @ViewBuilder
    private func dreamMessage(_ outcome: DreamOutcome) -> some View {
        switch outcome {
        case .finished(let remembered, let forgotten, let erased, let rules, let covered)
            where remembered + forgotten + erased + rules + covered == 0:
            Text("這次沒有要處理的記憶。")
        case .finished(let remembered, let forgotten, let erased, let rules, let covered):
            VStack(alignment: .leading, spacing: 2) {
                Text("作夢完成：記住 \(remembered) 條、忘記 \(forgotten) 條、刪除 \(erased) 條。")
                if rules > 0 || covered > 0 {
                    Text("新增 \(rules) 條一般記憶，涵蓋 \(covered) 條具體記憶。")
                }
            }
        case .alreadyRunning:
            Text("正在作夢。")
        case .failed:
            Text("作夢沒有完成，稍後會再試。")
        case .unavailable:
            EmptyView()
        }
    }
}

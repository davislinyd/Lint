import LintCore
import SwiftUI

private extension MemoryKind {
    var title: LocalizedStringKey {
        switch self {
        case .spelling: "拼寫"
        case .grammar: "文法"
        case .vocabulary: "用詞選擇"
        case .terminology: "術語"
        case .style: "風格"
        }
    }
}

private extension MemoryState {
    var title: LocalizedStringKey {
        switch self {
        case .candidate: "短期"
        case .active: "長期"
        case .pinned: "已釘選"
        case .disabled: "已停用"
        case .archived: "已忘記"
        }
    }
}

private extension MemoryLevel {
    var title: LocalizedStringKey {
        switch self {
        case .specific: "具體"
        case .generalized: "一般"
        case .core: "核心"
        }
    }
}

/// Every memory, where each one can be read, reworded, pinned, disabled or deleted.
/// Forgotten memories are only traces, so they are listed only when asked for.
struct MemoryManagementView: View {
    var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var memories: [WritingMemory] = []
    @State private var showForgotten = false
    /// How many memories each generalized or core memory was derived from.
    @State private var sourceCounts: [UUID: Int] = [:]
    @State private var editing: WritingMemory?
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("記憶")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            if memories.isEmpty {
                Text("還沒有任何記憶。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                Text("沒有使用中的記憶。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(MemoryKind.allCases, id: \.self) { kind in
                        let items = shown
                            .filter { $0.kind == kind }
                            .sorted { $0.lastConfirmedAt > $1.lastConfirmedAt }
                        if !items.isEmpty {
                            Section(kind.title) {
                                ForEach(items) { row($0) }
                            }
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button("清除所有記憶…", role: .destructive) { confirmClear = true }
                    .disabled(memories.isEmpty)
                Spacer()
                if forgottenCount > 0 {
                    Toggle("顯示已忘記的記憶（\(forgottenCount)）", isOn: $showForgotten)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 560, minHeight: 440)
        .task { await reload() }
        .sheet(item: $editing) { memory in
            InstructionEditor(text: memory.instruction) { text in
                perform { await app.memory.setInstruction(text, id: memory.id) }
            }
        }
        .confirmationDialog("清除所有記憶？", isPresented: $confirmClear) {
            Button("清除", role: .destructive) {
                perform { await app.memory.deleteAllMemories() }
            }
        } message: {
            Text("這會刪除所有記憶，回饋紀錄會保留。")
        }
    }

    private var forgottenCount: Int {
        memories.filter { $0.state == .archived }.count
    }

    private var shown: [WritingMemory] {
        showForgotten ? memories : memories.filter { $0.state != .archived }
    }

    private func row(_ memory: WritingMemory) -> some View {
        // Disabled by the user, or forgotten: not in use, and enabling brings it back.
        let dormant = memory.state == .disabled || memory.state == .archived
        // A rule says it already, so this one is not told to the model on its own account.
        let covered = isCovered(memory)
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(memory.instruction)
                    .foregroundStyle(dormant || covered ? .secondary : .primary)
                    .textSelection(.enabled)
                caption(memory, covered: covered)
                if memory.level != .specific, let count = sourceCounts[memory.id], count > 0 {
                    SourceMemories(app: app, parent: memory)
                }
            }
            Spacer(minLength: 8)
            Menu {
                Button(memory.state == .pinned ? LocalizedStringKey("取消釘選") : LocalizedStringKey("釘選")) {
                    perform { await app.memory.setPinned(memory.state != .pinned, id: memory.id) }
                }
                Button(dormant ? LocalizedStringKey("啟用") : LocalizedStringKey("停用")) {
                    perform { await app.memory.setEnabled(dormant, id: memory.id) }
                }
                Button("編輯…") { editing = memory }
                Divider()
                Button("刪除", role: .destructive) {
                    perform { await app.memory.deleteMemory(id: memory.id) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    /// A rule that is in use stands in for this memory.
    private func isCovered(_ memory: WritingMemory) -> Bool {
        guard memory.level == .specific, let rule = memory.supersededBy else { return false }
        return memories.contains { $0.id == rule && [.candidate, .active, .pinned].contains($0.state) }
    }

    private func caption(_ memory: WritingMemory, covered: Bool) -> some View {
        let filled = min(5, Int((memory.confidence(at: Date()) * 5).rounded()))
        let stars = String(repeating: "★", count: filled) + String(repeating: "☆", count: 5 - filled)
        let confirmed = memory.lastConfirmedAt.formatted(.relative(presentation: .named))
        return HStack(spacing: 4) {
            Text(memory.state.title)
                .foregroundStyle(memory.state == .pinned ? Color.accentColor : .secondary)
            Text(verbatim: "·")
            Text(memory.level.title)
            if memory.level != .specific, let count = sourceCounts[memory.id], count > 0 {
                Text(verbatim: "·")
                Text("衍生自 \(count) 則記憶")
            }
            if covered {
                Text(verbatim: "·")
                Text("已由一般規則涵蓋")
            }
            Text(verbatim: "·")
            Text("信心 \(stars)")
            Text(verbatim: "·")
            Text("觀察 \(memory.occurrenceCount) 次")
            Text(verbatim: "·")
            Text("最後確認 \(confirmed)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func perform(_ action: @escaping () async -> Void) {
        Task {
            await action()
            await reload()
        }
    }

    private func reload() async {
        memories = await app.memory.memories()
        sourceCounts = await app.memory.sourceCounts()
    }
}

/// The memories a generalized or core memory was derived from, read only when they are asked for.
private struct SourceMemories: View {
    var app: AppModel
    var parent: WritingMemory
    @State private var expanded = false
    @State private var sources: [WritingMemory] = []

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sources) { source in
                    Text(source.instruction)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 2)
        } label: {
            Text("來源記憶")
        }
        .font(.caption)
        .task(id: expanded) {
            if expanded { sources = await app.memory.sources(of: parent.id) }
        }
    }
}

private struct InstructionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    var onSave: (String) -> Void

    init(text: String, onSave: @escaping (String) -> Void) {
        _text = State(initialValue: text)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("編輯這條記憶")
                .font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 110)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("最多 \(MemoryCoordinator.maxInstructionLength) 字")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button("儲存") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onChange(of: text) {
            if text.count > MemoryCoordinator.maxInstructionLength {
                text = String(text.prefix(MemoryCoordinator.maxInstructionLength))
            }
        }
    }
}

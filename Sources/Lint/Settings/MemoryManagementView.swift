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
        case .candidate: "候選"
        case .active: "啟用中"
        case .pinned: "已釘選"
        case .disabled: "已停用"
        case .archived: "已封存"
        }
    }
}

/// Everything Lint has learned, where each memory can be read, reworded, pinned, disabled or deleted.
struct MemoryManagementView: View {
    var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var memories: [WritingMemory] = []
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
                Text("還沒有學到任何記憶。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(MemoryKind.allCases, id: \.self) { kind in
                        let items = memories
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
            }
            .padding(16)
        }
        .frame(minWidth: 560, minHeight: 440)
        .task { await reload() }
        .sheet(item: $editing) { memory in
            InstructionEditor(text: memory.instruction) { text in
                perform { await app.learning.setInstruction(text, id: memory.id) }
            }
        }
        .confirmationDialog("清除所有記憶？", isPresented: $confirmClear) {
            Button("清除", role: .destructive) {
                perform { await app.learning.deleteAllMemories() }
            }
        } message: {
            Text("這會刪除所有已學到的記憶，回饋紀錄會保留。")
        }
    }

    private func row(_ memory: WritingMemory) -> some View {
        // Disabled by the user, or faded away and archived: not in use, and enabling brings it back.
        let dormant = memory.state == .disabled || memory.state == .archived
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(memory.instruction)
                    .foregroundStyle(dormant ? .secondary : .primary)
                    .textSelection(.enabled)
                caption(memory)
            }
            Spacer(minLength: 8)
            Menu {
                Button(memory.state == .pinned ? LocalizedStringKey("取消釘選") : LocalizedStringKey("釘選")) {
                    perform { await app.learning.setPinned(memory.state != .pinned, id: memory.id) }
                }
                Button(dormant ? LocalizedStringKey("啟用") : LocalizedStringKey("停用")) {
                    perform { await app.learning.setEnabled(dormant, id: memory.id) }
                }
                Button("編輯…") { editing = memory }
                Divider()
                Button("刪除", role: .destructive) {
                    perform { await app.learning.deleteMemory(id: memory.id) }
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

    private func caption(_ memory: WritingMemory) -> some View {
        let filled = min(5, Int((memory.confidence(at: Date()) * 5).rounded()))
        let stars = String(repeating: "★", count: filled) + String(repeating: "☆", count: 5 - filled)
        let confirmed = memory.lastConfirmedAt.formatted(.relative(presentation: .named))
        return HStack(spacing: 4) {
            Text(memory.state.title)
                .foregroundStyle(memory.state == .pinned ? Color.accentColor : .secondary)
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
        memories = await app.learning.memories()
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
                Text("最多 \(LearningCoordinator.maxInstructionLength) 字")
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
            if text.count > LearningCoordinator.maxInstructionLength {
                text = String(text.prefix(LearningCoordinator.maxInstructionLength))
            }
        }
    }
}

import LintCore
import SwiftUI

struct FloatingPanelView: View {
    @Bindable var viewModel: FloatingPanelViewModel
    /// Carried out by the controller: the panel has to be taken away before the text is written back.
    var onReplace: () -> Void
    @FocusState private var originalFocused: Bool
    @State private var isEditingResult = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("模式", selection: $viewModel.mode) {
                    ForEach(WritingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 240)
                if viewModel.mode.supportsTone {
                    Picker("語氣", selection: $viewModel.tone) {
                        ForEach(viewModel.mode.tones) { tone in
                            // How much to change (preserve, idiomatic), then the styles.
                            if tone == .formal { Divider() }
                            Text(tone.title).tag(tone)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260)
                }
                if viewModel.mode == .translate {
                    Picker("翻譯語言", selection: Bindable(viewModel.settings).translationLanguage) {
                        ForEach(TranslationLanguage.allCases) { language in
                            Text(verbatim: language.englishName).tag(language)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Spacer()
                if viewModel.isStreaming {
                    ProgressView()
                        .controlSize(.small)
                    Text("串流中…")
                        .foregroundStyle(.secondary)
                }
            }

            if let note = viewModel.statusNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let advice = viewModel.unchangedAdvice {
                HStack(spacing: 10) {
                    Text(advice.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if advice == .tryIdiomatic {
                        Button("改用「道地」") { viewModel.retry() }
                            .controlSize(.small)
                    }
                }
            }
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                if viewModel.needsLocalAISetup {
                    HStack(spacing: 12) {
                        Button("設定本機 AI") { viewModel.openLocalAISetup() }
                        Button("改用其他模型來源") { viewModel.openModelSettings() }
                            .buttonStyle(.link)
                    }
                }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("原文")
                            .font(.headline)
                        Text("可編輯")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    TextEditor(text: $viewModel.originalText)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        .focused($originalFocused)
                        .disabled(viewModel.isStreaming)
                        .onChange(of: viewModel.originalText) { _, _ in
                            if viewModel.errorMessage?.contains("找不到選取文字") == true {
                                viewModel.errorMessage = nil
                            }
                            if viewModel.statusNote == FloatingPanelViewModel.noSelectionNote,
                               !viewModel.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                viewModel.statusNote = nil
                            }
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                resultColumn
            }

            if let usage = viewModel.lastUsage {
                Text(usage.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                Button {
                    onReplace()
                } label: {
                    Text("覆蓋取代") + shortcutHint("⌘⏎")
                }
                .disabled(viewModel.resultText.isEmpty || viewModel.isStreaming)
                .keyboardShortcut(.return, modifiers: [.command])

                Button {
                    viewModel.copyResult()
                } label: {
                    Text("複製") + shortcutHint("⌥⌘C")
                }
                .disabled(viewModel.resultText.isEmpty)
                // ⌘C stays with the original-text editor (copies the selection).
                .keyboardShortcut("c", modifiers: [.command, .option])

                Button {
                    viewModel.generateFromOriginal()
                } label: {
                    Text(viewModel.resultText.isEmpty ? String(localized: "產生") : String(localized: "重試")) + shortcutHint("⌥⌘⏎")
                }
                .disabled(viewModel.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isStreaming)
                .keyboardShortcut(.return, modifiers: [.command, .option])
                .buttonStyle(.borderedProminent)

                Spacer()
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 360)
        .onAppear {
            if viewModel.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                originalFocused = true
            }
        }
        .onChange(of: viewModel.isStreaming) { _, streaming in
            if streaming { isEditingResult = false }
        }
    }

    private func shortcutHint(_ keys: String) -> Text {
        Text(verbatim: " \(keys)").foregroundStyle(.secondary)
    }

    /// Read-only with the changes highlighted, or editable so the user's own wording is what gets
    /// applied (and remembered).
    private var resultColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("結果")
                    .font(.headline)
                Toggle("編輯", isOn: $isEditingResult)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(viewModel.resultText.isEmpty || viewModel.isStreaming)
                Spacer()
            }
            if isEditingResult {
                TextEditor(text: $viewModel.resultText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ScrollView {
                    DiffTextView(
                        original: viewModel.originalText,
                        result: viewModel.resultText,
                        highlight: !viewModel.isStreaming
                    )
                    .padding(8)
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

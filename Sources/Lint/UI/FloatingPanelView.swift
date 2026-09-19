import LintCore
import SwiftUI

struct FloatingPanelView: View {
    @Bindable var viewModel: FloatingPanelViewModel
    @FocusState private var originalFocused: Bool

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
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
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

                column(title: "結果") {
                    DiffTextView(
                        original: viewModel.originalText,
                        result: viewModel.resultText,
                        highlight: !viewModel.isStreaming
                    )
                }
            }

            if let usage = viewModel.lastUsage {
                Text(usage.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                Button("覆蓋取代") {
                    viewModel.replaceOriginal()
                }
                .disabled(viewModel.resultText.isEmpty || viewModel.isStreaming)
                .keyboardShortcut(.return, modifiers: [.command])

                Button("複製") {
                    viewModel.copyResult()
                }
                .disabled(viewModel.resultText.isEmpty)

                Button(viewModel.resultText.isEmpty ? String(localized: "產生") : String(localized: "重試")) {
                    viewModel.generateFromOriginal()
                }
                .disabled(viewModel.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isStreaming)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
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
    }

    private func column(title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            ScrollView {
                content().padding(8)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

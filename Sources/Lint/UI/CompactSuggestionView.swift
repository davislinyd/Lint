import LintCore
import SwiftUI

/// Grammarly-like compact bubble for selection auto-suggest.
struct CompactSuggestionView: View {
    @Bindable var viewModel: FloatingPanelViewModel
    var onDismiss: () -> Void
    var onReplace: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "pencil.and.outline")
                    .foregroundStyle(.blue)
                Text(viewModel.modeTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if viewModel.isStreaming {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("關閉")
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
                    .lineLimit(4)
                    .textSelection(.enabled)
            } else if viewModel.resultText.isEmpty && viewModel.isStreaming {
                Text("產生建議中…")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                DiffTextView(
                    original: viewModel.originalText,
                    result: viewModel.resultText,
                    highlight: !viewModel.isStreaming && !viewModel.resultText.isEmpty
                )
                .frame(maxWidth: 420, minHeight: 24, maxHeight: 120, alignment: .topLeading)
            }

            HStack(spacing: 12) {
                Button {
                    onReplace()
                } label: {
                    Text("取代")
                        .frame(minWidth: 52)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(viewModel.resultText.isEmpty || viewModel.isStreaming)
                .keyboardShortcut(.defaultAction)
                // Backup: some nonactivating panels swallow Button actions on first click.
                .simultaneousGesture(TapGesture().onEnded {
                    guard !viewModel.resultText.isEmpty, !viewModel.isStreaming else { return }
                    onReplace()
                })

                Button("重寫") {
                    viewModel.retry()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(viewModel.originalText.isEmpty || viewModel.isStreaming)

                Button("關閉") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .controlSize(.regular)
                .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        // Expand hit-testing so clicks near edges still land on controls.
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

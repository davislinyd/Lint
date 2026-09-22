import LintCore
import SwiftUI

struct PromptSettingsPane: View {
    var app: AppModel
    @State private var mode: WritingMode = .proofread
    @State private var tone: WritingTone = .preserve

    private var isOverridden: Bool {
        app.settings.isSystemPromptOverridden(for: mode, tone: tone)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("模式", selection: $mode) {
                    ForEach(WritingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                if mode.supportsTone {
                    Picker("語氣", selection: $tone) {
                        ForEach(WritingTone.allCases) { tone in
                            Text(tone.title).tag(tone)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Spacer()
                HStack(spacing: 6) {
                    StatusDot(color: isOverridden ? .orange : .green)
                    Text(isOverridden ? String(localized: "已自訂") : String(localized: "使用內建預設"))
                        .foregroundStyle(.secondary)
                }
            }

            if mode == .translate {
                HStack {
                    Text("翻譯目標語言")
                    TextField("翻譯目標語言", text: Bindable(app.settings).translateTarget)
                        .labelsHidden()
                }
            }

            if mode == .custom {
                VStack(alignment: .leading, spacing: 6) {
                    Text("額外指示")
                    CodeEditor(text: Bindable(app.settings).customPrompt)
                        .frame(height: 80)
                    Text("若下方 System Prompt 已自訂覆寫，以覆寫內容為準。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("System Prompt")
                CodeEditor(text: systemPromptBinding)
                    .frame(minHeight: 160, maxHeight: .infinity)
                HStack {
                    Text("每個模式與語氣組合可分開覆寫，改完即生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("恢復內建預設") {
                        app.settings.resetSystemPromptOverride(for: mode, tone: tone)
                    }
                    .disabled(!isOverridden)
                }
            }
        }
        .padding(20)
    }

    private var systemPromptBinding: Binding<String> {
        Binding(
            get: { app.settings.effectiveSystemPrompt(for: mode, tone: tone) },
            set: { app.settings.setSystemPromptOverride($0, for: mode, tone: tone) }
        )
    }
}

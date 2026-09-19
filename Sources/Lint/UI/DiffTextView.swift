import SwiftUI

struct DiffTextView: View {
    let original: String
    let result: String
    let highlight: Bool

    var body: some View {
        if highlight, !original.isEmpty, !result.isEmpty {
            Text(Self.attributed(original: original, result: result))
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text(result.isEmpty ? "（等待模型輸出）" : result)
                .foregroundStyle(result.isEmpty ? .secondary : .primary)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    static func attributed(original: String, result: String) -> AttributedString {
        let oldWords = original.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let newWords = result.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let diff = newWords.difference(from: oldWords)
        var inserted = Set<Int>()
        for change in diff {
            if case .insert(let offset, _, _) = change {
                inserted.insert(offset)
            }
        }
        var output = AttributedString()
        for (index, word) in newWords.enumerated() {
            var piece = AttributedString(word)
            if inserted.contains(index) {
                piece.backgroundColor = Color.green.opacity(0.28)
            }
            output += piece
            if index < newWords.count - 1 {
                output += AttributedString(" ")
            }
        }
        return output
    }
}

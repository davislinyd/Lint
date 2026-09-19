import Foundation

/// Heuristic script check for live typing watch.
enum TextLanguage {
    /// Auto-watch when Latin letters dominate (or clearly form an English phrase).
    /// Pure/mostly CJK is skipped; the check hotkey still works for any language.
    static func shouldAutoWatchTyping(_ text: String) -> Bool {
        var latin = 0
        var cjk = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) {
                latin += 1
            } else if (0x4E00...0x9FFF).contains(v)
                        || (0x3400...0x4DBF).contains(v)
                        || (0xF900...0xFAFF).contains(v)
                        || (0x3040...0x30FF).contains(v) { // kana rarely in TW but harmless
                cjk += 1
            }
        }

        let scripted = latin + cjk
        if scripted == 0 { return false }

        // Short English fragments: "ok thanks", "fix this".
        if latin >= 6 && cjk == 0 { return true }
        if latin >= 8 && cjk > 0 {
            // Mixed: need Latin to lead (e.g. "sync with 小明 later").
            return Double(latin) >= Double(scripted) * 0.55
        }
        // Mostly CJK with a couple English tokens → skip auto watch.
        return latin >= 10 && Double(latin) > Double(cjk)
    }
}

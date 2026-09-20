import AppKit
import ApplicationServices

@MainActor
final class TextCaptureService {
    struct CaptureResult {
        var text: String
        var usedClipboardFallback: Bool
        var axElement: AXUIElement?
        var sourceAppPID: pid_t?
        /// UTF-16 CFRange in the source field, when available (used for Replace).
        var selectedRange: CFRange?
        /// Where to park the check chip (caret / text end). Falls back to selectedRange.
        var chipAnchorRange: CFRange? = nil
    }

    private(set) var lastCapture: CaptureResult?
    /// PIDs already asked to expose their web AX tree (attempted once, whatever the result).
    private static var webAccessibilityRequested = Set<pid_t>()

    /// Chromium / Electron apps (SeaTalk, ChatGPT, Slack, browsers, …) build their web AX tree only
    /// after an assistive client asks: Electron listens for `AXManualAccessibility`, plain Chromium
    /// for `AXEnhancedUserInterface`. Both calls may report an error yet still switch the tree on.
    /// Native apps are left alone — `AXEnhancedUserInterface` changes their window behaviour.
    private static func ensureWebAccessibility() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              webAccessibilityRequested.insert(app.processIdentifier).inserted,
              isChromiumBased(app) else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        for name in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            let err = AXUIElementSetAttributeValue(element, name as CFString, kCFBooleanTrue)
            log("\(name) pid=\(app.processIdentifier) err=\(err.rawValue)")
        }
    }

    private static func isChromiumBased(_ app: NSRunningApplication) -> Bool {
        guard let bundle = app.bundleURL else { return false }
        if FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) {
            return true
        }
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        if info?["ElectronAsarIntegrity"] != nil || info?["ChromiumBaseVersion"] != nil { return true }
        return (info?["NSPrincipalClass"] as? String)?.contains("CrApplication") == true
    }

    /// `allowSelectAll` (⌥⌘K only): when nothing is selected and AX exposes no text, select the whole
    /// field to read it. The full panel keeps its old behaviour of never touching the source app's selection.
    func capture(allowSelectAll: Bool = false) async -> CaptureResult? {
        if AccessibilityPermission.isTrusted { Self.ensureWebAccessibility() }
        if AccessibilityPermission.isTrusted, let ax = Self.readAXSelectedText() {
            let result = CaptureResult(
                text: ax.text,
                usedClipboardFallback: false,
                axElement: ax.element,
                sourceAppPID: Self.frontmostPID(),
                selectedRange: Self.readSelectedRange(ax.element)
            )
            lastCapture = result
            return result
        }
        // Never fall back to whatever was already on the clipboard: only text that ⌘C just copied counts.
        if let selected = await readViaClipboard() {
            lastCapture = selected
            return selected
        }
        if allowSelectAll, let whole = await readViaSelectAll() {
            lastCapture = whole
            return whole
        }
        return nil
    }

    func peekAXSelection() -> CaptureResult? {
        guard AccessibilityPermission.isTrusted else { return nil }
        Self.ensureWebAccessibility()
        guard let ax = Self.readAXSelectedText() else { return nil }
        if Self.isSecureElement(ax.element) { return nil }
        return CaptureResult(
            text: ax.text,
            usedClipboardFallback: false,
            axElement: ax.element,
            sourceAppPID: Self.frontmostPID(),
            selectedRange: Self.readSelectedRange(ax.element)
        )
    }


    /// Focused field value around the caret (no selection required).
    /// `selectedRange` is the snippet's UTF-16 range in the full field so Replace still works.
    func peekAXFocusedSnippet(maxUTF16Length: Int = 1000) -> CaptureResult? {
        guard AccessibilityPermission.isTrusted else { return nil }
        Self.ensureWebAccessibility()
        guard let focused = Self.focusedElement() else { return nil }
        if Self.isSecureElement(focused) { return nil }

        // Prefer a real selection when present.
        if let selected = Self.readAXSelectedText(), selected.element == focused {
            let trimmed = selected.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 8 {
                return CaptureResult(
                    text: selected.text,
                    usedClipboardFallback: false,
                    axElement: focused,
                    sourceAppPID: Self.frontmostPID(),
                    selectedRange: Self.readSelectedRange(focused)
                )
            }
        }

        guard let full = Self.readStringAttribute(focused, kAXValueAttribute as String),
              !full.isEmpty else { return nil }

        let ns = full as NSString
        let fullLen = ns.length
        guard fullLen >= 8 else { return nil }

        var caret = fullLen
        if let range = Self.readSelectedRange(focused) {
            caret = max(0, min(range.location, fullLen))
        }

        // Paragraph around caret (UTF-16).
        var start = 0
        var idx = caret
        while idx > 0 {
            let ch = ns.character(at: idx - 1)
            if ch == 10 || ch == 13 { // \n / \r
                start = idx
                break
            }
            idx -= 1
        }
        var end = fullLen
        idx = caret
        while idx < fullLen {
            let ch = ns.character(at: idx)
            if ch == 10 || ch == 13 {
                end = idx
                break
            }
            idx += 1
        }

        var loc = start
        var len = end - start
        if len > maxUTF16Length {
            // Keep a window ending near the caret (recent typing).
            let desiredEnd = min(fullLen, max(caret + 40, start + len))
            let desiredStart = max(start, desiredEnd - maxUTF16Length)
            loc = desiredStart
            len = desiredEnd - desiredStart
        }

        let snippet = ns.substring(with: NSRange(location: loc, length: len))
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return nil }

        // Anchor the chip at the caret (text end while typing), not the whole paragraph.
        let anchorLoc = max(0, min(caret, fullLen))
        let anchor = CFRange(
            location: anchorLoc > 0 ? anchorLoc - 1 : anchorLoc,
            length: fullLen > 0 ? 1 : 0
        )

        return CaptureResult(
            text: snippet,
            usedClipboardFallback: false,
            axElement: focused,
            sourceAppPID: Self.frontmostPID(),
            selectedRange: CFRange(location: loc, length: len),
            chipAnchorRange: anchor
        )
    }

    func adopt(_ result: CaptureResult) {
        lastCapture = result
    }

    /// Replace previously captured selection. Returns error message or nil on success.
    func replaceLast(with newText: String) async -> String? {
        guard let last = lastCapture else { return String(localized: "沒有可覆蓋的選取") }
        Self.log("replace start originalCount=\(last.text.count) newCount=\(newText.count) hasAX=\(last.axElement != nil) range=\(String(describing: last.selectedRange)) pid=\(String(describing: last.sourceAppPID))")

        // Always bring source app forward first — we likely stole focus for the bubble.
        await activateSourceAppIfNeeded()

        if let element = last.axElement {
            // A) Best: rewrite the whole field value by substituting the original snippet.
            if Self.replaceInValue(element: element, original: last.text, newText: newText) {
                Self.log("replace via AXValue OK")
                return nil
            }

            // B) Restore selection range, then set selected text.
            if let range = last.selectedRange, Self.setSelectedRange(element, range) {
                let err = AXUIElementSetAttributeValue(
                    element,
                    kAXSelectedTextAttribute as CFString,
                    newText as CFTypeRef
                )
                Self.log("replace via restored range selectedText err=\(err.rawValue)")
                if err == .success {
                    return nil
                }
                // C) With range restored, try paste.
                await pasteViaClipboard(newText)
                if Self.verifyReplacement(element: element, original: last.text, newText: newText) {
                    Self.log("replace via paste after range OK")
                    return nil
                }
            }

            // D) Try selectedText directly anyway.
            let err = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                newText as CFTypeRef
            )
            Self.log("replace via selectedText direct err=\(err.rawValue)")
            if err == .success, Self.verifyReplacement(element: element, original: last.text, newText: newText) {
                return nil
            }
        }

        // E) Live focused selection
        if let live = Self.readAXSelectedText() {
            let err = AXUIElementSetAttributeValue(
                live.element,
                kAXSelectedTextAttribute as CFString,
                newText as CFTypeRef
            )
            Self.log("replace via live selection err=\(err.rawValue)")
            if err == .success {
                return nil
            }
            await pasteViaClipboard(newText)
            return nil
        }

        // F) Re-resolve focused element in the source app (AX refs go stale after focus hops).
        if let focused = Self.focusedElement() {
            if let range = last.selectedRange, Self.setSelectedRange(focused, range) {
                Self.log("replace F: restored snippet range on focused element")
                await pasteViaClipboard(newText)
                if Self.verifyReplacement(element: focused, original: last.text, newText: newText) {
                    Self.log("replace F paste after range OK")
                    return nil
                }
            }
            // Whole-field case (⌥⌘K on a short composer): select all then paste.
            if let full = Self.readStringAttribute(focused, kAXValueAttribute as String),
               full == last.text || full.trimmingCharacters(in: .whitespacesAndNewlines) == last.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                Self.log("replace F: field equals original — Cmd+A then paste")
                Self.postHotkey(keyCode: 0, to: last.sourceAppPID) // A
                try? await Task.sleep(for: .milliseconds(80))
                await pasteViaClipboard(newText)
                if Self.verifyReplacement(element: focused, original: last.text, newText: newText) {
                    return nil
                }
                // Web views often cannot verify via AXValue — assume paste landed.
                return nil
            }
            // Last ditch: paste at current caret (better than failing silently after beep).
            Self.log("replace F: caret paste fallback")
            await pasteViaClipboard(newText)
            return nil
        }

        // G) No AX focus (common in browsers after focus hop). App should be frontmost now —
        // for single-field chat composers, Select All + Paste is the reliable writeback.
        Self.log("replace G: no focused AX — Cmd+A then paste fallback")
        Self.postHotkey(keyCode: 0, to: last.sourceAppPID) // A
        try? await Task.sleep(for: .milliseconds(100))
        await pasteViaClipboard(newText)
        return nil
    }

            private func activateSourceAppIfNeeded() async {
        let pid = lastCapture?.sourceAppPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated else {
            Self.log("activateSource: no pid/app")
            return
        }
        if app.processIdentifier == NSRunningApplication.current.processIdentifier {
            Self.log("activateSource: already frontmost (self)")
            return
        }
        Self.log("activateSource begin pid=\(pid) name=\(app.localizedName ?? "?")")

        // 1) macOS 14+ yield
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: app)
            _ = app.activate(from: NSRunningApplication.current)
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        try? await Task.sleep(for: .milliseconds(150))

        // 2) AppleScript System Events — reliable for Electron / browsers
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            let script = """
            tell application "System Events"
              set frontmost of first process whose unix id is \(pid) to true
            end tell
            """
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
                if let error {
                    Self.log("activateSource AppleScript error=\(error)")
                } else {
                    Self.log("activateSource AppleScript OK")
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        let front = NSWorkspace.shared.frontmostApplication
        Self.log("activateSource done front=\(front?.localizedName ?? "?") pid=\(front?.processIdentifier ?? -1)")
    }

    private static func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard err == .success, let focused else { return nil }
        return (focused as! AXUIElement)
    }

    private static func readStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard err == .success else { return nil }
        return ref as? String
    }

        private static func readAXSelectedText() -> (text: String, element: AXUIElement)? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let focusedErr = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard focusedErr == .success, let focused else { return nil }
        let element = focused as! AXUIElement
        var selected: AnyObject?
        let selectedErr = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selected
        )
        guard selectedErr == .success, let text = selected as? String else { return nil }
        let trimmedCheck = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCheck.isEmpty else { return nil }
        return (text, element)
    }

    private static func readSelectedRange(_ element: AXUIElement) -> CFRange? {
        var ref: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &ref
        )
        guard err == .success, let axValue = ref else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    @discardableResult
    private static func setSelectedRange(_ element: AXUIElement, _ range: CFRange) -> Bool {
        var mutable = range
        guard let axRange = AXValueCreate(.cfRange, &mutable) else { return false }
        let err = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            axRange
        )
        return err == .success
    }

    /// Replace `original` inside the element's full string value.
    private static func replaceInValue(element: AXUIElement, original: String, newText: String) -> Bool {
        var ref: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref)
        guard err == .success, let full = ref as? String, !full.isEmpty else {
            log("AXValue unavailable")
            return false
        }
        guard let range = full.range(of: original) else {
            log("AXValue does not contain original snippet")
            return false
        }
        let updated = full.replacingCharacters(in: range, with: newText)
        let setErr = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updated as CFTypeRef
        )
        log("AXValue set err=\(setErr.rawValue)")
        return setErr == .success
    }

    private static func verifyReplacement(element: AXUIElement, original: String, newText: String) -> Bool {
        var ref: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success,
           let full = ref as? String {
            if full.contains(newText) { return true }
            if !full.contains(original) { return true } // original gone — likely replaced
        }
        return false
    }

    /// Screen rect (AppKit / bottom-left) used to park the check chip.
    /// For chat composers (wide single-line), prefer measured text-end over flaky AX caret.
    /// Whole focused field / AX element frame in Cocoa screen coords.
    /// Used to park the ready chip *outside* the text so paste never covers glyphs.
    static func focusedFieldScreenRect(for result: CaptureResult) -> NSRect? {
        guard let element = result.axElement, let frame = elementFrame(element) else { return nil }
        let rect = cocoaScreenRect(fromAX: frame)
        guard rect.width > 8, rect.height > 8 else { return nil }
        return rect
    }

    static func selectionScreenRect(for result: CaptureResult) -> NSRect? {
        let fieldCocoa: NSRect? = {
            guard let element = result.axElement, let frame = elementFrame(element) else { return nil }
            return cocoaScreenRect(fromAX: frame)
        }()

        let estimated: NSRect? = fieldCocoa.map { estimateCaretRect(in: $0, text: result.text) }

        // 1) AX caret/selection — only if it agrees with the measured text end (when we have one).
        let positionRange = result.chipAnchorRange ?? result.selectedRange
        if let element = result.axElement, let range = positionRange {
            var probe = range
            if probe.length <= 0 {
                probe = CFRange(location: max(probe.location - 1, 0), length: 1)
            }
            if let rect = boundsForRange(element, probe) {
                var cocoa = cocoaScreenRect(fromAX: rect)
                if cocoa.width < 2 { cocoa.size.width = 2 }
                if cocoa.height < 14 { cocoa.size.height = 18 }
                if isUsableAnchor(cocoa, field: fieldCocoa),
                   isPlausibleTextEnd(cocoa, field: fieldCocoa, text: result.text, estimated: estimated) {
                    return cocoa
                }
            }
        }

        // 2) Measured text-end inside the field (best for Grok Bot / chat bars).
        if let estimated {
            return estimated
        }

        // 3) Mouse-up only if near the measured text end (ignore clicks on send / trailing controls).
        if let mouse = InteractionAnchor.lastMouseUp {
            if let field = fieldCocoa, field.insetBy(dx: -40, dy: -40).contains(mouse) {
                if let estimated, abs(mouse.x - estimated.midX) <= 96 {
                    return NSRect(x: mouse.x, y: mouse.y - 8, width: 2, height: 18)
                }
                if estimated == nil {
                    return NSRect(x: mouse.x, y: mouse.y - 8, width: 2, height: 18)
                }
            }
        }

        return nil
    }

    /// Reject AX garbage (e.g. {0,0,0,0} → bottom-left of the screen).
    private static func isUsableAnchor(_ rect: NSRect, field: NSRect?) -> Bool {
        guard rect.width.isFinite, rect.height.isFinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite else { return false }
        guard rect.width > 0, rect.height > 0 else { return false }

        let center = NSPoint(x: rect.midX, y: rect.midY)
        guard isOnAnyScreen(center) else { return false }

        if let field {
            let padded = field.insetBy(dx: -120, dy: -120)
            if !padded.contains(center) { return false }
            if abs(rect.width - field.width) < 16, abs(rect.height - field.height) < 16 {
                return false
            }
        } else if rect.minX < 8, rect.minY < 8, rect.width <= 4, rect.height <= 24 {
            return false
        }
        return true
    }

    /// For short text in a wide composer, AX often parks the caret at the far trailing edge.
    private static func isPlausibleTextEnd(
        _ rect: NSRect,
        field: NSRect?,
        text: String,
        estimated: NSRect?
    ) -> Bool {
        guard let field, let estimated else { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Wide single-line chat bars (Grok Bot, etc.).
        let isComposer = field.width > 280 && field.height < 90
        guard isComposer, trimmed.count < 160 else { return true }

        // AX end must stay near the measured glyph end — not the send-button side.
        if abs(rect.midX - estimated.midX) > 40 { return false }
        // Also reject anything deep in the trailing 22% of the field when text is short.
        let textRatio = CGFloat(trimmed.count) / 160
        if textRatio < 0.55, rect.midX > field.minX + field.width * 0.78 {
            return false
        }
        return true
    }

    private static func isOnAnyScreen(_ point: NSPoint) -> Bool {
        for screen in NSScreen.screens {
            if screen.frame.insetBy(dx: -40, dy: -40).contains(point) {
                return true
            }
        }
        return false
    }

    /// Park just after the last glyph — not at the trailing chrome of the composer.
    private static func estimateCaretRect(in field: NSRect, text: String) -> NSRect {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isComposer = field.width > 280 && field.height < 90
        // Chat UIs (Grok Bot) use ~13pt; overestimating font width pushes the chip right.
        let font = NSFont.systemFont(ofSize: isComposer ? 13 : 15)
        let lineHeight = max(font.ascender - font.descender + font.leading, 16)

        // Leading "+" chip is compact; keep this tight so we sit by the last glyph.
        let leading: CGFloat = isComposer ? 36 : (field.width > 280 ? 48 : 12)
        let trailingReserve: CGFloat = isComposer ? 72 : (field.width > 280 ? 72 : 20)
        let usableWidth = max(field.width - leading - trailingReserve, 40)

        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textWidth = max((trimmed as NSString).size(withAttributes: attrs).width, trimmed.isEmpty ? 0 : 6)
        let lines = max(1, Int(ceil(max(textWidth, 1) / usableWidth)))
        let lastLineWidth = textWidth - CGFloat(lines - 1) * usableWidth

        // Only a couple points after the last character.
        let x = field.minX + leading + min(max(lastLineWidth, 0), usableWidth) + 2
        let y: CGFloat
        if isComposer {
            y = field.midY - lineHeight / 2
        } else {
            y = field.maxY - lineHeight - 8 - CGFloat(min(lines - 1, 12)) * (lineHeight + 2)
        }

        let clampedX = min(max(x, field.minX + leading), field.maxX - trailingReserve)
        let clampedY = min(max(y, field.minY + 4), field.maxY - lineHeight - 4)
        return NSRect(x: clampedX, y: clampedY, width: 2, height: lineHeight)
    }


    private static func isImplausibleSelection(_ sel: NSRect, field: NSRect?, text: String) -> Bool {
        guard let field else { return false }
        // AX often lies and returns the whole control bounds for web/chat inputs.
        if abs(sel.width - field.width) < 16, abs(sel.height - field.height) < 16 {
            return true
        }
        if field.width > 220, sel.width > field.width * 0.55, text.count < 120 {
            return true
        }
        if field.width > 220, sel.width > 280, text.count < 80 {
            return true
        }
        return false
    }

    private static func estimateSelectionRect(text: String, in field: NSRect) -> NSRect {
        let font = NSFont.systemFont(ofSize: 15)
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        // Wide composers usually have a leading + / attachment control.
        let leading: CGFloat = field.width > 280 ? 52 : 10
        let trailingReserve: CGFloat = field.width > 280 ? 96 : 24
        let width = min(max(textWidth, 24), max(field.width - leading - trailingReserve, 24))
        let height = min(max(field.height - 16, 18), 28)
        let y = field.midY - height / 2
        return NSRect(x: field.minX + leading, y: y, width: width, height: height)
    }

    private static func boundsForRange(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        var mutable = range
        guard let axRange = AXValueCreate(.cfRange, &mutable) else { return nil }
        var ref: AnyObject?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            axRange,
            &ref
        )
        guard err == .success, let ref else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(ref as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        var ref: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &ref)
        guard err == .success, let ref else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(ref as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// AX uses top-left global coords; AppKit uses bottom-left.
    private static func cocoaScreenRect(fromAX axRect: CGRect) -> NSRect {
        // AX global Y grows downward from the top of the primary display.
        // AppKit Y grows upward. Use primary height as the flip reference (AppKit convention).
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        let height = primary?.frame.height ?? axRect.maxY
        return NSRect(
            x: axRect.origin.x,
            y: height - axRect.origin.y - axRect.height,
            width: axRect.width,
            height: axRect.height
        )
    }

    private static func isSecureElement(_ element: AXUIElement) -> Bool {
        var subrole: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        if let sub = subrole as? String, sub == (kAXSecureTextFieldSubrole as String) {
            return true
        }
        if let sub = subrole as? String, sub.lowercased().contains("secure") {
            return true
        }
        return false
    }

    /// Only accepts text that Cmd+C actually put on the pasteboard (a real selection),
    /// not whatever was already there.
    private func readViaClipboard() async -> CaptureResult? {
        let snapshot = PasteboardMemory.snapshot()
        let before = NSPasteboard.general.changeCount
        Self.postHotkey(keyCode: 8) // C
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(25))
            if NSPasteboard.general.changeCount != before { break }
        }
        let changed = NSPasteboard.general.changeCount != before
        let text = NSPasteboard.general.string(forType: .string)
        PasteboardMemory.restore(snapshot)
        guard changed,
              let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return CaptureResult(
            text: text,
            usedClipboardFallback: true,
            axElement: nil,
            sourceAppPID: Self.frontmostPID(),
            selectedRange: nil
        )
    }

    /// Roles where Cmd+A means "the text of this field"; lists, tables, etc. would select files/rows.
    private static let selectAllRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXComboBox", "AXWebArea", "AXGroup", "AXScrollArea", "AXUnknown",
    ]

    /// Last resort for apps whose AX tree exposes no text: select the field, copy it, then collapse the
    /// selection to its end so the next keystroke does not overwrite the whole field.
    private func readViaSelectAll() async -> CaptureResult? {
        if let focused = Self.focusedElement(),
           let role = Self.readStringAttribute(focused, kAXRoleAttribute as String),
           !Self.selectAllRoles.contains(role) {
            return nil
        }
        let snapshot = PasteboardMemory.snapshot()
        let before = NSPasteboard.general.changeCount
        Self.postHotkey(keyCode: 0) // A
        try? await Task.sleep(for: .milliseconds(80))
        Self.postHotkey(keyCode: 8) // C
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(25))
            if NSPasteboard.general.changeCount != before { break }
        }
        let changed = NSPasteboard.general.changeCount != before
        let text = NSPasteboard.general.string(forType: .string)
        PasteboardMemory.restore(snapshot)
        Self.postHotkey(keyCode: 124, flags: []) // Right arrow
        guard changed, let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 4000 else { return nil }
        return CaptureResult(
            text: text,
            usedClipboardFallback: true,
            axElement: nil,
            sourceAppPID: Self.frontmostPID(),
            selectedRange: nil
        )
    }

    private func pasteViaClipboard(_ text: String) async {
        let snapshot = PasteboardMemory.snapshot()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        let pid = lastCapture?.sourceAppPID
        Self.postHotkey(keyCode: 9, to: pid) // V
        try? await Task.sleep(for: .milliseconds(350))
        PasteboardMemory.restore(snapshot)
    }

    private static func postHotkey(keyCode: CGKeyCode, to pid: pid_t? = nil, flags: CGEventFlags = .maskCommand) {
        // Always post to the HID tap after activating the target app.
        // postToPid fails for Electron/Chrome (focus lives in a helper process).
        _ = pid
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func logPublic(_ message: String) { log(message) }

    private static func log(_ message: String) {
        var line = String(describing: Date())
        line += " "
        line += message
        line += String(Character(UnicodeScalar(10)!))
        fputs(line, stdout)
        fflush(stdout)
        let path = "/tmp/lint-replace.log"
        // Also mirror under Application Support (always writable).
        let homeLog: String = {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/Lint", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("replace.log").path
        }()
        let url = URL(fileURLWithPath: path)
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
        if let homeData = line.data(using: .utf8) {
            let homeURL = URL(fileURLWithPath: homeLog)
            if FileManager.default.fileExists(atPath: homeLog),
               let handle = try? FileHandle(forWritingTo: homeURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: homeData)
            } else {
                try? homeData.write(to: homeURL)
            }
        }
    }
}

enum PasteboardMemory {
    static func snapshot() -> [[NSPasteboard.PasteboardType: Data]] {
        guard let items = NSPasteboard.general.pasteboardItems else { return [] }
        return items.map { item in
            var map: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    map[type] = data
                }
            }
            return map
        }
    }

    static func restore(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        for map in items {
            let item = NSPasteboardItem()
            for (type, data) in map {
                item.setData(data, forType: type)
            }
            pb.writeObjects([item])
        }
    }
}

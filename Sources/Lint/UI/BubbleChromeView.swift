import AppKit
import LintCore
import SwiftUI

/// AppKit chrome for the compact suggestion bubble.
/// Uses real `NSButton`s so clicks work on a nonactivating panel (SwiftUI buttons do not).
@MainActor
final class BubbleChromeView: NSView {
    var onReplace: (() -> Void)?
    var onRewrite: (() -> Void)?
    var onEdit: (() -> Void)?
    var onEndEditing: (() -> Void)?
    /// Every change typed in the editor, so `resultText` is always what Replace writes.
    var onTextEdited: ((String) -> Void)?
    var onSetUpLocalAI: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// The controller turns editing off when the bubble is shown without activating Lint: the editor
    /// needs the key window, and that mode exists so that Lint is not activated.
    var offersEditing = true
    /// Fired when the user starts dragging the bubble (not a button).
    var onDragBegan: (() -> Void)?
    /// Panel wires this for Enter / R / Esc while chrome is first responder.
    var onKeyDown: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyDown?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    private let titleLabel = NSTextField(labelWithString: "Lint")
    private let statusLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let translationLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let replaceButton = NSButton(title: String(localized: "取代"), target: nil, action: nil)
    private let rewriteButton = NSButton(title: String(localized: "重寫"), target: nil, action: nil)
    /// Shown instead of Replace / Rewrite while Local AI is not set up.
    private let setupButton = NSButton(title: String(localized: "設定本機 AI"), target: nil, action: nil)
    private let closeButton = NSButton(title: String(localized: "關閉"), target: nil, action: nil)
    private let xButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "關閉")) ?? NSImage(), target: nil, action: nil)
    /// In the row with the other keys, so E is seen where ⏎ and R are.
    private let editButton = NSButton(title: String(localized: "編輯 E"), target: nil, action: nil)
    /// Setup, Replace, Edit, Rewrite, Close: a hidden button leaves no gap.
    private let buttonRow = NSStackView()
    /// Takes the body's place while the suggestion is being edited. TextKit 1, so its height can be
    /// read from the layout manager.
    private let editor = NSTextView(usingTextLayoutManager: false)
    private let editorScroll = NSScrollView()
    private let card = NSVisualEffectView()
    private var widthConstraint: NSLayoutConstraint!
    /// The hidden body keeps the editor's slot: this gives it the editor's text height.
    private var bodyEditHeight: NSLayoutConstraint!
    private(set) var isEditing = false
    /// The suggestion as it was when editing first began; nil until then. Lets editing start again
    /// after an edit emptied the text.
    private var editBaseline: String?
    private var dragStartScreen: NSPoint?
    private var dragStartOrigin: NSPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        card.material = .popover
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.masksToBounds = true
        addSubview(card)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemOrange
        statusLabel.isHidden = true
        // A note is a sentence: let it wrap instead of clipping at the card's width.
        statusLabel.cell?.wraps = true
        statusLabel.cell?.usesSingleLineMode = false
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3

        bodyLabel.font = .systemFont(ofSize: 14)
        bodyLabel.textColor = .labelColor
        bodyLabel.maximumNumberOfLines = 12

        translationLabel.font = .systemFont(ofSize: 12)
        translationLabel.textColor = .secondaryLabelColor
        translationLabel.maximumNumberOfLines = 6
        translationLabel.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        replaceButton.bezelStyle = .rounded
        replaceButton.setButtonType(.momentaryPushIn)
        replaceButton.target = self
        replaceButton.action = #selector(tapReplace)
        if #available(macOS 14.0, *) {
            replaceButton.controlSize = .regular
        }
        // Enter handled by FloatingPanelController (keyEquivalent on disabled btn only beeps).

        rewriteButton.bezelStyle = .rounded
        rewriteButton.target = self
        rewriteButton.action = #selector(tapRewrite)

        setupButton.bezelStyle = .rounded
        setupButton.target = self
        setupButton.action = #selector(tapSetUpLocalAI)
        setupButton.isHidden = true

        closeButton.bezelStyle = .rounded
        // Escape handled by panel key monitor; keep button clickable.
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(tapClose)

        xButton.isBordered = false
        xButton.imagePosition = .imageOnly
        xButton.target = self
        xButton.action = #selector(tapDismiss)

        editButton.bezelStyle = .rounded
        editButton.target = self
        editButton.action = #selector(tapEdit)

        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY
        for button in [setupButton, replaceButton, editButton, rewriteButton, closeButton] {
            buttonRow.addArrangedSubview(button)
        }

        // Plain text, and nothing typed is changed behind the user's back: what they write is
        // what Replace writes and what is learned from.
        editor.font = bodyLabel.font
        editor.textColor = .labelColor
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.drawsBackground = true
        editor.backgroundColor = .textBackgroundColor
        // The scroll view sits 4 × 3 pt outside the body, so the text stays where the body showed it.
        editor.textContainerInset = NSSize(width: 4, height: 3)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.delegate = self
        editorScroll.documentView = editor
        editorScroll.hasVerticalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.scrollerStyle = .overlay
        editorScroll.drawsBackground = false
        editorScroll.wantsLayer = true
        editorScroll.layer?.cornerRadius = 6
        editorScroll.layer?.masksToBounds = true
        editorScroll.isHidden = true

        for v in [titleLabel, statusLabel, bodyLabel, editorScroll, translationLabel, spinner, buttonRow, xButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(v)
        }
        card.translatesAutoresizingMaskIntoConstraints = false

        widthConstraint = card.widthAnchor.constraint(equalToConstant: 280)
        bodyEditHeight = bodyLabel.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,

            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),

            spinner.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            spinner.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            xButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            xButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            xButton.widthAnchor.constraint(equalToConstant: 24),
            xButton.heightAnchor.constraint(equalToConstant: 24),

            statusLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),

            bodyLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            bodyLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            bodyLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),

            translationLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            translationLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            translationLabel.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 6),

            buttonRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            buttonRow.topAnchor.constraint(equalTo: translationLabel.bottomAnchor, constant: 12),
            buttonRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),

            editorScroll.leadingAnchor.constraint(equalTo: bodyLabel.leadingAnchor, constant: -4),
            editorScroll.trailingAnchor.constraint(equalTo: bodyLabel.trailingAnchor, constant: 4),
            editorScroll.topAnchor.constraint(equalTo: bodyLabel.topAnchor, constant: -3),
            editorScroll.bottomAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 3),

        ])
    }

    func apply(viewModel: FloatingPanelViewModel) {
        // A rewrite or another ⌥⌘K replaced the text under the editor: that edit is over. Typed text
        // reaches `resultText` at once, so they differ only then (marked text is not committed yet).
        if isEditing, viewModel.isStreaming || (!editor.hasMarkedText() && editor.string != viewModel.resultText) {
            endEditing()
        }
        if viewModel.isStreaming {
            editBaseline = nil
        }

        titleLabel.stringValue = viewModel.modeTitle

        if let err = viewModel.errorMessage, !err.isEmpty {
            statusLabel.isHidden = false
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = err
        } else if let note = viewModel.statusNote, !note.isEmpty {
            statusLabel.isHidden = false
            statusLabel.textColor = .systemOrange
            statusLabel.stringValue = note
        } else if let advice = viewModel.unchangedAdvice {
            // Not a warning: the answer is the text itself, and this says so.
            statusLabel.isHidden = false
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = advice.message
        } else {
            statusLabel.isHidden = true
            statusLabel.stringValue = ""
        }
        // Status sits above body — keep layout reserved when visible.
        statusLabel.needsDisplay = true

        if viewModel.isStreaming {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }

        if viewModel.resultText.isEmpty && viewModel.isStreaming {
            bodyLabel.stringValue = String(localized: "產生建議中…")
            bodyLabel.textColor = .secondaryLabelColor
        } else if viewModel.resultText.isEmpty {
            bodyLabel.stringValue = String(localized: "（尚無建議）")
            bodyLabel.textColor = .secondaryLabelColor
        } else {
            bodyLabel.stringValue = viewModel.resultText
            bodyLabel.textColor = .labelColor
        }

        // While editing too: the view model translates the edited text as it is typed.
        if viewModel.isTranslating && viewModel.translationText.isEmpty {
            translationLabel.isHidden = false
            translationLabel.stringValue = String(localized: "翻譯中…")
        } else if !viewModel.translationText.isEmpty {
            translationLabel.isHidden = false
            translationLabel.stringValue = viewModel.translationLanguage.glossLabel + viewModel.translationText
        } else {
            translationLabel.isHidden = true
            translationLabel.stringValue = ""
        }

        let canReplace = !viewModel.resultText.isEmpty
        // While editing ⏎ is a new line (and commits Zhuyin / Pinyin), so Replace is ⌘⏎ and esc ends the edit.
        replaceButton.title = isEditing ? String(localized: "取代 ⌘⏎") : String(localized: "取代 ⏎")
        // The same request would only come back unchanged again: R retries in the idiomatic tone.
        rewriteButton.title = viewModel.unchangedAdvice == .tryIdiomatic ? String(localized: "改用道地 R") : String(localized: "重寫 R")
        closeButton.title = isEditing ? String(localized: "結束編輯 esc") : String(localized: "關閉 esc")
        replaceButton.isEnabled = canReplace
        rewriteButton.isEnabled = !viewModel.originalText.isEmpty && !viewModel.isStreaming
        editButton.isEnabled = canBeginEditing(viewModel)
        // Not set up yet: Replace / Edit / Rewrite have nothing to act on, so offer the way forward.
        // While editing only Replace and the end of the edit are left.
        setupButton.isHidden = !viewModel.needsLocalAISetup
        replaceButton.isHidden = viewModel.needsLocalAISetup
        editButton.isHidden = viewModel.needsLocalAISetup || !offersEditing || isEditing
        rewriteButton.isHidden = viewModel.needsLocalAISetup || isEditing

        // Compact width for short text; grow height (not width) as content wraps. While editing the
        // width stays put, so the lines being typed do not rewrap under the caret.
        let targetWidth = isEditing
            ? widthConstraint.constant
            : Self.idealCardWidth(viewModel: viewModel, showsEdit: !editButton.isHidden)
        if abs(widthConstraint.constant - targetWidth) > 0.5 {
            widthConstraint.constant = targetWidth
        }
        bodyLabel.preferredMaxLayoutWidth = targetWidth - 28
        translationLabel.preferredMaxLayoutWidth = targetWidth - 28
        statusLabel.preferredMaxLayoutWidth = targetWidth - 28
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private static func idealCardWidth(viewModel: FloatingPanelViewModel, showsEdit: Bool) -> CGFloat {
        let maxWidth: CGFloat = 360
        let horizontalPad: CGFloat = 28
        let buttonFont = NSFont.systemFont(ofSize: 13)

        let body: String
        if viewModel.resultText.isEmpty && viewModel.isStreaming {
            body = String(localized: "產生建議中…")
        } else if viewModel.resultText.isEmpty {
            body = viewModel.errorMessage ?? String(localized: "（尚無建議）")
        } else {
            body = viewModel.resultText
        }
        let translation: String = {
            if viewModel.isTranslating && viewModel.translationText.isEmpty { return String(localized: "翻譯中…") }
            if viewModel.translationText.isEmpty { return "" }
            return viewModel.translationLanguage.glossLabel + viewModel.translationText
        }()

        let bodyFont = NSFont.systemFont(ofSize: 14)
        let transFont = NSFont.systemFont(ofSize: 12)
        let bodyW = (body as NSString).size(withAttributes: [.font: bodyFont]).width
        let transW = translation.isEmpty
            ? 0
            : (translation as NSString).size(withAttributes: [.font: transFont]).width
        // Room beside the title for the spinner and the close icon.
        let titleW = (viewModel.modeTitle as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width + 48

        // Buttons + gaps + side padding (~取代 ⏎ / 編輯 E / 重寫 R / 關閉 esc).
        let b1 = (String(localized: "取代 ⏎") as NSString).size(withAttributes: [.font: buttonFont]).width + 24
        let rewriteTitle = viewModel.unchangedAdvice == .tryIdiomatic ? String(localized: "改用道地 R") : String(localized: "重寫 R")
        let b2 = (rewriteTitle as NSString).size(withAttributes: [.font: buttonFont]).width + 24
        let b3 = (String(localized: "關閉 esc") as NSString).size(withAttributes: [.font: buttonFont]).width + 16
        let bEdit = showsEdit ? (String(localized: "編輯 E") as NSString).size(withAttributes: [.font: buttonFont]).width + 24 + 8 : 0
        let buttonsW = b1 + 8 + bEdit + b2 + 8 + b3 + horizontalPad

        let content = max(bodyW, transW, titleW) + horizontalPad
        let minWidth = max(240, ceil(buttonsW))
        // The text wraps at `maxWidth`; the row of buttons may need more (about 410 pt in Portuguese).
        return max(minWidth, min(maxWidth, ceil(content)))
    }

    /// Editing can start once a finished suggestion is on screen, or again after an edit emptied it.
    func canBeginEditing(_ viewModel: FloatingPanelViewModel) -> Bool {
        offersEditing && !viewModel.isStreaming && (viewModel.canEditResult || editBaseline != nil)
    }

    /// Where keys should land: the editor while editing, else this view (⏎ / R / esc).
    var focusTarget: NSView { isEditing ? editor : self }

    /// Zhuyin / Pinyin is composing: its keys (⏎ commits, esc cancels) belong to the input method,
    /// and the uncommitted text must not be written.
    var editorHasMarkedText: Bool { isEditing && editor.hasMarkedText() }

    /// The body becomes an editor holding `text`, with the caret at the end.
    func beginEditing(_ text: String) {
        guard !isEditing else { return }
        if editBaseline == nil {
            editBaseline = text
        }
        isEditing = true
        editor.string = text
        // One window, one editor: undo must not reach into an earlier suggestion's edit.
        editor.undoManager?.removeAllActions()
        bodyLabel.isHidden = true
        editorScroll.isHidden = false
        bodyEditHeight.constant = bodyLabel.frame.height
        bodyEditHeight.isActive = true
        layoutSubtreeIfNeeded()
        fitEditorHeight()
        window?.makeFirstResponder(editor)
        let end = NSRange(location: (text as NSString).length, length: 0)
        editor.setSelectedRange(end)
        editor.scrollRangeToVisible(end)
    }

    /// Back to the read-only body; what was typed stays the result.
    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        bodyEditHeight.isActive = false
        editorScroll.isHidden = true
        bodyLabel.isHidden = false
        if window?.firstResponder === editor {
            window?.makeFirstResponder(self)
        }
    }

    /// A new suggestion or a closed bubble: nothing of the last edit carries over.
    func resetEditing() {
        endEditing()
        editBaseline = nil
    }

    /// The hidden body gives the editor the height of its text, one line to twelve; past that the
    /// editor scrolls.
    private func fitEditorHeight() {
        guard let layout = editor.layoutManager, let container = editor.textContainer else { return }
        layout.ensureLayout(for: container)
        let line = layout.defaultLineHeight(for: editor.font ?? .systemFont(ofSize: 14))
        bodyEditHeight.constant = min(max(layout.usedRect(for: container).height, line), line * 12)
    }

    @objc private func tapReplace() {
        onReplace?()
    }

    @objc private func tapRewrite() {
        onRewrite?()
    }

    @objc private func tapEdit() {
        onEdit?()
    }

    @objc private func tapSetUpLocalAI() {
        onSetUpLocalAI?()
    }

    @objc private func tapDismiss() {
        onDismiss?()
    }

    /// The button beside Replace: ends the edit while editing, else closes the bubble.
    @objc private func tapClose() {
        if isEditing {
            onEndEditing?()
        } else {
            onDismiss?()
        }
    }


    private func isControlHit(_ view: NSView?) -> Bool {
        var v: NSView? = view
        while let cur = v {
            // The editor's margins too: a press there is not the start of a drag.
            if cur is NSButton || cur is NSControl || cur is NSText || cur is NSScrollView { return true }
            v = cur.superview
        }
        return false
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if isControlHit(hitTest(loc)) {
            dragStartScreen = nil
            dragStartOrigin = nil
            super.mouseDown(with: event)
            return
        }
        dragStartScreen = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartScreen, let origin = dragStartOrigin else {
            super.mouseDragged(with: event)
            return
        }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x
        let dy = now.y - start.y
        // Ignore tiny jitter; only treat as drag after a few points.
        if abs(dx) < 3, abs(dy) < 3 { return }
        if dragStartScreen != nil {
            onDragBegan?()
        }
        window?.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = dragStartScreen != nil
        dragStartScreen = nil
        dragStartOrigin = nil
        if !wasDragging {
            super.mouseUp(with: event)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension BubbleChromeView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        // Leaving the editor can commit marked text: that is not an edit of the result any more.
        guard isEditing else { return }
        fitEditorHeight()
        onTextEdited?(editor.string)
    }
}

private extension TranslationLanguage {
    /// Put before the reading aid under a suggestion.
    var glossLabel: String {
        switch self {
        case .indonesian: String(localized: "印尼文：")
        case .japanese: String(localized: "日文：")
        case .korean: String(localized: "韓文：")
        case .portuguese: String(localized: "葡萄牙文：")
        case .simplifiedChinese: String(localized: "簡體中文：")
        case .thai: String(localized: "泰文：")
        case .traditionalChinese: String(localized: "中文：")
        case .vietnamese: String(localized: "越南文：")
        }
    }
}

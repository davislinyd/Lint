import AppKit
import SwiftUI

/// AppKit chrome for the compact suggestion bubble.
/// Uses real `NSButton`s so clicks work on a nonactivating panel (SwiftUI buttons do not).
@MainActor
final class BubbleChromeView: NSView {
    var onReplace: (() -> Void)?
    var onRewrite: (() -> Void)?
    var onEdit: (() -> Void)?
    var onSetUpLocalAI: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// The controller turns the edit button off when the bubble is shown without activating Lint:
    /// opening the full panel would activate it, and closing the bubble hands the focus back.
    var offersFullPanelEdit = true {
        didSet { editButton.isHidden = !offersFullPanelEdit }
    }
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
    private let editButton = NSButton(image: NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: String(localized: "在全面板編輯")) ?? NSImage(), target: nil, action: nil)
    private let card = NSVisualEffectView()
    private var widthConstraint: NSLayoutConstraint!
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
        closeButton.action = #selector(tapDismiss)

        xButton.isBordered = false
        xButton.imagePosition = .imageOnly
        xButton.target = self
        xButton.action = #selector(tapDismiss)

        editButton.isBordered = false
        editButton.imagePosition = .imageOnly
        editButton.toolTip = String(localized: "在全面板編輯")
        editButton.target = self
        editButton.action = #selector(tapEdit)

        for v in [titleLabel, statusLabel, bodyLabel, translationLabel, spinner, replaceButton, rewriteButton, setupButton, closeButton, xButton, editButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(v)
        }
        card.translatesAutoresizingMaskIntoConstraints = false

        widthConstraint = card.widthAnchor.constraint(equalToConstant: 280)

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

            editButton.trailingAnchor.constraint(equalTo: xButton.leadingAnchor, constant: -2),
            editButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            editButton.widthAnchor.constraint(equalToConstant: 24),
            editButton.heightAnchor.constraint(equalToConstant: 24),

            statusLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),

            bodyLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            bodyLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            bodyLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),

            translationLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            translationLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            translationLabel.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 6),

            replaceButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            replaceButton.topAnchor.constraint(equalTo: translationLabel.bottomAnchor, constant: 12),
            replaceButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),

            rewriteButton.leadingAnchor.constraint(equalTo: replaceButton.trailingAnchor, constant: 8),
            rewriteButton.centerYAnchor.constraint(equalTo: replaceButton.centerYAnchor),

            setupButton.leadingAnchor.constraint(equalTo: replaceButton.leadingAnchor),
            setupButton.centerYAnchor.constraint(equalTo: replaceButton.centerYAnchor),

            closeButton.leadingAnchor.constraint(equalTo: rewriteButton.trailingAnchor, constant: 8),
            closeButton.centerYAnchor.constraint(equalTo: replaceButton.centerYAnchor),

        ])
    }

    func apply(viewModel: FloatingPanelViewModel) {
        titleLabel.stringValue = viewModel.mode.title

        if let err = viewModel.errorMessage, !err.isEmpty {
            statusLabel.isHidden = false
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = err
        } else if let note = viewModel.statusNote, !note.isEmpty {
            statusLabel.isHidden = false
            statusLabel.textColor = .systemOrange
            statusLabel.stringValue = note
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

        if viewModel.isTranslating && viewModel.translationText.isEmpty {
            translationLabel.isHidden = false
            translationLabel.stringValue = String(localized: "翻譯中…")
        } else if !viewModel.translationText.isEmpty {
            translationLabel.isHidden = false
            translationLabel.stringValue = String(localized: "中文：") + viewModel.translationText
        } else {
            translationLabel.isHidden = true
            translationLabel.stringValue = ""
        }

        let canReplace = !viewModel.resultText.isEmpty
        replaceButton.title = String(localized: "取代 ⏎")
        rewriteButton.title = String(localized: "重寫 R")
        closeButton.title = String(localized: "關閉 esc")
        replaceButton.isEnabled = canReplace
        rewriteButton.isEnabled = !viewModel.originalText.isEmpty && !viewModel.isStreaming
        editButton.isEnabled = viewModel.canEditInFullPanel
        // Not set up yet: Replace / Rewrite have nothing to act on, so offer the way forward. The hidden
        // buttons keep their layout slot, and the setup button sits in the same place.
        setupButton.isHidden = !viewModel.needsLocalAISetup
        replaceButton.isHidden = viewModel.needsLocalAISetup
        rewriteButton.isHidden = viewModel.needsLocalAISetup

        // Compact width for short text; grow height (not width) as content wraps.
        let targetWidth = Self.idealCardWidth(viewModel: viewModel)
        if abs(widthConstraint.constant - targetWidth) > 0.5 {
            widthConstraint.constant = targetWidth
        }
        bodyLabel.preferredMaxLayoutWidth = targetWidth - 28
        translationLabel.preferredMaxLayoutWidth = targetWidth - 28
        statusLabel.preferredMaxLayoutWidth = targetWidth - 28
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private static func idealCardWidth(viewModel: FloatingPanelViewModel) -> CGFloat {
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
            return String(localized: "中文：") + viewModel.translationText
        }()

        let bodyFont = NSFont.systemFont(ofSize: 14)
        let transFont = NSFont.systemFont(ofSize: 12)
        let bodyW = (body as NSString).size(withAttributes: [.font: bodyFont]).width
        let transW = translation.isEmpty
            ? 0
            : (translation as NSString).size(withAttributes: [.font: transFont]).width
        // Room beside the title for the spinner and the two icon buttons (edit, close).
        let titleW = (viewModel.mode.title as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width + 72

        // Buttons + gaps + side padding (~取代 ⏎ / 重寫 R / 關閉 esc).
        let b1 = (String(localized: "取代 ⏎") as NSString).size(withAttributes: [.font: buttonFont]).width + 24
        let b2 = (String(localized: "重寫 R") as NSString).size(withAttributes: [.font: buttonFont]).width + 24
        let b3 = (String(localized: "關閉 esc") as NSString).size(withAttributes: [.font: buttonFont]).width + 16
        let buttonsW = b1 + 8 + b2 + 8 + b3 + horizontalPad

        let content = max(bodyW, transW, titleW) + horizontalPad
        let minWidth = max(240, ceil(buttonsW))
        return min(maxWidth, max(minWidth, ceil(content)))
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


    private func isControlHit(_ view: NSView?) -> Bool {
        var v: NSView? = view
        while let cur = v {
            if cur is NSButton || cur is NSControl { return true }
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

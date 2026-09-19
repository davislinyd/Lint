import AppKit

/// Tiny Grammarly-style button shown near a selection. Click to run Lint.
@MainActor
final class SelectionChipView: NSView {
    var onTap: (() -> Void)?

    private let button = NSButton(title: String(localized: "檢查"), target: nil, action: nil)
    private let card = NSVisualEffectView()

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
        card.layer?.cornerRadius = 14
        card.layer?.masksToBounds = true
        // Let clicks fall through to us / the button, never eat them silently.
        card.addSubview(button)
        addSubview(card)

        button.bezelStyle = .rounded
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "pencil.line", accessibilityDescription: "Lint")
        button.imagePosition = .imageLeading
        button.title = String(localized: "檢查")
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.target = self
        button.action = #selector(tapped)
        button.setButtonType(.momentaryChange)
        button.focusRingType = .none

        card.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            button.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            button.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            button.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
            button.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
    }

    func setTitle(_ title: String) {
        button.title = title
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    @objc private func tapped() {
        onTap?()
    }

    // Nonactivating panels often skip NSButton tracking — treat any press on the chip as a tap.
    override func mouseDown(with event: NSEvent) {
        onTap?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) ?? self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

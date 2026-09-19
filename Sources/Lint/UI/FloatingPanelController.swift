import AppKit
import SwiftUI

private final class SuggestionBubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyDown?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    let viewModel: FloatingPanelViewModel
    /// Called with true when compact bubble is shown, false when dismissed.
    var onBubbleVisibilityChange: ((Bool) -> Void)?

    private var fullPanel: NSPanel?
    private var bubblePanel: SuggestionBubblePanel?
    private var bubbleChrome: BubbleChromeView?
    private var chipPanel: SuggestionBubblePanel?
    private var chipView: SelectionChipView?
    private var pendingChipCapture: TextCaptureService.CaptureResult?
    private var chipOutsideMonitor: Any?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var globalKeyMonitor: Any?
    private var bubbleKeyTap: BubbleKeyEventTap?
    private var uiPumpTask: Task<Void, Never>?
    /// True while Replace is hopping to the source app — do not steal key focus back.
    private var replacingInProgress = false
    private var bubbleActive = false
    /// Capture used to park the suggestion bubble (caret / text end), not the mouse.
    /// Frozen screen position for the bubble (captured once at show — do not re-query AX while Lint is key).
    private var bubbleAnchorPoint: NSPoint?
    /// Focused field / selection rect to avoid covering (Cocoa screen coords).
    private var bubbleAvoidRect: NSRect?
    /// Once the user drags, stop auto-repositioning on size changes.
    private var bubbleUserDragged = false
    /// Show the bubble without making Lint a regular, active app. Activating Lint while one of its own
    /// windows (Settings, full panel) sits on another Space makes macOS jump to that Space, taking the
    /// user away from the app they are typing in. Keys still work through `BubbleKeyEventTap`.
    private var bubbleNonActivating = false
    /// App that had the focus when a non-activating bubble opened; clicking the bubble activates Lint,
    /// so closing it hands the focus back.
    private var bubbleSourcePID: pid_t?

    init(viewModel: FloatingPanelViewModel) {
        self.viewModel = viewModel
        super.init()
        viewModel.onPrefetchStateChange = { [weak self] in
            self?.refreshChipTitle()
        }
        // Build every panel while Lint is still an accessory app. Panels first created after Lint turned
        // `.regular` (Settings open) did not show up in another app's fullscreen Space, and they are
        // cached for the process lifetime, so a late first use left the bubble on the wrong desktop.
        bubblePanel = makeBubblePanel()
        chipPanel = makeChipPanel()
        fullPanel = makeFullPanel()
    }

    var isVisible: Bool {
        (fullPanel?.isVisible == true) || (bubblePanel?.isVisible == true) || (chipPanel?.isVisible == true)
    }

    func run() {
        dismissChip()
        dismissBubble()
        showFull()
        viewModel.captureAndStream()
    }

    /// Selection settled — show a tiny chip only (do not call the model yet).
    func showSelectionChip(_ result: TextCaptureService.CaptureResult) {
        // Full ⌥⌘L panel or suggestion bubble open — ignore chips (and never hideFull).
        if fullPanel?.isVisible == true { return }
        if bubblePanel?.isVisible == true { return }
        pendingChipCapture = result
        hideFull()
        // Prefetch suggestion in the background so chip click / ⌥⌘K feels instant.
        viewModel.beginPrefetch(for: result)
        refreshChipTitle()
        guard viewModel.settings.showReadyChipNearField else {
            // Prefetch only — no floating chip over the editor.
            dismissChip(cancelPrefetch: false)
            return
        }
        showChipNearSelection(result)
        refreshChipTitle()
    }

    /// Hotkey ⌥⌘K: accept the visible chip, or check focused field / selection.
    /// Always uses the mini bubble — never the full ⌥⌘L panel.
    func activateCheckFromHotkey(capture: TextCaptureService) {
        if let pending = pendingChipCapture {
            runAutoSuggest(pending)
            return
        }
        if let snippet = capture.peekAXFocusedSnippet() {
            runAutoSuggest(snippet)
            return
        }
        if let selection = capture.peekAXSelection() {
            runAutoSuggest(selection)
            return
        }
        // Clipboard / broader capture fallback — still mini bubble, not full panel.
        Task { @MainActor in
            if let captured = await capture.capture(allowSelectAll: true) {
                self.runAutoSuggest(captured)
                return
            }
            self.showBubbleWithMessage(String(localized: "找不到可檢查的文字。請先選取，或把游標放在輸入框裡再按 ⌥⌘K。"))
        }
    }

    /// Show the mini bubble with an explanatory message (no model call).
    private func showBubbleWithMessage(_ message: String) {
        dismissChip()
        hideFull()
        viewModel.prepareMessageOnly(message)
        bubbleAnchorPoint = NSEvent.mouseLocation
        bubbleAvoidRect = nil
        bubbleUserDragged = false
        bubbleNonActivating = hasLintWindowOnAnotherSpace()
        showBubbleNearCapture()
    }

    private func hasLintWindowOnAnotherSpace() -> Bool {
        NSApp.windows.contains {
            $0.styleMask.contains(.titled) && $0.isVisible && !$0.isOnActiveSpace
        }
    }

    /// User clicked the chip (or wants immediate suggest).
    func runAutoSuggest(_ result: TextCaptureService.CaptureResult) {
        // Must adopt so Replace knows the AX element / range (⌥⌘K peek does not set lastCapture).
        viewModel.adoptCapture(result)
        // Consume prefetch before dismissing the chip so we do not cancel in-flight work.
        viewModel.consumePrefetchOrStream(result)
        dismissChip(cancelPrefetch: false)
        hideFull()
        bubbleAnchorPoint = Self.anchorPoint(for: result)
        bubbleAvoidRect = TextCaptureService.focusedFieldScreenRect(for: result)
            ?? TextCaptureService.selectionScreenRect(for: result)
        bubbleUserDragged = false
        bubbleNonActivating = hasLintWindowOnAnotherSpace()
        showBubbleNearCapture()
    }

    func dismissChip(cancelPrefetch: Bool = true) {
        removeChipOutsideMonitor()
        chipPanel?.orderOut(nil)
        pendingChipCapture = nil
        if cancelPrefetch {
            viewModel.cancelPrefetch()
        }
    }

    private func refreshChipTitle() {
        guard let chipView else { return }
        if viewModel.isPrefetchReady {
            chipView.setTitle(String(localized: "已就緒"))
        } else if viewModel.isPrefetching {
            chipView.setTitle(String(localized: "準備中"))
        } else {
            chipView.setTitle(String(localized: "檢查"))
        }
    }


    func dismissBubble() {
        uiPumpTask?.cancel()
        uiPumpTask = nil
        viewModel.cancelStream()
        removeOutsideClickMonitor()
        bubbleActive = false
        bubbleAnchorPoint = nil
        bubbleAvoidRect = nil
        bubbleUserDragged = false
        if bubbleNonActivating, NSApp.isActive,
           let pid = bubbleSourcePID, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            if #available(macOS 14.0, *) {
                NSApp.yieldActivation(to: app)
                _ = app.activate(from: NSRunningApplication.current)
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
        bubbleNonActivating = false
        bubblePanel?.orderOut(nil)
        onBubbleVisibilityChange?(false)
    }

    func hideFull() {
        let wasVisible = fullPanel?.isVisible == true
        fullPanel?.orderOut(nil)
        // Unpause selection monitor only if bubble is also gone.
        if wasVisible, bubblePanel?.isVisible != true {
            onBubbleVisibilityChange?(false)
        }
    }

    func showFull() {
        dismissChip()
        if fullPanel == nil {
            fullPanel = makeFullPanel()
        }
        guard let panel = fullPanel else { return }
        if panel.screen == nil { panel.center() }
        // Pause selection monitor BEFORE activating — otherwise live-watch /
        // clear-selection can call showSelectionChip → hideFull mid-typing.
        onBubbleVisibilityChange?(true)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func showBubbleNearCapture() {
        if bubblePanel == nil {
            bubblePanel = makeBubblePanel()
        }
        guard let panel = bubblePanel else { return }
        refreshBubbleChrome()
        applyBubbleFrameOrigin(panel)

        // Pause selection monitor BEFORE activating / showing so clear-selection
        // from focus change cannot dismiss us.
        bubbleActive = true
        onBubbleVisibilityChange?(true)

        // Same as Settings: .regular so the bubble can really become key and get keyDown.
        if bubbleNonActivating {
            bubbleSourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }

        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        if let chrome = bubbleChrome {
            _ = panel.makeFirstResponder(chrome)
        }
        installOutsideClickMonitor()
        startUIPump()
    }

    /// Park outside the focused field (prefer below/above), never covering the text.
    private func applyBubbleFrameOrigin(_ panel: NSPanel) {
        if bubbleUserDragged { return }

        let size = panel.frame.size
        let gap: CGFloat = 12

        let probeAnchor = bubbleAnchorPoint ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(probeAnchor, $0.frame, false) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)

        func clamp(_ origin: NSPoint) -> NSPoint {
            NSPoint(
                x: min(max(origin.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8)),
                y: min(max(origin.y, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))
            )
        }

        func onScreen(_ origin: NSPoint) -> Bool {
            let f = NSRect(origin: origin, size: size)
            return f.minX >= visible.minX + 4
                && f.maxX <= visible.maxX - 4
                && f.minY >= visible.minY + 4
                && f.maxY <= visible.maxY - 4
        }

        func clearOfText(_ origin: NSPoint) -> Bool {
            guard let avoid = bubbleAvoidRect else { return true }
            let padded = avoid.insetBy(dx: -6, dy: -6)
            return !NSRect(origin: origin, size: size).intersects(padded)
        }

        var candidates: [NSPoint] = []
        if let field = bubbleAvoidRect {
            let trailingX = field.maxX - size.width
            let leadingX = field.minX
            let centeredX = field.midX - size.width / 2
            // Prefer below the field (does not cover the composer).
            candidates.append(NSPoint(x: trailingX, y: field.minY - size.height - gap))
            candidates.append(NSPoint(x: centeredX, y: field.minY - size.height - gap))
            candidates.append(NSPoint(x: leadingX, y: field.minY - size.height - gap))
            // Then above.
            candidates.append(NSPoint(x: trailingX, y: field.maxY + gap))
            candidates.append(NSPoint(x: centeredX, y: field.maxY + gap))
            candidates.append(NSPoint(x: leadingX, y: field.maxY + gap))
            // Then left / right of the field.
            candidates.append(NSPoint(x: field.maxX + gap, y: field.midY - size.height / 2))
            candidates.append(NSPoint(x: field.minX - size.width - gap, y: field.midY - size.height / 2))
        } else if let anchor = bubbleAnchorPoint {
            // No field frame — sit above the caret, then below, then to the right.
            candidates.append(NSPoint(x: anchor.x - size.width / 2, y: anchor.y + gap))
            candidates.append(NSPoint(x: anchor.x + 10, y: anchor.y + gap))
            candidates.append(NSPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height - gap))
            candidates.append(NSPoint(x: anchor.x + 10, y: anchor.y - size.height / 2))
        } else {
            let mouse = NSEvent.mouseLocation
            candidates.append(NSPoint(x: mouse.x + 8, y: mouse.y + gap))
            candidates.append(NSPoint(x: mouse.x + 8, y: mouse.y - size.height - gap))
        }

        for raw in candidates {
            let origin = clamp(raw)
            if onScreen(origin), clearOfText(origin) {
                panel.setFrameOrigin(origin)
                return
            }
        }

        // Last resort: clamped first candidate (may slightly overlap if screen is tiny).
        let fallback = clamp(candidates.first ?? NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        panel.setFrameOrigin(fallback)
    }


    /// Resolve caret / text-end once, before Lint steals focus (AX goes stale afterward).
    private static func anchorPoint(for result: TextCaptureService.CaptureResult) -> NSPoint? {
        if let sel = TextCaptureService.selectionScreenRect(for: result),
           sel.width.isFinite, sel.height.isFinite,
           (sel.maxX > 24 || sel.maxY > 24) {
            if sel.height <= 48 {
                return NSPoint(x: sel.maxX, y: sel.midY)
            }
            return NSPoint(x: sel.minX, y: sel.minY)
        }
        if let mouse = InteractionAnchor.lastMouseUp {
            return mouse
        }
        return nil
    }

    private func startUIPump() {
        uiPumpTask?.cancel()
        uiPumpTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.refreshBubbleChrome()
                self.ensureBubbleKeyFocus()
                try? await Task.sleep(for: .milliseconds(100))
                if self.bubblePanel?.isVisible != true { break }
            }
        }
    }

    /// Keep the bubble key so Enter/R/Esc actually land (menu-bar apps lose focus easily).
    private func ensureBubbleKeyFocus() {
        guard !replacingInProgress else { return }
        guard let panel = bubblePanel, panel.isVisible, !bubbleNonActivating else { return }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        if NSApp.keyWindow !== panel || !panel.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            if let chrome = bubbleChrome {
                _ = panel.makeFirstResponder(chrome)
            }
        }
    }

    private func refreshBubbleChrome() {
        bubbleChrome?.apply(viewModel: viewModel)
        if let panel = bubblePanel, let chrome = bubbleChrome {
            let fitting = chrome.fittingSize
            if fitting.width > 1, fitting.height > 1 {
                panel.setContentSize(NSSize(
                    width: max(260, min(360, fitting.width)),
                    height: max(110, min(480, fitting.height))
                ))
                // Keep parked next to the text — setContentSize can nudge the frame.
                applyBubbleFrameOrigin(panel)
            }
        }
    }

    private func replaceFromBubble() {
        TextCaptureService.logPublic("REPLACE FROM BUBBLE originalCount=\(viewModel.originalText.count) resultCount=\(viewModel.resultText.count)")
        // Immediate UI feedback on the AppKit chrome (do not rely on Observation alone).
        viewModel.errorMessage = nil
        viewModel.statusNote = String(localized: "正在取代…")
        bubbleChrome?.apply(viewModel: viewModel)
        // Stop focus pump / monitors, then release key window so macOS 14+ yieldActivation can work.
        replacingInProgress = true
        uiPumpTask?.cancel()
        uiPumpTask = nil
        removeOutsideClickMonitor()
        bubblePanel?.orderOut(nil)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            let err = await viewModel.replaceOriginalReturningError()
            if let err {
                viewModel.statusNote = nil
                viewModel.errorMessage = err
                bubbleChrome?.apply(viewModel: viewModel)
                // Show bubble again so the user can retry / dismiss.
                if let panel = bubblePanel {
                    if !bubbleNonActivating {
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    panel.orderFrontRegardless()
                    panel.makeKeyAndOrderFront(nil)
                }
                replacingInProgress = false
                installOutsideClickMonitor()
                startUIPump()
                NSSound.beep()
                return
            }
            replacingInProgress = false
            dismissBubble()
        }
    }


    private func showChipNearSelection(_ result: TextCaptureService.CaptureResult) {
        if chipPanel == nil {
            chipPanel = makeChipPanel()
        }
        guard let panel = chipPanel else { return }

        let size = NSSize(width: 84, height: 32)
        panel.setContentSize(size)

        let screen = NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)

        let origin: NSPoint
        if let field = TextCaptureService.focusedFieldScreenRect(for: result) {
            // NEVER place inside the field (right-edge midY still overlaps wide composers).
            // Prefer just below the field, trailing-aligned; if no room, put just above.
            var x = field.maxX - size.width
            x = min(max(x, field.minX), visible.maxX - size.width - 8)
            x = max(x, visible.minX + 8)
            let below = field.minY - size.height - 10
            let above = field.maxY + 10
            if below >= visible.minY + 8 {
                origin = NSPoint(x: x, y: below)
            } else {
                origin = NSPoint(x: x, y: min(above, visible.maxY - size.height - 8))
            }
        } else if let sel = TextCaptureService.selectionScreenRect(for: result),
                  sel.width > 2 || sel.height > 2 {
            origin = NSPoint(
                x: min(max(sel.maxX - size.width, visible.minX + 8), visible.maxX - size.width - 8),
                y: max(visible.minY + 8, sel.minY - size.height - 10)
            )
        } else {
            let mouse = InteractionAnchor.lastMouseUp ?? NSEvent.mouseLocation
            origin = NSPoint(x: mouse.x + 10, y: mouse.y - size.height - 12)
        }

        var parked = origin
        parked.x = min(max(parked.x, visible.minX + 8), visible.maxX - size.width - 8)
        parked.y = min(max(parked.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(parked)
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        installChipOutsideMonitor()
    }

    private func makeChipPanel() -> SuggestionBubblePanel {
        let panel = SuggestionBubblePanel(
            contentRect: NSRect(x: 0, y: 0, width: 84, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let chip = SelectionChipView(frame: NSRect(x: 0, y: 0, width: 84, height: 32))
        chip.onTap = { [weak self] in
            self?.handleChipTap()
        }
        chip.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 84, height: 32))
        container.addSubview(chip)
        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            chip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            chip.topAnchor.constraint(equalTo: container.topAnchor),
            chip.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
        chipView = chip
        return panel
    }

    private func handleChipTap() {
        guard let pending = pendingChipCapture else {
            dismissChip()
            return
        }
        runAutoSuggest(pending)
    }

    private func installChipOutsideMonitor() {
        removeChipOutsideMonitor()
        // Global monitor: when another app is frontmost, nonactivating chip clicks often
        // never reach NSButton — treat an in-frame click as a tap.
        chipOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                guard let self, let panel = self.chipPanel, panel.isVisible else { return }
                let click = NSEvent.mouseLocation
                if panel.frame.insetBy(dx: -4, dy: -4).contains(click) {
                    if event.type == .leftMouseDown {
                        self.handleChipTap()
                    }
                    return
                }
                self.dismissChip()
            }
        }
    }

    private func removeChipOutsideMonitor() {
        if let chipOutsideMonitor {
            NSEvent.removeMonitor(chipOutsideMonitor)
            self.chipOutsideMonitor = nil
        }
    }


    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === fullPanel else { return }
        // Red-close does not go through hideFull(); still unpause selection monitor.
        if bubblePanel?.isVisible != true {
            onBubbleVisibilityChange?(false)
        }
    }

    private func makeFullPanel() -> NSPanel {
        // No `.nonactivatingPanel`: TextEditor in「原文」needs a real key window.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.title = "Lint"
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: FloatingPanelView(viewModel: viewModel))
        panel.delegate = self
        panel.center()
        return panel
    }

    private func makeBubblePanel() -> SuggestionBubblePanel {
        // IMPORTANT: no `.nonactivatingPanel` — accessory + nonactivating eats button clicks.
        let panel = SuggestionBubblePanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 140),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.acceptsMouseMovedEvents = true

        let chrome = BubbleChromeView(frame: NSRect(x: 0, y: 0, width: 280, height: 140))
        chrome.onReplace = { [weak self] in
            TextCaptureService.logPublic("button Replace clicked")
            self?.replaceFromBubble()
        }
        chrome.onRewrite = { [weak self] in
            self?.viewModel.retry()
        }
        chrome.onDismiss = { [weak self] in self?.dismissBubble() }
        chrome.onDragBegan = { [weak self] in
            self?.bubbleUserDragged = true
        }
        chrome.onKeyDown = { [weak self] event in
            self?.handleBubbleKey(event) ?? false
        }
        chrome.apply(viewModel: viewModel)
        panel.onKeyDown = { [weak self] event in
            self?.handleBubbleKey(event) ?? false
        }

        let container = ClickThroughDisabledView(frame: NSRect(x: 0, y: 0, width: 280, height: 140))
        chrome.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chrome)
        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: container.topAnchor),
            chrome.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
        bubbleChrome = chrome
        return panel
    }

    /// Enter → 取代, R → 重寫, Esc → 關閉. Returns true if consumed.
    @discardableResult
    private func handleBubbleKey(_ event: NSEvent) -> Bool {
        guard bubbleActive || bubblePanel?.isVisible == true else { return false }

        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let noMods = flags.isEmpty
        let cmdOnly = flags == .command
        guard noMods || cmdOnly else { return false }

        if event.keyCode == 53 {
            TextCaptureService.logPublic("bubble key Esc")
            dismissBubble()
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            TextCaptureService.logPublic("bubble key Enter resultCount=\(viewModel.resultText.count) streaming=\(viewModel.isStreaming) active=\(bubbleActive)")
            if viewModel.resultText.isEmpty {
                viewModel.statusNote = viewModel.isStreaming ? String(localized: "還在產生中…完成後再按 ⏎") : String(localized: "尚無建議可取代")
                bubbleChrome?.apply(viewModel: viewModel)
                NSSound.beep()
                return true
            }
            if viewModel.isStreaming {
                viewModel.cancelStream()
            }
            replaceFromBubble()
            return true
        }
        if event.keyCode == 15 {
            TextCaptureService.logPublic("bubble key R")
            if viewModel.originalText.isEmpty {
                NSSound.beep()
                return true
            }
            if viewModel.isStreaming {
                viewModel.cancelStream()
            }
            viewModel.retry()
            return true
        }
        return false
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in self?.handleOutsideClick(event) }
        }

        // Local monitor (when Lint is active).
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            var handled = false
            let work = { handled = self.handleBubbleKey(event) }
            if Thread.isMainThread {
                MainActor.assumeIsolated(work)
            } else {
                DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
            }
            return handled ? nil : event
        }

        // Session event tap: works even when another app stays frontmost after ⌥⌘K.
        let tap = BubbleKeyEventTap()
        tap.handler = { [weak self] event in
            self?.handleBubbleKey(event) ?? false
        }
        tap.start()
        bubbleKeyTap = tap
        TextCaptureService.logPublic("bubble key tap installed")
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        bubbleKeyTap?.stop()
        bubbleKeyTap = nil
    }

    private func handleOutsideClick(_ event: NSEvent) {
        guard let panel = bubblePanel, panel.isVisible else { return }
        let click = NSEvent.mouseLocation
        if panel.frame.insetBy(dx: -8, dy: -8).contains(click) {
            return
        }
        dismissBubble()
    }
}


/// System-wide keyDown tap so bubble shortcuts work after ⌥⌘K without relying on key-window focus.
private final class BubbleKeyEventTap: @unchecked Sendable {
    var handler: ((NSEvent) -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func start() {
        stop() // keeps `handler`: callers set it before start()
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let box = Unmanaged<BubbleKeyEventTap>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = box.tap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown else { return Unmanaged.passUnretained(event) }
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                // 36 return, 76 keypad enter, 53 esc, 15 R
                guard keyCode == 36 || keyCode == 76 || keyCode == 53 || keyCode == 15 else {
                    return Unmanaged.passUnretained(event)
                }
                guard let nsEvent = NSEvent(cgEvent: event) else {
                    return Unmanaged.passUnretained(event)
                }
                var handled = false
                let work = { handled = box.handler?(nsEvent) ?? false }
                if Thread.isMainThread {
                    work()
                } else {
                    DispatchQueue.main.sync(execute: work)
                }
                return handled ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            NSLog("Lint: bubble key tap failed — check Accessibility for Lint.app")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)!
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
    }
}

/// Container that never ignores mouse hits.
private final class ClickThroughDisabledView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) ?? self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

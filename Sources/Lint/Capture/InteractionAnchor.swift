import AppKit

/// Remembers the last mouse-up location so chips can sit near where the user finished selecting
/// when AX cannot resolve a tight selection rect (common in chat composers / web views).
@MainActor
enum InteractionAnchor {
    private(set) static var lastMouseUp: NSPoint?
    private static var monitor: Any?

    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { _ in
            Task { @MainActor in
                lastMouseUp = NSEvent.mouseLocation
            }
        }
    }
}

import AppKit
import ApplicationServices

@MainActor
final class RemotePointer {
    private(set) var dragging = false
    private var dragClickCount = 1
    private var magnifying = false
    private var magnifyPoint = CGPoint.zero
    var shiftHeld = false
    private let eventSource = CGEventSource(stateID: .privateState)
    private var modifiers: CGEventFlags { shiftHeld ? .maskShift : [] }
    func releaseAll() { endZoom(); endDrag(); shiftHeld = false }

    func validate() throws {
        guard AccessibilityInput.permitted else { throw InputFailure.permissionDenied }
    }
    private func displayBounds() -> [CGRect] {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
    func move(dx: Double, dy: Double) throws {
        try validate()
        guard dx.isFinite, dy.isFinite, abs(dx) <= 800, abs(dy) <= 800 else { throw LinkError.invalidMessage }
        guard let current = CGEvent(source: nil)?.location else { return }
        let proposed = CGPoint(x: current.x + dx, y: current.y + dy)
        let point = DesktopPointerGeometry.clamp(proposed, displays: displayBounds())
        let event = CGEvent(mouseEventSource: eventSource, mouseType: dragging ? .leftMouseDragged : .mouseMoved,
                            mouseCursorPosition: point, mouseButton: .left)
        event?.flags = modifiers
        if dragging { event?.setIntegerValueField(.mouseEventClickState, value: Int64(dragClickCount)) }
        event?.post(tap: .cghidEventTap)
    }
    func click(right: Bool = false, clickCount: Int = 1) throws {
        endDrag()
        try validate()
        guard let point = CGEvent(source: nil)?.location else { throw InputFailure.targetChanged }
        let down = PointerEventFactory.leftButton(pressed: true, point: point, shift: shiftHeld, clickCount: clickCount, right: right, source: eventSource)
        let up = PointerEventFactory.leftButton(pressed: false, point: point, shift: shiftHeld, clickCount: clickCount, right: right, source: eventSource)
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
    }
    func beginDrag(clickCount: Int = 1) throws {
        guard !dragging else { return }
        try validate()
        guard let point = CGEvent(source: nil)?.location,
              let event = PointerEventFactory.leftButton(pressed: true, point: point, shift: shiftHeld, clickCount: clickCount, source: eventSource) else { throw InputFailure.targetChanged }
        dragClickCount = clickCount
        dragging = true
        event.post(tap: .cghidEventTap)
    }
    func endDrag() {
        guard dragging else { return }
        dragging = false
        // Always balance the system-wide mouse-down, including on disconnect.
        if let point = CGEvent(source: nil)?.location {
            PointerEventFactory.leftButton(pressed: false, point: point, shift: shiftHeld, clickCount: dragClickCount, source: eventSource)?.post(tap: .cghidEventTap)
        }
    }
    func zoom(_ delta: Double) throws {
        try validate()
        guard delta.isFinite, (-0.8...1).contains(delta) else { throw LinkError.invalidMessage }
        if !magnifying {
            endDrag()
            magnifyPoint = CGEvent(source: nil)?.location ?? .zero
            guard let begin = MagnifyEventFactory.make(delta: 0, phase: .began, point: magnifyPoint, source: eventSource) else {
                throw InputFailure.unsupportedTarget
            }
            magnifying = true
            begin.post(tap: .cghidEventTap)
        }
        MagnifyEventFactory.make(delta: delta, phase: .changed, point: magnifyPoint, source: eventSource)?.post(tap: .cghidEventTap)
    }
    func endZoom() {
        guard magnifying else { return }
        magnifying = false
        MagnifyEventFactory.make(delta: 0, phase: .ended, point: magnifyPoint, source: eventSource)?.post(tap: .cghidEventTap)
    }
    func showDesktop() throws {
        releaseAll(); try validate()
        for pressed in [true, false] {
            let event = CGEvent(keyboardEventSource: eventSource, virtualKey: 103, keyDown: pressed) // F11
            event?.flags = .maskSecondaryFn
            event?.post(tap: .cghidEventTap)
        }
    }
    func missionControl() throws {
        releaseAll()
        try validate()
        for pressed in [true, false] {
            let event = CGEvent(keyboardEventSource: eventSource, virtualKey: 126, keyDown: pressed)
            event?.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
            event?.post(tap: .cghidEventTap)
        }
    }
    func desktop(_ direction: DesktopDirection) throws {
        endDrag()
        guard AccessibilityInput.permitted else { throw InputFailure.permissionDenied }
        // Explicit user-requested system action, independent of the service window,
        // so the next swipe can return from another Space.
        for pressed in [true, false] {
            let event = CGEvent(keyboardEventSource: eventSource, virtualKey: direction == .left ? 123 : 124, keyDown: pressed)
            event?.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
            event?.post(tap: .cghidEventTap)
        }
    }
    func scroll(dx: Double, dy: Double) throws {
        try validate()
        guard dx.isFinite, dy.isFinite, abs(dx) <= 800, abs(dy) <= 800,
              let point = CGEvent(source: nil)?.location else { throw InputFailure.targetChanged }
        let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel, wheelCount: 2,
                            wheel1: Int32(-dy.rounded()), wheel2: Int32(-dx.rounded()), wheel3: 0)
        event?.flags = modifiers
        event?.location = point
        event?.post(tap: .cghidEventTap)
    }
    func key(_ key: RemoteKey) throws {
        try validate()
        let code: CGKeyCode
        var flags: CGEventFlags = modifiers
        switch key {
        case .up: code = 126
        case .down: code = 125
        case .left: code = 123
        case .right: code = 124
        case .enter: code = 36
        case .tab: code = 48
        case .shiftTab: code = 48; flags.insert(.maskShift)
        case .escape: code = 53
        case .back: code = 33; flags.insert(.maskCommand)
        case .lockScreen: code = 12; flags = [.maskControl, .maskCommand]
        }
        for pressed in [true, false] {
            let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: pressed)
            event?.flags = flags; event?.post(tap: .cghidEventTap)
        }
    }
}

import Foundation
import CoreGraphics

/// A bounded, short-lived accumulator: moves never survive a disconnect or long stall.
struct PointerMotion {
    private(set) var x = 0.0
    private(set) var y = 0.0
    private var started: TimeInterval?
    static let maximumAge: TimeInterval = 0.15

    mutating func add(dx: Double, dy: Double, now: TimeInterval) {
        guard dx.isFinite, dy.isFinite else { return }
        if let started, now - started > Self.maximumAge { clear() }
        if started == nil { started = now }
        x = min(800, max(-800, x + dx))
        y = min(800, max(-800, y + dy))
    }
    mutating func take(now: TimeInterval) -> (Double, Double)? {
        defer { clear() }
        guard let started, now - started <= Self.maximumAge, x != 0 || y != 0 else { return nil }
        return (x, y)
    }
    mutating func clear() { x = 0; y = 0; started = nil }
}

/// State machine shared by UIKit and tests. Every synthetic press is balanced.
struct PadGesture {
    enum Action: Equatable {
        case move(Double, Double), scroll(Double, Double), click, rightClick
        case zoom(Double), zoomEnd, showDesktop
        case dragBegin, doubleClick, dragEnd, missionControlDismiss, missionControl, desktop(DesktopDirection)
    }
    private var initialRadius = 0.0
    private var zoomRadius = 0.0
    private(set) var pinching = false
    private var count = 0
    private var peakCount = 0
    private var previous = CGPoint.zero
    private var origin = CGPoint.zero
    private var travel = 0.0
    private var start = 0.0
    private(set) var dragging = false
    private(set) var dragStartDelta = CGPoint.zero
    private var dragFingers = 0
    private var dragReleaseAt: TimeInterval?
    var dragReleaseDeadline: TimeInterval? { dragReleaseAt }
    static let threeFingerDragGrace: TimeInterval = 0.8
    private var hadPress = false
    private var secondTap = false
    private var swipeX = 0.0
    private var swipeY = 0.0
    private var switched = false
    private var lastTapAt: TimeInterval?
    private var lastTapPoint = CGPoint.zero

    mutating func reset() { self = Self() }
    mutating func expire(now: TimeInterval) -> Action? {
        guard dragFingers == 3, let dragReleaseAt, now >= dragReleaseAt else { return nil }
        reset()
        return .dragEnd
    }
    mutating func update(points: [CGPoint], now: TimeInterval) -> Action? {
        if let action = expire(now: now) { return action }
        if dragging && dragFingers == 3, dragReleaseAt != nil {
            if points.count == 3 {
                self.dragReleaseAt = nil
                count = 0
                peakCount = 3
                hadPress = true
            } else if points.count == 0 {
                return nil
            } else if points.count > 3 {
                reset()
                return .dragEnd
            } else {
                // A three-finger lift often arrives as 3 → 2 → 1 → 0.
                // Keep the press, but do not treat the remaining fingers as a scroll.
                return nil
            }
        }
        guard !points.isEmpty else {
            let wasPinching = pinching
            let wasDragging = dragging
            if wasDragging && dragFingers == 3 {
                dragReleaseAt = now + Self.threeFingerDragGrace
                count = 0
                return nil
            }
            let secondClick = secondTap && !dragging && peakCount == 1
            let shortTap = count > 0 && !hadPress && travel <= 8 && now - start <= 0.35
            let click = shortTap && peakCount == 1
            let rightClick = shortTap && peakCount == 2
            let tapPoint = origin
            reset()
            if click { lastTapAt = now; lastTapPoint = tapPoint }
            if wasPinching { return .zoomEnd }
            return wasDragging ? .dragEnd : (secondClick ? .doubleClick : (click ? .click : (rightClick ? .rightClick : nil)))
        }
        let center = CGPoint(x: points.map(\.x).reduce(0, +) / Double(points.count),
                             y: points.map(\.y).reduce(0, +) / Double(points.count))
        let radius = points.map { hypot($0.x - center.x, $0.y - center.y) }.reduce(0, +) / Double(points.count)
        if count != points.count { initialRadius = radius; zoomRadius = radius }
        if count == 0 {
            start = now; origin = center
            if points.count == 1, let lastTapAt, now - lastTapAt <= 0.32,
               hypot(center.x - lastTapPoint.x, center.y - lastTapPoint.y) <= 35 {
                self.lastTapAt = nil
                count = 1; peakCount = 1; previous = center
                secondTap = true; hadPress = true
                return nil
            }
            lastTapAt = nil
        }
        peakCount = max(peakCount, points.count)
        if points.count != 1 { secondTap = false }
        defer { count = points.count; previous = center }
        if pinching && points.count != 2 { pinching = false; hadPress = true; return .zoomEnd }
        if dragging && points.count != dragFingers {
            if dragFingers == 3 && points.count < 3 {
                dragReleaseAt = now + Self.threeFingerDragGrace
                count = 0
                return nil
            }
            dragging = false
            return .dragEnd
        }
        guard count == points.count else { return nil }
        let dx = Double(center.x - previous.x), dy = Double(center.y - previous.y)
        travel += hypot(dx, dy)
        if count == 2 && peakCount == 2 && !hadPress {
            if !pinching && abs(radius - initialRadius) >= 10 && abs(radius - initialRadius) > travel * 0.65 {
                pinching = true
            }
            if pinching {
                // Radius changes also count as travel, preventing a right click on lift.
                travel = max(travel, 9)
                if abs(radius - zoomRadius) >= 0.1, zoomRadius > 1 {
                    let delta = min(1, max(-0.8, radius / zoomRadius - 1))
                    zoomRadius = radius
                    return .zoom(delta)
                }
                return nil
            }
        }
        if count == 4 && peakCount == 4 && !switched && initialRadius > 10 &&
            abs(radius - initialRadius) > max(24, initialRadius * 0.3) &&
            abs(radius - initialRadius) > hypot(swipeX + dx, swipeY + dy) * 0.8 {
            switched = true
            return .showDesktop // Both spread and pinch toggle Show Desktop.
        }
        guard dx != 0 || dy != 0 else { return nil }
        if count == 1 && peakCount == 1 {
            if secondTap && !dragging {
                if travel > 4 { dragging = true; dragFingers = 1; dragStartDelta = CGPoint(x: center.x - origin.x, y: center.y - origin.y); return .dragBegin }
                return nil
            }
            return .move(dx, dy)
        }
        if count == 2 && peakCount == 2 && !hadPress { return .scroll(dx, dy) }
        if count == 3 && peakCount == 3 {
            if dragging { return .move(dx, dy) }
            if travel > 8 { dragging = true; dragFingers = 3; hadPress = true; dragStartDelta = CGPoint(x: dx, y: dy); return .dragBegin }
        }
        if count == 4 && peakCount == 4 && !switched {
            swipeX += dx; swipeY += dy
            if swipeY <= -70 && abs(swipeY) > abs(swipeX) * 1.4 {
                switched = true
                return .missionControl
            }
            if swipeY >= 70 && abs(swipeY) > abs(swipeX) * 1.4 {
                switched = true
                return .missionControlDismiss
            }
            if abs(swipeX) >= 70 && abs(swipeX) > abs(swipeY) * 1.4 {
                switched = true
                return .desktop(swipeX < 0 ? .right : .left)
            }
        }
        return nil
    }
}

/// Quartz display coordinates support external monitors on either side/above.
enum DesktopPointerGeometry {
    static func clamp(_ point: CGPoint, displays: [CGRect]) -> CGPoint {
        let valid = displays.filter { $0.width > 1 && $0.height > 1 }
        if valid.contains(where: { $0.contains(point) }) { return point }
        return valid.map { rect in
            CGPoint(x: min(rect.maxX - 1, max(rect.minX, point.x)),
                    y: min(rect.maxY - 1, max(rect.minY, point.y)))
        }.min { a, b in
            hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
        } ?? point
    }
}

#if os(macOS)
enum PointerEventFactory {
    static func leftButton(pressed: Bool, point: CGPoint, shift: Bool, clickCount: Int = 1, right: Bool = false, source suppliedSource: CGEventSource? = nil) -> CGEvent? {
        guard let source = suppliedSource ?? CGEventSource(stateID: .privateState),
              let event = CGEvent(mouseEventSource: source,
                                  mouseType: right ? (pressed ? .rightMouseDown : .rightMouseUp) : (pressed ? .leftMouseDown : .leftMouseUp),
                                  mouseCursorPosition: point, mouseButton: right ? .right : .left) else { return nil }
        // Never inherit Control: Control + left click opens a secondary-click menu.
        event.flags = shift ? .maskShift : []
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event.setIntegerValueField(.mouseEventButtonNumber, value: right ? 1 : 0)
        return event
    }
}
#endif

#if os(macOS)
/// Undocumented Quartz gesture encoding. Isolate it here; never replace failure
/// with keyboard shortcuts. Verified through NSEvent conversion on the host OS.
/// Encoding reference: https://github.com/noah-nuebling/mac-mouse-fix/discussions/366
/// HID phase bits differ from NSEvent.Phase raw values.
enum MagnifyEventFactory {
    enum Phase: Int64 { case began = 1, changed = 2, ended = 4, cancelled = 8 }
    static func make(delta: Double, phase: Phase, point: CGPoint, source: CGEventSource? = nil) -> CGEvent? {
        guard delta.isFinite, (-0.8...1).contains(delta), let event = CGEvent(source: source) else { return nil }
        event.type = CGEventType(rawValue: 29)!
        event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)
        event.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase.rawValue)
        event.setDoubleValueField(CGEventField(rawValue: 113)!, value: delta)
        event.flags = []
        event.location = point
        return event
    }
}
#endif

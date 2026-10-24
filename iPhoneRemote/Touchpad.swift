import SwiftUI
import UIKit

struct Touchpad: UIViewRepresentable {
    let move: (Double, Double) -> Void
    let scroll: (Double, Double) -> Void
    let tap: () -> Void
    let rightTap: () -> Void
    let doubleClick: () -> Void
    let drag: (Bool) -> Void
    let desktop: (DesktopDirection) -> Void
    let missionControl: () -> Void
    let missionControlDismiss: () -> Void
    let zoom: (Double) -> Void
    let zoomEnd: () -> Void
    let showDesktop: () -> Void

    func makeUIView(context: Context) -> PadView { PadView() }
    func updateUIView(_ view: PadView, context: Context) {
        view.move = move; view.scroll = scroll; view.tap = tap; view.rightTap = rightTap; view.doubleClick = doubleClick
        view.zoomEnd = zoomEnd; view.zoom = zoom; view.showDesktop = showDesktop
        view.drag = drag; view.desktop = desktop; view.missionControl = missionControl; view.missionControlDismiss = missionControlDismiss
    }
}

/// Receives touches directly in a dedicated, non-scrolling screen. Changing finger
/// count resets the centroid so adding/removing a finger cannot jump the cursor.
final class PadView: UIView {
    var move: ((Double, Double) -> Void)?
    var scroll: ((Double, Double) -> Void)?
    var tap: (() -> Void)?
    var rightTap: (() -> Void)?
    var doubleClick: (() -> Void)?
    var drag: ((Bool) -> Void)?
    var desktop: ((DesktopDirection) -> Void)?
    var missionControl: (() -> Void)?
    var missionControlDismiss: (() -> Void)?
    var zoom: ((Double) -> Void)?
    var zoomEnd: (() -> Void)?
    var showDesktop: (() -> Void)?
    private var fingers: [ObjectIdentifier: CGPoint] = [:]
    private var gesture = PadGesture()
    private var lastSize = CGSize.zero
    private var dragReleaseTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.secondarySystemBackground
        isMultipleTouchEnabled = true
        accessibilityLabel = "Mac 터치패드. 한 손가락 이동, 탭으로 클릭, 두 손가락으로 스크롤, 세 손가락 드래그, 네 손가락 좌우 데스크톱 전환"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { update(touches, ending: false) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { update(touches, ending: false) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { update(touches, ending: true) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        dragReleaseTimer?.invalidate(); dragReleaseTimer = nil
        if gesture.pinching { zoomEnd?() }; if gesture.dragging { drag?(false) }; fingers.removeAll(); gesture.reset()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if lastSize != bounds.size {
            dragReleaseTimer?.invalidate(); dragReleaseTimer = nil
            // Rotation/keyboard layout must not turn old coordinates into movement.
            if gesture.pinching { zoomEnd?() }; if gesture.dragging { drag?(false) }
            fingers.removeAll(); gesture.reset()
            lastSize = bounds.size
        }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            dragReleaseTimer?.invalidate(); dragReleaseTimer = nil
            if gesture.pinching { zoomEnd?() }; if gesture.dragging { drag?(false) }; fingers.removeAll(); gesture.reset()
        }
    }
    private func update(_ touches: Set<UITouch>, ending: Bool) {
        // Ignore the remainder of a gesture cancelled by a size/rotation change.
        let accepted = touches.filter { $0.phase == .began || fingers[ObjectIdentifier($0)] != nil }
        guard !accepted.isEmpty else { return }
        for touch in accepted { fingers[ObjectIdentifier(touch)] = touch.location(in: self) }
        // Account for final travel before lifting, including a quick swipe whose
        // final displacement arrives only in touchesEnded.
        if ending { emit(gesture.update(points: Array(fingers.values), now: ProcessInfo.processInfo.systemUptime)) }
        if ending { for touch in touches { fingers.removeValue(forKey: ObjectIdentifier(touch)) } }
        emit(gesture.update(points: Array(fingers.values), now: ProcessInfo.processInfo.systemUptime))
        scheduleDragReleaseIfNeeded()
    }
    private func scheduleDragReleaseIfNeeded() {
        dragReleaseTimer?.invalidate(); dragReleaseTimer = nil
        guard let deadline = gesture.dragReleaseDeadline else { return }
        let interval = max(0.01, deadline - ProcessInfo.processInfo.systemUptime + 0.02)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.emit(self.gesture.expire(now: ProcessInfo.processInfo.systemUptime))
            self.dragReleaseTimer = nil
        }
        dragReleaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func emit(_ action: PadGesture.Action?) {
        switch action {
        case let .move(x, y): move?(x, y)
        case let .scroll(x, y): scroll?(x, y)
        case let .zoom(enlarge): zoom?(enlarge)
        case .zoomEnd: zoomEnd?()
        case .showDesktop: showDesktop?()
        case .click: tap?()
        case .rightClick: rightTap?()
        case .doubleClick: doubleClick?()
        case .dragBegin:
            drag?(true)
            move?(gesture.dragStartDelta.x, gesture.dragStartDelta.y)
        case .dragEnd: drag?(false)
        case let .desktop(direction): desktop?(direction)
        case .missionControl: missionControl?()
        case .missionControlDismiss: missionControlDismiss?()
        case nil: break
        }
    }
}

import XCTest
import CoreGraphics
@testable import RemoteCore

final class RemoteInteractionTests: XCTestCase {
    func testMovesAreCoalescedAndClearedAfterDelivery() {
        var motion = PointerMotion()
        motion.add(dx: 2, dy: -3, now: 0)
        motion.add(dx: 4, dy: 1, now: 0.01)
        let value = motion.take(now: 0.02)
        XCTAssertEqual(value?.0, 6); XCTAssertEqual(value?.1, -2)
        XCTAssertNil(motion.take(now: 0.03))
    }
    func testOldMovementIsDroppedOnStallOrDisconnect() {
        var motion = PointerMotion()
        motion.add(dx: 100, dy: 100, now: 0)
        XCTAssertNil(motion.take(now: 1))
        motion.add(dx: 100, dy: 100, now: 1)
        motion.clear()
        XCTAssertNil(motion.take(now: 1.01))
    }
    func testFreshMovementDoesNotIncludeStaleMovement() {
        var motion = PointerMotion()
        motion.add(dx: 100, dy: 100, now: 0)
        motion.add(dx: 2, dy: 3, now: 1)
        let value = motion.take(now: 1.01)
        XCTAssertEqual(value?.0, 2); XCTAssertEqual(value?.1, 3)
    }
    func testNonFiniteAndExcessiveMovementIsBounded() {
        var motion = PointerMotion()
        motion.add(dx: .infinity, dy: .nan, now: 0)
        XCTAssertNil(motion.take(now: 0.01))
        motion.add(dx: 50_000, dy: -50_000, now: 1)
        let value = motion.take(now: 1.01)
        XCTAssertEqual(value?.0, 800); XCTAssertEqual(value?.1, -800)
    }
    func testDismissalRejectsLateKeyboardBaseline() {
        var state = KeyboardNegotiation()
        let request = state.request()
        state.cancel()
        XCTAssertFalse(state.accept(request))
    }
    func testNewFieldRejectsPriorFieldAndDuplicateBaseline() {
        var state = KeyboardNegotiation()
        let first = state.request()
        let second = state.request()
        XCTAssertFalse(state.accept(first))
        XCTAssertTrue(state.accept(second))
        XCTAssertFalse(state.accept(second))
    }
}

final class PadGestureTests: XCTestCase {
    func testShortTapClicksExactlyOnce() {
        var pad = PadGesture()
        XCTAssertNil(pad.update(points: [.zero], now: 0))
        XCTAssertEqual(pad.update(points: [], now: 0.1), .click)
        XCTAssertNil(pad.update(points: [], now: 0.2))
    }
    func testMovingOrHoldingDoesNotClick() {
        var pad = PadGesture()
        _ = pad.update(points: [.zero], now: 0)
        XCTAssertEqual(pad.update(points: [CGPoint(x: 20, y: 5)], now: 0.1), .move(20, 5))
        XCTAssertNil(pad.update(points: [], now: 0.2))
        _ = pad.update(points: [.zero], now: 1)
        XCTAssertNil(pad.update(points: [], now: 2))
    }
    func testSecondFingerRebasesAndScrollsWithoutCursorJumpOrClick() {
        var pad = PadGesture()
        _ = pad.update(points: [.zero], now: 0)
        XCTAssertNil(pad.update(points: [.zero, CGPoint(x: 100, y: 0)], now: 0.02))
        XCTAssertEqual(pad.update(points: [CGPoint(x: 3, y: 12), CGPoint(x: 103, y: 12)], now: 0.04), .scroll(3, 12))
        XCTAssertNil(pad.update(points: [CGPoint(x: 103, y: 12)], now: 0.06))
        XCTAssertNil(pad.update(points: [CGPoint(x: 110, y: 20)], now: 0.08))
        XCTAssertNil(pad.update(points: [], now: 0.1))
    }
    func testCancellationAndUnsupportedFingerCountsNeverClick() {
        var pad = PadGesture()
        _ = pad.update(points: [.zero], now: 0)
        pad.reset()
        XCTAssertNil(pad.update(points: [], now: 0.1))
        _ = pad.update(points: [.zero, .zero, .zero], now: 1)
        XCTAssertNil(pad.update(points: [.zero, CGPoint(x: 5, y: 10)], now: 1.1))
        XCTAssertNil(pad.update(points: [], now: 1.2))
    }
}

final class MultiFingerGestureTests: XCTestCase {
    private func points(_ count: Int, x: Double = 0, y: Double = 0) -> [CGPoint] {
        (0..<count).map { CGPoint(x: Double($0) * 30 + x, y: y) }
    }
    func testThreeFingerDragContinuesAfterBriefLift() {
        var pad = PadGesture()
        XCTAssertNil(pad.update(points: points(3), now: 0))
        XCTAssertEqual(pad.update(points: points(3, x: 10), now: 0.1), .dragBegin)
        XCTAssertEqual(pad.update(points: points(3, x: 20), now: 0.2), .move(10, 0))
        XCTAssertNil(pad.update(points: points(2, x: 20), now: 0.3))
        XCTAssertNil(pad.update(points: [], now: 0.4))
        XCTAssertTrue(pad.dragging)
        XCTAssertNil(pad.update(points: points(3, x: 100), now: 0.6))
        XCTAssertEqual(pad.update(points: points(3, x: 110), now: 0.7), .move(10, 0))
        XCTAssertTrue(pad.dragging)
        XCTAssertNil(pad.update(points: [], now: 0.8))
        XCTAssertNil(pad.expire(now: 1.5))
        XCTAssertEqual(pad.expire(now: 1.61), .dragEnd)
        XCTAssertFalse(pad.dragging)
    }
    func testFourFingerSwipeSwitchesOnceAndNeverStartsDragOrClicks() {
        var pad = PadGesture()
        _ = pad.update(points: points(3), now: 0)
        XCTAssertNil(pad.update(points: points(4), now: 0.01))
        XCTAssertEqual(pad.update(points: points(4, x: -80), now: 0.1), .desktop(.right))
        XCTAssertNil(pad.update(points: points(4, x: -160), now: 0.2))
        XCTAssertNil(pad.update(points: points(3, x: -160), now: 0.3))
        XCTAssertNil(pad.update(points: [], now: 0.4))
    }
    func testDownDismissesAndRightSwipeStillGoesToLeftSpace() {
        var pad = PadGesture()
        _ = pad.update(points: points(4), now: 0)
        XCTAssertEqual(pad.update(points: points(4, y: 100), now: 0.1), .missionControlDismiss)
        _ = pad.update(points: [], now: 0.2)
        _ = pad.update(points: points(4), now: 1)
        XCTAssertEqual(pad.update(points: points(4, x: 80), now: 1.1), .desktop(.left))
    }
    func testThreeFingerDragReleasesAfterGraceAndResetsOnCancellation() {
        var pad = PadGesture()
        _ = pad.update(points: points(3), now: 0)
        _ = pad.update(points: points(3, x: 10), now: 0.1)
        XCTAssertNil(pad.update(points: [], now: 0.2))
        XCTAssertTrue(pad.dragging)
        XCTAssertEqual(pad.expire(now: 1.01), .dragEnd)
        XCTAssertFalse(pad.dragging)
        _ = pad.update(points: points(3), now: 1)
        _ = pad.update(points: points(3, x: 10), now: 1.1)
        XCTAssertTrue(pad.dragging)
        pad.reset()
        XCTAssertFalse(pad.dragging)
    }
    func testThreeFingerDragDoesNotTurnRemainingFingersIntoScroll() {
        var pad = PadGesture()
        _ = pad.update(points: points(3), now: 0)
        _ = pad.update(points: points(3, x: 12), now: 0.1)
        XCTAssertNil(pad.update(points: points(2, x: 12), now: 0.2))
        XCTAssertNil(pad.update(points: points(2, x: 50), now: 0.3))
        XCTAssertEqual(pad.expire(now: 1.01), .dragEnd)
    }
    func testOneFingerDragStillReleasesImmediately() {
        var pad = PadGesture()
        _ = pad.update(points: [.zero], now: 0)
        _ = pad.update(points: [], now: 0.05)
        _ = pad.update(points: [.zero], now: 0.15)
        XCTAssertEqual(pad.update(points: [CGPoint(x: 10, y: 0)], now: 0.2), .dragBegin)
        XCTAssertEqual(pad.update(points: [], now: 0.3), .dragEnd)
    }
    func testNewCommandsRoundTrip() throws {
        for command: RemoteCommand in [.dragBegin, .dragEnd, .desktop(.left), .desktop(.right), .key(.lockScreen)] {
            let data = try JSONEncoder().encode(command)
            let decoded = try JSONDecoder().decode(RemoteCommand.self, from: data)
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            XCTAssertEqual(try encoder.encode(command), try encoder.encode(decoded))
        }
    }
}

final class DesktopPointerGeometryTests: XCTestCase {
    func testMovementAcrossDisplaysIsNotConfinedToServiceWindow() {
        let displays = [CGRect(x: 0, y: 0, width: 1000, height: 800),
                        CGRect(x: 1000, y: -200, width: 1600, height: 1000)]
        let target = CGPoint(x: 1300, y: -100)
        XCTAssertEqual(DesktopPointerGeometry.clamp(target, displays: displays), target)
    }
    func testNegativeCoordinatesAndDisplayEdges() {
        let displays = [CGRect(x: -1200, y: 0, width: 1200, height: 800),
                        CGRect(x: 0, y: 0, width: 1000, height: 800)]
        XCTAssertEqual(DesktopPointerGeometry.clamp(CGPoint(x: -400, y: 100), displays: displays), CGPoint(x: -400, y: 100))
        XCTAssertEqual(DesktopPointerGeometry.clamp(CGPoint(x: 1400, y: 900), displays: displays), CGPoint(x: 999, y: 799))
    }
}

#if os(macOS)
final class PointerButtonTests: XCTestCase {
    func testTapCreatesOnlyLeftClickWithoutControlOrSecondaryButton() throws {
        for pressed in [true, false] {
            let event = try XCTUnwrap(PointerEventFactory.leftButton(pressed: pressed, point: .zero, shift: false))
            XCTAssertEqual(event.type, pressed ? .leftMouseDown : .leftMouseUp)
            XCTAssertEqual(event.getIntegerValueField(.mouseEventButtonNumber), 0)
            XCTAssertEqual(event.getIntegerValueField(.mouseEventClickState), 1)
            XCTAssertEqual(event.flags.rawValue, 0)
        }
    }
    func testShiftClickDoesNotAddControl() throws {
        let event = try XCTUnwrap(PointerEventFactory.leftButton(pressed: true, point: .zero, shift: true))
        XCTAssertEqual(event.flags, .maskShift)
        XCTAssertFalse(event.flags.contains(.maskControl))
    }
    func testShiftCommandsRoundTrip() throws {
        for state in [true, false] {
            let data = try JSONEncoder().encode(RemoteCommand.shift(state))
            guard case .shift(let decoded) = try JSONDecoder().decode(RemoteCommand.self, from: data) else {
                return XCTFail("Expected shift command")
            }
            XCTAssertEqual(decoded, state)
        }
    }
}
#endif

final class TapGestureTests: XCTestCase {
    func testStationaryTwoFingerTapIsRightClickAndScrollIsNot() {
        var pad = PadGesture()
        let pair = [CGPoint.zero, CGPoint(x: 30, y: 0)]
        _ = pad.update(points: pair, now: 0)
        _ = pad.update(points: [pair[0]], now: 0.1)
        XCTAssertEqual(pad.update(points: [], now: 0.15), .rightClick)
        _ = pad.update(points: pair, now: 1)
        XCTAssertEqual(pad.update(points: pair.map { CGPoint(x: $0.x, y: 20) }, now: 1.1), .scroll(0, 20))
        _ = pad.update(points: [.zero], now: 1.2)
        XCTAssertNil(pad.update(points: [], now: 1.25))
    }
    func testDoubleTapIsDeferredUntilSecondRelease() {
        var pad = PadGesture()
        _ = pad.update(points: [.zero], now: 0)
        XCTAssertEqual(pad.update(points: [], now: 0.05), .click)
        XCTAssertNil(pad.update(points: [.zero], now: 0.15))
        XCTAssertEqual(pad.update(points: [], now: 0.2), .doubleClick)
        XCTAssertFalse(pad.dragging)
    }
    func testDoubleTapHoldMovesWhilePressedAndReleases() {
        var pad = PadGesture()
        _ = pad.update(points: [.zero], now: 0)
        _ = pad.update(points: [], now: 0.05)
        XCTAssertNil(pad.update(points: [.zero], now: 0.15))
        XCTAssertEqual(pad.update(points: [CGPoint(x: 20, y: 10)], now: 0.25), .dragBegin)
        XCTAssertEqual(pad.update(points: [CGPoint(x: 30, y: 20)], now: 0.35), .move(10, 10))
        XCTAssertTrue(pad.dragging)
        XCTAssertEqual(pad.update(points: [], now: 1), .dragEnd)
    }
    func testSlowOrDistantSecondTapIsNotDoubleClick() {
        var pad = PadGesture()
        _ = pad.update(points: [.zero], now: 0)
        _ = pad.update(points: [], now: 0.05)
        XCTAssertNil(pad.update(points: [.zero], now: 0.5))
        _ = pad.update(points: [], now: 0.55)
        XCTAssertNil(pad.update(points: [CGPoint(x: 100, y: 0)], now: 0.65))
    }
    func testAddingFingerCancelsPendingDoubleClickWithoutRightClick() {
        var pad = PadGesture()
        _ = pad.update(points: [.zero], now: 0)
        _ = pad.update(points: [], now: 0.05)
        _ = pad.update(points: [.zero], now: 0.1)
        XCTAssertNil(pad.update(points: [.zero, CGPoint(x: 30, y: 0)], now: 0.15))
        XCTAssertNil(pad.update(points: [], now: 0.2))
    }
}

final class PendingKeyboardTextTests: XCTestCase {
    func testPendingKoreanCompositionReplacesExistingSelection() throws {
        let baseline = TextSnapshot(text: "abOLDcd", selection: .init(location: 2, length: 3), marked: nil)
        let draft = TextSnapshot(text: "한", selection: .init(location: 1, length: 0), marked: .init(location: 0, length: 1))
        let merged = try PendingKeyboardText.merge(draft, into: baseline)
        XCTAssertEqual(merged.text, "ab한cd")
        XCTAssertEqual(merged.selection, .init(location: 3, length: 0))
        XCTAssertEqual(merged.marked, .init(location: 2, length: 1))
    }
    func testEmptyDraftDoesNotDeleteMacSelection() throws {
        let baseline = TextSnapshot(text: "keep", selection: .init(location: 0, length: 4), marked: nil)
        XCTAssertEqual(try PendingKeyboardText.merge(CompositionFixture.snapshot(""), into: baseline), baseline)
    }
    func testUnicodeDraftAndInvalidSelection() throws {
        let baseline = TextSnapshot(text: "😀!", selection: .init(location: 2, length: 0), marked: nil)
        let draft = TextSnapshot(text: "🎉", selection: .init(location: 2, length: 0), marked: nil)
        let merged = try PendingKeyboardText.merge(draft, into: baseline)
        XCTAssertEqual(merged.text, "😀🎉!")
        XCTAssertEqual(merged.selection.location, 4)
        let invalid = TextSnapshot(text: "😀", selection: .init(location: 1, length: 0), marked: nil)
        XCTAssertThrowsError(try PendingKeyboardText.merge(draft, into: invalid))
    }
}

#if os(macOS)
final class SecondaryClickTests: XCTestCase {
    func testRightClickAndDoublePressFields() throws {
        for pressed in [true, false] {
            let right = try XCTUnwrap(PointerEventFactory.leftButton(pressed: pressed, point: .zero, shift: false, right: true))
            XCTAssertEqual(right.type, pressed ? .rightMouseDown : .rightMouseUp)
            XCTAssertEqual(right.getIntegerValueField(.mouseEventButtonNumber), 1)
            let second = try XCTUnwrap(PointerEventFactory.leftButton(pressed: pressed, point: .zero, shift: false, clickCount: 2))
            XCTAssertEqual(second.type, pressed ? .leftMouseDown : .leftMouseUp)
            XCTAssertEqual(second.getIntegerValueField(.mouseEventClickState), 2)
            XCTAssertEqual(second.getIntegerValueField(.mouseEventButtonNumber), 0)
        }
    }
}
#endif

final class NativeTextEditTests: XCTestCase {
    func testKoreanRecompositionReplacesPreviousSyllable() throws {
        let edit = try NativeTextEdit.between(CompositionFixture.snapshot("하"), CompositionFixture.snapshot("한"))
        XCTAssertEqual(edit, .init(deleteCount: 1, insert: "한"))
    }
    func testEmojiDeletionUsesGraphemesNotUTF16CodeUnits() throws {
        let edit = try NativeTextEdit.between(CompositionFixture.snapshot("a👨‍👩‍👧‍👦"), CompositionFixture.snapshot("a"))
        XCTAssertEqual(edit, .init(deleteCount: 1, insert: ""))
    }
    func testAppendNeverDeletesMacExistingContents() throws {
        let edit = try NativeTextEdit.between(CompositionFixture.snapshot(""), CompositionFixture.snapshot("검색"))
        XCTAssertEqual(edit, .init(deleteCount: 0, insert: "검색"))
    }
    func testNonTerminalSelectionIsRejected() {
        let next = TextSnapshot(text: "abc", selection: .init(location: 1, length: 0), marked: nil)
        XCTAssertThrowsError(try NativeTextEdit.between(CompositionFixture.snapshot("abc"), next))
    }
}

final class MissionControlGestureTests: XCTestCase {
    func testFourFingerUpTriggersOnlyOnceUntilLift() {
        var pad = PadGesture()
        let points = (0..<4).map { CGPoint(x: $0 * 25, y: 100) }
        _ = pad.update(points: points, now: 0)
        XCTAssertEqual(pad.update(points: points.map { CGPoint(x: $0.x, y: 20) }, now: 0.1), .missionControl)
        XCTAssertNil(pad.update(points: points.map { CGPoint(x: $0.x, y: -100) }, now: 0.2))
        XCTAssertNil(pad.update(points: [], now: 0.3))
    }
    func testDiagonalIgnoredAndDownDismissesMissionControl() {
        var pad = PadGesture()
        _ = pad.update(points: Array(repeating: .zero, count: 4), now: 0)
        XCTAssertNil(pad.update(points: Array(repeating: CGPoint(x: 80, y: -80), count: 4), now: 0.1))
        _ = pad.update(points: [], now: 0.2)
        _ = pad.update(points: Array(repeating: .zero, count: 4), now: 1)
        XCTAssertEqual(pad.update(points: Array(repeating: CGPoint(x: 0, y: 100), count: 4), now: 1.1), .missionControlDismiss)
        XCTAssertNil(pad.update(points: Array(repeating: CGPoint(x: 0, y: 200), count: 4), now: 1.2))
        XCTAssertNil(pad.update(points: [], now: 1.3))
    }
}

final class ReconnectPolicyTests: XCTestCase {
    func testExplicitDisconnectStaysDisconnectedAfterAppReturn() {
        var policy = ReconnectPolicy()
        policy.stop(); policy.foreground = false; policy.foreground = true
        XCTAssertNil(policy.nextDelay())
        policy.start()
        XCTAssertEqual(policy.nextDelay(), 1)
    }
    func testNoBackgroundRetryAndBoundedForegroundBackoff() {
        var policy = ReconnectPolicy()
        policy.foreground = false
        XCTAssertNil(policy.nextDelay())
        policy.foreground = true
        XCTAssertEqual([policy.nextDelay(), policy.nextDelay(), policy.nextDelay(), policy.nextDelay()], [1, 2, 4, 8])
        XCTAssertNil(policy.nextDelay())
        policy.succeeded()
        XCTAssertEqual(policy.nextDelay(), 1)
    }
}

final class PinchAndSpreadTests: XCTestCase {
    private func pair(_ radius: Double, x: Double = 0, y: Double = 0) -> [CGPoint] {
        [CGPoint(x: x - radius, y: y), CGPoint(x: x + radius, y: y)]
    }
    private func four(_ radius: Double, y: Double = 0) -> [CGPoint] {
        [CGPoint(x: -radius, y: y), CGPoint(x: radius, y: y),
         CGPoint(x: 0, y: y - radius), CGPoint(x: 0, y: y + radius)]
    }
    func testSymmetricPinchWorksWithoutCentroidMovementAndDoesNotRightClick() {
        var pad = PadGesture()
        _ = pad.update(points: pair(40), now: 0)
        XCTAssertEqual(pad.update(points: pair(56), now: 0.05), .zoom(56.0 / 40 - 1))
        XCTAssertEqual(pad.update(points: pair(60), now: 0.07), .zoom(60.0 / 56 - 1))
        XCTAssertEqual(pad.update(points: pair(40), now: 0.1), .zoom(40.0 / 60 - 1))
        XCTAssertEqual(pad.update(points: [], now: 0.2), .zoomEnd)
    }
    func testPinchLocksOutScrollAndResidualFingerMotion() {
        var pad = PadGesture()
        _ = pad.update(points: pair(40), now: 0)
        _ = pad.update(points: pair(60), now: 0.05)
        XCTAssertNil(pad.update(points: pair(60, x: 30), now: 0.1))
        XCTAssertEqual(pad.update(points: [CGPoint(x: 90, y: 0)], now: 0.15), .zoomEnd)
        XCTAssertNil(pad.update(points: [CGPoint(x: 120, y: 0)], now: 0.2))
        XCTAssertNil(pad.update(points: [], now: 0.25))
    }
    func testParallelTwoFingerMotionRemainsScroll() {
        var pad = PadGesture()
        _ = pad.update(points: pair(40), now: 0)
        XCTAssertEqual(pad.update(points: pair(42, y: 30), now: 0.05), .scroll(0, 30))
    }
    func testFourFingerSpreadAndPinchToggleOnceWithoutTriggeringMissionControl() {
        var pad = PadGesture()
        _ = pad.update(points: four(50), now: 0)
        XCTAssertEqual(pad.update(points: four(85), now: 0.1), .showDesktop)
        XCTAssertNil(pad.update(points: four(120, y: -90), now: 0.2))
        XCTAssertNil(pad.update(points: [], now: 0.3))
        _ = pad.update(points: four(100), now: 1)
        XCTAssertEqual(pad.update(points: four(60), now: 1.1), .showDesktop)
        XCTAssertNil(pad.update(points: [], now: 1.2))
    }
    func testDragStartPreservesThresholdMovement() {
        var pad = PadGesture()
        _ = pad.update(points: [.zero], now: 0)
        _ = pad.update(points: [], now: 0.1)
        _ = pad.update(points: [.zero], now: 0.2)
        XCTAssertEqual(pad.update(points: [CGPoint(x: 6, y: 2)], now: 0.25), .dragBegin)
        XCTAssertEqual(pad.dragStartDelta, CGPoint(x: 6, y: 2))
        XCTAssertEqual(pad.update(points: [], now: 0.3), .dragEnd)
    }
}

#if os(macOS)
import AppKit
final class NativeMagnificationTests: XCTestCase {
    func testQuartzEventsDecodeAsRealMagnifyWithPhasesAndNoCommandKey() throws {
        let phases: [(MagnifyEventFactory.Phase, NSEvent.Phase)] = [(.began, .began), (.changed, .changed), (.ended, .ended), (.cancelled, .cancelled)]
        for (hid, expected) in phases {
            let cg = try XCTUnwrap(MagnifyEventFactory.make(delta: 0.05, phase: hid, point: .zero))
            let event = try XCTUnwrap(NSEvent(cgEvent: cg))
            XCTAssertEqual(event.type, .magnify)
            XCTAssertEqual(event.phase, expected)
            XCTAssertEqual(event.magnification, 0.05, accuracy: 0.00001)
            XCTAssertFalse(event.modifierFlags.contains(.command))
        }
        XCTAssertNil(MagnifyEventFactory.make(delta: .nan, phase: .changed, point: .zero))
        XCTAssertNil(MagnifyEventFactory.make(delta: 10, phase: .changed, point: .zero))
    }
}
#endif

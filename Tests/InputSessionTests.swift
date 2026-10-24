import XCTest
@testable import RemoteCore

final class InputSessionTests: XCTestCase {
    func testCompositionFixtures() throws {
        for fixture in CompositionFixture.all {
            var session = try InputSession(baseline: fixture.baseline)
            for snapshot in fixture.updates {
                let packet = InputEnvelope(connectionID: session.connectionID, inputSessionID: session.id,
                                           sequence: session.nextSequence, snapshot: snapshot)
                XCTAssertTrue(try session.accept(packet), fixture.name)
                XCTAssertEqual(session.snapshot, snapshot)
                XCTAssertFalse(try session.accept(packet), "Duplicate must not insert or delete again")
            }
            XCTAssertEqual(session.snapshot.text, fixture.expected, fixture.name)
            XCTAssertNil(session.snapshot.marked)
        }
    }

    func testOldConnectionAndOldTextSessionAreRejected() throws {
        var session = try InputSession(baseline: CompositionFixture.snapshot(""))
        let staleConnection = InputEnvelope(connectionID: UUID(), inputSessionID: session.id, sequence: 1,
                                            snapshot: CompositionFixture.snapshot("한"))
        XCTAssertThrowsError(try session.accept(staleConnection))
        let staleInput = InputEnvelope(connectionID: session.connectionID, inputSessionID: UUID(), sequence: 1,
                                      snapshot: CompositionFixture.snapshot("한"))
        XCTAssertThrowsError(try session.accept(staleInput))
        XCTAssertEqual(session.snapshot.text, "")
    }

    func testGapInvalidatesSession() throws {
        var session = try InputSession(baseline: CompositionFixture.snapshot(""))
        let gap = InputEnvelope(connectionID: session.connectionID, inputSessionID: session.id,
                                sequence: 2, snapshot: CompositionFixture.snapshot("한"))
        XCTAssertThrowsError(try session.accept(gap))
        XCTAssertFalse(session.active)
        let next = InputEnvelope(connectionID: session.connectionID, inputSessionID: session.id,
                                 sequence: 1, snapshot: CompositionFixture.snapshot("ㅎ"))
        XCTAssertThrowsError(try session.accept(next))
    }

    func testDisconnectAndTargetChangeInvalidation() throws {
        var session = try InputSession(baseline: CompositionFixture.snapshot(""))
        session.invalidate()
        let packet = InputEnvelope(connectionID: session.connectionID, inputSessionID: session.id,
                                   sequence: 1, snapshot: CompositionFixture.snapshot("한"))
        XCTAssertThrowsError(try session.accept(packet))
    }

    func testInvalidUTF16RangesAndOversizedText() throws {
        for range in [TextRange(location: -1, length: 0), TextRange(location: 1, length: 0),
                      TextRange(location: Int.max, length: Int.max)] {
            XCTAssertThrowsError(try TextSnapshot(text: "😀", selection: range, marked: nil).validate())
        }
        XCTAssertNoThrow(try TextSnapshot(text: "😀한", selection: .init(location: 2, length: 1), marked: nil).validate())
        XCTAssertThrowsError(try CompositionFixture.snapshot(String(repeating: "한", count: 12_000)).validate())
    }

    func testCommitPreservesFinalSyllableWithoutDuplication() throws {
        var session = try InputSession(baseline: CompositionFixture.snapshot(""))
        for snapshot in [CompositionFixture.snapshot("한", markedLength: 1), CompositionFixture.snapshot("한")] {
            _ = try session.accept(.init(connectionID: session.connectionID, inputSessionID: session.id,
                                         sequence: session.nextSequence, snapshot: snapshot))
        }
        XCTAssertEqual(session.snapshot.text, "한")
        XCTAssertNil(session.snapshot.marked)
        XCTAssertEqual(session.nextSequence, 3)
    }

    func testVersionAndZeroSequenceRejection() throws {
        var session = try InputSession(baseline: CompositionFixture.snapshot(""))
        var packet = InputEnvelope(connectionID: session.connectionID, inputSessionID: session.id,
                                   sequence: 1, snapshot: CompositionFixture.snapshot("한"))
        packet.version = 2
        XCTAssertThrowsError(try session.accept(packet))
        XCTAssertThrowsError(try session.accept(.init(connectionID: session.connectionID, inputSessionID: session.id,
                                                     sequence: 0, snapshot: CompositionFixture.snapshot("한"))))
    }

    func testFramesSplitAtEveryByteAndCoalesced() throws {
        let data = try FrameDecoder.encode(CompositionFixture.snapshot("한글 검색"))
        var decoder = FrameDecoder()
        var frames = [Data]()
        for byte in data { frames += try decoder.append(Data([byte])) }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(TextSnapshot.self, from: frames[0]).text, "한글 검색")
        XCTAssertEqual(try decoder.append(data + data).count, 2)
    }

    func testMaliciousFrameLengthRejected() {
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0xff, 0xff, 0xff, 0xff])))
    }
}

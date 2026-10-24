import XCTest
@testable import RemoteCore

final class WebRemoteTests: XCTestCase {
    func testFragmentedBodyWaitsAndPreservesUTF8() throws {
        let body = Data("{\"text\":\"한글\"}".utf8)
        let header = Data("POST /commands HTTP/1.1\r\nHost: localhost:8080\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        XCTAssertNil(try LocalHTTPRequest.parse(header + body.prefix(3)))
        let request = try XCTUnwrap(LocalHTTPRequest.parse(header + body))
        XCTAssertEqual(request.path, "/commands")
        XCTAssertEqual(request.body, body)
    }
    func testRejectsAmbiguousFramingAndExcessData() {
        for headers in ["Content-Length: 0\r\nContent-Length: 2", "Transfer-Encoding: chunked", "Content-Length: -1", "Content-Length: 70000"] {
            XCTAssertThrowsError(try LocalHTTPRequest.parse(Data("POST /commands HTTP/1.1\r\n\(headers)\r\n\r\n".utf8)))
        }
        XCTAssertThrowsError(try LocalHTTPRequest.parse(Data("GET / HTTP/1.1\r\nHost: localhost\r\n\r\nEXTRA".utf8)))
        XCTAssertThrowsError(try LocalHTTPRequest.parse(Data(repeating: 65, count: 9000)))
    }
    func testSequenceRejectsReplayAndGapsWithoutAdvancing() {
        var sequence = WebSequence()
        XCTAssertFalse(sequence.accept(0))
        XCTAssertTrue(sequence.accept(1))
        XCTAssertFalse(sequence.accept(1))
        XCTAssertFalse(sequence.accept(3))
        XCTAssertTrue(sequence.accept(2))
    }
    func testRejectsUnknownCommandsAndInvalidTouchCoordinates() throws {
        let decoder = JSONDecoder()
        for value in ["{\"type\":\"shell\"}", "{\"type\":\"touch\",\"points\":[{\"x\":20000,\"y\":0}]}", "{\"type\":\"touch\",\"x\":100}"] {
            let action = try decoder.decode(WebRemoteAction.self, from: Data(value.utf8))
            XCTAssertThrowsError(try action.validate())
        }
        let valid = try decoder.decode(WebRemoteAction.self, from: Data("{\"type\":\"touch\",\"points\":[{\"x\":15,\"y\":25}],\"x\":1.6,\"y\":-1}".utf8))
        XCTAssertNoThrow(try valid.validate())
    }
}

final class WebOriginPolicyTests: XCTestCase {
    func testSafariLowercaseHostAndOriginAreAccepted() {
        let authorities: Set<String> = ["bagsang-yun-ui-MacBookAir.local:49373"]
        XCTAssertTrue(WebOriginPolicy.accepts(host: "bagsang-yun-ui-macbookair.local:49373", origin: nil, authorities: authorities))
        XCTAssertTrue(WebOriginPolicy.accepts(host: "bagsang-yun-ui-macbookair.local:49373", origin: "http://bagsang-yun-ui-MacBookAir.local:49373", authorities: authorities))
    }
    func testUnknownHostsOriginsAndPortsRemainBlocked() {
        let authorities: Set<String> = ["Mac.local:49373"]
        XCTAssertFalse(WebOriginPolicy.accepts(host: "evil.local:49373", origin: nil, authorities: authorities))
        XCTAssertFalse(WebOriginPolicy.accepts(host: "mac.local:49373", origin: "http://evil.local:49373", authorities: authorities))
        XCTAssertFalse(WebOriginPolicy.accepts(host: "mac.local:80", origin: nil, authorities: authorities))
        XCTAssertFalse(WebOriginPolicy.accepts(host: "mac.local:49373", origin: "null", authorities: authorities))
    }
}

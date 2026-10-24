import XCTest
import Network
@testable import RemoteCore

final class SecureLinkTests: XCTestCase {
    func testCodeExpiresAndIsSingleUse() {
        let now = Date()
        var gate = PairingGate(code: "123456", deadline: now.addingTimeInterval(120))
        XCTAssertTrue(gate.accept("123456", now: now))
        XCTAssertFalse(gate.accept("123456", now: now))
        var expired = PairingGate(code: "123456", deadline: now)
        XCTAssertFalse(expired.accept("123456", now: now))
    }
    func testFiveFailuresLockPairingAcrossConnections() {
        var gate = PairingGate(code: "123456", deadline: Date().addingTimeInterval(120))
        for _ in 0..<5 { XCTAssertFalse(gate.accept("000000")) }
        XCTAssertFalse(gate.accept("123456"))
        XCTAssertEqual(gate.failures, 5)
    }
    func testInvitationValidation() throws {
        let key = try SecretStore.random()
        let valid = PairingInvitation(service: "RTV-test", key: key, expires: Date().addingTimeInterval(120))
        XCTAssertEqual(try PairingInvitation.decode(valid.encoded).key, key)
        let expired = PairingInvitation(service: "RTV-test", key: key, expires: Date().addingTimeInterval(-1))
        XCTAssertThrowsError(try PairingInvitation.decode(expired.encoded))
        let weak = PairingInvitation(service: "RTV-test", key: Data("123456".utf8), expires: Date().addingTimeInterval(120))
        XCTAssertThrowsError(try PairingInvitation.decode(weak.encoded))
        XCTAssertThrowsError(try PairingInvitation.decode("remotetv:not-base64"))
    }

    @MainActor
    func testTLSPSKRoundTripAndOrderedFrames() async throws {
        let key = try SecretStore.random()
        let parameters = SecureParameters.make(key: key)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "loopback listener")
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        var server: SecureChannel?
        let delivered = expectation(description: "ordered encrypted payloads")
        delivered.expectedFulfillmentCount = 2
        var sequences = [UInt64]()
        listener.newConnectionHandler = { connection in
            let channel = SecureChannel(connection: connection)
            server = channel
            channel.onPacket = { packet in
                sequences.append(packet.sequence)
                delivered.fulfill()
            }
            channel.start()
        }
        listener.start(queue: .main)
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let client = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: port, using: SecureParameters.make(key: key)))
        let id = UUID()
        client.onReady = {
            client.send(.init(connection: id, sequence: 1, payload: .heartbeat))
            client.send(.init(connection: id, sequence: 2, payload: .heartbeat))
        }
        client.start()
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(sequences, [1, 2])
        client.close(); server?.close(); listener.cancel()
    }

    @MainActor
    func testWrongTLSKeyCannotDeliverCommand() async throws {
        let parameters = SecureParameters.make(key: try SecretStore.random())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "loopback listener")
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        var server: SecureChannel?
        let delivery = expectation(description: "no unauthenticated payload")
        delivery.isInverted = true
        listener.newConnectionHandler = { connection in
            let channel = SecureChannel(connection: connection)
            server = channel
            channel.onPacket = { _ in delivery.fulfill() }
            channel.start()
        }
        listener.start(queue: .main)
        await fulfillment(of: [ready], timeout: 5)
        let client = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port),
                                                            using: SecureParameters.make(key: try SecretStore.random())))
        let rejected = expectation(description: "TLS rejects incorrect PSK")
        client.onClose = { _ in rejected.fulfill() }
        client.onReady = { delivery.fulfill() }
        client.start()
        // An incorrect PSK may stall negotiation until our bounded handshake timeout.
        await fulfillment(of: [rejected, delivery], timeout: 14)
        client.onClose = nil
        client.close(); server?.close(); listener.cancel()
    }
}

final class CredentialCollectionTests: XCTestCase {
    private func peer(_ service: String, name: String = "Mac") -> PairedCredential {
        .init(service: service, key: Data(repeating: 1, count: 32), token: "saved-token", name: name)
    }
    func testLegacySinglePeerMigratesWithoutLosingKey() throws {
        let original = peer("RTV-old")
        let decoded = try CredentialCollection.decode(JSONEncoder().encode(original))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.key, original.key)
        XCTAssertEqual(decoded.first?.token, original.token)
    }
    func testNewQRForRegisteredMacReturnsOriginalCredential() throws {
        let id = UUID()
        var existing = peer("RTV-original"); existing.deviceID = id
        let qr = PairingInvitation(service: "RTV-temporary", key: Data(repeating: 7, count: 32), expires: Date().addingTimeInterval(120), deviceID: id)
        let decoded = try PairingInvitation.decode(qr.encoded)
        let result = try XCTUnwrap(decoded.registeredPeer(in: [existing]))
        XCTAssertEqual(result.service, existing.service)
        XCTAssertEqual(result.key, existing.key)
        XCTAssertEqual(result.token, existing.token)
    }
    func testUnknownQRDoesNotReuseUnrelatedOrLegacyPeer() {
        var existing = peer("RTV-old"); existing.deviceID = UUID()
        let qr = PairingInvitation(service: "RTV-new", key: existing.key, expires: Date().addingTimeInterval(120), deviceID: UUID())
        XCTAssertNil(qr.registeredPeer(in: [existing, peer("RTV-legacy")]))
    }
    func testExistingRegistrationRedirectRoundTrips() throws {
        let payload = LinkPayload.alreadyRegistered(service: "RTV-existing")
        guard case let .alreadyRegistered(service) = try JSONDecoder().decode(LinkPayload.self, from: JSONEncoder().encode(payload)) else { return XCTFail() }
        XCTAssertEqual(service, "RTV-existing")
    }
    func testStableIdentityReplacesPairingEvenWhenNameChanges() throws {
        let id = UUID()
        var old = peer("RTV-old"); old.deviceID = id
        var new = peer("RTV-new", name: "Renamed Mac"); new.deviceID = id
        let other = peer("RTV-other")
        let result = CredentialCollection.upserting(new, into: [old, other])
        XCTAssertEqual(result.map(\.service), ["RTV-new", "RTV-other"])
        XCTAssertEqual(try CredentialCollection.decode(JSONEncoder().encode(result)).first?.deviceID, id)
        XCTAssertEqual(CredentialCollection.upserting(new, into: result).count, 2)
    }
    func testUnchangedReconnectDoesNotChangePersistedCollection() {
        let existing = peer("RTV-existing")
        let peers = [existing, peer("RTV-other")]
        XCTAssertEqual(CredentialCollection.upserting(existing, into: peers), peers)
    }
    func testSameNameDoesNotMergeDifferentDevices() {
        var a = peer("RTV-a"); a.deviceID = UUID()
        var b = peer("RTV-b"); b.deviceID = UUID()
        XCTAssertEqual(CredentialCollection.upserting(b, into: [a]).count, 2)
        XCTAssertEqual(CredentialCollection.upserting(peer("RTV-legacy"), into: [a, b]).count, 3)
    }
    func testLegacyDuplicatesMergeOnBothSidesUsingSharedRegistrations() {
        let first = peer("RTV-first"), second = peer("RTV-second"), other = peer("RTV-other")
        let matches = CredentialCollection.matchingServices(proofs: [first.registrationProof, second.registrationProof], in: [first, second, other])
        XCTAssertEqual(matches, Set([first.service, second.service]))
        var renewed = peer("RTV-new"); renewed.deviceID = UUID()
        let host = CredentialCollection.upserting(renewed, into: [first, second, other], replacing: matches)
        let phone = CredentialCollection.upserting(renewed, into: [first, second, other], replacing: matches)
        XCTAssertEqual(host.map(\.service), ["RTV-new", "RTV-other"])
        XCTAssertEqual(phone.map(\.service), host.map(\.service))
    }
    func testProofRequiresKeyAndTokenNotJustServiceOrName() {
        let original = peer("RTV-a")
        var wrong = original; wrong.token = "wrong"
        XCTAssertTrue(CredentialCollection.matchingServices(proofs: [wrong.registrationProof], in: [original]).isEmpty)
        let wrongKey = PairedCredential(service: original.service, key: Data(repeating: 2, count: 32), token: original.token, name: original.name)
        XCTAssertNotEqual(original.registrationProof, wrongKey.registrationProof)
    }
    func testOldHandshakeDecodesWithoutIdentityAndNewHandshakeRoundTrips() throws {
        let legacy = Data(#"{"authenticate":{"code":"123456","name":"iPhone"}}"#.utf8)
        guard case let .authenticate(_, _, _, id, proofs) = try JSONDecoder().decode(LinkPayload.self, from: legacy) else { return XCTFail() }
        XCTAssertNil(id); XCTAssertNil(proofs)
        let device = UUID()
        let payload = LinkPayload.accepted(token: "token", name: "Mac", deviceID: device, replacedServices: ["RTV-old"])
        guard case let .accepted(_, _, decodedID, removed) = try JSONDecoder().decode(LinkPayload.self, from: JSONEncoder().encode(payload)) else { return XCTFail() }
        XCTAssertEqual(decodedID, device); XCTAssertEqual(removed, ["RTV-old"])
    }
    func testAddingAndUpdatingKeepsOtherRegisteredPeers() throws {
        let peers = CredentialCollection.upserting(peer("RTV-b"), into: [peer("RTV-a")])
        let updated = CredentialCollection.upserting(peer("RTV-a", name: "Renamed"), into: peers)
        let decoded = try CredentialCollection.decode(JSONEncoder().encode(updated))
        XCTAssertEqual(decoded.map(\.service), ["RTV-a", "RTV-b"])
        XCTAssertEqual(decoded.first?.name, "Renamed")
        XCTAssertThrowsError(try CredentialCollection.decode(JSONEncoder().encode([peer("RTV-a"), peer("RTV-a")])))
    }
}

final class HostMaintenancePolicyTests: XCTestCase {
    func testIdleHostDoesNotPoll() {
        XCTAssertNil(HostMaintenancePolicy.interval(authenticated: false, clientInactive: false,
            dragging: false, hasInput: false, invitationExpiry: nil))
    }
    func testConnectedIntervalsAdaptToActivity() {
        XCTAssertEqual(HostMaintenancePolicy.interval(authenticated: true, clientInactive: false,
            dragging: false, hasInput: false, invitationExpiry: nil), 1)
        XCTAssertEqual(HostMaintenancePolicy.interval(authenticated: true, clientInactive: false,
            dragging: true, hasInput: false, invitationExpiry: nil), 0.25)
        XCTAssertEqual(HostMaintenancePolicy.interval(authenticated: true, clientInactive: true,
            dragging: false, hasInput: false, invitationExpiry: nil), 3)
    }
    func testPairingSleepsUntilExpiry() {
        let now = Date()
        XCTAssertEqual(HostMaintenancePolicy.interval(authenticated: false, clientInactive: false,
            dragging: false, hasInput: false, invitationExpiry: now.addingTimeInterval(120), now: now), 120)
    }
}

final class ReverseConnectionTests: XCTestCase {
    @MainActor
    func testMacInitiatesAndPhoneAuthenticatesThenReceivesDisconnect() async throws {
        let key = try SecretStore.random()
        let parameters = SecureParameters.make(key: key)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let phoneListener = try NWListener(using: parameters)
        let ready = expectation(description: "phone listener")
        let completed = expectation(description: "reverse authentication and clean disconnect")
        phoneListener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        var phone: SecureChannel?
        let id = UUID()
        phoneListener.newConnectionHandler = { connection in
            let candidate = SecureChannel(connection: connection)
            phone = candidate
            candidate.onReady = {
                candidate.send(.init(connection: id, sequence: 1,
                                     payload: .authenticate(code: nil, token: "registered", name: "Phone")))
            }
            candidate.onPacket = { packet in
                XCTAssertEqual(packet.connection, id)
                if case .disconnectRequested = packet.payload { completed.fulfill() }
            }
            candidate.start()
        }
        phoneListener.start(queue: .main)
        await fulfillment(of: [ready], timeout: 5)
        let mac = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: try XCTUnwrap(phoneListener.port),
                                                         using: SecureParameters.make(key: key)))
        mac.onPacket = { packet in
            guard case let .authenticate(_, token, _, _, _) = packet.payload, token == "registered" else {
                XCTFail("Only registered phone can take control"); return
            }
            mac.send(.init(connection: packet.connection, sequence: 1, payload: .disconnectRequested))
            mac.closeAfterSending()
        }
        mac.start()
        await fulfillment(of: [completed], timeout: 5)
        mac.close(); phone?.close(); phoneListener.cancel()
    }
}

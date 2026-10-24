import Foundation
import Network
import Security
import CryptoKit

struct PairingInvitation: Codable {
    let service: String
    let key: Data
    let expires: Date
    var deviceID: UUID? = nil

    func registeredPeer(in peers: [PairedCredential]) -> PairedCredential? {
        peers.first { $0.service == service || (deviceID != nil && $0.deviceID == deviceID) }
    }

    var encoded: String { "remotetv:" + (try! JSONEncoder().encode(self)).base64EncodedString() }
    static func decode(_ string: String) throws -> Self {
        guard string.hasPrefix("remotetv:"), string.count < 2048,
              let data = Data(base64Encoded: String(string.dropFirst(9))) else { throw LinkError.invalidInvitation }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.key.count == 32, value.service.hasPrefix("RTV-"), value.service.count < 64,
              value.expires > Date(), value.expires.timeIntervalSinceNow <= 125 else { throw LinkError.invalidInvitation }
        return value
    }
}

struct PairedCredential: Codable, Identifiable, Equatable {
    var id: String { service }
    let service: String
    let key: Data
    var token: String
    var name: String
    var deviceID: UUID? = nil

    // Migration proof: never transmit the stored authentication token or PSK.
    var registrationProof: String {
        SHA256.hash(data: key + Data((service + token).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// This identifier is only used to recognize the same installation after a QR is scanned again.
/// It is not an authentication secret, so keeping it out of Keychain avoids an authorization
/// prompt on every connection while the PSK and token remain protected by Keychain.
enum DeviceIdentity {
    private static let key = "personal.remotefor.mac.device-id"

    static var current: UUID {
        if let value = UserDefaults.standard.string(forKey: key),
           let existing = UUID(uuidString: value) { return existing }
        let created = UUID()
        UserDefaults.standard.set(created.uuidString, forKey: key)
        return created
    }
}

enum HostMaintenancePolicy {
    static func interval(authenticated: Bool, clientInactive: Bool, dragging: Bool,
                         hasInput: Bool, invitationExpiry: Date?, now: Date = Date()) -> TimeInterval? {
        if authenticated {
            if dragging || hasInput { return 0.25 }
            return clientInactive ? 3 : 1
        }
        guard let invitationExpiry else { return nil }
        return max(0.05, invitationExpiry.timeIntervalSince(now))
    }
}

enum LinkError: String, Error, LocalizedError {
    case invalidInvitation, keychain, disconnected, queueFull, invalidMessage, timeout
    var errorDescription: String? {
        switch self {
        case .invalidInvitation: return "연결 QR 코드가 만료되었거나 올바르지 않습니다. Mac에서 다시 생성하세요."
        case .keychain: return "인증 정보를 Keychain에 저장할 수 없습니다."
        case .disconnected: return "연결이 끊어졌습니다. 같은 Wi-Fi와 Mac 실행 상태를 확인하세요."
        case .queueFull: return "연결 처리가 지연되어 입력을 중지했습니다."
        case .invalidMessage: return "잘못된 연결 메시지를 거부했습니다."
        case .timeout: return "연결 시간이 초과되었습니다. 로컬 네트워크 권한, 방화벽, 공유기의 기기 격리 설정을 확인하세요."
        }
    }
}

enum SecretStore {
    static func random(count: Int = 32) throws -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard result == errSecSuccess else { throw LinkError.keychain }
        return data
    }
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "personal.remotetv.pairing.v1", kSecAttrAccount as String: "peer"]
    }
    static func load() throws -> PairedCredential? { try loadAll().first }
    static func loadAll() throws -> [PairedCredential] {
        var request = query
        request[kSecReturnData as String] = true
        var value: CFTypeRef?
        let result = SecItemCopyMatching(request as CFDictionary, &value)
        if result == errSecItemNotFound { return [] }
        guard result == errSecSuccess, let data = value as? Data else { throw LinkError.keychain }
        return try CredentialCollection.decode(data)
    }
    static func save(_ credential: PairedCredential, replacing services: Set<String> = []) throws {
        let peers = CredentialCollection.upserting(credential, into: try loadAll(), replacing: services)
        try saveAll(peers)
    }
    static func remove(service: String) throws {
        try saveAll(loadAll().filter { $0.service != service })
    }
    static func saveAll(_ peers: [PairedCredential]) throws {
        let data = try JSONEncoder().encode(peers)
        let update = [kSecValueData as String: data]
        let result = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if result == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw LinkError.keychain }
        } else if result != errSecSuccess { throw LinkError.keychain }
    }
    static func delete() throws {
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw LinkError.keychain }
    }
}

enum CredentialCollection {
    static func decode(_ data: Data) throws -> [PairedCredential] {
        let decoder = JSONDecoder()
        let peers: [PairedCredential]
        if let array = try? decoder.decode([PairedCredential].self, from: data) { peers = array }
        else { peers = [try decoder.decode(PairedCredential.self, from: data)] }
        guard peers.allSatisfy({ $0.key.count == 32 && !$0.token.isEmpty }),
              Set(peers.map(\.service)).count == peers.count else { throw LinkError.keychain }
        return peers
    }
    static func matchingServices(proofs: [String], in peers: [PairedCredential]) -> Set<String> {
        let proofs = Set(proofs)
        return Set(peers.filter { proofs.contains($0.registrationProof) }.map(\.service))
    }
    static func upserting(_ peer: PairedCredential, into peers: [PairedCredential], replacing services: Set<String> = []) -> [PairedCredential] {
        [peer] + peers.filter {
            $0.service != peer.service && !services.contains($0.service) &&
                !(peer.deviceID != nil && $0.deviceID == peer.deviceID)
        }
    }
}

struct PairingGate {
    let code: String
    let deadline: Date
    private(set) var failures = 0
    private(set) var consumed = false
    mutating func accept(_ entered: String, now: Date = Date()) -> Bool {
        guard !consumed, failures < 5, now < deadline else { return false }
        guard entered == code else { failures += 1; return false }
        consumed = true
        return true
    }
}

enum LinkPayload: Codable {
    case authenticate(code: String?, token: String?, name: String, deviceID: UUID? = nil, registrations: [String]? = nil)
    case accepted(token: String, name: String, deviceID: UUID? = nil, replacedServices: [String]? = nil)
    case alreadyRegistered(service: String)
    case command(RemoteCommand)
    case baseline(request: UUID, session: UUID, snapshot: TextSnapshot)
    case keyboardUnavailable(request: UUID, message: String)
    case focusAvailable(UUID)
    case backspace(session: UUID)
    case submit(session: UUID)
    case notice(String)
    case textEnded
    case presence(active: Bool)
    case heartbeat
    case disconnectRequested
}

struct LinkPacket: Codable {
    static let currentVersion = 9
    var version = currentVersion
    let connection: UUID
    let sequence: UInt64
    let payload: LinkPayload
}

/// TLS 1.2 PSK with a random 256-bit QR secret, NOT a guessable six-digit PSK.
/// Peer possession is verified by TLS Finished. No trust/verify bypass callback.
/// Network.framework's TLS-PSK is TLS 1.2 only (Apple TN3213).
enum SecureParameters {
    static func make(key: Data) -> NWParameters {
        precondition(key.count == 32)
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("RemoteTV-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, identity as __DispatchData)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
    }
}

/// All operations and callbacks run on the main queue; frame and command order is preserved.
/// No retry queue survives cancellation. Packet payloads are never logged.
final class SecureChannel {
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onPacket: ((LinkPacket) -> Void)?
    var onClose: ((String) -> Void)?
    private var decoder = FrameDecoder()
    private var pending = 0
    private var closed = false
    private var finishing = false
    private var timeout: DispatchWorkItem?
    var acceptsMotion: Bool { !closed && pending < 2 }

    init(connection: NWConnection) { self.connection = connection }
    func start() {
        let timeout = DispatchWorkItem { [weak self] in self?.close(LinkError.timeout.localizedDescription) }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready: self.timeout?.cancel(); self.onReady?(); self.receive()
            case .failed: self.close("보안 연결 실패. 연결 QR 코드, 네트워크 권한과 방화벽을 확인하세요.")
            case .cancelled: self.close(LinkError.disconnected.localizedDescription)
            default: break
            }
        }
        connection.start(queue: .main)
    }
    func send(_ packet: LinkPacket) {
        guard !closed else { return }
        guard pending < 64 else { close(LinkError.queueFull.localizedDescription); return }
        do {
            let bytes = try FrameDecoder.encode(packet)
            pending += 1
            connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.pending -= 1
                if self.finishing && self.pending == 0 { self.close(); return }
                if error != nil { self.close(LinkError.disconnected.localizedDescription) }
            })
        } catch { close(LinkError.invalidMessage.localizedDescription) }
    }
    func closeAfterSending() {
        finishing = true
        if pending == 0 { close(); return }
        // Retain until the queued disconnect notification has been processed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.close() }
    }
    func close(_ message: String = LinkError.disconnected.localizedDescription) {
        guard !closed else { return }
        closed = true; timeout?.cancel(); connection.cancel()
        onClose?(message)
        onPacket = nil; onReady = nil; onClose = nil
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            do {
                if let data {
                    for frame in try self.decoder.append(data) {
                        let packet = try JSONDecoder().decode(LinkPacket.self, from: frame)
                        guard packet.version == LinkPacket.currentVersion else { throw InputFailure.wrongVersion }
                        self.onPacket?(packet)
                        if self.closed { return }
                    }
                }
                if done || error != nil { self.close(); return }
                self.receive()
            } catch { self.close(LinkError.invalidMessage.localizedDescription) }
        }
    }
}


/// Bounded foreground-only recovery. Explicit disconnect wins over lifecycle changes.
struct ReconnectPolicy {
    var foreground = true
    private(set) var wantsConnection = true
    private(set) var attempts = 0
    mutating func start() { wantsConnection = true; attempts = 0 }
    mutating func stop() { wantsConnection = false; attempts = 0 }
    mutating func succeeded() { attempts = 0 }
    mutating func nextDelay() -> TimeInterval? {
        guard foreground, wantsConnection, attempts < 4 else { return nil }
        let delay = Double(1 << attempts)
        attempts += 1
        return delay
    }
}

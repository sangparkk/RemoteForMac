import Foundation
import Network
import AppKit
import CoreImage.CIFilterBuiltins
import Darwin
import Security
import SystemConfiguration
import dnssd

@MainActor
final class WebRemoteServer: ObservableObject {
    @Published var urls: [String] = []
    @Published var status = "웹 리모컨 꺼짐"
    @Published var running = false
    @Published var pairingCode = ""
    @Published private(set) var pairingDeadline: Date?
    @Published private(set) var connectedDevice: String?
    @Published private(set) var nativeDevice: String?
    var activeDevice: String? { connectedDevice ?? nativeDevice }
    private var pairingGate: PairingGate?
    private var codeRenewal: DispatchWorkItem?
    var onConnect: ((UUID, String) -> Bool)?
    var onBatch: ((WebRemoteBatch) throws -> [LinkPayload])?
    var onStop: (() -> Void)?
    private let assetRoot: URL
    private let suppliedAccessKey: String?
    init(assetRoot: URL? = nil, accessKey: String? = nil) {
        self.suppliedAccessKey = accessKey
        self.assetRoot = assetRoot ?? Bundle.main.resourceURL!.appendingPathComponent("WebRemote")
    }
    private let alias = WebRemoteAlias()
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var timeouts: [UUID: DispatchWorkItem] = [:]
    private var token = ""
    private var authorities = Set<String>()

    func start() {
        stop()
        do {
            token = try suppliedAccessKey ?? WebAccessKey.loadOrCreate()
            if activeDevice == nil { issueCode() }
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
            let listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: 49373)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port?.rawValue else { return }
                        let addresses = Self.addresses()
                        let hostname = (SCDynamicStoreCopyLocalHostName(nil) as String?).map { $0.lowercased() + ".local" }
                        let names = hostname.map { [$0] } ?? []
                        self.authorities = Set((names + addresses + ["127.0.0.1", "localhost"]).map { "\($0):\(port)" })
                        self.urls = (names + addresses).map { "http://\($0):\(port)/" }
                        UserDefaults.standard.set(true, forKey: "webRemoteEnabled")
                        if let hostname {
                            self.alias.start(target: hostname) { [weak self] available in
                                guard let self, self.running else { return }
                                if available {
                                    self.authorities.insert("remotetv.local:\(port)")
                                    self.urls = ["http://remotetv.local:\(port)/"] + self.urls.filter { !$0.contains("remotetv.local:") }
                                } else {
                                    self.authorities.remove("remotetv.local:\(port)")
                                    self.urls.removeAll { $0.contains("remotetv.local:") }
                                    self.status = "remotetv.local 이름을 등록하지 못했습니다(이름 충돌 또는 네트워크 오류). 아래 Mac 주소로 접속할 수 있습니다."
                                }
                            }
                        }
                        self.running = true
                        self.status = self.activeDevice.map { "\($0) 연결됨" } ?? (addresses.isEmpty ? "Wi-Fi 연결을 확인하세요. 웹 연결을 껐다 다시 켜면 주소를 갱신합니다." : "홈 화면의 웹앱에서 연결하세요. 처음 등록할 때만 아래 6자리 코드를 입력합니다.")
                    case .failed: self.stop(); self.status = "웹 서버 시작 실패. 49373 포트 사용 여부와 네트워크 권한·방화벽을 확인하세요."
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        } catch { status = error.localizedDescription }
    }
    func stop() {
        UserDefaults.standard.set(false, forKey: "webRemoteEnabled")
        codeRenewal?.cancel(); codeRenewal = nil
        pairingGate = nil; pairingCode = ""; pairingDeadline = nil
        connectedDevice = nil
        onStop?()
        alias.stop()
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        for timeout in timeouts.values { timeout.cancel() }; timeouts.removeAll()
        connections.removeAll(); token = ""; urls = []; authorities = []; running = false
        status = "웹 리모컨 꺼짐"
    }
    func issueCode() {
        guard activeDevice == nil else { return }
        codeRenewal?.cancel()
        pairingCode = String(format: "%06u", arc4random_uniform(1_000_000))
        let deadline = Date().addingTimeInterval(120)
        pairingDeadline = deadline
        pairingGate = PairingGate(code: pairingCode, deadline: deadline)
        let renewal = DispatchWorkItem { [weak self] in
            guard let self, self.running, self.activeDevice == nil else { return }
            self.issueCode()
        }
        codeRenewal = renewal
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: renewal)
    }
    func setConnectedDevice(_ name: String?) {
        connectedDevice = name
        if let name {
            codeRenewal?.cancel(); codeRenewal = nil
            pairingGate = nil; pairingCode = ""; pairingDeadline = nil
            status = "\(name) 연결됨"
        } else if running, nativeDevice == nil {
            status = "웹앱 연결 대기 · 등록한 기기는 자동으로 다시 연결됩니다."
            issueCode()
        }
    }
    func setNativeDevice(_ name: String?) {
        nativeDevice = name
        if let name {
            codeRenewal?.cancel(); codeRenewal = nil
            pairingGate = nil; pairingCode = ""; pairingDeadline = nil
            if running { status = "\(name) 연결됨" }
        } else if running, connectedDevice == nil {
            status = "웹앱 연결 대기 · 등록한 기기는 자동으로 다시 연결됩니다."
            issueCode()
        }
    }
    func resetAccess() {
        stop()
        do { try WebAccessKey.rotate(); start() }
        catch { status = error.localizedDescription }
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 24 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: .main)
        read(connection, id: id, buffer: Data())
    }
    private func read(_ connection: NWConnection, id: UUID, buffer: Data) {
        timeouts[id]?.cancel()
        let timeout = DispatchWorkItem { [weak self, weak connection] in
            connection?.cancel(); self?.connections.removeValue(forKey: id); self?.timeouts.removeValue(forKey: id)
        }
        timeouts[id] = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self, self.connections[id] != nil else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                do {
                    if let request = try LocalHTTPRequest.parse(buffer) { self.route(request, connection: connection, id: id); return }
                    if done || error != nil { connection.cancel(); self.connections.removeValue(forKey: id); self.timeouts.removeValue(forKey: id)?.cancel(); return }
                    self.read(connection, id: id, buffer: buffer)
                } catch { self.reply(connection, id: id, code: 400, body: Data("Bad request".utf8)) }
            }
        }
    }
    private func route(_ request: LocalHTTPRequest, connection: NWConnection, id: UUID) {
        guard WebOriginPolicy.accepts(host: request.headers["host"], origin: request.headers["origin"], authorities: authorities) else {
            reply(connection, id: id, code: 403, body: Data("접속 주소를 확인할 수 없습니다. Mac의 웹 리모컨 QR을 다시 읽어 주세요.".utf8), mime: "text/plain; charset=utf-8"); return
        }
        if request.method == "GET" {
            let assets = ["/": ("index.html", "text/html; charset=utf-8"), "/app.js": ("app.js", "text/javascript; charset=utf-8"), "/style.css": ("style.css", "text/css; charset=utf-8"), "/manifest.webmanifest": ("manifest.webmanifest", "application/manifest+json"), "/icon.svg": ("icon.svg", "image/svg+xml"), "/icon-180.png": ("icon-180.png", "image/png"), "/icon-192.png": ("icon-192.png", "image/png"), "/icon-512.png": ("icon-512.png", "image/png")]
            guard let (name, mime) = assets[request.path],
                  let data = try? Data(contentsOf: assetRoot.appendingPathComponent(name)) else {
                reply(connection, id: id, code: 404, body: Data()); return
            }
            reply(connection, id: id, code: 200, body: data, mime: mime); return
        }
        if request.path == "/pair", request.headers["content-type"] == "application/json" {
            struct Pair: Decodable { let code: String }
            if let pair = try? JSONDecoder().decode(Pair.self, from: request.body),
               pairingGate?.accept(pair.code) == true, !token.isEmpty {
                issueCode()
                let data = try! JSONSerialization.data(withJSONObject: ["token": token])
                reply(connection, id: id, code: 200, body: data)
            } else { reply(connection, id: id, code: 403, body: Data()) }
            return
        }
        guard !token.isEmpty, request.headers["authorization"] == "Bearer " + token,
              request.headers["content-type"] == "application/json" else {
            reply(connection, id: id, code: 403, body: Data()); return
        }
        do {
            if request.path == "/connect" {
                struct Connect: Decodable { let client: UUID; let device: UUID?; let kind: String? }
                let value = try JSONDecoder().decode(Connect.self, from: request.body)
                let kind = ["iPhone", "iPad"].contains(value.kind ?? "") ? value.kind! + " 웹앱" : "웹앱"
                let name = value.device.map { kind + " · " + $0.uuidString.prefix(6) } ?? kind
                guard onConnect?(value.client, name) == true else { throw LinkError.disconnected }
                reply(connection, id: id, code: 200, body: Data("[]".utf8)); return
            }
            guard request.path == "/commands" else { throw LinkError.invalidMessage }
            let batch = try JSONDecoder().decode(WebRemoteBatch.self, from: request.body)
            guard batch.actions.count <= 64 else { throw LinkError.invalidMessage }
            for action in batch.actions { try action.validate() }
            let output = try onBatch?(batch) ?? []
            reply(connection, id: id, code: 200, body: try JSONEncoder().encode(output))
        } catch {
            reply(connection, id: id, code: 409, body: Data("연결이 끝났습니다. 다시 연결하세요.".utf8), mime: "text/plain; charset=utf-8")
        }
    }
    private func reply(_ connection: NWConnection, id: UUID, code: Int, body: Data, mime: String = "application/json") {
        let headers = "HTTP/1.1 \(code) Response\r\nContent-Length: \(body.count)\r\nContent-Type: \(mime)\r\nConnection: keep-alive\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n\r\n"
        connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                if code == 400 { connection.cancel(); self.connections.removeValue(forKey: id); self.timeouts.removeValue(forKey: id)?.cancel() }
                else { self.read(connection, id: id, buffer: Data()) }
            }
        })
    }
    static func addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var result: [String] = []; var item = head
        while let current = item {
            defer { item = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  current.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  String(cString: current.pointee.ifa_name).hasPrefix("en") else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: buffer)
                if ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || (ip.hasPrefix("172.") && (16...31).contains(Int(ip.split(separator: ".")[1]) ?? 0)) { result.append(ip) }
            }
        }
        return Array(Set(result)).sorted()
    }
    var qrImage: NSImage? {
        guard let url = urls.first else { return nil }
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(url.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 5, y: 5)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 220, height: 220))
    }
}


/// Separate from native-app pairing; browser registration survives host restarts.
private enum WebAccessKey {
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "personal.remotetv.web.v1", kSecAttrAccount as String: "access"]
    }
    static func loadOrCreate() throws -> String {
        var request = query; request[kSecReturnData as String] = true
        var value: CFTypeRef?
        let result = SecItemCopyMatching(request as CFDictionary, &value)
        if result == errSecItemNotFound { try rotate(); return try loadOrCreate() }
        guard result == errSecSuccess, let data = value as? Data, data.count == 32 else { throw LinkError.keychain }
        return data.map { String(format: "%02x", $0) }.joined()
    }
    static func rotate() throws {
        let data = try SecretStore.random()
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var request = query; request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw LinkError.keychain }
        } else if result != errSecSuccess { throw LinkError.keychain }
    }
}


/// Publishes only an app-owned mDNS CNAME, leaving the computer name unchanged.
@MainActor
private final class WebRemoteAlias {
    private var service: DNSServiceRef?
    private var record: DNSRecordRef?
    private var result: ((Bool) -> Void)?
    func start(target: String, result: @escaping (Bool) -> Void) {
        stop(); self.result = result
        guard DNSServiceCreateConnection(&service) == kDNSServiceErr_NoError, let service else { result(false); return }
        guard DNSServiceSetDispatchQueue(service, .main) == kDNSServiceErr_NoError else { stop(); result(false); return }
        var wire = [UInt8]()
        for label in target.split(separator: ".") {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty, bytes.count <= 63 else { stop(); result(false); return }
            wire.append(UInt8(bytes.count)); wire.append(contentsOf: bytes)
        }
        wire.append(0)
        let error = wire.withUnsafeBytes { bytes in
            DNSServiceRegisterRecord(service, &record, DNSServiceFlags(kDNSServiceFlagsUnique), 0,
                "remotetv.local.", UInt16(kDNSServiceType_CNAME), UInt16(kDNSServiceClass_IN),
                UInt16(bytes.count), bytes.baseAddress, 120, { _, _, _, error, context in
                    guard let context else { return }
                    MainActor.assumeIsolated {
                        let owner = Unmanaged<WebRemoteAlias>.fromOpaque(context).takeUnretainedValue()
                        owner.result?(error == kDNSServiceErr_NoError)
                    }
                }, Unmanaged.passUnretained(self).toOpaque())
        }
        if error != kDNSServiceErr_NoError { stop(); result(false) }
    }
    func stop() {
        if let service { DNSServiceRefDeallocate(service) }
        service = nil; record = nil; result = nil
    }
}

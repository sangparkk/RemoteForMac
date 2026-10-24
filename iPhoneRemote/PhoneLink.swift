import Foundation
import Network
import UIKit

@MainActor
final class PhoneLink: NSObject, ObservableObject {
    @Published var shiftHeld = false
    var touchpadVisible = false
    func toggleShift() {
        guard connected else { return }
        shiftHeld.toggle(); send(.command(.shift(shiftHeld)))
    }
    func releaseShift() {
        if connected && shiftHeld { send(.command(.shift(false))) }
        shiftHeld = false
    }
    @Published var status = "Mac에 연결하세요."
    @Published var connected = false
    @Published var macName = ""
    @Published var keyboardOpen = false
    @Published var keyboardVisible = false
    private var manualKeyboard = false
    private var pendingText = CompositionFixture.snapshot("")
    private var keyboardTimeout: DispatchWorkItem?
    @Published var registrationNotice: String?
    @Published var inputID = UUID()
    @Published var baseline = CompositionFixture.snapshot("")
    @Published var eventCount = 0
    @Published var markedCount = 0
    @Published var canReconnect = false
    @Published var peers: [PairedCredential] = []
    @Published var selectedService = ""
    private var reverseListeners: [String: NWListener] = [:]
    private var incomingCandidate: SecureChannel?
    private var credential: PairedCredential?
    private var invitation: PairingInvitation?
    private var code: String?
    private var channel: SecureChannel?
    private var browser: NWBrowser?
    private var connectionID = UUID()
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    private var textSequence: UInt64 = 0
    private var keyboardNegotiation = KeyboardNegotiation()
    private var heartbeat: Timer?
    private var lastMessage = Date()
    private var discoveryTimeout: DispatchWorkItem?
    private var authTimeout: DispatchWorkItem?
    private var motion = PointerMotion()
    private var scrolling = PointerMotion()
    private var motionTimer: CADisplayLink?

    private var recovery = ReconnectPolicy()
    private var recoveryTask: DispatchWorkItem?
    private var inactiveAt: Date?
    private var savedHost = ""
    private var savedPort = ""
    @Published var interactionGeneration = 0

    func becameInactive() {
        guard recovery.foreground else { return }
        recovery.foreground = false; inactiveAt = Date()
        stopListening()
        recoveryTask?.cancel(); recoveryTask = nil
        clearMotion(); releaseShift(); endKeyboard()
        interactionGeneration += 1
        if connected { send(.presence(active: false)) }
        else { disconnect(userInitiated: false) }
    }
    func becameActive() {
        recovery.foreground = true
        startListening()
        let absence = inactiveAt.map { Date().timeIntervalSince($0) } ?? 0
        inactiveAt = nil
        guard recovery.wantsConnection else { return }
        if connected && absence < 50 {
            lastMessage = Date()
            send(.presence(active: true)); send(.heartbeat)
            return
        }
        if connected { disconnect(userInitiated: false) }
        if canReconnect && channel == nil && browser == nil {
            recovery.succeeded()
            reconnect(host: savedHost, port: savedPort, automatic: true)
        }
    }
    private func scheduleRecovery() {
        guard canReconnect, invitation == nil, let delay = recovery.nextDelay() else { return }
        recoveryTask?.cancel()
        status = "Mac에 다시 연결하는 중…"
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.recovery.foreground, self.recovery.wantsConnection, !self.connected else { return }
            self.reconnect(host: self.savedHost, port: self.savedPort, automatic: true)
        }
        recoveryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }
    func zoom(_ delta: Double) {
        guard connected else { return }; flushMotion(); send(.command(.zoom(delta)))
    }
    func endZoom() { if connected { send(.command(.zoomEnd)) } }
    func showDesktop() {
        guard connected else { return }; clearMotion(); endKeyboard(); send(.command(.showDesktop))
    }
    func missionControl() {
        guard connected else { return }
        clearMotion(); releaseShift(); endKeyboard(); send(.command(.missionControl))
    }

    override init() {
        super.init()
        do { peers = try SecretStore.loadAll(); credential = peers.first; selectedService = credential?.service ?? ""; canReconnect = credential != nil }
        catch { status = error.localizedDescription }
    }
    func isRegisteredInvitation(_ text: String) -> Bool {
        guard let decoded = try? PairingInvitation.decode(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return decoded.registeredPeer(in: peers) != nil
    }
    func pair(invitation string: String, code: String, host: String = "", port: String = "") {
        do {
            let decoded = try PairingInvitation.decode(string.trimmingCharacters(in: .whitespacesAndNewlines))
            peers = try SecretStore.loadAll()
            if let existing = decoded.registeredPeer(in: peers) {
                registrationNotice = "이미 등록된 기기입니다. 기존 페어링을 사용합니다."
                if connected && credential?.service == existing.service { return }
                selectedService = existing.service
                reconnect(host: host) // The QR port belongs to a temporary pairing listener.
                return
            }
            guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw LinkError.invalidInvitation }
            registrationNotice = nil
            disconnect(userInitiated: false); recovery.start()
            savedHost = host; savedPort = port
            invitation = decoded
            self.code = code
            credential = nil
            discover(host: host, port: port)
        } catch { status = error.localizedDescription }
    }
    func reconnect(host: String = "", port: String = "", automatic: Bool = false) {
        disconnect(userInitiated: false)
        if !automatic { recovery.start() }
        savedHost = host; savedPort = port
        do {
            peers = try SecretStore.loadAll()
            credential = peers.first { $0.service == selectedService } ?? peers.first
            selectedService = credential?.service ?? ""
            invitation = nil; code = nil
            guard credential != nil else { throw LinkError.invalidInvitation }
            discover(host: host, port: port)
        } catch { status = error.localizedDescription }
    }
    func selectPeer(_ peer: PairedCredential) {
        registrationNotice = nil
        selectedService = peer.service
        reconnect()
    }
    private func stopListening() {
        incomingCandidate?.close(); incomingCandidate = nil
        for listener in reverseListeners.values { listener.cancel() }
        reverseListeners.removeAll()
    }
    private func startListening() {
        guard recovery.foreground else { return }
        let current = Set(peers.map(\.service))
        for service in Array(reverseListeners.keys) where !current.contains(service) {
            reverseListeners.removeValue(forKey: service)?.cancel()
        }
        for peer in peers where reverseListeners[peer.service] == nil {
            do {
                let listener = try NWListener(using: SecureParameters.make(key: peer.key))
                listener.service = .init(name: peer.service + "-phone", type: "_remotetv._tcp")
                listener.newConnectionHandler = { [weak self] connection in
                    MainActor.assumeIsolated {
                        guard let self, self.recovery.foreground else { connection.cancel(); return }
                        guard self.incomingCandidate == nil else { connection.cancel(); return }
                        let candidate = SecureChannel(connection: connection)
                        self.incomingCandidate = candidate
                        candidate.onClose = { [weak self, weak candidate] _ in
                            if self?.incomingCandidate === candidate { self?.incomingCandidate = nil }
                        }
                        candidate.onReady = { [weak self, weak candidate] in
                            guard let self, let candidate, self.recovery.foreground else { candidate?.close(); return }
                            // NWConnection.ready means the paired PSK was verified by TLS.
                            // Only now can this Mac replace a currently active Mac.
                            self.incomingCandidate = nil
                            self.disconnect(userInitiated: false); self.recovery.start()
                            self.credential = peer; self.selectedService = peer.service
                            self.invitation = nil; self.code = nil
                            self.openChannel(connection, readyChannel: candidate)
                        }
                        candidate.start()
                    }
                }
                reverseListeners[peer.service] = listener
                listener.start(queue: .main)
            } catch { status = error.localizedDescription }
        }
    }
    func forget(_ peer: PairedCredential) {
        do {
            if selectedService == peer.service { disconnect(); credential = nil; selectedService = "" }
            try SecretStore.remove(service: peer.service)
            reverseListeners.removeValue(forKey: peer.service)?.cancel()
            peers = try SecretStore.loadAll(); canReconnect = !peers.isEmpty
        } catch { status = error.localizedDescription }
    }
    func disconnect(userInitiated: Bool = true) {
        interactionGeneration += 1
        if userInitiated { recovery.stop() }
        recoveryTask?.cancel(); recoveryTask = nil
        releaseShift()
        clearMotion()
        discoveryTimeout?.cancel(); authTimeout?.cancel(); browser?.cancel(); browser = nil
        let old = channel; channel = nil; old?.close()
        heartbeat?.invalidate(); heartbeat = nil
        motionTimer?.invalidate(); motionTimer = nil; motion.clear(); scrolling.clear()
        connected = false; endKeyboard(send: false)
        status = "연결 해제됨"
    }
    func beginKeyboard() {
        guard connected else { return }
        endKeyboard()
        manualKeyboard = true; keyboardVisible = true
        status = "키보드 열림 · Mac 입력창 연결 중…"
        let request = keyboardNegotiation.request()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.keyboardNegotiation.pending == request else { return }
            self.keyboardNegotiation.cancel()
            self.status = "Mac 입력창 응답이 없습니다. 입력창을 클릭한 뒤 키보드를 다시 열어 주세요. 입력은 전송되지 않았습니다."
        }
        keyboardTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        send(.command(.beginText(request)))
    }
    func endKeyboard(send shouldSend: Bool = true) {
        if shouldSend, connected, keyboardOpen { send(.command(.endText(session: inputID))) }
        keyboardTimeout?.cancel(); keyboardTimeout = nil
        pendingText = CompositionFixture.snapshot("")
        keyboardVisible = false; manualKeyboard = false
        keyboardNegotiation.cancel(); keyboardOpen = false; inputID = UUID()
        baseline = CompositionFixture.snapshot(""); textSequence = 0
    }
    func update(_ snapshot: TextSnapshot) {
        guard connected, keyboardVisible else { return }
        guard keyboardOpen else {
            if keyboardNegotiation.pending != nil { pendingText = snapshot }
            return
        }
        do {
            try snapshot.validate()
            textSequence += 1; eventCount += 1
            if snapshot.marked != nil { markedCount += 1 }
            let envelope = InputEnvelope(connectionID: connectionID, inputSessionID: inputID,
                                         sequence: textSequence, snapshot: snapshot)
            send(.command(.text(envelope)))
        } catch { endKeyboard(); status = error.localizedDescription }
    }
    func backspace() {
        guard connected, keyboardOpen else { return }
        send(.backspace(session: inputID))
    }
    func submit() {
        guard connected, keyboardOpen else { return }
        send(.submit(session: inputID))
        endKeyboard(send: false)
    }
    func activateYouTube() { clearMotion(); endKeyboard(); send(.command(.activate(.youtube))) }
    func activateNetflix() { clearMotion(); endKeyboard(); send(.command(.activate(.netflix))) }
    func move(dx: Double, dy: Double) {
        guard connected else { return }
        motion.add(dx: dx, dy: dy, now: ProcessInfo.processInfo.systemUptime)
    }
    func scroll(dx: Double, dy: Double) {
        guard connected else { return }
        scrolling.add(dx: dx, dy: dy, now: ProcessInfo.processInfo.systemUptime)
    }
    func clearMotion() {
        motion.clear(); scrolling.clear(); endZoom()
        if connected { send(.command(.dragEnd)) }
    }
    func drag(_ pressed: Bool) {
        guard connected else { return }
        flushMotion()
        if pressed { endKeyboard() }
        send(.command(pressed ? .dragBegin : .dragEnd))
    }
    func desktop(_ direction: DesktopDirection) {
        guard connected else { return }
        clearMotion(); endKeyboard(); send(.command(.desktop(direction)))
    }
    func click() {
        guard connected else { return }
        flushMotion(); endKeyboard(); send(.command(.click))
    }
    func rightClick() {
        guard connected else { return }
        flushMotion(); endKeyboard(); send(.command(.rightClick))
    }
    func doubleClick() {
        guard connected else { return }
        flushMotion(); endKeyboard(); send(.command(.doubleClick))
    }
    func key(_ key: RemoteKey) {
        guard connected else { return }
        motion.clear(); scrolling.clear(); endKeyboard(); send(.command(.key(key)))
    }
    @objc private func displayFrame() { flushMotion() }
    private func flushMotion() {
        let now = ProcessInfo.processInfo.systemUptime
        guard connected, channel?.acceptsMotion == true else { return }
        let delta = motion.take(now: now), scroll = scrolling.take(now: now)
        if let (dx, dy) = delta { send(.command(.pointer(dx: dx, dy: dy))) }
        if let (dx, dy) = scroll { send(.command(.scroll(dx: dx, dy: dy))) }
    }

    private func discover(host: String, port: String) {
        guard let key = invitation?.key ?? credential?.key,
              let service = invitation?.service ?? credential?.service else { return }
        status = "같은 네트워크에서 Mac을 찾는 중…"
        if !host.isEmpty {
            guard let portNumber = UInt16(port), portNumber > 0, let nwPort = NWEndpoint.Port(rawValue: portNumber) else {
                status = "Mac 설정에 표시된 포트 번호를 입력하세요."; return
            }
            connect(endpoint: .hostPort(host: .init(host), port: nwPort), key: key)
            return
        }
        let browser = NWBrowser(for: .bonjour(type: "_remotetv._tcp", domain: nil), using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
            guard let self, self.channel == nil else { return }
            for result in results {
                if case let .service(name, _, _, _) = result.endpoint, name == service {
                    self.discoveryTimeout?.cancel(); browser.cancel(); self.browser = nil
                    self.connect(endpoint: result.endpoint, key: key)
                    return
                }
            }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
            if case .failed = state {
                self?.browser?.cancel(); self?.browser = nil
                self?.status = "Mac 검색 실패. 설정에서 로컬 네트워크 접근을 허용하세요."
                self?.scheduleRecovery()
            }
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            self?.browser?.cancel(); self?.browser = nil; self?.status = LinkError.timeout.localizedDescription
            self?.scheduleRecovery()
        }
        discoveryTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
        browser.start(queue: .main)
    }
    private func connect(endpoint: NWEndpoint, key: Data) {
        openChannel(NWConnection(to: endpoint, using: SecureParameters.make(key: key)))
    }
    private func openChannel(_ connection: NWConnection, readyChannel: SecureChannel? = nil) {
        connectionID = UUID(); sent = 0; received = 0
        let channel = readyChannel ?? SecureChannel(connection: connection)
        self.channel = channel
        status = "Mac과 보안 연결 중…"
        channel.onReady = { [weak self] in
            guard let self else { return }
            self.send(.authenticate(code: self.code, token: self.credential?.token, name: UIDevice.current.name,
                deviceID: DeviceIdentity.current, registrations: self.peers.map(\.registrationProof)))
            let timeout = DispatchWorkItem { [weak channel] in channel?.close("Mac 인증 응답 시간이 초과되었습니다.") }
            self.authTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        }
        channel.onPacket = { [weak self] packet in self?.receive(packet) }
        channel.onClose = { [weak self, weak channel] message in
            guard let self, self.channel === channel else { return }
            self.shiftHeld = false
            self.connected = false; self.endKeyboard(send: false); self.channel = nil
            self.heartbeat?.invalidate(); self.heartbeat = nil; self.authTimeout?.cancel(); self.status = message
            self.motionTimer?.invalidate(); self.motionTimer = nil; self.motion.clear(); self.scrolling.clear()
            self.scheduleRecovery()
        }
        if readyChannel != nil { channel.onReady?() } else { channel.start() }
    }
    private func receive(_ packet: LinkPacket) {
        guard packet.connection == connectionID, packet.sequence > 0 else { channel?.close(); return }
        if packet.sequence <= received { return }
        guard packet.sequence == received + 1 else { channel?.close(); return }
        received = packet.sequence; lastMessage = Date()
        do {
            switch packet.payload {
            case .alreadyRegistered(let service):
                guard !connected, invitation != nil, peers.contains(where: { $0.service == service }) else {
                    throw LinkError.invalidMessage
                }
                registrationNotice = "이미 등록된 기기입니다. 기존 페어링을 사용합니다."
                selectedService = service
                reconnect(host: savedHost)
            case .accepted(let token, let name, let deviceID, let replacedServices):
                guard !connected, let key = invitation?.key ?? credential?.key,
                      let service = invitation?.service ?? credential?.service,
                      Data(base64Encoded: token)?.count == 32, name.utf8.count <= 256 else { throw LinkError.invalidMessage }
                let saved = PairedCredential(service: service, key: key, token: token, name: name, deviceID: deviceID ?? credential?.deviceID)
                let updatedPeers = CredentialCollection.upserting(saved, into: peers,
                    replacing: Set(replacedServices ?? []))
                if updatedPeers != peers { try SecretStore.saveAll(updatedPeers) }
                credential = saved; selectedService = saved.service
                peers = updatedPeers; startListening()
                invitation = nil; code = nil
                recovery.succeeded(); recoveryTask?.cancel(); recoveryTask = nil
                connected = true; canReconnect = true; macName = name; status = "연결됨"; authTimeout?.cancel()
                motionTimer?.invalidate()
                let displayLink = CADisplayLink(target: self, selector: #selector(displayFrame))
                displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
                displayLink.add(to: .main, forMode: .common)
                motionTimer = displayLink
                heartbeat = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.recovery.foreground else { return }
                        if Date().timeIntervalSince(self.lastMessage) > 12 { self.channel?.close(); return }
                        self.send(.heartbeat)
                    }
                }
                if let heartbeat { RunLoop.main.add(heartbeat, forMode: .common) }
            case .focusAvailable(let id):
                guard connected, recovery.foreground, touchpadVisible, !keyboardVisible else { return }
                pendingText = CompositionFixture.snapshot("")
                _ = keyboardNegotiation.request(id)
                send(.command(.acceptFocus(id)))
            case .baseline(let request, let id, let snapshot):
                guard connected, keyboardNegotiation.accept(request) else { return }
                try snapshot.validate()
                keyboardTimeout?.cancel(); keyboardTimeout = nil
                let merged = try PendingKeyboardText.merge(pendingText, into: snapshot)
                pendingText = CompositionFixture.snapshot("")
                baseline = merged; inputID = id; textSequence = 0
                keyboardOpen = true; keyboardVisible = true
                status = "Mac 입력창에 입력 중"
                if merged != snapshot { update(merged) }
            case .keyboardUnavailable(let request, let message):
                guard keyboardNegotiation.accept(request) else { return }
                keyboardTimeout?.cancel(); keyboardTimeout = nil
                pendingText = CompositionFixture.snapshot("")
                status = "Mac 입력 연결 실패: " + String(message.prefix(256)) + " 입력은 전송되지 않습니다."
            case .textEnded:
                // A begin request causes the server to terminate its prior session first.
                if keyboardNegotiation.pending == nil {
                    if manualKeyboard && keyboardVisible {
                        keyboardOpen = false
                        status = "Mac 입력 연결이 끝났습니다. 입력창을 선택하고 키보드를 닫았다 다시 열어 주세요."
                    } else { endKeyboard(send: false) }
                }
            case .notice(let message):
                if manualKeyboard && keyboardVisible {
                    keyboardOpen = false; keyboardNegotiation.cancel(); keyboardTimeout?.cancel()
                } else { endKeyboard(send: false) }
                status = String(message.prefix(256))
            case .disconnectRequested:
                disconnect(); status = "Mac에서 연결을 해제했습니다."
            case .heartbeat: break
            default: throw LinkError.invalidMessage
            }
        } catch { channel?.close(error.localizedDescription) }
    }
    private func send(_ payload: LinkPayload) {
        guard channel != nil else { return }
        sent += 1
        channel?.send(.init(connection: connectionID, sequence: sent, payload: payload))
    }
}

import AppKit
import Network
import SwiftUI
import CoreImage.CIFilterBuiltins

@MainActor
final class HostLink: ObservableObject {
    @Published var status = "연결 대기"
    @Published var invitation: PairingInvitation?
    @Published var code = ""
    @Published var port = ""
    @Published var peerName = ""
    @Published var paused = false { didSet { if paused { pointer.releaseAll(); endInput() } } }
    @Published var useTestField = false { didSet { endInput(); observedField = nil } }
    weak var probe: ProbeModel?
    weak var launcher: ServiceLauncher?
    @Published var peers: [PairedCredential] = []
    @Published var activeService = ""
    private var peerListeners: [String: NWListener] = [:]
    private var requestBrowser: NWBrowser?
    private var requestTimeout: DispatchWorkItem?
    let web = WebRemoteServer()
    private var webClient: UUID?
    private var webSequence = WebSequence()
    private var webEvents: [LinkPayload] = []
    private var webGesture = PadGesture()
    private var webTextSequence: UInt64 = 0
    private var credential: PairedCredential?
    private var gate: PairingGate?
    private var listener: NWListener?
    private var channel: SecureChannel?
    private var incomingCandidate: SecureChannel?
    private var connectionID: UUID?
    private var received: UInt64 = 0
    private var sent: UInt64 = 0
    private var authenticated = false
    private var clientInactive = false
    private var input: InputSession?
    private var deadline: DispatchWorkItem?
    private var heartbeat: Timer?
    private var lastMessage = Date()
    private var activationObserver: NSObjectProtocol?
    private let backend = AccessibilityInput()
    private let nativeKeyboard = NativeKeyboardInput()
    private var usingNativeKeyboard = false
    private let pointer = RemotePointer()
    private var observedField: AXUIElement?
    private var offeredField: AXUIElement?
    private var focusOffer: UUID?
    private var focusNotBefore = Date.distantPast
    private var mouseMonitor: Any?
    private var keyboardRequests = 0
    private var keyboardReady = 0
    private var pointerReceived = 0
    private var pointerApplied = 0
    private var lastPointerError = ""
    private var lastNotice = ""
    private var lastNoticeAt = Date.distantPast

    func start(probe: ProbeModel, launcher: ServiceLauncher) {
        guard self.probe == nil else { return }
        self.probe = probe; self.launcher = launcher
        web.onConnect = { [weak self] id, name in
            guard let self, !self.paused else { return false }
            self.disconnectPeer()
            self.webClient = id; self.webSequence = WebSequence(); self.webEvents = []; self.webGesture.reset()
            self.connectionID = UUID(); self.received = 0; self.sent = 0
            self.authenticated = true; self.clientInactive = false; self.lastMessage = Date()
            self.peerName = name; self.activeService = "web"; self.status = "\(name) 연결됨"
            self.web.setConnectedDevice(name)
            self.scheduleMaintenance()
            return true
        }
        web.onBatch = { [weak self] batch in
            guard let self, self.webClient == batch.client, self.authenticated,
                  self.webSequence.accept(batch.sequence) else { throw LinkError.disconnected }
            self.lastMessage = Date()
            for action in batch.actions {
                guard self.webClient == batch.client else { break }
                self.webAction(action)
            }
            let output = self.webEvents; self.webEvents.removeAll(); return output
        }
        web.onStop = { [weak self] in if self?.webClient != nil { self?.disconnectPeer() } }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let pid = self.useTestField ? ProcessInfo.processInfo.processIdentifier : self.launcher?.controlledApplication?.processIdentifier
                if app.processIdentifier != pid {
                    self.endInput()
                    // App changes end text input, but do not interrupt the global touchpad.
                }
            }
        }
        do {
            peers = try SecretStore.loadAll()
            for peer in peers { try listen(key: peer.key, service: peer.service) }
            status = peers.isEmpty ? "아이폰 등록을 눌러 연결을 시작하세요." : "등록된 아이폰 연결 대기"
        } catch { status = error.localizedDescription }
        if UserDefaults.standard.bool(forKey: "webRemoteEnabled") { web.start() }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.authenticated, !self.paused, !self.useTestField else { return }
                self.endInput(); self.observedField = nil
                self.focusNotBefore = Date().addingTimeInterval(0.15)
                self.scheduleMaintenance(prefer: 0.2)
            }
        }
        scheduleMaintenance()
    }
    func newPairing() {
        disconnectPeer()
        if let invitation { peerListeners.removeValue(forKey: invitation.service)?.cancel() }
        credential = nil
        do {
            let key = try SecretStore.random()
            let invitation = PairingInvitation(service: "RTV-" + UUID().uuidString, key: key, expires: Date().addingTimeInterval(120), deviceID: DeviceIdentity.current)
            let code = String(format: "%06u", arc4random_uniform(1_000_000))
            gate = PairingGate(code: code, deadline: invitation.expires)
            self.invitation = invitation; self.code = code
            try listen(key: key, service: invitation.service)
            status = "QR을 읽고 연결 코드를 입력하세요. 유효 시간 2분."
            scheduleMaintenance()
        } catch { status = error.localizedDescription }
    }
    func disconnectPeer() {
        incomingCandidate?.close(); incomingCandidate = nil
        requestBrowser?.cancel(); requestBrowser = nil; requestTimeout?.cancel()
        if authenticated { send(.disconnectRequested) }
        pointer.releaseAll(); endInput()
        webClient = nil; webGesture.reset()
        if web.connectedDevice != nil { web.setConnectedDevice(nil) }
        if web.nativeDevice != nil { web.setNativeDevice(nil) }
        let old = channel; channel = nil; old?.closeAfterSending(); authenticated = false; peerName = ""; activeService = ""
        status = "연결 해제됨"
        scheduleMaintenance()
    }
    func removePeer(_ peer: PairedCredential) {
        do {
            try SecretStore.remove(service: peer.service)
            if activeService == peer.service { disconnectPeer() }
            peerListeners.removeValue(forKey: peer.service)?.cancel()
            peers = try SecretStore.loadAll()
        } catch { status = error.localizedDescription }
    }
    func connectPeer(_ peer: PairedCredential) {
        disconnectPeer()
        status = "\(peer.name) 찾는 중 · 아이폰 앱을 열어 주세요."
        let browser = NWBrowser(for: .bonjour(type: "_remotetv._tcp", domain: nil), using: .tcp)
        requestBrowser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self, self.requestBrowser === browser else { return }
                for result in results {
                    if case let .service(name, _, _, _) = result.endpoint, name == peer.service + "-phone" {
                        browser.cancel(); self.requestBrowser = nil; self.requestTimeout?.cancel()
                        self.attach(NWConnection(to: result.endpoint, using: SecureParameters.make(key: peer.key)), service: peer.service)
                        return
                    }
                }
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.requestBrowser === browser else { return }
            browser.cancel(); self.requestBrowser = nil
            self.status = "아이폰을 찾지 못했습니다. 같은 Wi-Fi에서 아이폰 앱을 열고 다시 연결하세요."
        }
        requestTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
        browser.start(queue: .main)
    }
    func endInput() {
        input?.invalidate(); input = nil; backend.invalidate(); nativeKeyboard.invalidate(); usingNativeKeyboard = false
        focusOffer = nil; offeredField = nil
        if authenticated { send(.textEnded) }
        scheduleMaintenance()
    }
    private func listen(key: Data, service: String) throws {
        peerListeners.removeValue(forKey: service)?.cancel()
        let listener = try NWListener(using: SecureParameters.make(key: key))
        listener.service = .init(name: service, type: "_remotetv._tcp")
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
            guard let self else { connection.cancel(); return }
            self.attach(connection, service: service)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
            if case .ready = state { self?.port = listener.port.map { String($0.rawValue) } ?? "" }
            if case .failed = state { self?.status = "네트워크 수신 실패. 로컬 네트워크 권한과 방화벽을 확인하세요." }
            }
        }
        self.listener = listener
        peerListeners[service] = listener
        listener.start(queue: .main)
    }
    private func attach(_ connection: NWConnection, service: String) {
        guard webClient == nil else { connection.cancel(); return }
        guard channel != nil else { adopt(connection, service: service); return }
        // Authenticate a replacement fully before releasing the existing controller.
        guard incomingCandidate == nil, let peer = peers.first(where: { $0.service == service }) else {
            connection.cancel(); return
        }
        let candidate = SecureChannel(connection: connection)
        incomingCandidate = candidate
        candidate.onClose = { [weak self, weak candidate] _ in
            if self?.incomingCandidate === candidate { self?.incomingCandidate = nil }
        }
        candidate.onPacket = { [weak self, weak candidate] packet in
            guard let self, let candidate else { return }
            guard packet.sequence == 1, case let .authenticate(_, token, name, _, _) = packet.payload,
                  token == peer.token, name.utf8.count <= 128,
                  self.peers.contains(where: { $0.service == service }) else { candidate.close(); return }
            self.incomingCandidate = nil
            self.disconnectPeer()
            self.adopt(connection, service: service, readyChannel: candidate)
            self.receive(packet)
        }
        candidate.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak candidate] in
            if let candidate, self?.incomingCandidate === candidate { candidate.close() }
        }
    }
    private func adopt(_ connection: NWConnection, service: String, readyChannel: SecureChannel? = nil) {
            credential = peers.first { $0.service == service }; activeService = service
            self.received = 0; self.sent = 0; self.connectionID = nil; self.authenticated = false; self.clientInactive = false
            let channel = readyChannel ?? SecureChannel(connection: connection)
            self.channel = channel
            channel.onPacket = { [weak self] packet in self?.receive(packet) }
            channel.onClose = { [weak self, weak channel] message in
                guard let self, self.channel === channel else { return }
                self.pointer.releaseAll(); self.authenticated = false; self.endInput(); self.channel = nil
                self.web.setNativeDevice(nil)
                self.peerName = ""; self.activeService = ""; self.status = message; self.deadline?.cancel()
                self.scheduleMaintenance()
            }
            let timeout = DispatchWorkItem { [weak channel] in channel?.close("인증 시간이 초과되었습니다.") }
            self.deadline = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
            if readyChannel == nil { channel.start() }
    }
    private func receive(_ packet: LinkPacket) {
        guard packet.sequence > 0 else { channel?.close(); return }
        if connectionID == nil { connectionID = packet.connection }
        guard packet.connection == connectionID else { channel?.close(); return }
        if packet.sequence <= received { return }
        guard packet.sequence == received + 1 else { channel?.close(); return }
        received = packet.sequence; lastMessage = Date()
        if !authenticated {
            guard case let .authenticate(enteredCode, token, name, deviceID, registrations) = packet.payload, name.utf8.count <= 128, (registrations?.count ?? 0) <= 128,
                  registrations?.allSatisfy({ $0.count == 64 }) ?? true else {
                channel?.close("등록되지 않은 기기의 명령을 거부했습니다."); return
            }
            do {
                var saved: PairedCredential
                if let existing = credential {
                    guard token == existing.token else { channel?.close("기기 인증 실패. 다시 등록하세요."); return }
                    saved = existing
                    saved.name = String(name.prefix(64))
                    saved.deviceID = deviceID ?? existing.deviceID
                } else {
                    guard let invitation, invitation.service == activeService, gate?.accept(enteredCode ?? "") == true else {
                        channel?.close("연결 코드가 틀렸거나 만료되었습니다."); return
                    }
                    let knownServices = CredentialCollection.matchingServices(proofs: registrations ?? [], in: peers)
                    if let existing = peers.first(where: { knownServices.contains($0.service) }) {
                        // Keep the original PSK, token and service. Reconnect over its existing listener.
                        status = "이미 등록된 기기입니다. 기존 페어링으로 연결합니다."
                        send(.alreadyRegistered(service: existing.service))
                        return
                    }
                    saved = PairedCredential(service: invitation.service, key: invitation.key,
                        token: try SecretStore.random().base64EncodedString(), name: String(name.prefix(64)), deviceID: deviceID)
                }
                // Only merge legacy entries after the peer passed token or pairing-code authentication.
                let oldPeers = peers
                let replacements = CredentialCollection.matchingServices(proofs: registrations ?? [], in: oldPeers)
                let updatedPeers = CredentialCollection.upserting(saved, into: oldPeers, replacing: replacements)
                if updatedPeers != oldPeers { try SecretStore.saveAll(updatedPeers) }
                peers = updatedPeers
                let removed = Set(oldPeers.map(\.service)).subtracting(updatedPeers.map(\.service))
                for service in removed { peerListeners.removeValue(forKey: service)?.cancel() }
                credential = saved; self.invitation = nil; code = ""; gate = nil
                guard let credential else { throw LinkError.keychain }
                authenticated = true; peerName = credential.name
                web.setNativeDevice(peerName)
                deadline?.cancel(); status = "\(peerName) 연결됨"
                send(.accepted(token: credential.token, name: Host.current().localizedName ?? "Mac", deviceID: DeviceIdentity.current, replacedServices: Array(removed)))
                scheduleMaintenance()
            } catch { channel?.close(error.localizedDescription) }
            return
        }
        do {
            switch packet.payload {
            case .heartbeat: send(.heartbeat)
            case .presence(let active):
                clientInactive = !active
                if !active { pointer.releaseAll(); endInput() }
                send(.heartbeat)
                scheduleMaintenance()
            case .command(.zoom(let delta)):
                try preparePointer(); try pointer.zoom(delta)
            case .command(.zoomEnd): pointer.endZoom()
            case .command(.showDesktop):
                try preparePointer(); endInput(); try pointer.showDesktop()
            case .command(.missionControl):
                try preparePointer(); endInput(); try pointer.missionControl()
            case .command(.endText(let id)):
                if input?.id == id { endInput() }
            case .command(.beginText(let request)):
                keyboardRequests += 1
                do {
                    try beginInput(request: request, manual: true)
                    keyboardReady += 1
                } catch {
                    endInput(); status = error.localizedDescription
                    send(.keyboardUnavailable(request: request, message: status))
                }
            case .command(.acceptFocus(let id)):
                guard focusOffer == id, let offeredField, let app = launcher?.controlledApplication,
                      let current = AccessibilityInput.focusedServiceField(application: app, service: launcher?.currentService ?? .youtube),
                      CFEqual(offeredField, current) else { return }
                try beginInput(request: id)
            case .command(.pointer(let dx, let dy)):
                pointerReceived += 1
                try preparePointer(); try pointer.move(dx: dx, dy: dy)
                pointerApplied += 1; lastPointerError = ""
            case .command(.shift(let enabled)):
                try preparePointer(); pointer.shiftHeld = enabled
            case .command(.rightClick):
                try preparePointer(); endInput(); try pointer.click(right: true)
            case .command(.doubleClick):
                try preparePointer(); endInput(); try pointer.click(clickCount: 2)
            case .command(.dragBegin):
                try preparePointer(); endInput(); try pointer.beginDrag()
                scheduleMaintenance()
            case .command(.dragEnd):
                pointer.endDrag()
                observedField = nil; focusNotBefore = Date().addingTimeInterval(0.15)
                scheduleMaintenance()
            case .command(.desktop(let direction)):
                guard !paused, !clientInactive else { throw InputFailure.expiredSession }
                endInput(); try pointer.desktop(direction)
                status = "화면 전환 요청 · 터치패드를 계속 사용할 수 있습니다."
                send(.notice(status))
            case .command(.click):
                try preparePointer(); endInput(); observedField = nil
                focusNotBefore = Date().addingTimeInterval(0.15)
                try pointer.click()
            case .command(.scroll(let dx, let dy)):
                try preparePointer(); try pointer.scroll(dx: dx, dy: dy)
            case .command(.key(let key)):
                try preparePointer(); endInput(); observedField = nil
                if key == .lockScreen { pointer.releaseAll() }
                focusNotBefore = Date().addingTimeInterval(0.15)
                try pointer.key(key)
            case .command(.text(let envelope)):
                guard !paused, var session = input else { throw InputFailure.expiredSession }
                if try session.accept(envelope) {
                    if useTestField {
                        try validateTestField()
                        guard let view = probe?.testView else { throw InputFailure.unsupportedTarget }
                        view.string = session.snapshot.text
                        view.setSelectedRange(session.snapshot.selection.nsRange)
                    } else if usingNativeKeyboard { try nativeKeyboard.apply(session.snapshot) }
                    else { try backend.apply(session.snapshot) }
                }
                input = session
            case .backspace(let id):
                guard !paused, input?.id == id else { throw InputFailure.expiredSession }
                if usingNativeKeyboard { try nativeKeyboard.deleteBackward() }
            case .submit(let id):
                guard !paused, let session = input, session.id == id, session.snapshot.marked == nil else { throw InputFailure.expiredSession }
                if useTestField {
                    try validateTestField()
                    status = "검색 키 수신 완료 · 테스트 입력란"
                } else {
                    if usingNativeKeyboard { try nativeKeyboard.submit() } else { try backend.submit() }
                    status = "Enter 전달 완료 · 검색 실행 결과는 확인 필요"
                }
                endInput()
            case .command(.activate(.youtube)):
                guard !paused, !clientInactive else { throw InputFailure.expiredSession }
                pointer.endDrag(); endInput(); launcher?.launchYouTube()
            case .command(.activate(.netflix)):
                guard !paused, !clientInactive else { throw InputFailure.expiredSession }
                pointer.endDrag(); endInput(); launcher?.launchNetflix()
            default: send(.notice("이 명령은 현재 기술 검증판에서 지원하지 않습니다."))
            }
        } catch {
            lastPointerError = error.localizedDescription
            pointer.releaseAll(); endInput(); status = error.localizedDescription
            if status != lastNotice || Date().timeIntervalSince(lastNoticeAt) > 2 {
                send(.notice(status)); lastNotice = status; lastNoticeAt = Date()
            }
        }
    }
    private func webPayload(_ payload: LinkPayload) {
        guard webClient != nil, let connectionID else { return }
        receive(.init(connection: connectionID, sequence: received + 1, payload: payload))
    }
    private func webAction(_ action: WebRemoteAction) {
        switch action.type {
        case "touch":
            guard !paused, let points = action.points else { return }
            let outcome = webGesture.update(points: points.map { CGPoint(x: $0.x, y: $0.y) }, now: ProcessInfo.processInfo.systemUptime)
            let sensitivity = action.x ?? 1.6, direction = action.y ?? 1
            switch outcome {
            case let .move(x, y): webPayload(.command(.pointer(dx: x * sensitivity, dy: y * sensitivity)))
            case let .scroll(x, y): webPayload(.command(.scroll(dx: x * direction, dy: y * direction)))
            case .click: webPayload(.command(.click))
            case .rightClick: webPayload(.command(.rightClick))
            case .doubleClick: webPayload(.command(.doubleClick))
            case .dragBegin:
                webPayload(.command(.dragBegin))
                webPayload(.command(.pointer(dx: webGesture.dragStartDelta.x * sensitivity, dy: webGesture.dragStartDelta.y * sensitivity)))
            case .dragEnd: webPayload(.command(.dragEnd))
            case let .zoom(delta): webPayload(.command(.zoom(delta)))
            case .zoomEnd: webPayload(.command(.zoomEnd))
            case .showDesktop: webPayload(.command(.showDesktop))
            case .missionControl: webPayload(.command(.missionControl))
            case .missionControlDismiss: webPayload(.command(.key(.escape)))
            case let .desktop(direction): webPayload(.command(.desktop(direction)))
            case nil: break
            }
        case "cancel": pointer.releaseAll(); webGesture.reset()
        case "key": if let key = action.key { webPayload(.command(.key(key))) }
        case "activate": if let service = action.service { webPayload(.command(.activate(service))) }
        case "keyboard":
            if let request = action.request { webTextSequence = 0; webPayload(.command(.beginText(request))) }
        case "text":
            if let id = action.session, let snapshot = action.snapshot, let connectionID {
                webTextSequence += 1
                webPayload(.command(.text(.init(connectionID: connectionID, inputSessionID: id, sequence: webTextSequence, snapshot: snapshot))))
            }
        case "endText": endInput()
        case "submit": if let id = action.session { webPayload(.submit(session: id)) }
        case "backspace": if let id = action.session { webPayload(.backspace(session: id)) }
        case "disconnect": disconnectPeer()
        case "heartbeat": break
        default: break
        }
    }
    func releasePointer() { pointer.releaseAll() }
    private func preparePointer() throws {
        guard !paused, !clientInactive else { throw InputFailure.expiredSession }
        try pointer.validate()
    }
    private func beginInput(request: UUID, manual: Bool = false) throws {
        guard !paused, !clientInactive, let connectionID else { throw InputFailure.expiredSession }
        endInput()
        let baseline: TextSnapshot
        if useTestField {
            guard let view = probe?.testView else { throw InputFailure.unsupportedTarget }
            NSApp.activate(ignoringOtherApps: true)
            view.window?.makeKeyAndOrderFront(nil); view.window?.makeFirstResponder(view)
            baseline = .init(text: view.string, selection: .init(location: view.selectedRange().location, length: view.selectedRange().length), marked: nil)
        } else {
            try preparePointer()
            guard let app = manual ? NSWorkspace.shared.frontmostApplication : launcher?.controlledApplication else { throw InputFailure.unsupportedTarget }
            do {
                baseline = try backend.begin(application: app, service: manual ? nil : (launcher?.currentService ?? .youtube))
            } catch InputFailure.unsupportedTarget where manual {
                baseline = try nativeKeyboard.begin(application: app)
                usingNativeKeyboard = true
            }
        }
        let session = try InputSession(connectionID: connectionID, baseline: baseline)
        input = session
        send(.baseline(request: request, session: session.id, snapshot: baseline))
    }
    private func offerFocusedField() {
        guard webClient == nil, !paused, !clientInactive, !pointer.dragging, !useTestField, input == nil, Date() >= focusNotBefore,
              let app = launcher?.controlledApplication else { return }
        do { try preparePointer() } catch { return }
        guard let focused = AccessibilityInput.focusedServiceField(application: app, service: launcher?.currentService ?? .youtube) else {
            observedField = nil; focusOffer = nil; offeredField = nil; return
        }
        if let observedField, CFEqual(focused, observedField) { return }
        observedField = focused; offeredField = focused
        let id = UUID(); focusOffer = id
        send(.focusAvailable(id))
    }
    private func validateTestField() throws {
        guard let session = input, let view = probe?.testView,
              NSApp.isActive, view.window?.firstResponder === view,
              view.string == session.snapshot.text, view.selectedRange() == session.snapshot.selection.nsRange else {
            throw InputFailure.targetChanged
        }
    }
    private func tick() {
        defer { scheduleMaintenance() }
        writeInputDiagnostics()
        if webClient != nil, webGesture.expire(now: ProcessInfo.processInfo.systemUptime) == .dragEnd {
            pointer.endDrag()
        }
        if let invitation, Date() >= invitation.expires {
            self.invitation = nil; code = ""; gate = nil
            peerListeners.removeValue(forKey: invitation.service)?.cancel()
            if activeService == invitation.service { disconnectPeer() }
            status = "연결 코드가 만료되었습니다. 다시 등록을 시작하세요."
        }
        if authenticated {
            if pointer.dragging {
                do { try pointer.validate() } catch { pointer.endDrag() }
            }
            if Date().timeIntervalSince(lastMessage) > (webClient != nil ? 5 : (clientInactive ? 60 : 12)) {
                if webClient != nil { disconnectPeer() } else { channel?.close() }; return
            }
            if input != nil {
                do { if useTestField { try validateTestField() } else if usingNativeKeyboard { try nativeKeyboard.validateTarget() } else { try backend.validateTarget() } }
                catch { endInput(); send(.notice(error.localizedDescription)) }
            }
            offerFocusedField()
        }
    }
    private func scheduleMaintenance(prefer preferredInterval: TimeInterval? = nil) {
        heartbeat?.invalidate(); heartbeat = nil
        guard let normalInterval = HostMaintenancePolicy.interval(
            authenticated: authenticated, clientInactive: clientInactive,
            dragging: pointer.dragging, hasInput: input != nil,
            invitationExpiry: invitation?.expires
        ) else {
            writeInputDiagnostics()
            return
        }
        let interval = max(0.05, min(normalInterval, preferredInterval ?? normalInterval))
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.heartbeat = nil
                self?.tick()
            }
        }
        timer.tolerance = interval >= 3 ? 0.5 : (interval >= 1 ? 0.15 : 0.03)
        heartbeat = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    /// Opt-in local diagnostics: counters and state only, never input text or secrets.
    private func writeInputDiagnostics() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--input-report"), index + 1 < args.count else { return }
        let report: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "connected": authenticated, "paused": paused,
            "accessibilityAllowed": AccessibilityInput.permitted,
            "keyboardRequests": keyboardRequests, "keyboardReady": keyboardReady,
            "nativeKeyboard": usingNativeKeyboard, "dragging": pointer.dragging,
            "pointerReceived": pointerReceived, "pointerApplied": pointerApplied,
            "lastPointerError": lastPointerError, "status": status,
            "serviceStatus": launcher?.status ?? "",
            "hasServiceApplication": launcher?.controlledApplication != nil,
            "serviceApplicationActive": launcher?.controlledApplication?.isActive ?? false
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: args[index + 1]), options: .atomic)
        }
    }
    private func send(_ payload: LinkPayload) {
        if webClient != nil {
            if webEvents.count < 64 { webEvents.append(payload) }
            return
        }
        guard let connectionID else { return }
        sent += 1
        channel?.send(.init(connection: connectionID, sequence: sent, payload: payload))
    }
    var qrImage: NSImage? {
        guard let invitation else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(invitation.encoded.utf8)
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 5, y: 5)),
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 250, height: 250))
    }
}

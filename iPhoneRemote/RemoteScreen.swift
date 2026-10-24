import SwiftUI

struct RemoteScreen: View {
    @StateObject private var link = PhoneLink()
    @Environment(\.scenePhase) private var scenePhase
    @State private var invitation = ""
    @State private var code = ""
    @State private var host = ""
    @State private var port = ""
    @State private var scan = false
    @State private var showingTouchpad = false
    @State private var scannerError: String?
    @AppStorage("pointerSensitivity") private var sensitivity = 1.6
    @AppStorage("scrollReversed") private var scrollReversed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Label(link.connected ? link.macName : "Mac 연결", systemImage: "tv").font(.title2.bold())
                    Text(link.status).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    if let notice = link.registrationNotice {
                        Label(notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green)
                    }
                    if !link.peers.isEmpty {
                        DisclosureGroup("등록된 Mac · \(link.peers.count)대") {
                            ForEach(link.peers) { peer in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(peer.name)
                                        Text(String(peer.service.suffix(6))).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(link.connected && link.selectedService == peer.service ? "연결됨" : "연결") { link.selectPeer(peer) }
                                        .disabled(link.connected && link.selectedService == peer.service)
                                    Button(role: .destructive) { link.forget(peer) } label: { Image(systemName: "trash") }
                                }.padding(.vertical, 6)
                            }
                        }
                    }
                    if link.connected {
                        Button { link.activateYouTube() } label: {
                            Label("YouTube 열기", systemImage: "play.rectangle.fill").frame(maxWidth: .infinity, minHeight: 48)
                        }.buttonStyle(.bordered)
                        Button { link.activateNetflix() } label: {
                            Label("Netflix 열기", systemImage: "play.tv.fill").frame(maxWidth: .infinity, minHeight: 48)
                        }.buttonStyle(.bordered)
                        Button {
                            link.endKeyboard()
                            showingTouchpad = true
                        } label: {
                            Label("터치패드", systemImage: "hand.draw.fill")
                                .frame(maxWidth: .infinity, minHeight: 72)
                        }.buttonStyle(.borderedProminent)
                        Text("터치패드에서 Mac 입력창을 클릭한 뒤 키보드 버튼을 누르세요.")
                            .font(.callout)
                        DisclosureGroup("터치패드 설정") {
                            HStack { Text("감도"); Slider(value: $sensitivity, in: 0.5...3, step: 0.1) }
                            Picker("스크롤 방향", selection: $scrollReversed) {
                                Text("기본").tag(false)
                                Text("반대로").tag(true)
                            }.pickerStyle(.segmented)
                            Text("두 손가락 벌리기·오므리기: 연속 핀치 확대·축소(지원 앱). 네 손가락 펼치기·오므리기: 데스크톱 보기·복귀. 네 손가락 위·아래: Mission Control 열기·닫기. Mac의 데스크톱 보기 단축키는 F11이어야 합니다.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("연결 해제") { link.disconnect() }
                    } else {
                        if link.canReconnect {
                            Button("등록된 Mac 다시 연결") { link.reconnect(host: host, port: port) }.buttonStyle(.borderedProminent)
                        }
                        Button("Mac 연결 QR 읽기") { scan = true }.buttonStyle(.bordered)
                        SecureField("연결 정보 직접 붙여넣기", text: $invitation).textContentType(.none)
                        if link.isRegisteredInvitation(invitation) {
                            Text("이미 등록된 기기입니다. 기존 페어링으로 연결합니다.").font(.callout).foregroundStyle(.green)
                        } else {
                            TextField("Mac의 6자리 연결 코드", text: $code).keyboardType(.numberPad)
                        }
                        Button(link.isRegisteredInvitation(invitation) ? "기존 페어링으로 연결" : "등록 및 연결") { link.pair(invitation: invitation, code: code, host: host, port: port); invitation = ""; code = "" }
                            .buttonStyle(.borderedProminent).disabled(invitation.isEmpty || (!link.isRegisteredInvitation(invitation) && code.count != 6))
                        DisclosureGroup("자동 검색 실패 시 수동 주소") {
                            TextField("Mac IP 주소 또는 이름.local", text: $host)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("Mac에 표시된 포트", text: $port).keyboardType(.numberPad)
                        }
                        Text("Mac에서도 이 아이폰을 선택해 연결할 수 있습니다. 앱을 이 화면에 열어 두세요.").font(.caption)
                        if let scannerError { Text(scannerError).foregroundStyle(.red) }
                    }
                }.padding(24).textFieldStyle(.roundedBorder)
            }
            .navigationTitle("RemoteForMac")
            .onAppear { link.becameActive() }
            .fullScreenCover(isPresented: $showingTouchpad, onDismiss: {
                link.endKeyboard(); link.releaseShift()
                link.clearMotion()
            }) {
                FullScreenTouchpad(link: link, sensitivity: sensitivity)
            }
            .sheet(isPresented: $scan) {
                QRScanner(scanned: { invitation = $0; scan = false }, failed: { scannerError = $0; scan = false })
                    .ignoresSafeArea()
                    .overlay(alignment: .topTrailing) { Button("닫기") { scan = false }.padding().background(.ultraThinMaterial) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { link.becameActive() } else { link.becameInactive() }
            }
            .onDisappear { link.endKeyboard() }
        }
    }
}


private struct FullScreenTouchpad: View {
    @ObservedObject var link: PhoneLink
    let sensitivity: Double
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage("scrollReversed") private var scrollReversed = false
    private var landscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground).ignoresSafeArea()
            Touchpad(move: { link.move(dx: $0 * sensitivity, dy: $1 * sensitivity) },
                     scroll: { link.scroll(dx: $0 * (scrollReversed ? -1 : 1), dy: $1 * (scrollReversed ? -1 : 1)) }, tap: link.click, rightTap: link.rightClick, doubleClick: link.doubleClick,
                     drag: link.drag, desktop: link.desktop, missionControl: link.missionControl,
                     missionControlDismiss: { link.key(.escape) },
                     zoom: { link.zoom($0) }, zoomEnd: { link.endZoom() }, showDesktop: { link.showDesktop() })
                .id(link.interactionGeneration)
                .ignoresSafeArea(edges: [.horizontal, .bottom])
                .overlay {
                    VStack(spacing: landscape ? 6 : 16) {
                        Image(systemName: "hand.draw").font(.system(size: landscape ? 26 : 44))
                        Text("한 손가락 이동 · 탭 클릭\n두 손가락 탭: 오른쪽 클릭 · 쓸기: 스크롤\n두 번 탭: 더블클릭 · 두 번째 탭을 잡고 이동: 드래그\n세 손가락 드래그 · 네 손가락 좌우 화면 전환 · 위로 Mission Control · 아래로 닫기")
                            .font(landscape ? .caption : .callout)
                            .multilineTextAlignment(.center)
                    }.foregroundStyle(.tertiary).allowsHitTesting(false)
                }
            KeyboardCapture(active: link.keyboardVisible, sessionID: link.inputID, baseline: link.baseline,
                            onSnapshot: link.update, onSubmit: link.submit, onEmptyDelete: link.backspace)
                .frame(width: 1, height: 1).clipped()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button {
                    link.endKeyboard(); link.releaseShift(); link.clearMotion(); dismiss()
                } label: { Label("뒤로", systemImage: "chevron.left").frame(minHeight: 44) }
                Spacer()
                if landscape {
                    RemoteShortcuts(link: link)
                } else { Text("터치패드").font(.headline) }
                Spacer()
                Button {
                    link.key(.lockScreen)
                } label: {
                    Image(systemName: "lock.fill")
                        .frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("Mac 화면 잠금")
                Menu {
                    Picker("스크롤 방향", selection: $scrollReversed) {
                        Text("기본 방향").tag(false)
                        Text("반대 방향").tag(true)
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("스크롤 방향")
                Button {
                    link.keyboardVisible ? link.endKeyboard() : link.beginKeyboard()
                } label: {
                    Image(systemName: link.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
                        .frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel(link.keyboardVisible ? "키보드 닫기" : "키보드 열기")
            }.padding(.horizontal, 16).background(.regularMaterial)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                if !landscape { RemoteShortcuts(link: link) }
                Text(link.status).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(landscape ? 1 : 3).allowsHitTesting(false)
            }.padding(8).background(.regularMaterial)
        }
        .onAppear { link.touchpadVisible = true }
        .onDisappear { link.touchpadVisible = false; link.endKeyboard(); link.releaseShift() }
        // Keep this screen in place while foreground reconnection is in progress.
    }
}


private struct RemoteShortcuts: View {
    @ObservedObject var link: PhoneLink
    var body: some View {
        HStack(spacing: 6) {
            key("뒤로", .back)
            key("Esc", .escape)
            arrow("arrow.left", "왼쪽 방향키", .left)
            arrow("arrow.up", "위쪽 방향키", .up)
            arrow("arrow.down", "아래쪽 방향키", .down)
            arrow("arrow.right", "오른쪽 방향키", .right)
        }.buttonStyle(.plain)
    }
    private func key(_ label: String, _ code: RemoteKey) -> some View {
        Button { link.key(code) } label: {
            Text(label).font(.callout).frame(width: 44, height: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
    }
    private func arrow(_ icon: String, _ label: String, _ code: RemoteKey) -> some View {
        Button { link.key(code) } label: {
            Image(systemName: icon).frame(width: 44, height: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }.accessibilityLabel(label)
    }
}

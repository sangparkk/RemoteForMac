import SwiftUI
import AppKit

@main
struct RemoteTVHostApp: App {
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra("RemoteForMac Host", systemImage: "appletvremote.gen4") {
            HostMenu(delegate: delegate, link: delegate.link)
        }
    }
}

/// A menu-bar app must explicitly create its first window and handle Finder reopen.
/// Keep one window alive so closing it does not stop the remote connection.
@MainActor
final class HostAppDelegate: NSObject, NSApplicationDelegate {
    let launcher = ServiceLauncher()
    let probe = ProbeModel()
    let link = HostLink()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        writeLaunchReport(stage: "launched")
        showSettings()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) { link.releasePointer() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func showSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: HostSettings(launcher: launcher, probe: probe, link: link))
            let window = NSWindow(contentViewController: controller)
            window.title = "RemoteForMac Host · 연결 및 설정"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 720, height: 700))
            window.minSize = NSSize(width: 660, height: 620)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.deminiaturize(nil)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.writeLaunchReport(stage: "window-shown")
        }
    }

    /// Opt-in developer smoke-test output; never captures screen pixels or text input.
    private func writeLaunchReport(stage: String) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--launch-report"), index + 1 < arguments.count else { return }
        let report: [String: Any] = [
            "stage": stage,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundlePath": Bundle.main.bundleURL.path,
            "windowVisible": settingsWindow?.isVisible ?? false,
            "windowKey": settingsWindow?.isKeyWindow ?? false,
            "applicationActive": NSApp.isActive,
            "windowOnScreen": settingsWindow.map { window in NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) } } ?? false
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: arguments[index + 1]), options: .atomic)
    }
}

private struct HostMenu: View {
    let delegate: HostAppDelegate
    @ObservedObject var link: HostLink
    var body: some View {
        Button("연결 및 설정") { delegate.showSettings() }
        Divider()
        Button("YouTube 열기") { link.endInput(); delegate.launcher.launchYouTube() }
        Button("Netflix 열기") { link.endInput(); delegate.launcher.launchNetflix() }
        Button(link.paused ? "원격 입력 재개" : "원격 입력 일시 중지") {
            link.paused.toggle(); delegate.probe.stop()
        }
        Divider()
        Text(link.status)
        Button("종료") { NSApp.terminate(nil) }
    }
}

struct HostSettings: View {
    @ObservedObject var launcher: ServiceLauncher
    @ObservedObject var probe: ProbeModel
    @ObservedObject var link: HostLink
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("아이폰을 Mac 리모컨으로").font(.largeTitle.bold())
                Text("연결 후 터치패드로 Mac 전체를 조작할 수 있습니다. 서비스 검색창을 클릭하면 아이폰 키보드가 열립니다.")
                    .foregroundStyle(.secondary)
                GroupBox("아이폰 연결") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(link.status)
                        HStack {
                            Button("아이폰 추가 등록") { link.newPairing() }
                            if !link.activeService.isEmpty { Button("연결 해제") { link.disconnectPeer() } }
                        }
                        ForEach(link.peers) { peer in
                            HStack {
                                Label(peer.name, systemImage: "iphone")
                                Text(String(peer.service.suffix(6))).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if link.activeService == peer.service { Text("연결 중").foregroundStyle(.green) }
                                else { Button("연결") { link.connectPeer(peer) } }
                                Button("등록 삭제", role: .destructive) { link.removePeer(peer) }
                            }
                        }
                        Text("Mac에서 연결하려면 같은 Wi-Fi에서 아이폰 앱을 열어 주세요. 동시에 한 기기만 제어합니다.").font(.caption)
                        if let image = link.qrImage {
                            HStack {
                                Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220).padding(12).background(.white)
                                VStack(alignment: .leading) {
                                    Text(link.code).font(.system(size: 34, weight: .bold, design: .monospaced))
                                    if let invitation = link.invitation {
                                        PairingCountdown(deadline: invitation.expires)
                                    }
                                    Text("QR을 읽은 뒤 코드를 입력하세요.")
                                    if let invitation = link.invitation {
                                        DisclosureGroup("카메라 없이 연결") {
                                            Text(invitation.encoded).font(.caption2).textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                        }
                        Text("수동 연결: Mac 네트워크 설정의 IP 주소 · 포트 \(link.port)").font(.caption)
                        Toggle("원격 입력 일시 중지", isOn: $link.paused)
                    }.padding(8)
                }
                WebRemoteSettings(server: link.web)
                GroupBox("권한") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(AccessibilityInput.permitted ? "손쉬운 사용 허용됨" : "손쉬운 사용 권한 필요")
                            Spacer()
                            Button("권한 요청") { AccessibilityInput.requestPermission() }
                        }
                        Text("시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 → RemoteForMac Host 켜기")
                            .font(.callout)
                        Text("목록에 없으면 + 버튼에서 아래 실행 중인 앱을 추가하세요.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(Bundle.main.bundleURL.path).font(.caption).textSelection(.enabled)
                        Button("실행 중인 앱을 Finder에서 보기") {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                    }.padding(8)
                }
                GroupBox("설치된 Safari YouTube 웹 앱") {
                    VStack(alignment: .leading) {
                        Picker("앱", selection: $launcher.selectedPath) {
                            Text("선택 필요").tag("")
                            ForEach(launcher.candidates) { Text("\($0.name) — \($0.url.path)").tag($0.id) }
                        }
                        HStack {
                            Button("다시 찾기") { launcher.refresh() }
                            Button("직접 선택") { launcher.choose() }
                            Button("실행·활성화") { probe.stop(); link.endInput(); launcher.launchYouTube() }
                            Button("Safari Netflix 열기") { probe.stop(); link.endInput(); launcher.launchNetflix() }
                        }
                        Text(launcher.status).font(.callout)
                    }.padding(8)
                }
                DisclosureGroup("입력 문제 진단") {
                Toggle("Mac 테스트 입력란 사용", isOn: $link.useTestField)
                GroupBox("Mac 테스트 입력란 · 합성 입력 이벤트") {
                    VStack(alignment: .leading) {
                        NativeTestField(model: probe).frame(height: 80)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))]) {
                            ForEach(CompositionFixture.all, id: \.name) { fixture in
                                Button(fixture.name) { link.endInput(); probe.runLocalFixture(fixture) }.disabled(probe.running)
                            }
                        }
                    }.padding(8)
                }
                GroupBox("실제 서비스 검색창 검증") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("버튼을 누른 뒤 5초 안에 선택한 서비스 검색창을 선택하세요. 두 번째 버튼은 선택 영역을 실제로 수정합니다.")
                        HStack {
                            Button("지원 속성만 확인") { link.endInput(); probe.inspectTarget(launcher.controlledApplication, service: launcher.currentService) }
                            Button("선택 영역에 ‘한’ 조합 실험") { link.endInput(); probe.runTargetFixture(launcher.controlledApplication, service: launcher.currentService) }
                        }.disabled(probe.running)
                        Text(probe.capabilities).font(.callout)
                    }.padding(8)
                }
                HStack {
                    Text(probe.status).textSelection(.enabled)
                    Spacer()
                    Button("중지") { probe.stop() }
                }
                }
            }.padding(24)
        }.frame(minWidth: 660, minHeight: 620)
            .onAppear { link.start(probe: probe, launcher: launcher) }
    }
}


private struct WebRemoteSettings: View {
    @ObservedObject var server: WebRemoteServer
    private var alternativeURL: String? {
        let alternatives = server.urls.dropFirst()
        return alternatives.first { URL(string: $0)?.host?.first?.isNumber == true } ?? alternatives.first
    }

    var body: some View {
        GroupBox("Safari 웹 리모컨 · 개발자 모드 없이 사용") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(server.running ? "웹 리모컨 끄기" : "웹 리모컨 켜기") {
                        server.running ? server.stop() : server.start()
                    }
                    if server.running && server.activeDevice == nil { Button("새 등록 코드") { server.issueCode() } }
                    if server.running {
                        Button("웹 등록 초기화", role: .destructive) { server.resetAccess() } }
                }
                Text(server.status)
                if server.running && server.activeDevice == nil {
                    Text(server.pairingCode).font(.system(size: 30, weight: .bold, design: .monospaced))
                    if let deadline = server.pairingDeadline {
                        PairingCountdown(deadline: deadline)
                    }
                    Text("처음 등록할 때만 입력 · 2분마다 자동 갱신").font(.caption)
                } else if server.running, let device = server.activeDevice {
                    Label("연결된 기기: \(device)", systemImage: "iphone").font(.headline)
                    if server.connectedDevice != nil {
                        Text("웹브라우저에서는 실제 기기 이름을 읽을 수 없어 웹앱마다 고유 식별 코드를 표시합니다.").font(.caption)
                    }
                }
                if let image = server.qrImage {
                    HStack {
                        Image(nsImage: image).interpolation(.none).resizable().frame(width: 190, height: 190).padding(8).background(.white)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("① 최초 한 번만 QR로 웹앱 열기\n② 공유 → 홈 화면에 추가\n③ 홈 화면 웹앱에서 6자리 코드 등록\n④ 다음부터 홈 화면에서 열면 자동 연결")
                            Text("연결하면 기존 앱의 제어 연결은 해제됩니다. 기존 등록 정보는 유지됩니다.").font(.caption)
                            if let url = server.urls.first {
                                Text(url).font(.caption).textSelection(.enabled)
                                Button("리모컨 주소 복사") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url, forType: .string)
                                }
                            }
                            if let url = alternativeURL {
                                Button("대체 주소 복사") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url, forType: .string)
                                }
                            }
                        }
                    }
                    Text("로컬 HTTP 방식으로 암호화되지 않습니다. 신뢰하는 개인 Wi-Fi에서만 사용하세요. 등록 코드와 브라우저에 저장된 인증키를 공유하지 마세요.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("저장된 등록 정보로 웹앱을 열 때 자동 연결합니다. 웹 등록 초기화 또는 Safari 데이터 삭제 시 코드를 다시 입력하세요.").font(.caption)
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PairingCountdown: View {
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(ceil(deadline.timeIntervalSince(context.date))))
            Text("남은 시간 \(remaining / 60)분 \(remaining % 60)초")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

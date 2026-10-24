import AppKit
import SwiftUI

@MainActor
final class ProbeModel: ObservableObject {
    @Published var status = "로컬 입력 검증 준비됨"
    @Published var running = false
    @Published var capabilities = "서비스 입력란 지원 여부: 미검증"
    let backend = AccessibilityInput()
    private var task: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var boundPID: pid_t?
    weak var testView: NSTextView?

    init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                guard let self, let pid = self.boundPID, pid != application.processIdentifier else { return }
                self.stop(reason: "다른 앱으로 전환되어 입력 검증을 중지했습니다.")
            }
        }
    }

    func stop(reason: String = "검증을 중지했습니다.") {
        task?.cancel(); task = nil; backend.invalidate(); boundPID = nil; running = false; status = reason
    }

    func runLocalFixture(_ fixture: CompositionFixture) {
        stop()
        guard let view = testView else { return }
        view.string = fixture.baseline.text
        view.setSelectedRange(fixture.baseline.selection.nsRange)
        running = true
        task = Task { @MainActor in
            do {
                var session = try InputSession(baseline: fixture.baseline)
                for snapshot in fixture.updates {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(250))
                    let envelope = InputEnvelope(connectionID: session.connectionID, inputSessionID: session.id,
                                                 sequence: session.nextSequence, snapshot: snapshot)
                    if try session.accept(envelope) {
                        view.string = session.snapshot.text
                        view.setSelectedRange(session.snapshot.selection.nsRange)
                    }
                }
                status = "로컬 픽스처 적용 완료: \(fixture.name). 실제 아이폰 키보드 검증과 별개입니다."
                running = false
            } catch is CancellationError { } catch { stop(reason: error.localizedDescription) }
        }
    }

    /// Read-only probe after a delay, allowing the user to focus an actual search box.
    func inspectTarget(_ app: NSRunningApplication?, service: Service) {
        stop()
        guard let app else { status = "먼저 서비스 앱을 실행하세요."; return }
        running = true
        status = "5초 안에 선택한 서비스의 검색창을 클릭하세요. 내용을 수정하지 않고 지원 여부를 확인합니다."
        task = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(5))
                _ = try backend.begin(application: app, service: service)
                capabilities = "값·선택 범위 읽기 및 쓰기 가능 속성 확인됨. 실제 수정·검색 반응은 미검증."
                backend.invalidate(); running = false; status = "입력란 속성 확인 완료. 입력 내용은 기록하지 않았습니다."
            } catch is CancellationError { } catch { stop(reason: error.localizedDescription) }
        }
    }

    /// Explicit destructive probe, only after the user opts in via the dedicated button.
    /// Inserts into the existing selection, preserving text before and after it.
    func runTargetFixture(_ app: NSRunningApplication?, service: Service) {
        stop()
        guard let app else { status = "먼저 서비스 앱을 실행하세요."; return }
        status = "5초 안에 수정해도 되는 서비스 검색창을 선택하세요. 선택 영역에 ‘한’을 조합합니다."
        running = true
        task = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(5))
                let baseline = try backend.begin(application: app, service: service)
                boundPID = app.processIdentifier
                var session = try InputSession(baseline: baseline)
                let source = baseline.text as NSString
                let prefix = source.substring(to: baseline.selection.location)
                let suffix = source.substring(from: baseline.selection.location + baseline.selection.length)
                for (index, part) in ["ㅎ", "하", "한", "한"].enumerated() {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(400))
                    let snapshot = TextSnapshot(text: prefix + part + suffix,
                        selection: .init(location: prefix.utf16.count + part.utf16.count, length: 0),
                        marked: index == 3 ? nil : .init(location: prefix.utf16.count, length: part.utf16.count))
                    let envelope = InputEnvelope(connectionID: session.connectionID, inputSessionID: session.id,
                                                 sequence: session.nextSequence, snapshot: snapshot)
                    if try session.accept(envelope) { try backend.apply(snapshot) }
                }
                capabilities = "AX 수정·읽기 반환 확인됨. 사이트 검색 제안·검색 실행은 직접 확인 필요."
                stop(reason: "‘ㅎ → 하 → 한’ 적용 완료. 페이지가 입력을 인식하는지 확인하세요.")
            } catch is CancellationError { } catch { stop(reason: error.localizedDescription) }
        }
    }
}

struct NativeTestField: NSViewRepresentable {
    let model: ProbeModel
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.font = .systemFont(ofSize: 30)
        view.isRichText = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.setAccessibilityIdentifier("composition-test-field")
        model.testView = view
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) { }
}

import SwiftUI

@main
struct RemoteTVPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            RemoteScreen()
        }
    }
}

/// Local hardware-keyboard probe only. Never labels local capture as Mac delivery.
struct KeyboardProbeScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboardOpen = false
    @State private var sessionID = UUID()
    @State private var eventCount = 0
    @State private var compositionCount = 0
    @State private var commitCount = 0
    @State private var submitCount = 0
    @State private var wasMarked = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "tv").font(.system(size: 58)).foregroundStyle(.indigo)
                Text("키보드 기술 검증").font(.title.bold())
                Text("Mac 연결 전 · 이 화면은 아이폰 기본 키보드의 조합 이벤트만 확인합니다.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                VStack(spacing: 12) {
                    metric("입력 변경", eventCount)
                    metric("조합 중 변경", compositionCount)
                    metric("조합 확정", commitCount)
                    metric("검색 키", submitCount)
                }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 20))
                Text("작성한 내용은 이 화면에 표시하거나 로그에 저장하지 않습니다.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
                Button {
                    if keyboardOpen { close() }
                    else { sessionID = UUID(); wasMarked = false; keyboardOpen = true }
                } label: {
                    Label(keyboardOpen ? "키보드 닫기" : "키보드 열기", systemImage: "keyboard")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(.borderedProminent)
                Button("측정 초기화") {
                    close(); eventCount = 0; compositionCount = 0; commitCount = 0; submitCount = 0; error = nil
                }
                KeyboardCapture(active: keyboardOpen, sessionID: sessionID,
                    baseline: CompositionFixture.snapshot(""), onSnapshot: receive,
                    onSubmit: { submitCount += 1 })
                    .frame(width: 1, height: 1).clipped().allowsHitTesting(false)
                Spacer(minLength: 0)
            }.padding(24)
                .navigationTitle("RemoteForMac")
                .navigationBarTitleDisplayMode(.inline)
                .onChange(of: scenePhase) { _, phase in if phase != .active { close() } }
                .onDisappear { close() }
        }
    }
    private func metric(_ title: String, _ count: Int) -> some View {
        HStack { Text(title); Spacer(); Text(count, format: .number).monospacedDigit() }
    }
    private func receive(_ snapshot: TextSnapshot) {
        do {
            try snapshot.validate()
            eventCount += 1
            if snapshot.marked != nil { compositionCount += 1 }
            if wasMarked && snapshot.marked == nil { commitCount += 1 }
            wasMarked = snapshot.marked != nil
        } catch { self.error = error.localizedDescription; close() }
    }
    private func close() { keyboardOpen = false; sessionID = UUID(); wasMarked = false }
}

import AppKit

struct WebAppCandidate: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let bundleIdentifier: String
    let startURL: URL

    static func inspect(_ url: URL) -> WebAppCandidate? {
        // Read Info.plist directly: template apps need not have CFBundleExecutable.
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              info["LSTemplateApplication"] as? Bool == true,
              let template = info["LSTemplateApplicationParameters"] as? [String: Any],
              template["CFBundleIdentifier"] as? String == "com.apple.Safari.WebApp",
              let manifest = info["Manifest"] as? [String: Any],
              let start = manifest["start_url"] as? String, let startURL = URL(string: start),
              let host = startURL.host?.lowercased(),
              startURL.scheme == "https", host == "youtube.com" || host.hasSuffix(".youtube.com"),
              let identifier = info["CFBundleIdentifier"] as? String else { return nil }
        return .init(url: url, name: info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent,
                     bundleIdentifier: identifier, startURL: startURL)
    }

    static func discover() -> [WebAppCandidate] {
        let manager = FileManager.default
        let roots = [manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications")]
        var found = [WebAppCandidate]()
        for root in roots {
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                if url.pathExtension == "app" {
                    enumerator.skipDescendants()
                    if let candidate = inspect(url) { found.append(candidate) }
                }
            }
        }
        return found.sorted { $0.url.path < $1.url.path }
    }
}

@MainActor
final class ServiceLauncher: ObservableObject {
    @Published var candidates = [WebAppCandidate]()
    @Published var selectedPath = ""
    @Published var status = "YouTube 웹 앱을 선택하세요."
    private(set) var controlledApplication: NSRunningApplication?
    private(set) var currentService: Service = .youtube
    private(set) var activationID = UUID()
    private var netflixWindowID: Int32 = 0
    private var netflixPID: pid_t = 0
    private var launchGeneration = UUID()
    private var openingNetflix = false

    init() { refresh() }
    func refresh() {
        candidates = WebAppCandidate.discover()
        let saved = UserDefaults.standard.string(forKey: "youtubeWebApp") ?? ""
        if candidates.contains(where: { $0.id == saved }) { selectedPath = saved }
        else if candidates.count == 1 { selectedPath = candidates[0].id }
        else { selectedPath = "" }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let candidate = WebAppCandidate.inspect(url) else {
            status = "Safari에서 youtube.com을 열고 파일 > Dock에 추가로 만든 앱을 선택하세요."; return
        }
        if !candidates.contains(candidate) { candidates.append(candidate) }
        selectedPath = candidate.id
    }

    func launchYouTube() {
        let generation = UUID()
        launchGeneration = generation; openingNetflix = false
        controlledApplication = nil
        currentService = .youtube
        guard let candidate = candidates.first(where: { $0.id == selectedPath }),
              WebAppCandidate.inspect(candidate.url) == candidate else {
            status = "YouTube 웹 앱이 없습니다. Safari의 파일 > Dock에 추가로 설치하거나 앱을 선택하세요."; return
        }
        UserDefaults.standard.set(selectedPath, forKey: "youtubeWebApp")
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: candidate.bundleIdentifier).first {
            controlledApplication = running
            activationID = UUID()
            running.activate(options: [.activateAllWindows])
            status = "기존 YouTube 웹 앱을 활성화했습니다."; return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: candidate.url, configuration: configuration) { [weak self] app, error in
            Task { @MainActor in
                guard self?.launchGeneration == generation else { return }
                self?.controlledApplication = app
                self?.activationID = UUID()
                self?.status = error == nil ? "YouTube 웹 앱을 실행했습니다." : "YouTube 실행 실패: \(error!.localizedDescription)"
            }
        }
    }

    func launchNetflix() {
        guard !openingNetflix else { return }
        let generation = UUID()
        launchGeneration = generation
        controlledApplication = nil
        currentService = .netflix
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            status = "Safari를 찾을 수 없습니다."; return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        openingNetflix = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] app, error in
            Task { @MainActor in
                guard self?.launchGeneration == generation else { return }
                self?.openingNetflix = false
                guard let self, let app, error == nil else { self?.status = "Safari 실행에 실패했습니다."; return }
                // Ignore stale window IDs after a Safari process restart.
                let oldID = self.netflixPID == app.processIdentifier ? self.netflixWindowID : 0
                let source = """
                tell application id "com.apple.Safari"
                    set ownedWindow to missing value
                    repeat with candidate in windows
                        if id of candidate is \(oldID) then
                            set currentURL to URL of current tab of candidate
                            if currentURL starts with "https://www.netflix.com/" or currentURL starts with "https://netflix.com/" then
                                set ownedWindow to candidate
                            end if
                        end if
                    end repeat
                    if ownedWindow is missing value then
                        make new document with properties {URL:"https://www.netflix.com/"}
                        set ownedWindow to front window
                    end if
                    set index of ownedWindow to 1
                    activate
                    return id of ownedWindow
                end tell
                """
                var scriptError: NSDictionary?
                guard let script = NSAppleScript(source: source) else { self.status = "Safari 제어 스크립트를 만들 수 없습니다."; return }
                let result = script.executeAndReturnError(&scriptError)
                guard scriptError == nil else {
                    self.status = "Safari 자동화가 거부되었거나 창 제어에 실패했습니다. 시스템 설정 > 개인정보 보호 및 보안 > 자동화를 확인하세요."; return
                }
                self.netflixWindowID = result.int32Value
                self.netflixPID = app.processIdentifier
                self.controlledApplication = app
                self.activationID = UUID()
                self.status = "Safari의 앱 관리 Netflix 창을 열었습니다. 로그인과 검색창 선택이 필요합니다."
            }
        }
    }
}

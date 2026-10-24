import Foundation

/// All ranges on the wire use UTF-16, matching UIKit and Accessibility.
struct TextRange: Codable, Equatable {
    var location: Int
    var length: Int
    var nsRange: NSRange { NSRange(location: location, length: length) }

    func isValid(in text: String) -> Bool {
        let count = text.utf16.count
        guard location >= 0, length >= 0, location <= count, length <= count - location else { return false }
        let units = Array(text.utf16)
        func boundary(_ offset: Int) -> Bool {
            guard offset > 0, offset < units.count else { return true }
            return !(0xD800...0xDBFF).contains(units[offset - 1]) || !(0xDC00...0xDFFF).contains(units[offset])
        }
        return boundary(location) && boundary(location + length)
    }
}

struct TextSnapshot: Codable, Equatable {
    var text: String
    var selection: TextRange
    var marked: TextRange?

    func validate() throws {
        guard text.utf8.count <= 32_768,
              selection.isValid(in: text),
              marked?.isValid(in: text) ?? true else { throw InputFailure.invalidSnapshot }
    }
}

struct InputEnvelope: Codable {
    static let currentVersion = 1
    var version = currentVersion
    let connectionID: UUID
    let inputSessionID: UUID
    let sequence: UInt64
    let snapshot: TextSnapshot
}

enum InputFailure: String, Error, LocalizedError {
    case invalidSnapshot, wrongVersion, expiredSession, outOfOrder, targetChanged, unsupportedTarget
    case permissionDenied, writeFailed, readbackMismatch
    var errorDescription: String? {
        switch self {
        case .invalidSnapshot: return "입력 범위 또는 입력 크기가 올바르지 않습니다."
        case .wrongVersion: return "앱의 통신 버전이 다릅니다."
        case .expiredSession: return "입력 연결이 종료되었습니다. 검색창을 다시 선택하세요."
        case .outOfOrder: return "입력 순서가 달라 입력을 중지했습니다."
        case .targetChanged: return "입력 대상이나 커서가 변경되었습니다. 검색창을 다시 선택하세요."
        case .unsupportedTarget: return "이 입력란은 현재 입력 방식으로 안전하게 수정할 수 없습니다."
        case .permissionDenied: return "Mac에서 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 → RemoteTVHost를 켜세요."
        case .writeFailed: return "입력란 수정에 실패하여 입력을 중지했습니다."
        case .readbackMismatch: return "입력 결과를 확인할 수 없어 입력을 중지했습니다."
        }
    }
}

/// Snapshot replacement, never concatenation: ㅎ → 하 → 한 stays one syllable.
/// A baseline is read from the focused Mac field before the phone becomes first responder.
struct InputSession {
    let connectionID: UUID
    let id: UUID
    private(set) var snapshot: TextSnapshot
    private(set) var nextSequence: UInt64 = 1
    private(set) var active = true

    init(connectionID: UUID = UUID(), id: UUID = UUID(), baseline: TextSnapshot) throws {
        try baseline.validate()
        self.connectionID = connectionID
        self.id = id
        self.snapshot = baseline
    }

    /// Duplicate envelopes are acknowledged without performing a second write.
    /// Transport must not retry failed effects or replay across connection IDs.
    mutating func accept(_ envelope: InputEnvelope) throws -> Bool {
        guard active, envelope.connectionID == connectionID, envelope.inputSessionID == id else {
            throw InputFailure.expiredSession
        }
        guard envelope.version == InputEnvelope.currentVersion else { throw InputFailure.wrongVersion }
        guard envelope.sequence > 0 else { throw InputFailure.outOfOrder }
        if envelope.sequence < nextSequence { return false }
        guard envelope.sequence == nextSequence, nextSequence < UInt64.max else {
            active = false
            throw InputFailure.outOfOrder
        }
        try envelope.snapshot.validate()
        snapshot = envelope.snapshot
        nextSequence += 1
        return true
    }

    mutating func invalidate() { active = false }
}

enum RemoteKey: String, Codable, CaseIterable {
    case up, down, left, right, enter, tab, shiftTab, escape, back, lockScreen
}

enum DesktopDirection: String, Codable { case left, right }

enum Service: String, Codable { case youtube, netflix }

/// Deliberately closed command set. No script, URL, executable, or shell payload.
enum RemoteCommand: Codable {
    case activate(Service)
    case pointer(dx: Double, dy: Double)
    case click
    case rightClick
    case doubleClick
    case shift(Bool)
    case dragBegin
    case dragEnd
    case missionControl
    case showDesktop
    case zoom(Double)
    case zoomEnd
    case desktop(DesktopDirection)
    case scroll(dx: Double, dy: Double)
    case key(RemoteKey)
    case beginText(UUID)
    case acceptFocus(UUID)
    case text(InputEnvelope)
    case endText(session: UUID)
    case playback(PlaybackAction)
    case status
}

enum PlaybackAction: String, Codable { case toggle, backward, forward, fullscreen }

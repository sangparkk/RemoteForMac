import Foundation

/// Correlates asynchronous focus offers and baselines. A late reply can never reopen
/// a dismissed keyboard or overwrite a newer field's baseline.
struct KeyboardNegotiation {
    private(set) var pending: UUID?
    mutating func request(_ id: UUID = UUID()) -> UUID { pending = id; return id }
    mutating func accept(_ id: UUID) -> Bool {
        guard pending == id else { return false }
        pending = nil
        return true
    }
    mutating func cancel() { pending = nil }
}

/// Preserve text typed while the Mac is returning its focused-field baseline.
enum PendingKeyboardText {
    static func merge(_ draft: TextSnapshot, into baseline: TextSnapshot) throws -> TextSnapshot {
        try draft.validate(); try baseline.validate()
        guard !draft.text.isEmpty else { return baseline }
        let offset = baseline.selection.location
        let text = (baseline.text as NSString).replacingCharacters(in: baseline.selection.nsRange, with: draft.text)
        let result = TextSnapshot(text: text,
                                  selection: .init(location: offset + draft.selection.location, length: draft.selection.length),
                                  marked: draft.marked.map { .init(location: offset + $0.location, length: $0.length) })
        try result.validate()
        return result
    }
}

/// Native input buffer starts at the Mac's current selection. Recomposition only
/// replaces characters previously inserted by this session, never unrelated text.
struct NativeTextEdit: Equatable {
    let deleteCount: Int
    let insert: String
    static func between(_ previous: TextSnapshot, _ next: TextSnapshot) throws -> Self {
        try previous.validate(); try next.validate()
        guard next.selection.length == 0, next.selection.location == next.text.utf16.count else {
            throw InputFailure.unsupportedTarget
        }
        let old = Array(previous.text), new = Array(next.text)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        return Self(deleteCount: old.count - prefix, insert: String(new.dropFirst(prefix)))
    }
}

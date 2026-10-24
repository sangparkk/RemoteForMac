import SwiftUI
import UIKit

/// UITextView provides Apple's real UITextInput implementation, including Korean IME.
/// Its text/caret are invisible, but the view remains first-responder eligible.
/// We never hide/disable the view or use secure entry (which changes available keyboards).
final class KeyboardCaptureView: UITextView, UITextViewDelegate {
    var onSnapshot: ((TextSnapshot) -> Void)?
    var onSubmit: (() -> Void)?
    var onEmptyDelete: (() -> Void)?
    var wantsKeyboard = false
    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncKeyboard()
    }
    func syncKeyboard() {
        if wantsKeyboard {
            guard window != nil else { return }
            if !isFirstResponder { becomeFirstResponder() }
        } else if isFirstResponder { resignFirstResponder() }
    }
    private var suppress = false
    private var mutationDepth = 0
    private var lastSnapshot: TextSnapshot?

    init() {
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        font = .systemFont(ofSize: 17)
        autocorrectionType = .no
        autocapitalizationType = .none
        inlinePredictionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        returnKeyType = .search
        textContentType = .none
        isScrollEnabled = false
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        accessibilityLabel = "모니터 검색창에 입력"
        // Avoid making a second representation of the remote text accessible.
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reset(to baseline: TextSnapshot) {
        suppress = true
        super.unmarkText()
        text = baseline.text
        selectedRange = baseline.selection.nsRange
        if let marked = baseline.marked {
            selectedRange = marked.nsRange
            let relativeStart = max(0, min(marked.length, baseline.selection.location - marked.location))
            let relativeLength = min(baseline.selection.length, marked.length - relativeStart)
            super.setMarkedText((baseline.text as NSString).substring(with: marked.nsRange),
                                selectedRange: NSRange(location: relativeStart, length: relativeLength))
        }
        lastSnapshot = baseline
        suppress = false
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        mutationDepth += 1
        super.setMarkedText(markedText, selectedRange: selectedRange)
        mutationDepth -= 1
        publish()
    }
    override func unmarkText() {
        mutationDepth += 1
        super.unmarkText()
        mutationDepth -= 1
        publish()
    }
    override func insertText(_ text: String) {
        if text == "\n" { submit(); return }
        mutationDepth += 1
        super.insertText(text)
        mutationDepth -= 1
        publish()
    }
    override func deleteBackward() {
        if (text ?? "").isEmpty { onEmptyDelete?(); return }
        mutationDepth += 1
        super.deleteBackward()
        mutationDepth -= 1
        publish()
    }
    override func replace(_ range: UITextRange, withText text: String) {
        mutationDepth += 1
        super.replace(range, withText: text)
        mutationDepth -= 1
        publish()
    }
    func textViewDidChange(_ textView: UITextView) { publish() }
    func textViewDidChangeSelection(_ textView: UITextView) { publish() }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n" { submit(); return false }
        return true
    }
    private func submit() {
        unmarkText() // Publish final syllable before enqueueing Enter, on the same serial stream.
        publish()
        onSubmit?()
    }
    private func publish() {
        guard !suppress, mutationDepth == 0 else { return }
        let marked = markedTextRange.map {
            TextRange(location: offset(from: beginningOfDocument, to: $0.start),
                      length: offset(from: $0.start, to: $0.end))
        }
        let snapshot = TextSnapshot(text: text ?? "", selection: .init(location: selectedRange.location, length: selectedRange.length), marked: marked)
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onSnapshot?(snapshot)
    }
}

struct KeyboardCapture: UIViewRepresentable {
    let active: Bool
    let sessionID: UUID
    let baseline: TextSnapshot
    let onSnapshot: (TextSnapshot) -> Void
    let onSubmit: () -> Void
    var onEmptyDelete: () -> Void = {}

    class Coordinator { var sessionID: UUID? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> KeyboardCaptureView { KeyboardCaptureView() }
    func updateUIView(_ view: KeyboardCaptureView, context: Context) {
        view.onSnapshot = onSnapshot
        view.onSubmit = onSubmit
        view.onEmptyDelete = onEmptyDelete
        if context.coordinator.sessionID != sessionID {
            view.resignFirstResponder()
            view.reset(to: baseline)
            context.coordinator.sessionID = sessionID
        }
        view.wantsKeyboard = active
        view.syncKeyboard()
        // SwiftUI may attach/present this view after updateUIView has returned.
        DispatchQueue.main.async { [weak view] in view?.syncKeyboard() }
    }
    static func dismantleUIView(_ view: KeyboardCaptureView, coordinator: Coordinator) {
        view.wantsKeyboard = false
        view.onSnapshot = nil; view.onSubmit = nil; view.onEmptyDelete = nil
        view.resignFirstResponder()
        view.reset(to: CompositionFixture.snapshot(""))
    }
}

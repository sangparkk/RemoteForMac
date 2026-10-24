import AppKit
import ApplicationServices

/// Experimental AX backend. It mirrors the text, not a native macOS IME marked range.
/// Never falls back to clipboard, blind backspaces, or unscoped keystrokes.
@MainActor
final class AccessibilityInput {
    private var element: AXUIElement?
    private var window: AXUIElement?
    private var pid: pid_t?
    private var expected: TextSnapshot?
    private var service: Service? = .youtube
    private var observer: AXObserver?

    static var permitted: Bool { AXIsProcessTrusted() }
    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// A read-only identity probe; no values or search strings are logged.
    static func focusedServiceField(application: NSRunningApplication, service: Service) -> AXUIElement? {
        guard permitted, application.isActive,
              let focused = element(AXUIElementCreateApplication(application.processIdentifier), kAXFocusedUIElementAttribute),
              string(focused, kAXSubroleAttribute) != kAXSecureTextFieldSubrole as String,
              [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(string(focused, kAXRoleAttribute) ?? ""),
              isInsideServicePage(focused, service: service) else { return nil }
        return focused
    }

    func begin(application: NSRunningApplication, service: Service? = .youtube) throws -> TextSnapshot {
        invalidate()
        guard Self.permitted else { throw InputFailure.permissionDenied }
        guard application.isActive else { throw InputFailure.targetChanged }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let focused = Self.element(app, kAXFocusedUIElementAttribute),
              let focusedWindow = Self.element(app, kAXFocusedWindowAttribute),
              Self.string(focused, kAXSubroleAttribute) != kAXSecureTextFieldSubrole as String,
              [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(Self.string(focused, kAXRoleAttribute) ?? "")
        else { throw InputFailure.unsupportedTarget }
        // Only page content, never Safari's address bar or an unrelated browser tab.
        if let service, !Self.isInsideServicePage(focused, service: service) { throw InputFailure.unsupportedTarget }
        var valueSettable = DarwinBoolean(false), rangeSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &valueSettable) == .success,
              AXUIElementIsAttributeSettable(focused, kAXSelectedTextRangeAttribute as CFString, &rangeSettable) == .success,
              valueSettable.boolValue, rangeSettable.boolValue else { throw InputFailure.unsupportedTarget }
        let snapshot = try Self.read(focused)
        try snapshot.validate()
        element = focused; window = focusedWindow; pid = application.processIdentifier; expected = snapshot
        self.service = service
        var observer: AXObserver?
        let result = AXObserverCreate(application.processIdentifier, { _, _, _, context in
            guard let context else { return }
            let backend = Unmanaged<AccessibilityInput>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { backend.invalidate() }
        }, &observer)
        if result == .success, let observer {
            let pointer = Unmanaged.passUnretained(self).toOpaque()
            let focusResult = AXObserverAddNotification(observer, app, kAXFocusedUIElementChangedNotification as CFString, pointer)
            let windowResult = AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, pointer)
            if focusResult == .success || windowResult == .success {
                self.observer = observer
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        return snapshot
    }

    func apply(_ snapshot: TextSnapshot) throws {
        do {
            try snapshot.validate()
            try validateTarget()
            guard let element, let expected else { throw InputFailure.expiredSession }
            // Metadata-only composition commits require no text mutation.
            if snapshot.text != expected.text {
                guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, snapshot.text as CFString) == .success else {
                    throw InputFailure.writeFailed
                }
            }
            var range = CFRange(location: snapshot.selection.location, length: snapshot.selection.length)
            guard let value = AXValueCreate(.cfRange, &range),
                  AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
                throw InputFailure.writeFailed
            }
            let actual = try Self.read(element)
            guard actual.text == snapshot.text, actual.selection == snapshot.selection else {
                throw InputFailure.readbackMismatch
            }
            self.expected = snapshot
        } catch {
            invalidate()
            throw error
        }
    }

    func validateTarget() throws {
        guard let element, let window, let pid, let expected,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw InputFailure.targetChanged }
        let app = AXUIElementCreateApplication(pid)
        guard let current = Self.element(app, kAXFocusedUIElementAttribute), CFEqual(element, current),
              let currentWindow = Self.element(app, kAXFocusedWindowAttribute), CFEqual(window, currentWindow) else {
            throw InputFailure.targetChanged
        }
        let actual = try Self.read(element)
        guard actual.text == expected.text, actual.selection == expected.selection,
              service.map({ Self.isInsideServicePage(element, service: $0) }) ?? true else { throw InputFailure.targetChanged }
    }

    func submit() throws {
        try validateTarget()
        guard let pid else { throw InputFailure.expiredSession }
        for pressed in [true, false] {
            let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: 36, keyDown: pressed)
            event?.flags = []; event?.postToPid(pid)
        }
    }

    func invalidate() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; element = nil; window = nil; pid = nil; expected = nil
    }

    static func element(_ object: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = attributeValue(object, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    static func attributeValue(_ object: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(object, attribute as CFString, &value) == .success else { return nil }
        return value
    }
    static func string(_ object: AXUIElement, _ attribute: String) -> String? {
        attributeValue(object, attribute) as? String
    }
    private static func read(_ element: AXUIElement) throws -> TextSnapshot {
        guard let text = string(element, kAXValueAttribute),
              let raw = attributeValue(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else {
            throw InputFailure.unsupportedTarget
        }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { throw InputFailure.unsupportedTarget }
        return .init(text: text, selection: .init(location: range.location, length: range.length), marked: nil)
    }

    private static func isInsideServicePage(_ focused: AXUIElement, service: Service) -> Bool {
        var current: AXUIElement? = focused
        for _ in 0..<64 {
            guard let node = current else { return false }
            if string(node, kAXRoleAttribute) == "AXWebArea" {
                let raw = attributeValue(node, kAXURLAttribute)
                let url = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:))
                guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
                let domain = service == .youtube ? "youtube.com" : "netflix.com"
                return host == domain || host.hasSuffix("." + domain)
            }
            current = element(node, kAXParentAttribute)
        }
        return false
    }
}

/// Native keyboard fallback for fields that expose focus but cannot set AXValue.
/// No clipboard. Text edits affect only the remote session's own inserted buffer.
@MainActor
final class NativeKeyboardInput {
    private var pid: pid_t?
    private var focused: AXUIElement?
    private var window: AXUIElement?
    private var expected = CompositionFixture.snapshot("")
    private let source = CGEventSource(stateID: .privateState)

    func begin(application: NSRunningApplication) throws -> TextSnapshot {
        invalidate()
        guard AccessibilityInput.permitted else { throw InputFailure.permissionDenied }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        guard application.isActive else { throw InputFailure.targetChanged }
        let focused = AccessibilityInput.element(app, kAXFocusedUIElementAttribute)
        let window = AccessibilityInput.element(app, kAXFocusedWindowAttribute)
        if let focused, AccessibilityInput.string(focused, kAXSubroleAttribute) == kAXSecureTextFieldSubrole as String {
            throw InputFailure.unsupportedTarget
        }
        // Custom editors may expose no text role/value. Bind the native keyboard
        // recipient to the current app and any focus/window identity it does expose.
        self.pid = application.processIdentifier; self.focused = focused; self.window = window
        return expected
    }
    func validateTarget() throws {
        guard AccessibilityInput.permitted else { throw InputFailure.permissionDenied }
        guard let pid, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw InputFailure.targetChanged }
        let app = AXUIElementCreateApplication(pid)
        let current = AccessibilityInput.element(app, kAXFocusedUIElementAttribute)
        if let focused {
            guard let current, CFEqual(current, focused) else { throw InputFailure.targetChanged }
        }
        if let window {
            guard let currentWindow = AccessibilityInput.element(app, kAXFocusedWindowAttribute), CFEqual(currentWindow, window) else { throw InputFailure.targetChanged }
        }
        if let current, AccessibilityInput.string(current, kAXSubroleAttribute) == kAXSecureTextFieldSubrole as String {
            throw InputFailure.unsupportedTarget
        }
    }
    func deleteBackward() throws {
        try validateTarget()
        guard expected.text.isEmpty else { throw InputFailure.invalidSnapshot }
        try key(51)
    }
    func apply(_ snapshot: TextSnapshot) throws {
        try validateTarget()
        let edit = try NativeTextEdit.between(expected, snapshot)
        guard edit.deleteCount <= 1024, edit.insert.utf16.count <= 4096 else { throw InputFailure.invalidSnapshot }
        for _ in 0..<edit.deleteCount { try key(51) }
        // One grapheme per event avoids cutting surrogate pairs or emoji sequences.
        for character in edit.insert {
            let units = Array(String(character).utf16)
            for pressed in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: pressed), let pid else { throw InputFailure.writeFailed }
                event.flags = []
                units.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                }
                event.postToPid(pid)
            }
        }
        expected = snapshot
    }
    func submit() throws { try validateTarget(); try key(36) }
    private func key(_ code: CGKeyCode) throws {
        guard let pid else { throw InputFailure.expiredSession }
        for pressed in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: pressed)
            event?.flags = []; event?.postToPid(pid)
        }
    }
    func invalidate() {
        pid = nil; focused = nil; window = nil; expected = CompositionFixture.snapshot("")
    }
}

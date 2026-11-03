// Live insertion into the focused text field: append-only, verified, never deletes.

import AppKit
import ApplicationServices
import Carbon.HIToolbox

// MARK: - Target snapshot

/// The text field the user was in when recording started, captured BEFORE the
/// overlay appears. Everything inserts into this element/pid — never "whatever
/// is focused now" — so a focus change mid-dictation stops insertion instead of
/// typing into the wrong place.
struct FocusedTarget {
    let pid: pid_t
    let bundleID: String?
    let element: AXUIElement

    static func capture() -> FocusedTarget? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        enableWebAccessibility(appElement)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return FocusedTarget(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                             element: focused as! AXUIElement)
    }

    /// Chromium/Electron build their AX tree lazily; this is the documented
    /// switch for third-party assistive tech (VoiceInk does the same).
    private static func enableWebAccessibility(_ app: AXUIElement) {
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Still the same field in the same app? Checked before every insertion.
    func stillFocused() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        var focused: CFTypeRef?
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return false }
        return CFEqual(focused, element)
    }

    var selectedRange: CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    var valueLength: Int? {
        var n: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &n) == .success
        else { return nil }
        return (n as? NSNumber)?.intValue
    }

    func string(in range: CFRange) -> String? {
        var r = range
        guard let axRange = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, axRange, &out) == .success
        else { return nil }
        return out as? String
    }
}

// MARK: - Inserters

protocol LiveInserter: AnyObject {
    /// Append-only. Returns false when the target can no longer be trusted —
    /// the session then stops inserting and the rest goes to caption+clipboard.
    func append(_ text: String) -> Bool
}

enum InsertError: Error, CustomStringConvertible {
    case focusMoved, notAccepted(String), imeActive(String)
    var description: String {
        switch self {
        case .focusMoved: return "focused field changed during dictation — live insertion stopped"
        case .notAccepted(let why): return "target rejected insertion: \(why)"
        case .imeActive(let id): return "input source \(id) composes keystrokes — live typing disabled"
        }
    }
}

/// AX path: replace the (empty) selection at the caret. Bypasses keyboard
/// layout, IME and autocorrect, and can later replace our own range.
/// Many web/Electron fields return .success and do nothing, so every write is
/// VERIFIED by the length delta; a first failed write demotes the session to
/// the keystroke path (safe: nothing was inserted, so nothing duplicates).
final class AXInserter: LiveInserter {
    let target: FocusedTarget
    private(set) var insertedStart: Int?
    private(set) var insertedLength = 0
    var lastError: InsertError?

    init?(target: FocusedTarget) {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(target.element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue, target.selectedRange != nil, target.valueLength != nil else { return nil }
        self.target = target
    }

    func append(_ text: String) -> Bool {
        guard target.stillFocused() else { lastError = .focusMoved; return false }
        guard let before = target.valueLength, let caret = target.selectedRange else {
            lastError = .notAccepted("value unreadable"); return false
        }
        let status = AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, text as CFString)
        let delta = (target.valueLength ?? before) - before
        guard status == .success, delta == text.utf16.count else {
            lastError = .notAccepted("AX status \(status.rawValue), length delta \(delta) for \(text.utf16.count)")
            return false
        }
        if insertedStart == nil { insertedStart = caret.location }
        insertedLength += delta
        return true
    }

    /// Stop-time reconcile: swap our whole inserted run for the final
    /// transcript, ONLY if the run is still byte-identical to what we typed.
    func replaceInserted(expected: String, with final: String) -> Bool {
        guard let start = insertedStart, target.stillFocused(),
              target.string(in: CFRange(location: start, length: insertedLength)) == expected else { return false }
        var range = CFRange(location: start, length: insertedLength)
        guard let axRange = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success,
              AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, final as CFString) == .success
        else { return false }
        return target.string(in: CFRange(location: start, length: final.utf16.count)) == final
    }
}

/// Keystroke path: Unicode payloads on a neutral key, posted into the HID
/// stream (the target is frontmost — live mode never activates yapless) and
/// tagged so yapless's own blocking event tap lets them through. Works in
/// terminals, Electron and browsers where AX doesn't.
final class KeystrokeInserter: LiveInserter {
    /// OverlayWindow's tap returns nil for every keyDown during recording; it
    /// must pass events carrying this tag or our own typing gets swallowed.
    static let tag: Int64 = 0x7961_706c  // "yapl"
    private static let chunk = 20  // UTF-16 units per event; longer payloads get truncated by some receivers

    let target: FocusedTarget
    private let source = CGEventSource(stateID: .privateState)
    var lastError: InsertError?

    init(target: FocusedTarget) throws {
        self.target = target
        if let id = Self.composingInputSource() { throw InsertError.imeActive(id) }
    }

    /// Keyboard layouts pass Unicode events straight through; input methods
    /// (Kotoeri, Pinyin, …) may compose them.
    static func composingInputSource() -> String? {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let typePtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceType) else { return nil }
        let type = Unmanaged<CFString>.fromOpaque(typePtr).takeUnretainedValue() as String
        guard type != (kTISTypeKeyboardLayout as String) else { return nil }
        let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID)
        return idPtr.map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? type
    }

    func append(_ text: String) -> Bool {
        guard target.stillFocused() else { lastError = .focusMoved; return false }
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            var end = min(i + Self.chunk, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            let slice = Array(units[i..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { lastError = .notAccepted("could not create key event"); return false }
            for e in [down, up] {
                e.flags = []
                e.setIntegerValueField(.eventSourceUserData, value: Self.tag)
                slice.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            i = end
        }
        return true
    }
}

// MARK: - Session

/// Owns one dictation's live insertion: picks the inserter, appends only
/// LocalAgreement-committed words, and reconciles with the final transcript.
final class LiveInsertionSession {
    private let target: FocusedTarget
    private var inserter: LiveInserter?
    private(set) var inserted: [String] = []
    private(set) var stopReason: String?
    private let queue = DispatchQueue(label: "yapless.live-insert")
    /// Whether the caret sits right after a non-space character, so the first
    /// word needs a separating space. Read once, before anything is typed.
    private let needsLeadingSpace: Bool

    /// "AX" / "keys" — shown on the overlay so a downgrade is never silent.
    var label: String { queue.sync { inserter is AXInserter ? "AX" : inserter == nil ? "off" : "keys" } }

    init?(target: FocusedTarget) {
        self.target = target
        if let caret = target.selectedRange, caret.location > 0,
           let before = target.string(in: CFRange(location: caret.location - 1, length: 1)) {
            needsLeadingSpace = !(before.last?.isWhitespace ?? true)
        } else {
            needsLeadingSpace = false
        }
        if let ax = AXInserter(target: target) {
            inserter = ax
        } else {
            do { inserter = try KeystrokeInserter(target: target) } catch {
                print("live insertion off: \(error)")
                return nil
            }
        }
    }

    /// Called with the words LiveCaptioner just committed (append-only).
    func commit(_ words: [String]) {
        queue.async { [self] in
            guard let inserter, !words.isEmpty else { return }
            let text = (inserted.isEmpty ? (needsLeadingSpace ? " " : "") : " ") + words.joined(separator: " ")
            if inserter.append(text) {
                inserted += words
                return
            }
            if let ax = inserter as? AXInserter, ax.insertedStart == nil,
               let typer = try? KeystrokeInserter(target: target), typer.append(text) {
                print("AX insertion not accepted (\(ax.lastError.map { "\($0)" } ?? "?")) — switched to keystrokes")
                self.inserter = typer
                inserted += words
                return
            }
            stopReason = (inserter as? AXInserter)?.lastError?.description
                ?? (inserter as? KeystrokeInserter)?.lastError?.description ?? "insert failed"
            print("live insertion stopped: \(stopReason!)")
            self.inserter = nil
        }
    }

    /// Stop-time: make the field end with the final transcript.
    /// AX targets whose run is intact get an exact swap; everyone else gets
    /// the words after the last committed anchor appended.
    func finish(final: String, completion: @escaping (_ handled: Bool) -> Void) {
        queue.async { [self] in
            defer { inserter = nil }
            guard let inserter, !inserted.isEmpty else { return completion(false) }
            let lead = needsLeadingSpace ? " " : ""
            if let ax = inserter as? AXInserter,
               ax.replaceInserted(expected: lead + inserted.joined(separator: " "), with: lead + final) {
                print("live: swapped inserted run for the final transcript")
                return completion(true)
            }
            let finalWords = final.split(separator: " ").map(String.init)
            let rest = finalWords[Self.resumeIndex(committed: inserted, final: finalWords)...]
            completion(rest.isEmpty || inserter.append(" " + rest.joined(separator: " ")))
        }
    }

    /// Index in `final` right after the rightmost match of the committed tail.
    static func resumeIndex(committed: [String], final: [String]) -> Int {
        func n(_ w: String) -> String { w.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let f = final.map(n)
        for k in stride(from: min(8, committed.count), through: 1, by: -1) {
            let tail = committed.suffix(k).map(n)
            for i in stride(from: f.count - k, through: 0, by: -1) where Array(f[i..<(i + k)]) == tail {
                return i + k
            }
        }
        return 0
    }
}

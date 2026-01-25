import AppKit
import Carbon.HIToolbox
import UserNotifications

/// Handles output of transcribed text (clipboard, paste, notifications)
final class OutputHandler {
    private let config: OutputConfig

    init(config: OutputConfig) {
        self.config = config
    }

    /// Handle the transcribed text according to config
    /// - Parameters:
    ///   - text: The transcribed text
    ///   - pressEnter: Whether to press Enter after pasting (to send in chat apps)
    ///   - completion: Called when done
    func handle(text: String, pressEnter: Bool = false, completion: @escaping () -> Void) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedText.isEmpty else {
            completion()
            return
        }

        // Copy to clipboard
        if config.copyToClipboard {
            copyToClipboard(trimmedText)
        }

        // Paste to active app
        if config.pasteToActiveApp {
            pasteToActiveApp(trimmedText, pressEnter: pressEnter) {
                if self.config.playCompletionSound {
                    self.playCompletionSound()
                }
                completion()
            }
        } else {
            if config.playCompletionSound {
                playCompletionSound()
            }
            completion()
        }

        // Show notification if enabled
        if config.showNotification {
            showNotification(text: trimmedText)
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        print("Copied to clipboard: \(text.prefix(50))...")
    }

    private func pasteToActiveApp(_ text: String, pressEnter: Bool, completion: @escaping () -> Void) {
        // Small delay to ensure clipboard is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.simulatePaste()

            if pressEnter {
                // Longer delay after paste to ensure Cmd key is released
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.simulateEnter()
                    completion()
                }
            } else {
                completion()
            }
        }
    }

    private func simulatePaste() {
        // Simulate Cmd+V using CGEvent
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down for Cmd+V
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        // Key up for Cmd+V
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)

        print("Simulated paste")
    }

    private func simulateEnter() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down for Enter - explicitly clear all modifiers
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: true)
        keyDown?.flags = []  // No modifiers
        keyDown?.post(tap: .cghidEventTap)

        // Key up for Enter
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: false)
        keyUp?.flags = []  // No modifiers
        keyUp?.post(tap: .cghidEventTap)

        print("Simulated enter")
    }

    private func playCompletionSound() {
        NSSound(named: "Tink")?.play()
    }

    private func showNotification(text: String) {
        let content = UNMutableNotificationContent()
        content.title = "Voice to Text"
        content.body = String(text.prefix(100))

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}

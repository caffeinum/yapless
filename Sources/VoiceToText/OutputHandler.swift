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
    func handle(text: String, completion: @escaping () -> Void) {
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
            pasteToActiveApp(trimmedText) {
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

    private func pasteToActiveApp(_ text: String, completion: @escaping () -> Void) {
        // Small delay to ensure clipboard is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.simulatePaste()
            completion()
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

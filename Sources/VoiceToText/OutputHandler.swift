import AppKit
import ApplicationServices
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

        // Paste first, then hand off to the sink: typing should feel instant,
        // and only the exit waits on the command.
        let finish = { [weak self] (pasteSucceeded: Bool) in
            guard let self = self else { completion(); return }
            if self.config.playCompletionSound {
                self.play(pasteSucceeded ? self.config.completionSound : self.config.pasteFailedSound,
                          label: pasteSucceeded ? "completionSound" : "pasteFailedSound")
            }
            self.runOutputCommand(with: trimmedText, completion: completion)
        }

        if config.pasteToActiveApp {
            pasteToActiveApp(trimmedText, pressEnter: pressEnter, completion: finish)
        } else {
            // Nothing was attempted, so nothing failed — clipboard-only runs
            // get the ordinary completion sound.
            finish(true)
        }

        // Show notification if enabled
        if config.showNotification {
            showNotification(text: trimmedText)
        }
    }

    /// Hand the transcript to `output.command` on stdin.
    ///
    /// stdin, never argv or env: dictation contains quotes and newlines, and
    /// anything in argv is visible to every process listing on the machine.
    /// yapless exits right after this, so it waits — a sink that spawns and
    /// forgets would be killed mid-flight.
    private func runOutputCommand(with text: String, completion: @escaping () -> Void) {
        guard let commandLine = config.command?.trimmingCharacters(in: .whitespaces),
              !commandLine.isEmpty else {
            completion()
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", commandLine]

            var environment = ProcessInfo.processInfo.environment
            environment["YAPLESS_TRANSCRIPT_LENGTH"] = String(text.count)
            process.environment = environment

            let stdin = Pipe()
            let stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stdout

            do {
                try process.run()
            } catch {
                print("output command failed to start: \(error.localizedDescription)")
                DispatchQueue.main.async { completion() }
                return
            }

            stdin.fileHandleForWriting.write(Data(text.utf8))
            stdin.fileHandleForWriting.closeFile()

            // Read concurrently: a chatty command that fills the pipe buffer
            // would otherwise block forever and burn the whole timeout.
            var output = Data()
            let reader = DispatchQueue(label: "yapless.output-command.read")
            reader.async { output = stdout.fileHandleForReading.readDataToEndOfFile() }

            let deadline = Date().addingTimeInterval(self.config.commandTimeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }

            if process.isRunning {
                process.terminate()
                print("output command timed out after \(self.config.commandTimeout)s — killed")
            } else if process.terminationStatus != 0 {
                reader.sync {}
                let message = String(data: output, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                print("output command exited \(process.terminationStatus): \(message)")
            }

            DispatchQueue.main.async { completion() }
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        print("Copied to clipboard: \(text.prefix(50))...")
    }

    private func pasteToActiveApp(_ text: String, pressEnter: Bool, completion: @escaping (Bool) -> Void) {
        // Small delay to ensure clipboard is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let sent = self.simulatePaste()

            guard sent else {
                print("Paste not sent — text is on the clipboard, press ⌘V")
                completion(false)
                return
            }

            if pressEnter {
                // Longer delay after paste to ensure Cmd key is released
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.simulateEnter()
                    completion(true)
                }
            } else {
                completion(true)
            }
        }
    }

    /// Returns whether the keystroke could be SENT — not whether the target
    /// app accepted it. Nothing reports that back, so this detects the failure
    /// that actually happens: without Accessibility permission, posting a
    /// CGEvent silently does nothing and the text just sits on the clipboard.
    @discardableResult
    private func simulatePaste() -> Bool {
        guard AXIsProcessTrusted() else {
            print("Paste blocked: Accessibility permission not granted for this binary")
            return false
        }

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            print("Paste blocked: could not create the key event")
            return false
        }

        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.flags = .maskCommand
        keyUp.post(tap: .cghidEventTap)

        print("Simulated paste")
        return true
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

    private func play(_ name: String?, label: String) {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        let sound = name.hasPrefix("/") ? NSSound(contentsOfFile: name, byReference: true)
                                        : NSSound(named: name)
        if sound == nil { print("WARNING: \(label) '\(name)' not found") }
        sound?.play()
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

import AppKit
import Carbon.HIToolbox

/// Transparent overlay window for displaying animations
final class OverlayWindow: NSWindow {
    private let animationConfig: AnimationConfig
    private var animationView: AnimationView?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Called when user clicks or presses enter/space to stop recording
    /// Bool indicates whether to press Enter after pasting (true if Enter was pressed)
    var onStopRequested: ((Bool) -> Void)?

    init(config: AnimationConfig) {
        self.animationConfig = config

        // Calculate window frame based on animation style and position
        let frame = Self.calculateFrame(for: config)

        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        setupWindow()
        setupAnimationView()
    }

    private static func calculateFrame(for config: AnimationConfig) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 0, y: 0, width: 200, height: 200)
        }

        // Glow style needs fullscreen
        if config.style == .glow {
            return screen.frame
        }

        // Siri style - full width, fixed height at bottom
        if config.style == .siri {
            let height: CGFloat = 200
            return NSRect(
                x: screen.frame.minX,
                y: screen.visibleFrame.minY,
                width: screen.frame.width,
                height: height
            )
        }

        let screenFrame = screen.visibleFrame
        let size = CGFloat(config.size)

        switch config.position {
        case .center:
            let x = screenFrame.midX - size / 2
            let y = screenFrame.midY - size / 2
            return NSRect(x: x, y: y, width: size, height: size)

        case .topCenter:
            let x = screenFrame.midX - size / 2
            let y = screenFrame.maxY - size - 50
            return NSRect(x: x, y: y, width: size, height: size)

        case .bottomCenter:
            let x = screenFrame.midX - size / 2
            let y = screenFrame.minY + 50
            return NSRect(x: x, y: y, width: size, height: size)

        case .cursor:
            let mouseLocation = NSEvent.mouseLocation
            return NSRect(
                x: mouseLocation.x - size / 2,
                y: mouseLocation.y - size / 2,
                width: size,
                height: size
            )
        }
    }

    private func setupWindow() {
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        ignoresMouseEvents = false
        hasShadow = false
        isReleasedWhenClosed = false

        // Make window accept key events
        makeKeyAndOrderFront(nil)

        setupInputMonitors()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onStopRequested?(false)  // click = just paste
    }

    override func keyDown(with event: NSEvent) {
        // enter (36) or space (49) or escape (53)
        if event.keyCode == 36 {
            onStopRequested?(true)  // enter = paste + send
        } else if event.keyCode == 49 || event.keyCode == 53 {
            onStopRequested?(false)  // space/escape = just paste
        } else {
            super.keyDown(with: event)
        }
    }

    private func setupInputMonitors() {
        // Use CGEvent tap to intercept AND block keyboard events
        setupEventTap()

        // Global click monitor (requires accessibility)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.onStopRequested?(false)
        }

        // Local monitors as fallback
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 36 {
                self?.onStopRequested?(true)  // enter = paste + send
                return nil
            } else if event.keyCode == 49 || event.keyCode == 53 {
                self?.onStopRequested?(false)  // space/escape = just paste
                return nil
            }
            return event
        }

        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.onStopRequested?(false)
            return event
        }
    }

    private func setupEventTap() {
        // Store self pointer for callback
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Create event tap to intercept keyboard events
        let eventMask = (1 << CGEventType.keyDown.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }

                let window = Unmanaged<OverlayWindow>.fromOpaque(refcon).takeUnretainedValue()
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

                // Enter (36) - stop and send
                if keyCode == 36 {
                    DispatchQueue.main.async {
                        window.onStopRequested?(true)
                    }
                    return nil
                }

                // Space (49), Escape (53) - stop without send
                if keyCode == 49 || keyCode == 53 {
                    DispatchQueue.main.async {
                        window.onStopRequested?(false)
                    }
                    return nil
                }

                // Block all other key events during recording too
                return nil
            },
            userInfo: refcon
        )

        guard let eventTap = eventTap else {
            print("Failed to create event tap - accessibility permission may be needed")
            return
        }

        // Add to run loop
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    private func removeInputMonitors() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }

        // Clean up event tap
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
    }

    deinit {
        removeInputMonitors()
    }

    private func setupAnimationView() {
        let animationView: AnimationView

        switch animationConfig.style {
        case .orb:
            animationView = NewOrbAnimationView(config: animationConfig)
        case .waveform:
            animationView = NewWaveformAnimationView(config: animationConfig)
        case .glow:
            animationView = NewGlowAnimationView(config: animationConfig)
        case .siri:
            animationView = NewSiriAnimationView(config: animationConfig)
        case .cursor:
            animationView = NewOrbAnimationView(config: animationConfig)  // Orb follows cursor
        }

        animationView.frame = contentView?.bounds ?? .zero
        animationView.autoresizingMask = [.width, .height]
        contentView?.addSubview(animationView)

        self.animationView = animationView
    }

    func updateAudioLevel(_ level: Float) {
        animationView?.updateAudioLevel(level)
    }

    func updateSpectrum(_ bands: [Float]) {
        animationView?.updateSpectrum(bands)
    }

    func showRecordingState() {
        makeKeyAndOrderFront(nil)
        makeFirstResponder(self)
        animationView?.startRecordingAnimation()
    }

    func showProcessingState() {
        animationView?.startProcessingAnimation()
    }

    func showCompletionState() {
        animationView?.showCompletionAnimation()
        releaseKeyboard()  // Allow keystrokes again before paste
    }

    /// Release keyboard control to allow keystrokes to pass through
    func releaseKeyboard() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
    }

    func animateCompletion(completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15  // faster fade out
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
        }, completionHandler: completion)
    }

    /// Update window position to follow cursor
    func updateCursorPosition() {
        guard animationConfig.position == .cursor else { return }

        let mouseLocation = NSEvent.mouseLocation
        let size = frame.size
        let newOrigin = NSPoint(
            x: mouseLocation.x - size.width / 2,
            y: mouseLocation.y - size.height / 2
        )
        setFrameOrigin(newOrigin)
    }
}

// MARK: - Animation View Protocol

protocol AnimationView: NSView {
    var config: AnimationConfig { get }
    func updateAudioLevel(_ level: Float)
    func updateSpectrum(_ bands: [Float])
    func startRecordingAnimation()
    func startProcessingAnimation()
    func showCompletionAnimation()
}

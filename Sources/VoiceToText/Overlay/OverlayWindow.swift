import AppKit

/// Transparent overlay window for displaying animations
final class OverlayWindow: NSWindow {
    private let animationConfig: AnimationConfig
    private var animationView: AnimationView?
    private var keyMonitor: Any?
    private var clickMonitor: Any?

    /// Called when user clicks or presses enter/space to stop recording
    var onStopRequested: (() -> Void)?

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
        onStopRequested?()
    }

    override func keyDown(with event: NSEvent) {
        // enter (36) or space (49) or escape (53)
        if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 53 {
            onStopRequested?()
        } else {
            super.keyDown(with: event)
        }
    }

    private func setupInputMonitors() {
        // Global key monitor for enter/space (requires accessibility)
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 53 {
                self?.onStopRequested?()
            }
        }

        // Global click monitor (requires accessibility)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.onStopRequested?()
        }

        // Local monitors work without accessibility
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 53 {
                self?.onStopRequested?()
                return nil
            }
            return event
        }

        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.onStopRequested?()
            return event
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
    }

    func animateCompletion(completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
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

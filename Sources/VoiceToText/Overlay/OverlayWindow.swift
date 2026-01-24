import AppKit

/// Transparent overlay window for displaying animations
final class OverlayWindow: NSWindow {
    private let animationConfig: AnimationConfig
    private var animationView: AnimationView?

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
        ignoresMouseEvents = true
        hasShadow = false

        // Ensure window appears on all spaces
        isReleasedWhenClosed = false
    }

    private func setupAnimationView() {
        let animationView: AnimationView

        switch animationConfig.style {
        case .orb:
            animationView = OrbAnimationView(config: animationConfig)
        case .waveform:
            animationView = WaveformAnimationView(config: animationConfig)
        case .glow:
            animationView = GlowAnimationView(config: animationConfig)
        case .cursor:
            animationView = OrbAnimationView(config: animationConfig)  // Fallback to orb for now
        }

        animationView.frame = contentView?.bounds ?? .zero
        animationView.autoresizingMask = [.width, .height]
        contentView?.addSubview(animationView)

        self.animationView = animationView
    }

    func updateAudioLevel(_ level: Float) {
        animationView?.updateAudioLevel(level)
    }

    func showRecordingState() {
        orderFront(nil)
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
    func startRecordingAnimation()
    func startProcessingAnimation()
    func showCompletionAnimation()
}

import AppKit
import QuartzCore

/// Screen edge glow effect (Dynamic Island style)
final class GlowAnimationView: NSView, AnimationView {
    let config: AnimationConfig

    private var glowLayers: [CAGradientLayer] = []
    private var stopButton: NSView?
    private var currentAudioLevel: Float = 0

    init(config: AnimationConfig) {
        self.config = config
        super.init(frame: .zero)
        wantsLayer = true
        setupLayers()
        setupStopButton()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupLayers() {
        // Create glow layers for each edge
        let edges: [(CGPoint, CGPoint, CGPoint, CGPoint)] = [
            // Top edge
            (CGPoint(x: 0, y: 1), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)),
            // Bottom edge
            (CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)),
            // Left edge
            (CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 1)),
            // Right edge
            (CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1))
        ]

        for (startPoint, endPoint, _, _) in edges {
            let glowLayer = CAGradientLayer()
            glowLayer.colors = [
                NSColor(hex: config.primaryColor)?.withAlphaComponent(0.8).cgColor ?? NSColor.systemBlue.withAlphaComponent(0.8).cgColor,
                NSColor(hex: config.secondaryColor)?.withAlphaComponent(0.4).cgColor ?? NSColor.systemPurple.withAlphaComponent(0.4).cgColor,
                NSColor.clear.cgColor
            ]
            glowLayer.locations = [0, 0.3, 1]
            glowLayer.startPoint = startPoint
            glowLayer.endPoint = endPoint
            glowLayer.opacity = 0

            layer?.addSublayer(glowLayer)
            glowLayers.append(glowLayer)
        }
    }

    private func setupStopButton() {
        let buttonSize: CGFloat = 60
        let button = NSView(frame: NSRect(x: 0, y: 0, width: buttonSize, height: buttonSize))
        button.wantsLayer = true
        button.layer?.cornerRadius = buttonSize / 2
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        button.layer?.borderColor = NSColor(hex: config.primaryColor)?.cgColor ?? NSColor.systemBlue.cgColor
        button.layer?.borderWidth = 2

        // Stop icon (square)
        let stopIcon = NSView(frame: NSRect(x: 18, y: 18, width: 24, height: 24))
        stopIcon.wantsLayer = true
        stopIcon.layer?.cornerRadius = 4
        stopIcon.layer?.backgroundColor = NSColor.white.cgColor
        button.addSubview(stopIcon)

        addSubview(button)
        self.stopButton = button
    }

    override func layout() {
        super.layout()
        updateLayerFrames()

        // Center the stop button
        if let button = stopButton {
            let x = (bounds.width - button.frame.width) / 2
            let y = (bounds.height - button.frame.height) / 2
            button.frame.origin = NSPoint(x: x, y: y)
        }
    }

    private func updateLayerFrames() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let glowThickness: CGFloat = 80

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Top
        if glowLayers.count > 0 {
            glowLayers[0].frame = CGRect(
                x: 0,
                y: screenFrame.height - glowThickness,
                width: screenFrame.width,
                height: glowThickness
            )
        }

        // Bottom
        if glowLayers.count > 1 {
            glowLayers[1].frame = CGRect(
                x: 0,
                y: 0,
                width: screenFrame.width,
                height: glowThickness
            )
        }

        // Left
        if glowLayers.count > 2 {
            glowLayers[2].frame = CGRect(
                x: 0,
                y: 0,
                width: glowThickness,
                height: screenFrame.height
            )
        }

        // Right
        if glowLayers.count > 3 {
            glowLayers[3].frame = CGRect(
                x: screenFrame.width - glowThickness,
                y: 0,
                width: glowThickness,
                height: screenFrame.height
            )
        }

        CATransaction.commit()
    }

    func updateAudioLevel(_ level: Float) {
        currentAudioLevel = level

        let baseOpacity = Float(0.3)
        let dynamicOpacity = level * 0.7

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)

        for glowLayer in glowLayers {
            glowLayer.opacity = baseOpacity + dynamicOpacity
        }

        CATransaction.commit()
    }

    func startRecordingAnimation() {
        // Fade in all edges with staggered timing
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)

        for glowLayer in glowLayers {
            glowLayer.opacity = 0.4
        }

        CATransaction.commit()
    }

    func startProcessingAnimation() {
        // Rotating highlight effect
        for (index, glowLayer) in glowLayers.enumerated() {
            glowLayer.removeAllAnimations()

            let flash = CABasicAnimation(keyPath: "opacity")
            flash.fromValue = 0.2
            flash.toValue = 0.8
            flash.duration = 0.5
            flash.beginTime = CACurrentMediaTime() + Double(index) * 0.125
            flash.autoreverses = true
            flash.repeatCount = .infinity
            glowLayer.add(flash, forKey: "processing")
        }
    }

    func showCompletionAnimation() {
        for glowLayer in glowLayers {
            glowLayer.removeAllAnimations()

            // Flash green
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            glowLayer.colors = [
                NSColor.systemGreen.withAlphaComponent(0.8).cgColor,
                NSColor.systemGreen.withAlphaComponent(0.4).cgColor,
                NSColor.clear.cgColor
            ]
            glowLayer.opacity = 1.0
            CATransaction.commit()

            // Fade out
            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = 1.0
            fadeOut.toValue = 0.0
            fadeOut.duration = 0.3
            fadeOut.beginTime = CACurrentMediaTime() + 0.15
            fadeOut.fillMode = .forwards
            fadeOut.isRemovedOnCompletion = false
            glowLayer.add(fadeOut, forKey: "completion")
        }
    }
}

import AppKit
import QuartzCore

/// Screen edge glow effect (Dynamic Island style)
final class GlowAnimationView: NSView, AnimationView {
    let config: AnimationConfig

    private var glowLayers: [CAGradientLayer] = []
    private var currentAudioLevel: Float = 0

    init(config: AnimationConfig) {
        self.config = config
        super.init(frame: .zero)
        wantsLayer = true
        setupLayers()
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

    override func layout() {
        super.layout()
        updateLayerFrames()
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
        // Fade in all edges
        for (index, glowLayer) in glowLayers.enumerated() {
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 0.5
            fadeIn.duration = 0.3
            fadeIn.beginTime = CACurrentMediaTime() + Double(index) * 0.1
            fadeIn.fillMode = .forwards
            fadeIn.isRemovedOnCompletion = false
            glowLayer.add(fadeIn, forKey: "fadeIn")

            // Pulsing animation
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.3
            pulse.toValue = 0.6
            pulse.duration = 1.0
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.beginTime = CACurrentMediaTime() + 0.3
            glowLayer.add(pulse, forKey: "pulse")
        }
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

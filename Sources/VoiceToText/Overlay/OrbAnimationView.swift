import AppKit
import QuartzCore

/// Breathing orb animation that responds to audio levels
final class OrbAnimationView: NSView, AnimationView {
    let config: AnimationConfig

    private var orbLayer: CAGradientLayer!
    private var pulseLayer: CAShapeLayer!
    private var currentAudioLevel: Float = 0
    private var displayLink: CVDisplayLink?

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
        // Background pulse layer
        pulseLayer = CAShapeLayer()
        pulseLayer.fillColor = NSColor(hex: config.primaryColor)?.withAlphaComponent(0.3).cgColor
        layer?.addSublayer(pulseLayer)

        // Main orb gradient layer
        orbLayer = CAGradientLayer()
        orbLayer.type = .radial
        orbLayer.colors = [
            NSColor(hex: config.primaryColor)?.cgColor ?? NSColor.systemBlue.cgColor,
            NSColor(hex: config.secondaryColor)?.cgColor ?? NSColor.systemPurple.cgColor,
            NSColor.clear.cgColor
        ]
        orbLayer.locations = [0, 0.5, 1]
        orbLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        orbLayer.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(orbLayer)
    }

    override func layout() {
        super.layout()
        updateLayerFrames()
    }

    private func updateLayerFrames() {
        let size = min(bounds.width, bounds.height)
        let orbSize = size * 0.6
        let orbFrame = NSRect(
            x: (bounds.width - orbSize) / 2,
            y: (bounds.height - orbSize) / 2,
            width: orbSize,
            height: orbSize
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        orbLayer.frame = orbFrame
        orbLayer.cornerRadius = orbSize / 2
        pulseLayer.frame = bounds
        updatePulsePath(scale: 1.0)
        CATransaction.commit()
    }

    private func updatePulsePath(scale: CGFloat) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let baseRadius = min(bounds.width, bounds.height) * 0.3
        let radius = baseRadius * scale

        pulseLayer.path = CGPath(
            ellipseIn: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ),
            transform: nil
        )
    }

    func updateAudioLevel(_ level: Float) {
        currentAudioLevel = level

        // Animate orb scale based on audio level
        let scale = 1.0 + CGFloat(level) * 0.3

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)

        orbLayer.transform = CATransform3DMakeScale(scale, scale, 1)

        // Update pulse layer opacity based on level
        pulseLayer.opacity = Float(0.3 + level * 0.5)
        updatePulsePath(scale: scale * 1.2)

        CATransaction.commit()
    }

    func startRecordingAnimation() {
        // Breathing animation
        let breathingAnimation = CABasicAnimation(keyPath: "transform.scale")
        breathingAnimation.fromValue = 0.95
        breathingAnimation.toValue = 1.05
        breathingAnimation.duration = 1.0
        breathingAnimation.autoreverses = true
        breathingAnimation.repeatCount = .infinity
        breathingAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        orbLayer.add(breathingAnimation, forKey: "breathing")

        // Pulse ring animation
        let pulseAnimation = CABasicAnimation(keyPath: "opacity")
        pulseAnimation.fromValue = 0.5
        pulseAnimation.toValue = 0.1
        pulseAnimation.duration = 1.5
        pulseAnimation.autoreverses = true
        pulseAnimation.repeatCount = .infinity
        pulseLayer.add(pulseAnimation, forKey: "pulse")

        // Fade in
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = 0.3
        layer?.add(fadeIn, forKey: "fadeIn")
    }

    func startProcessingAnimation() {
        orbLayer.removeAllAnimations()
        pulseLayer.removeAllAnimations()

        // Rotation animation for processing
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = 1.5
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        orbLayer.add(rotation, forKey: "rotation")

        // Pulsing scale
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.8
        scale.toValue = 1.0
        scale.duration = 0.5
        scale.autoreverses = true
        scale.repeatCount = .infinity
        orbLayer.add(scale, forKey: "processingScale")
    }

    func showCompletionAnimation() {
        orbLayer.removeAllAnimations()
        pulseLayer.removeAllAnimations()

        // Success pulse
        let scaleUp = CABasicAnimation(keyPath: "transform.scale")
        scaleUp.fromValue = 1.0
        scaleUp.toValue = 1.3
        scaleUp.duration = 0.15
        scaleUp.autoreverses = true
        orbLayer.add(scaleUp, forKey: "completionPulse")

        // Change color to green briefly
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        orbLayer.colors = [
            NSColor.systemGreen.cgColor,
            NSColor.systemGreen.withAlphaComponent(0.5).cgColor,
            NSColor.clear.cgColor
        ]
        CATransaction.commit()
    }
}

// MARK: - NSColor Hex Extension

extension NSColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}

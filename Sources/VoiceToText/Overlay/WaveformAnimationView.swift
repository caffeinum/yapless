import AppKit
import QuartzCore

/// Real-time audio waveform visualization
final class WaveformAnimationView: NSView, AnimationView {
    let config: AnimationConfig

    private var waveformLayer: CAShapeLayer!
    private var backgroundLayer: CAGradientLayer!
    private var audioLevels: [Float] = Array(repeating: 0, count: 32)
    private var currentIndex = 0
    private var animationTimer: Timer?

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
        // Background gradient
        backgroundLayer = CAGradientLayer()
        backgroundLayer.colors = [
            NSColor.black.withAlphaComponent(0.7).cgColor,
            NSColor.black.withAlphaComponent(0.5).cgColor
        ]
        backgroundLayer.cornerRadius = 20
        layer?.addSublayer(backgroundLayer)

        // Waveform shape layer
        waveformLayer = CAShapeLayer()
        waveformLayer.strokeColor = NSColor(hex: config.primaryColor)?.cgColor ?? NSColor.systemBlue.cgColor
        waveformLayer.fillColor = NSColor(hex: config.primaryColor)?.withAlphaComponent(0.3).cgColor
        waveformLayer.lineWidth = 2
        waveformLayer.lineCap = .round
        waveformLayer.lineJoin = .round
        layer?.addSublayer(waveformLayer)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        waveformLayer.frame = bounds
        updateWaveformPath()
        CATransaction.commit()
    }

    private func updateWaveformPath() {
        let path = CGMutablePath()
        let width = bounds.width
        let height = bounds.height
        let midY = height / 2
        let barCount = audioLevels.count
        let barWidth = width / CGFloat(barCount)
        let maxBarHeight = height * 0.7

        // Start at bottom left
        path.move(to: CGPoint(x: 0, y: midY))

        // Draw waveform bars
        for (index, level) in audioLevels.enumerated() {
            let x = CGFloat(index) * barWidth + barWidth / 2
            let barHeight = CGFloat(level) * maxBarHeight

            // Top point
            path.addLine(to: CGPoint(x: x, y: midY + barHeight / 2))
        }

        // Complete the path back
        for (index, level) in audioLevels.enumerated().reversed() {
            let x = CGFloat(index) * barWidth + barWidth / 2
            let barHeight = CGFloat(level) * maxBarHeight

            // Bottom point
            path.addLine(to: CGPoint(x: x, y: midY - barHeight / 2))
        }

        path.closeSubpath()

        waveformLayer.path = path
    }

    func updateAudioLevel(_ level: Float) {
        // Shift levels and add new one
        audioLevels[currentIndex] = level
        currentIndex = (currentIndex + 1) % audioLevels.count

        // Smooth animation
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.05)
        updateWaveformPath()
        CATransaction.commit()
    }

    func startRecordingAnimation() {
        // Fade in
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = 0.3
        layer?.add(fadeIn, forKey: "fadeIn")

        // Subtle glow animation
        let glow = CABasicAnimation(keyPath: "shadowOpacity")
        glow.fromValue = 0.3
        glow.toValue = 0.8
        glow.duration = 1.0
        glow.autoreverses = true
        glow.repeatCount = .infinity
        waveformLayer.add(glow, forKey: "glow")
    }

    func startProcessingAnimation() {
        // Morphing dots animation
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.5
        animation.toValue = 1.0
        animation.duration = 0.5
        animation.autoreverses = true
        animation.repeatCount = .infinity
        waveformLayer.add(animation, forKey: "processing")

        // Create simple dots pattern
        audioLevels = audioLevels.enumerated().map { index, _ in
            sin(Float(index) * 0.3) * 0.3 + 0.3
        }
        updateWaveformPath()
    }

    func showCompletionAnimation() {
        waveformLayer.removeAllAnimations()

        // Flash green
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        waveformLayer.strokeColor = NSColor.systemGreen.cgColor
        waveformLayer.fillColor = NSColor.systemGreen.withAlphaComponent(0.3).cgColor
        CATransaction.commit()

        // Expand and fade
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.2
        scale.duration = 0.2
        waveformLayer.add(scale, forKey: "completionScale")
    }
}

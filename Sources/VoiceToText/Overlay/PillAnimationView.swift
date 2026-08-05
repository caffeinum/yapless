import SwiftUI
import AppKit

// MARK: - Pill Animation (floating capsule with a mirrored equalizer)

/// Shared geometry so the window and the view agree on where the capsule sits.
/// The window is deliberately larger than the capsule — the drop shadow needs
/// room inside the window or it gets clipped into hard rectangular corners.
enum PillMetrics {
    /// Shadow room on each side, as a fraction of capsule height.
    static let marginRatio: CGFloat = 0.62

    static func capsuleSize(base: CGFloat) -> CGSize {
        let height = min(40, max(24, base * 0.24))
        return CGSize(width: height * 3.9, height: height)
    }

    static func windowSize(base: CGFloat) -> CGSize {
        let capsule = capsuleSize(base: base)
        let margin = capsule.height * marginRatio
        return CGSize(
            width: capsule.width + margin * 2,
            height: capsule.height + margin * 2
        )
    }

    /// Inverse of `windowSize` — recovers the capsule height from the window.
    static func capsuleHeight(inWindowHeight height: CGFloat) -> CGFloat {
        height / (1 + marginRatio * 2)
    }
}

final class NewPillAnimationView: NSView, AnimationView {
    let config: AnimationConfig
    private let hostingView: NSHostingView<PillAnimationContent>
    private let model = AnimationModel()

    init(config: AnimationConfig) {
        self.config = config
        self.hostingView = NSHostingView(rootView: PillAnimationContent(model: model, config: config))

        super.init(frame: .zero)

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateAudioLevel(_ level: Float) {
        model.updateAudioLevel(CGFloat(level))
    }

    func updateSpectrum(_ bands: [Float]) {
        model.updateSpectrum(bands)
    }

    func startRecordingAnimation() {
        model.state = .recording
    }

    func startProcessingAnimation() {
        model.state = .processing
    }

    func showCompletionAnimation() {
        model.state = .complete
    }

    func showErrorAnimation() {
        model.state = .error
    }
}

struct PillAnimationContent: View {
    @ObservedObject var model: AnimationModel
    let config: AnimationConfig

    var body: some View {
        TimelineView(.animation) { timeline in
            PillFrame(
                time: timeline.date.timeIntervalSinceReferenceDate,
                spectrum: model.smoothedSpectrum,
                level: model.smoothedLevel,
                state: model.state,
                config: config
            )
        }
    }
}

struct PillFrame: View {
    let time: Double
    let spectrum: [CGFloat]
    let level: CGFloat
    let state: AnimationState
    let config: AnimationConfig

    private var primary: Color {
        Color(nsColor: NSColor(hex: config.primaryColor) ?? .systemBlue)
    }
    private var secondary: Color {
        Color(nsColor: NSColor(hex: config.secondaryColor) ?? .systemPurple)
    }

    /// Center bar color per state; edges fade toward `edgeColor`.
    private var coreColor: Color {
        switch state {
        case .recording: return primary
        case .processing: return Color(red: 0.15, green: 0.55, blue: 1.0)
        case .complete: return Color(red: 0.16, green: 0.78, blue: 0.36)
        case .error: return Color(red: 0.95, green: 0.25, blue: 0.25)
        }
    }

    private var edgeColor: Color {
        switch state {
        case .recording: return secondary
        case .processing: return Color(red: 0.45, green: 0.75, blue: 1.0)
        case .complete: return Color(red: 0.45, green: 0.86, blue: 0.55)
        case .error: return Color(red: 1.0, green: 0.55, blue: 0.45)
        }
    }

    var body: some View {
        GeometryReader { geo in
            // Capsule is inset by the shadow margin; bar insets scale with the
            // capsule so proportions hold at any size.
            let capsuleHeight = PillMetrics.capsuleHeight(inWindowHeight: geo.size.height)

            ZStack {
                PillShell(state: state, height: capsuleHeight)

                Canvas { context, size in
                    drawBars(context: context, size: size)
                }
                .padding(.horizontal, capsuleHeight * 0.3)
                .padding(.vertical, capsuleHeight * 0.22)
            }
            .padding(capsuleHeight * PillMetrics.marginRatio)
        }
        .opacity(config.opacity)
    }

    private let barCount = 29

    private func drawBars(context: GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        let gapRatio: CGFloat = 0.85  // gap = barWidth * gapRatio
        let barWidth = size.width / (CGFloat(barCount) * (1 + gapRatio) - gapRatio)
        let step = barWidth * (1 + gapRatio)
        let centerY = size.height / 2
        let maxHalf = size.height / 2
        let center = CGFloat(barCount - 1) / 2

        for i in 0..<barCount {
            let d = abs(CGFloat(i) - center) / center  // 0 at center, 1 at edge
            let envelope = pow(cos(d * .pi / 2), 1.4)
            let energy = energy(at: d)

            // Dots at the edges grow into bars as they approach the center.
            let half = max(barWidth / 2, maxHalf * envelope * (0.08 + energy * 0.92))

            let x = CGFloat(i) * step
            let rect = CGRect(x: x, y: centerY - half, width: barWidth, height: half * 2)
            let color = coreColor.interpolated(to: edgeColor, amount: d)
                .opacity(0.35 + Double(envelope) * 0.65)

            context.fill(Capsule().path(in: rect), with: .color(color))
        }
    }

    /// Bass in the middle, treble at the edges, with an idle breathing wave when silent.
    private func energy(at d: CGFloat) -> CGFloat {
        if state == .processing {
            // Pulse sweeping out from the center and back. Stops short of the
            // edge so the envelope never flattens the whole pill into dots.
            let sweep = 0.72 * CGFloat(abs(sin(time * 1.4)))
            let dist = d - sweep
            return 0.22 + exp(-dist * dist * 10) * 0.7
        }

        if state == .complete || state == .error {
            let settle = CGFloat(sin(time * 3 - Double(d) * 2.5)) * 0.5 + 0.5
            return 0.12 + settle * 0.25
        }

        let band = sampleSpectrum(at: d)
        let breathe = CGFloat(sin(time * 2.2 - Double(d) * 3.4)) * 0.5 + 0.5
        let idle = 0.04 + breathe * 0.05
        return min(1, idle + band * (0.35 + level * 0.85))
    }

    /// Linear interpolation between neighbouring FFT bands so bars read as one fluid curve.
    private func sampleSpectrum(at d: CGFloat) -> CGFloat {
        guard !spectrum.isEmpty else { return 0 }
        if spectrum.count == 1 { return spectrum[0] }

        let pos = d * CGFloat(spectrum.count - 1)
        let lower = Int(pos)
        let upper = min(lower + 1, spectrum.count - 1)
        let frac = pos - CGFloat(lower)
        return spectrum[lower] + (spectrum[upper] - spectrum[lower]) * frac
    }
}

/// The frosted capsule the equalizer lives in.
struct PillShell: View {
    let state: AnimationState
    /// Shadow scales with the capsule — a fixed radius swamps a small pill.
    let height: CGFloat

    private var borderTint: Color {
        switch state {
        case .recording: return Color.black.opacity(0.16)
        case .processing: return Color(red: 0.15, green: 0.55, blue: 1.0).opacity(0.45)
        case .complete: return Color(red: 0.16, green: 0.78, blue: 0.36).opacity(0.5)
        case .error: return Color(red: 0.95, green: 0.25, blue: 0.25).opacity(0.55)
        }
    }

    var body: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        Color(white: 1.0),
                        Color(white: 0.94)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                    .blendMode(.plusLighter)
            )
            .overlay(
                Capsule().strokeBorder(borderTint, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: height * 0.42, x: 0, y: height * 0.14)
            .shadow(color: .black.opacity(0.12), radius: height * 0.05, x: 0, y: 1)
    }
}

// MARK: - Color blending

extension Color {
    /// Blend in sRGB — enough for bar-to-bar gradients, no need for a full color space dance.
    func interpolated(to other: Color, amount: CGFloat) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB)
        let b = NSColor(other).usingColorSpace(.sRGB)
        guard let a = a, let b = b else { return self }

        let t = min(max(amount, 0), 1)
        return Color(
            nsColor: NSColor(
                srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
                alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * t
            )
        )
    }
}

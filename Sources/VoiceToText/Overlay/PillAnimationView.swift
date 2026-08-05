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

/// What the bars mean. Same capsule, two readings of the same voice.
enum PillMode {
    /// Bar position is time: the last ~1.7s of loudness, scrolling.
    case history
    /// Bar position is frequency: fixed bands, each rising and falling in place.
    case bands
}

final class NewPillAnimationView: NSView, AnimationView {
    let config: AnimationConfig
    private let hostingView: NSHostingView<PillAnimationContent>
    private let model = AnimationModel()

    init(config: AnimationConfig, mode: PillMode) {
        self.config = config
        self.hostingView = NSHostingView(rootView: PillAnimationContent(model: model, config: config, mode: mode))

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
    let mode: PillMode

    var body: some View {
        TimelineView(.animation) { timeline in
            PillFrame(
                time: timeline.date.timeIntervalSinceReferenceDate,
                history: model.levelHistory,
                spectrum: model.smoothedSpectrum,
                level: model.smoothedLevel,
                state: model.state,
                config: config,
                mode: mode
            )
        }
    }
}

struct PillFrame: View {
    let time: Double
    /// Loudness over the last ~1.7s, oldest first.
    let history: [CGFloat]
    /// Per-band energy, low frequency first.
    let spectrum: [CGFloat]
    let level: CGFloat
    let state: AnimationState
    let config: AnimationConfig
    let mode: PillMode

    private var primary: Color {
        Color(nsColor: NSColor(hex: config.primaryColor) ?? .systemBlue)
    }
    private var secondary: Color {
        Color(nsColor: NSColor(hex: config.secondaryColor) ?? .systemPurple)
    }
    private var shellColor: Color {
        Color(nsColor: NSColor(hex: config.shellColor) ?? .white)
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
                PillShell(state: state, height: capsuleHeight, fill: shellColor, tint: primary)

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

    /// Bands 0-2 are rumble (HVAC, desk thump, mic handling) and the top band is
    /// hiss — all of it moves without you saying anything, so it's dropped.
    private static let usableBands = 3..<13

    /// Bars stay thin in both modes — one bar per band would make each one four
    /// times the width of the history row's, which reads as chunky. Bands are
    /// interpolated across a finer row instead.
    private var barCount: Int {
        switch mode {
        case .history: return 29
        case .bands: return 25
        }
    }

    private func drawBars(context: GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        let barCount = self.barCount
        let gapRatio: CGFloat = 0.85
        let barWidth = size.width / (CGFloat(barCount) * (1 + gapRatio) - gapRatio)
        let step = barWidth * (1 + gapRatio)
        let centerY = size.height / 2
        let maxHalf = size.height / 2

        for i in 0..<barCount {
            // history: position is time, oldest left, live right.
            // bands: position is frequency, low left, high right — each bar
            // stays put and only changes height.
            let position = CGFloat(i) / CGFloat(barCount - 1)
            // Gentle bow so the capsule still tapers, without flattening the ends.
            let envelope = 0.62 + 0.38 * sin(position * .pi)
            let energy = energy(at: position)

            let half = max(barWidth / 2, maxHalf * envelope * (0.06 + energy * 0.94))

            let x = CGFloat(i) * step
            let rect = CGRect(x: x, y: centerY - half, width: barWidth, height: half * 2)
            let color = coreColor.interpolated(to: edgeColor, amount: position)
                .opacity(0.45 + Double(envelope) * 0.55)

            context.fill(Capsule().path(in: rect), with: .color(color))
        }
    }

    /// `position` is 0 at the low-frequency end, 1 at the high end.
    private func energy(at d: CGFloat) -> CGFloat {
        if state == .processing {
            // Pulse sweeping across the pill and back.
            let sweep = 0.5 + 0.5 * CGFloat(sin(time * 1.6))
            let dist = d - sweep
            return 0.22 + exp(-dist * dist * 22) * 0.7
        }

        if state == .complete || state == .error {
            let settle = CGFloat(sin(time * 3 - Double(d) * 2.5)) * 0.5 + 0.5
            return 0.12 + settle * 0.25
        }

        switch mode {
        case .history:
            let breathe = CGFloat(sin(time * 2.2 - Double(d) * 3.4)) * 0.5 + 0.5
            return min(1, 0.04 + breathe * 0.05 + sampleHistory(at: d) * 1.6)
        case .bands:
            // Flat rest state, no idle wave: a travelling sine across bars that
            // are supposed to mean frequency is indistinguishable from noise.
            // AudioCapture gates on absolute loudness, so silence reads as zero.
            return min(1, 0.03 + sampleSpectrum(at: d))
        }
    }

    /// Interpolates between neighbouring usable bands so a thin bar row still
    /// reads as one continuous curve.
    private func sampleSpectrum(at d: CGFloat) -> CGFloat {
        guard !spectrum.isEmpty else { return 0 }

        let position = d * CGFloat(Self.usableBands.count - 1)
        let lower = Self.usableBands.lowerBound + Int(position)
        let upper = min(lower + 1, Self.usableBands.upperBound - 1)
        guard lower >= 0, upper < spectrum.count else { return 0 }

        let frac = position - CGFloat(Int(position))
        return spectrum[lower] + (spectrum[upper] - spectrum[lower]) * frac
    }

    /// The history is shorter than the bar row until you've been talking for a
    /// moment, so it's anchored to the right — new audio arrives at the live
    /// end and scrolls left, and the empty past stays flat.
    private func sampleHistory(at d: CGFloat) -> CGFloat {
        guard !history.isEmpty else { return 0 }

        let barsFromRight = (1 - d) * CGFloat(barCount - 1)
        let index = CGFloat(history.count - 1) - barsFromRight
        guard index >= 0 else { return 0 }

        let lower = Int(index)
        let upper = min(lower + 1, history.count - 1)
        return history[lower] + (history[upper] - history[lower]) * (index - CGFloat(lower))
    }
}

/// The frosted capsule the equalizer lives in.
struct PillShell: View {
    let state: AnimationState
    /// Shadow scales with the capsule — a fixed radius swamps a small pill.
    let height: CGFloat
    let fill: Color
    /// Recording-state border colour, so a dark shell can glow in its own hue.
    let tint: Color

    /// A dark capsule needs a lit rim, a light one needs a shaded rim.
    private var isDarkShell: Bool {
        (NSColor(fill).usingColorSpace(.sRGB)?.brightnessComponent ?? 1) < 0.5
    }

    private var borderTint: Color {
        switch state {
        case .recording: return isDarkShell ? tint.opacity(0.55) : Color.black.opacity(0.16)
        case .processing: return Color(red: 0.15, green: 0.55, blue: 1.0).opacity(0.45)
        case .complete: return Color(red: 0.16, green: 0.78, blue: 0.36).opacity(0.5)
        case .error: return Color(red: 0.95, green: 0.25, blue: 0.25).opacity(0.55)
        }
    }

    var body: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: isDarkShell
                        ? [fill.opacity(0.98), fill.mixed(with: .black, amount: 0.35)]
                        : [fill, fill.mixed(with: .black, amount: 0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isDarkShell ? Color.white.opacity(0.12) : Color.white.opacity(0.9),
                        lineWidth: isDarkShell ? 1 : 2
                    )
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
    /// Shorthand for shading a shell colour toward black or white.
    func mixed(with other: Color, amount: CGFloat) -> Color {
        interpolated(to: other, amount: amount)
    }

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

import SwiftUI
import AppKit

// MARK: - SwiftUI Animation Wrapper

final class SwiftUIAnimationView<Content: View>: NSView, AnimationView {
    let config: AnimationConfig
    private let hostingView: NSHostingView<Content>
    private var audioLevelBinding: Binding<CGFloat>?
    private var stateBinding: Binding<AnimationState>?

    @Published var audioLevel: CGFloat = 0
    @Published var state: AnimationState = .recording

    init(config: AnimationConfig, @ViewBuilder content: (Binding<CGFloat>, Binding<AnimationState>) -> Content) {
        self.config = config

        var audioLevel: CGFloat = 0
        var state: AnimationState = .recording

        let audioBinding = Binding<CGFloat>(
            get: { audioLevel },
            set: { audioLevel = $0 }
        )
        let stateBinding = Binding<AnimationState>(
            get: { state },
            set: { state = $0 }
        )

        self.hostingView = NSHostingView(rootView: content(audioBinding, stateBinding))

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
        audioLevel = CGFloat(level)
    }

    func updateSpectrum(_ bands: [Float]) {
        // Generic wrapper doesn't use spectrum
    }

    func startRecordingAnimation() {
        state = .recording
    }

    func startProcessingAnimation() {
        state = .processing
    }

    func showCompletionAnimation() {
        state = .complete
    }
}

enum AnimationState {
    case recording
    case processing
    case complete
    case error
}

// MARK: - Observable Animation Model

class AnimationModel: ObservableObject {
    @Published var audioLevel: CGFloat = 0
    @Published var smoothedLevel: CGFloat = 0
    @Published var spectrum: [CGFloat] = Array(repeating: 0, count: 14)
    @Published var smoothedSpectrum: [CGFloat] = Array(repeating: 0, count: 14)
    @Published var state: AnimationState = .recording
    /// Recent loudness, oldest first — a scrolling picture of what you just
    /// said. A frequency spectrum can't fill a bar row: voice energy lives
    /// almost entirely below ~1kHz, so the treble bars would sit still.
    @Published var levelHistory: [CGFloat] = []

    static let historyLength = 48
    private static let historyInterval: TimeInterval = 0.035

    private var lastHistoryPush: Date = .distantPast
    private var lastUpdate: Date = Date()
    /// Separate clock: AudioCapture fires onAudioLevel immediately before
    /// onFrequencySpectrum, so sharing `lastUpdate` left the spectrum with
    /// dt≈0 every frame — bars rose instantly and then never fell.
    private var lastSpectrumUpdate: Date = Date()

    func updateAudioLevel(_ raw: CGFloat) {
        let now = Date()
        let dt = now.timeIntervalSince(lastUpdate)
        lastUpdate = now

        audioLevel = raw

        // Rise instant, fall slow
        if raw > smoothedLevel {
            smoothedLevel = raw
        } else {
            smoothedLevel = smoothedLevel + (raw - smoothedLevel) * min(1.0, CGFloat(dt) * 5)
        }

        // Sampled on a clock, not per buffer — buffers arrive far faster than
        // the eye can follow and the row would blur into noise.
        if now.timeIntervalSince(lastHistoryPush) >= Self.historyInterval {
            lastHistoryPush = now
            levelHistory.append(max(raw, smoothedLevel))
            if levelHistory.count > Self.historyLength {
                levelHistory.removeFirst(levelHistory.count - Self.historyLength)
            }
        }
    }

    func updateSpectrum(_ bands: [Float]) {
        let now = Date()
        let dt = now.timeIntervalSince(lastSpectrumUpdate)
        lastSpectrumUpdate = now

        spectrum = bands.map { CGFloat($0) }

        // Smooth each band - rise instant, fall slow
        for i in 0..<min(bands.count, smoothedSpectrum.count) {
            let target = CGFloat(bands[i])
            if target > smoothedSpectrum[i] {
                smoothedSpectrum[i] = target
            } else {
                smoothedSpectrum[i] = smoothedSpectrum[i] + (target - smoothedSpectrum[i]) * min(1.0, CGFloat(dt) * 6)
            }
        }
    }
}

// MARK: - New Orb Animation View (NSView wrapper)

final class NewOrbAnimationView: NSView, AnimationView {
    let config: AnimationConfig
    private let hostingView: NSHostingView<OrbAnimationContent>
    private let model = AnimationModel()

    init(config: AnimationConfig) {
        self.config = config
        self.hostingView = NSHostingView(rootView: OrbAnimationContent(model: model, config: config))

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
        model.audioLevel = CGFloat(level)
    }

    func updateSpectrum(_ bands: [Float]) {
        // Orb doesn't use spectrum
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
}

struct OrbAnimationContent: View {
    @ObservedObject var model: AnimationModel
    let config: AnimationConfig

    private var primary: Color {
        Color(nsColor: NSColor(hex: config.primaryColor) ?? .systemBlue)
    }
    private var secondary: Color {
        Color(nsColor: NSColor(hex: config.secondaryColor) ?? .systemPurple)
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let level = model.audioLevel

            ZStack {
                // Outer glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [primary.opacity(0.6), primary.opacity(0.0)],
                            center: .center,
                            startRadius: 20,
                            endRadius: 60 + level * 20
                        )
                    )
                    .scaleEffect(1.0 + sin(t * 2) * 0.1 + level * 0.3)

                // Orbiting blob 1
                Circle()
                    .fill(secondary.opacity(0.5))
                    .frame(width: 40, height: 40)
                    .offset(x: cos(t * 1.5) * 20, y: sin(t * 1.5) * 20)
                    .blur(radius: 10)

                // Orbiting blob 2
                Circle()
                    .fill(primary.opacity(0.6))
                    .frame(width: 35, height: 35)
                    .offset(x: cos(t * 1.5 + .pi) * 15, y: sin(t * 1.5 + .pi) * 15)
                    .blur(radius: 8)

                // Core orb
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [primary, secondary],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40 + level * 25, height: 40 + level * 25)
                    .shadow(color: primary.opacity(0.8), radius: 20)
                    .scaleEffect(1.0 + sin(t * 3) * 0.05)

                // Inner highlight
                Circle()
                    .fill(Color.white.opacity(0.3 + level * 0.2))
                    .frame(width: 15, height: 15)
                    .offset(x: -6, y: -6)
                    .blur(radius: 4)

                // Processing spinner
                if model.state == .processing {
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(Color.white.opacity(0.8), lineWidth: 3)
                        .frame(width: 60, height: 60)
                        .rotationEffect(.degrees(t * 200))
                }

                // Completion flash
                if model.state == .complete {
                    Circle()
                        .fill(Color.green.opacity(0.6))
                        .frame(width: 50, height: 50)
                        .scaleEffect(1.5)
                        .opacity(0.5)
                }
            }
        }
    }
}

// MARK: - New Waveform Animation View (Style 5: Physics-based bars)

final class NewWaveformAnimationView: NSView, AnimationView {
    let config: AnimationConfig
    private let hostingView: NSHostingView<WaveformAnimationContent>
    private let model = AnimationModel()

    init(config: AnimationConfig) {
        self.config = config
        self.hostingView = NSHostingView(rootView: WaveformAnimationContent(
            model: model,
            config: config
        ))

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
}

struct WaveformAnimationContent: View {
    @ObservedObject var model: AnimationModel
    let config: AnimationConfig
    private let barCount = 28

    private let barColor: Color
    private let secondaryColor: Color
    private let processingColor: Color

    init(model: AnimationModel, config: AnimationConfig) {
        self.model = model
        self.config = config
        self.barColor = Color(nsColor: NSColor(hex: config.primaryColor) ?? .systemBlue)
        self.secondaryColor = Color(nsColor: NSColor(hex: config.secondaryColor) ?? .systemPurple)
        self.processingColor = Color.orange
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                drawWaveform(context: context, size: size, time: t)
            }
        }
    }

    private func drawWaveform(context: GraphicsContext, size: CGSize, time: Double) {
        let centerY = size.height / 2
        let barWidth: CGFloat = 20
        let gap: CGFloat = 6
        let usableWidth = size.width * 0.85
        let totalWidth = CGFloat(barCount) * (barWidth + gap) - gap
        let scale = min(1.0, usableWidth / totalWidth)
        let actualBarWidth = barWidth * scale
        let actualGap = gap * scale
        let actualTotalWidth = CGFloat(barCount) * (actualBarWidth + actualGap) - actualGap
        let startX = (size.width - actualTotalWidth) / 2
        let center = CGFloat(barCount) / 2.0
        let maxHeight = size.height * 0.9

        let isProcessing = model.state == .processing
        let level = model.smoothedLevel

        for i in 0..<barCount {
            // Edge fade
            let distFromCenter = abs(CGFloat(i) - center) / center
            let edgeFade = pow(cos(distFromCenter * .pi / 2), 1.5)

            if edgeFade < 0.05 { continue }

            // Wave that flows outward from center
            let wavePhase = time * 3.0 - Double(distFromCenter) * 2.0
            let wave = sin(wavePhase) * 0.5 + 0.5

            // Processing animation - faster wave
            let processingWave = sin(time * 4.0 - Double(distFromCenter) * 3.0) * 0.5 + 0.5

            // Height based on audio level or processing state
            let idleHeight: CGFloat = 8
            let audioHeight: CGFloat
            if isProcessing {
                audioHeight = CGFloat(processingWave) * maxHeight * 0.5
            } else {
                let waveHeight = CGFloat(wave) * (idleHeight + level * maxHeight * 0.3)
                audioHeight = waveHeight + level * maxHeight * 0.5
            }

            let totalHeight = (idleHeight + audioHeight) * edgeFade
            let halfHeight = max(4, totalHeight / 2)

            let x = startX + CGFloat(i) * (actualBarWidth + actualGap)
            let opacity = 0.7 + edgeFade * 0.25

            // Color: orange during processing, normal otherwise
            let color: Color
            if isProcessing {
                color = processingColor.opacity(opacity)
            } else {
                let colorMix = distFromCenter
                color = colorMix < 0.5 ? barColor.opacity(opacity) : secondaryColor.opacity(opacity)
            }

            let fullHeight = halfHeight * 2
            let barRect = CGRect(x: x, y: centerY - halfHeight, width: actualBarWidth, height: fullHeight)
            context.fill(RoundedRectangle(cornerRadius: actualBarWidth / 2).path(in: barRect), with: .color(color))
        }
    }
}


// MARK: - New Glow Animation View

final class NewGlowAnimationView: NSView, AnimationView {
    let config: AnimationConfig
    private let hostingView: NSHostingView<GlowAnimationContent>
    private let model = AnimationModel()

    init(config: AnimationConfig) {
        self.config = config
        self.hostingView = NSHostingView(rootView: GlowAnimationContent(model: model, config: config))

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
        model.updateAudioLevel(CGFloat(level))  // use smoothed update
    }

    func updateSpectrum(_ bands: [Float]) {
        // Glow doesn't use spectrum
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

struct GlowAnimationContent: View {
    @ObservedObject var model: AnimationModel
    let config: AnimationConfig

    private var colors: [Color] {
        let primary = Color(nsColor: NSColor(hex: config.primaryColor) ?? .systemPurple)
        let secondary = Color(nsColor: NSColor(hex: config.secondaryColor) ?? .systemPink)
        return [
            primary,
            secondary,
            Color(red: 0.55, green: 0.62, blue: 1.0),
            Color(red: 1.0, green: 0.6, blue: 0.4),
        ]
    }

    private var stateColors: [Color] {
        switch model.state {
        case .recording:
            return colors
        case .processing:
            return [.orange, .yellow, .orange, .yellow]
        case .complete:
            return [.green, .mint, .green, .mint]
        case .error:
            return [.red, .pink, .red, .pink]
        }
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let level = model.smoothedLevel  // use smoothed level

                ZStack {
                    // Blurred glow layer - reacts to voice
                    Rectangle()
                        .strokeBorder(
                            AngularGradient(
                                colors: stateColors + [stateColors[0]],
                                center: .center,
                                startAngle: .degrees(t * 60),
                                endAngle: .degrees(t * 60 + 360)
                            ),
                            lineWidth: 15 + level * 50
                        )
                        .blur(radius: 25 + level * 30)

                    // Sharp border
                    Rectangle()
                        .strokeBorder(
                            AngularGradient(
                                colors: stateColors + [stateColors[0]],
                                center: .center,
                                startAngle: .degrees(t * 60),
                                endAngle: .degrees(t * 60 + 360)
                            ),
                            lineWidth: 3 + level * 3
                        )
                }
            }
        }
    }
}

// MARK: - New Siri Animation View

final class NewSiriAnimationView: NSView, AnimationView {
    let config: AnimationConfig
    private let hostingView: NSHostingView<SiriAnimationContent>
    private let model = AnimationModel()

    init(config: AnimationConfig) {
        self.config = config
        self.hostingView = NSHostingView(rootView: SiriAnimationContent(model: model, config: config))

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
        model.updateAudioLevel(CGFloat(level))  // use smoothed update
    }

    func updateSpectrum(_ bands: [Float]) {
        // Siri doesn't use spectrum
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

struct SiriAnimationContent: View {
    @ObservedObject var model: AnimationModel
    let config: AnimationConfig

    private let waveColors: [Color] = [
        Color(red: 0.0, green: 0.85, blue: 1.0),
        Color(red: 0.6, green: 0.3, blue: 1.0),
        Color(red: 1.0, green: 0.35, blue: 0.55),
        Color(red: 0.35, green: 1.0, blue: 0.55),
    ]

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in  // 60fps
                let t = timeline.date.timeIntervalSinceReferenceDate
                let level = model.smoothedLevel  // use smoothed level

                ZStack {
                    // Gradient shadow - 0.7 black at bottom, transparent at top
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0),
                            Color.black.opacity(0.7)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    // Wave lines
                    ForEach(0..<4, id: \.self) { index in
                        SiriWaveLine(
                            time: t,
                            index: index,
                            audioLevel: level,
                            color: waveColors[index],
                            state: model.state
                        )
                    }
                    .blur(radius: 1)

                    // Processing indicator
                    if model.state == .processing {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.8)
                    }
                }
            }
        }
    }
}

struct SiriWaveLine: View {
    let time: Double
    let index: Int
    let audioLevel: CGFloat
    let color: Color
    let state: AnimationState

    private var displayColor: Color {
        switch state {
        case .complete:
            let colors = [Color.green, Color.mint, Color.green, Color.mint]
            return colors[index % colors.count]
        case .processing:
            let colors = [Color.orange, Color.yellow, Color.orange, Color.yellow]
            return colors[index % colors.count]
        case .recording:
            return color
        case .error:
            let colors = [Color.red, Color.pink, Color.red, Color.pink]
            return colors[index % colors.count]
        }
    }

    private var isAnimating: Bool {
        state == .processing || state == .complete || state == .error
    }

    var body: some View {
        // Always use time-based phase to avoid jumps - just different speeds
        // Alternate direction: even lines flow right, odd lines flow left
        let direction: Double = index % 2 == 0 ? 1.0 : -1.0
        let speed: Double = isAnimating ? 3.0 : 0.5
        let phase = time * speed * direction + Double(index) * 0.6

        // Very steep curve - need loud audio to peak
        let thresholded = max(0, audioLevel - 0.15) / 0.85  // ignore bottom 15%
        let curved = pow(thresholded, 2.5)  // very steep - hard to reach peak
        let amp: CGFloat = isAnimating ? 20 + CGFloat(sin(time * 2)) * 10 : (15 + curved * 55) * (1.0 - CGFloat(index) * 0.1)
        let freq: CGFloat = 0.02 + CGFloat(index) * 0.005
        let opacity: Double = 0.75 - Double(index) * 0.1
        let thicknessFactor: CGFloat = [1.0, 2.5, 1.3, 2.0][index % 4]
        let lineWidth: CGFloat = (3.5 - CGFloat(index) * 0.4) * thicknessFactor

        SiriWaveShape(phase: phase, amplitude: amp, frequency: freq)
            .stroke(displayColor.opacity(opacity), lineWidth: lineWidth)
    }
}

struct SiriWaveShape: Shape {
    let phase: Double
    let amplitude: CGFloat
    let frequency: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY

        path.move(to: CGPoint(x: 0, y: midY))

        for x in stride(from: 0, through: rect.width, by: 2) {
            let relX = x / rect.width
            let envelope = sin(relX * .pi)
            let y = midY + sin(x * frequency + phase) * amplitude * envelope
            path.addLine(to: CGPoint(x: x, y: y))
        }

        return path
    }
}

// MARK: - Dot Cursor Animation (cursor becomes a black dot that pulses with volume)

final class NewDotCursorAnimationView: NSView, AnimationView {
    let config: AnimationConfig
    private let hostingView: NSHostingView<DotCursorAnimationContent>
    private let model = AnimationModel()
    private var cursorHidden = false

    init(config: AnimationConfig) {
        self.config = config
        self.hostingView = NSHostingView(rootView: DotCursorAnimationContent(model: model, config: config))

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

    func updateSpectrum(_ bands: [Float]) {}

    func startRecordingAnimation() {
        model.state = .recording
        if !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        }
    }

    func startProcessingAnimation() {
        model.state = .processing
    }

    func showCompletionAnimation() {
        model.state = .complete
        // Keep cursor hidden — deinit unhides when the overlay closes.
    }

    func showErrorAnimation() {
        model.state = .error
        // Keep cursor hidden — deinit unhides when the overlay closes.
    }

    deinit {
        if cursorHidden {
            NSCursor.unhide()
        }
    }
}

struct DotCursorAnimationContent: View {
    @ObservedObject var model: AnimationModel
    let config: AnimationConfig

    var body: some View {
        TimelineView(.animation) { timeline in
            DotCursorFrame(
                time: timeline.date.timeIntervalSinceReferenceDate,
                level: model.smoothedLevel,
                state: model.state
            )
        }
    }
}

struct DotCursorFrame: View {
    let time: Double
    let level: CGFloat
    let state: AnimationState

    var body: some View {
        let mouseGlobal = NSEvent.mouseLocation
        let screenFrame = NSScreen.main?.frame ?? .zero
        let localX = mouseGlobal.x - screenFrame.minX
        let localY = screenFrame.maxY - mouseGlobal.y

        let baseSize: CGFloat = 22
        let maxBoost: CGFloat = 70
        let pulse: CGFloat = {
            switch state {
            case .processing: return 12 + CGFloat(sin(time * 4)) * 6
            case .complete: return 14
            case .error: return 12 + CGFloat(sin(time * 6)) * 4
            case .recording: return 0
            }
        }()
        let dotSize = baseSize + level * maxBoost + pulse

        let dotColor: Color = {
            switch state {
            case .recording: return .black
            case .processing: return Color(red: 0.15, green: 0.55, blue: 1.0)
            case .complete: return Color(red: 0.16, green: 0.78, blue: 0.36)
            case .error: return Color(red: 0.95, green: 0.25, blue: 0.25)
            }
        }()

        let ringSize: CGFloat = {
            switch state {
            case .processing: return dotSize + 14 + CGFloat(sin(time * 3)) * 6
            case .error: return dotSize + 10
            default: return dotSize
            }
        }()

        let ringColor: Color = {
            switch state {
            case .processing: return Color.white.opacity(0.9)
            case .error: return Color.white.opacity(0.9)
            default: return Color.white.opacity(0.65)
            }
        }()

        return ZStack {
            Color.clear

            if state == .processing || state == .error {
                Circle()
                    .stroke(ringColor, lineWidth: 2)
                    .frame(width: ringSize, height: ringSize)
                    .position(x: localX, y: localY)
                    .shadow(color: .black.opacity(0.4), radius: 4)
            }

            Circle()
                .fill(dotColor)
                .frame(width: dotSize, height: dotSize)
                .position(x: localX, y: localY)
                .shadow(color: dotColor.opacity(0.6), radius: 12, x: 0, y: 0)
                .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 1)

            Circle()
                .stroke(Color.white.opacity(0.75), lineWidth: 1.5)
                .frame(width: dotSize, height: dotSize)
                .position(x: localX, y: localY)
        }
    }
}

// MARK: - Color Extension

extension Color {
    init(nsColor: NSColor) {
        self.init(nsColor)
    }
}

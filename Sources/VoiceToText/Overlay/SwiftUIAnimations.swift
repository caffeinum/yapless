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
}

// MARK: - Observable Animation Model

class AnimationModel: ObservableObject {
    @Published var audioLevel: CGFloat = 0
    @Published var state: AnimationState = .recording
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

// MARK: - New Waveform Animation View

final class NewWaveformAnimationView: NSView, AnimationView {
    let config: AnimationConfig
    private let hostingView: NSHostingView<WaveformAnimationContent>
    private let model = AnimationModel()

    init(config: AnimationConfig) {
        self.config = config
        self.hostingView = NSHostingView(rootView: WaveformAnimationContent(model: model, config: config))

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
    private let barCount = 32

    private var barColor: Color {
        Color(nsColor: NSColor(hex: config.primaryColor) ?? .systemBlue)
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 0.016)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let level = model.audioLevel

                ZStack {
                    HStack(spacing: 2) {
                        ForEach(0..<barCount, id: \.self) { i in
                            WaveformBar(
                                index: i,
                                time: t,
                                audioLevel: level,
                                color: barColor,
                                state: model.state,
                                maxHeight: geo.size.height * 0.9
                            )
                        }
                    }

                    // Processing overlay
                    if model.state == .processing {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.8)
                    }

                    // Completion flash
                    if model.state == .complete {
                        Color.green.opacity(0.3)
                    }
                }
            }
        }
    }
}

struct WaveformBar: View {
    let index: Int
    let time: Double
    let audioLevel: CGFloat
    let color: Color
    let state: AnimationState
    var maxHeight: CGFloat = 100

    var body: some View {
        let wave = sin(Double(index) * 0.4 + time * 4) * 0.5 + 0.5
        let baseHeight: CGFloat = state == .processing ? 0.3 : (0.15 + CGFloat(wave) * 0.7 * (0.3 + audioLevel))
        let height = max(4, baseHeight * maxHeight)

        RoundedRectangle(cornerRadius: 3)
            .fill(color.opacity(0.6 + wave * 0.4))
            .frame(width: 3, height: height)
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
        model.audioLevel = CGFloat(level)
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
        }
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let level = model.audioLevel

                ZStack {
                    // Blurred glow layer
                    Rectangle()
                        .strokeBorder(
                            AngularGradient(
                                colors: stateColors + [stateColors[0]],
                                center: .center,
                                startAngle: .degrees(t * 60),
                                endAngle: .degrees(t * 60 + 360)
                            ),
                            lineWidth: 20 + level * 40
                        )
                        .blur(radius: 30 + level * 20)

                    // Sharp border
                    Rectangle()
                        .strokeBorder(
                            AngularGradient(
                                colors: stateColors + [stateColors[0]],
                                center: .center,
                                startAngle: .degrees(t * 60),
                                endAngle: .degrees(t * 60 + 360)
                            ),
                            lineWidth: 4
                        )

                    // Center stop button
                    VStack {
                        ZStack {
                            Circle()
                                .fill(Color.black.opacity(0.6))
                                .frame(width: 60, height: 60)

                            Circle()
                                .strokeBorder(
                                    AngularGradient(
                                        colors: stateColors + [stateColors[0]],
                                        center: .center,
                                        startAngle: .degrees(t * 60),
                                        endAngle: .degrees(t * 60 + 360)
                                    ),
                                    lineWidth: 2
                                )
                                .frame(width: 60, height: 60)

                            if model.state == .processing {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(0.6)
                            } else {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.white)
                                    .frame(width: 20, height: 20)
                            }
                        }
                    }
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
        model.audioLevel = CGFloat(level)
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
            TimelineView(.animation(minimumInterval: 0.016)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let level = model.audioLevel

                ZStack {
                    // Background
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.black.opacity(0.7))

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

                    // Completion flash
                    if model.state == .complete {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.green.opacity(0.3))
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

    var body: some View {
        let phase = time * 3 + Double(index) * 0.6
        let amp = state == .processing ? 15 : (20 + audioLevel * 50) * (1.0 - CGFloat(index) * 0.12)
        let freq = 0.04 + CGFloat(index) * 0.01

        SiriWaveShape(phase: phase, amplitude: amp, frequency: freq)
            .stroke(color.opacity(0.75 - Double(index) * 0.1), lineWidth: 3.5 - CGFloat(index) * 0.4)
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

// MARK: - Color Extension

extension Color {
    init(nsColor: NSColor) {
        self.init(nsColor)
    }
}

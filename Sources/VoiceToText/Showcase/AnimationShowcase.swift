import SwiftUI
import AppKit

// MARK: - Showcase Window

final class ShowcaseWindowController {
    private var window: NSWindow?

    func show() {
        let contentView = NSHostingView(rootView: AnimationShowcaseView())

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        window?.title = "Animation Showcase"
        window?.contentView = contentView
        window?.center()
        window?.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Main Showcase View

struct AnimationShowcaseView: View {
    @State private var audioLevel: CGFloat = 0.3
    @State private var isRecording = true
    @State private var isProcessing = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Animation Showcase")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)

            HStack(spacing: 30) {
                AnimationCard(title: "Orb", style: .orb, audioLevel: audioLevel)
                AnimationCard(title: "Waveform", style: .waveform, audioLevel: audioLevel)
                AnimationCard(title: "Glow", style: .glow, audioLevel: audioLevel)
                AnimationCard(title: "Siri", style: .siri, audioLevel: audioLevel)
            }
            .padding()

            VStack(spacing: 15) {
                HStack {
                    Text("Audio Level")
                        .foregroundColor(.white)
                    Slider(value: $audioLevel, in: 0...1)
                        .frame(width: 300)
                    Text("\(Int(audioLevel * 100))%")
                        .foregroundColor(.gray)
                        .frame(width: 40)
                }

                HStack(spacing: 20) {
                    Button("Recording") {
                        isRecording = true
                        isProcessing = false
                    }
                    .buttonStyle(ShowcaseButtonStyle(isActive: isRecording && !isProcessing, color: .red))

                    Button("Processing") {
                        isRecording = false
                        isProcessing = true
                    }
                    .buttonStyle(ShowcaseButtonStyle(isActive: isProcessing, color: .orange))
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

struct ShowcaseButtonStyle: ButtonStyle {
    let isActive: Bool
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(isActive ? color : Color.gray.opacity(0.3))
            .foregroundColor(.white)
            .cornerRadius(8)
    }
}

// MARK: - Animation Card

struct AnimationCard: View {
    let title: String
    let style: ShowcaseAnimationStyle
    let audioLevel: CGFloat

    var body: some View {
        VStack {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(white: 0.1))

                animationContent
            }
            .frame(width: 200, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Text(title)
                .font(.headline)
                .foregroundColor(.white)
        }
    }

    @ViewBuilder
    var animationContent: some View {
        switch style {
        case .orb:
            OrbShowcaseView(audioLevel: audioLevel)
        case .waveform:
            WaveformShowcaseView(audioLevel: audioLevel)
        case .glow:
            GlowShowcaseView(audioLevel: audioLevel)
        case .siri:
            SiriShowcaseView(audioLevel: audioLevel)
        }
    }
}

enum ShowcaseAnimationStyle {
    case orb, waveform, glow, siri
}

// MARK: - Orb Animation (inspired by metasidd/Orb)

struct OrbShowcaseView: View {
    let audioLevel: CGFloat

    private let primary = Color(red: 0.4, green: 0.6, blue: 1.0)
    private let secondary = Color(red: 0.8, green: 0.4, blue: 1.0)

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                // Outer glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [primary.opacity(0.6), primary.opacity(0.0)],
                            center: .center,
                            startRadius: 30,
                            endRadius: 80 + audioLevel * 20
                        )
                    )
                    .scaleEffect(1.0 + sin(t * 2) * 0.1 + audioLevel * 0.2)

                // Secondary blob
                Circle()
                    .fill(secondary.opacity(0.5))
                    .frame(width: 60, height: 60)
                    .offset(x: cos(t * 1.5) * 15, y: sin(t * 1.5) * 15)
                    .blur(radius: 10)

                // Primary blob
                Circle()
                    .fill(primary.opacity(0.6))
                    .frame(width: 50, height: 50)
                    .offset(x: cos(t * 1.5 + .pi) * 12, y: sin(t * 1.5 + .pi) * 12)
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
                    .frame(width: 50 + audioLevel * 20, height: 50 + audioLevel * 20)
                    .shadow(color: primary.opacity(0.8), radius: 20)
                    .scaleEffect(1.0 + sin(t * 3) * 0.05)

                // Inner highlight
                Circle()
                    .fill(Color.white.opacity(0.3 + audioLevel * 0.2))
                    .frame(width: 20, height: 20)
                    .offset(x: -8, y: -8)
                    .blur(radius: 5)
            }
        }
    }
}

// MARK: - Waveform Animation (Smooth bars)

struct WaveformShowcaseView: View {
    let audioLevel: CGFloat
    private let barCount = 24
    private let barColor = Color(red: 0.3, green: 0.85, blue: 0.5)

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.016)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { i in
                    BarView(
                        index: i,
                        time: t,
                        audioLevel: audioLevel,
                        color: barColor
                    )
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

struct BarView: View {
    let index: Int
    let time: Double
    let audioLevel: CGFloat
    let color: Color

    var body: some View {
        let wave = sin(Double(index) * 0.4 + time * 4) * 0.5 + 0.5
        let height: CGFloat = 20 + CGFloat(wave) * 60 * (0.5 + audioLevel)

        RoundedRectangle(cornerRadius: 2)
            .fill(color.opacity(0.5 + wave * 0.5))
            .frame(width: 4, height: height)
    }
}

// MARK: - Glow Animation (Apple Intelligence style border)

struct GlowShowcaseView: View {
    let audioLevel: CGFloat

    private let colors: [Color] = [
        Color(red: 0.74, green: 0.51, blue: 0.95),
        Color(red: 0.96, green: 0.73, blue: 0.92),
        Color(red: 0.55, green: 0.62, blue: 1.0),
        Color(red: 1.0, green: 0.6, blue: 0.4),
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                Color.black

                // Blurred glow layer
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        AngularGradient(
                            colors: colors + [colors[0]],
                            center: .center,
                            startAngle: .degrees(t * 60),
                            endAngle: .degrees(t * 60 + 360)
                        ),
                        lineWidth: 6 + audioLevel * 10
                    )
                    .blur(radius: 8 + audioLevel * 8)

                // Sharp border
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        AngularGradient(
                            colors: colors + [colors[0]],
                            center: .center,
                            startAngle: .degrees(t * 60),
                            endAngle: .degrees(t * 60 + 360)
                        ),
                        lineWidth: 3
                    )

                // Inner dark area
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black)
                    .padding(10)
            }
        }
    }
}

// MARK: - Siri Wave Animation

struct SiriShowcaseView: View {
    let audioLevel: CGFloat

    private let colors: [Color] = [
        Color(red: 0.0, green: 0.85, blue: 1.0),
        Color(red: 0.6, green: 0.3, blue: 1.0),
        Color(red: 1.0, green: 0.35, blue: 0.55),
        Color(red: 0.35, green: 1.0, blue: 0.55),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.016)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                ForEach(0..<4, id: \.self) { index in
                    WaveLine(
                        time: t,
                        index: index,
                        audioLevel: audioLevel,
                        color: colors[index]
                    )
                }
            }
            .blur(radius: 1)
        }
    }
}

struct WaveLine: View {
    let time: Double
    let index: Int
    let audioLevel: CGFloat
    let color: Color

    var body: some View {
        let phase = time * 3 + Double(index) * 0.6
        let amp = (25 + audioLevel * 50) * (1.0 - CGFloat(index) * 0.12)
        let freq = 0.035 + CGFloat(index) * 0.008

        WaveShape(phase: phase, amplitude: amp, frequency: freq)
            .stroke(color.opacity(0.75 - Double(index) * 0.1), lineWidth: 3.5 - CGFloat(index) * 0.4)
    }
}

struct WaveShape: Shape {
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

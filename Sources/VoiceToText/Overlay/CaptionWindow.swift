import AppKit

/// Closed-captions strip: a fixed-size dark bar at the bottom of the screen,
/// independent of the animation overlay so it works with every style, the
/// tiny pill included.
///
/// The frame never changes and the text is head-truncated, so new words
/// appear at the right edge and old ones slide out of view — the caption
/// grows, it never jumps or reflows.
final class CaptionWindow {
    private var window: NSWindow?
    private var label: NSTextField?

    /// `stable` never rewrites; `tentative` is drawn dimmed and may change
    /// until the next pass confirms it.
    func show(stable: String, tentative: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.window == nil { self.build() }
            guard let label = self.label else { return }

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingHead
            let text = NSMutableAttributedString()
            text.append(NSAttributedString(string: stable, attributes: [
                .foregroundColor: NSColor.white,
                .font: label.font ?? NSFont.systemFont(ofSize: 17, weight: .medium),
                .paragraphStyle: paragraph,
            ]))
            if !tentative.isEmpty {
                text.append(NSAttributedString(string: (stable.isEmpty ? "" : " ") + tentative, attributes: [
                    .foregroundColor: NSColor.white.withAlphaComponent(0.45),
                    .font: label.font ?? NSFont.systemFont(ofSize: 17, weight: .medium),
                    .paragraphStyle: paragraph,
                ]))
            }
            label.attributedStringValue = text
        }
    }

    func close() {
        DispatchQueue.main.async { [weak self] in
            self?.window?.orderOut(nil)
            self?.window = nil
            self?.label = nil
        }
    }

    private func build() {
        guard let screen = NSScreen.main else { return }
        let width = min(640, screen.frame.width * 0.6)
        let height: CGFloat = 64
        let frame = NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.minY + screen.frame.height * 0.10,
            width: width,
            height: height
        )

        let window = NSWindow(contentRect: frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = false

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        container.layer?.cornerRadius = 10

        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 17, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.cell?.truncatesLastVisibleLine = true
        label.lineBreakMode = .byTruncatingHead
        label.frame = container.bounds.insetBy(dx: 16, dy: 8)
        label.autoresizingMask = [.width, .height]

        container.addSubview(label)
        window.contentView = container
        window.orderFrontRegardless()

        self.window = window
        self.label = label
    }
}

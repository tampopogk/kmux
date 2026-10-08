import AppKit
import KmuxCore

/// A pane on screen: its content, with no chrome except a focus outline, a
/// notice once it exits or fails, and the ⋯ grip while the mouse is over it.
@MainActor
final class PaneView: NSView {
    let id: String
    let content: NSView
    private let notice = NSTextField(labelWithString: "")
    private let outline = NSView()
    let grip = PaneGrip(frame: NSRect(origin: .zero, size: PaneGrip.size))

    init(id: String, content: NSView) {
        self.id = id
        self.content = content
        super.init(frame: .zero)
        addSubview(content)

        notice.font = .systemFont(ofSize: 13, weight: .medium)
        notice.textColor = .white
        notice.alignment = .center
        notice.wantsLayer = true
        notice.drawsBackground = true
        notice.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        notice.isHidden = true
        addSubview(notice)

        outline.wantsLayer = true
        outline.layer?.borderWidth = 2
        outline.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        outline.isHidden = true
        addSubview(outline)

        grip.isHidden = true
        addSubview(grip)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { grip.isHidden = false }
    override func mouseExited(with event: NSEvent) { grip.isHidden = true }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var focused = false { didSet { outline.isHidden = !focused } }

    func show(_ pane: Pane) {
        switch pane.state {
        case .exited: notice.stringValue = "  exited\(pane.exitCode.map { " (\($0))" } ?? "")  "
        case .failed: notice.stringValue = "  failed: \(pane.error ?? "unknown error")  "
        default: notice.stringValue = ""
        }
        notice.isHidden = notice.stringValue.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        content.frame = bounds
        outline.frame = bounds
        notice.sizeToFit()
        notice.frame.origin = NSPoint(x: (bounds.width - notice.frame.width) / 2, y: 12)
        grip.frame.origin = NSPoint(x: ((bounds.width - PaneGrip.size.width) / 2).rounded(), y: bounds.height - PaneGrip.size.height)
    }
}

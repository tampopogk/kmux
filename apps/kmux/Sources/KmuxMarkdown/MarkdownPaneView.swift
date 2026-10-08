import AppKit
import Markdown

/// A markdown pane: a file rendered natively (TextKit, no web view), read
/// only, reloaded when it changes on disk. Mermaid blocks are drawn by
/// KmuxDiagram. Zoom steps with ⌘= ⌘− ⌘0 and follows a pinch smoothly by
/// laying the text out again at each step, as kanna-v3's doc view did.
@MainActor
public final class MarkdownPaneView: NSView, NSTextViewDelegate {
    /// Safari's steps for Zoom In / Zoom Out; a pinch moves freely between the ends.
    public static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    public var onFocus: (() -> Void)? { didSet { textView.onFocus = onFocus } }
    /// A link to another markdown file (absolute path): show it in this pane.
    public var onOpenMarkdown: ((String) -> Void)?
    /// kmux's pane menu, added below the text view's own items on a right-click.
    public var contextMenu: (() -> NSMenu?)? { didSet { textView.contextMenu = contextMenu } }
    public let path: String
    /// The view that takes keyboard focus.
    public var keyView: NSView { textView }
    public private(set) var zoom: CGFloat = 1
    /// How long the last render took (parse excluded), in milliseconds.
    public private(set) var renderMs: Double = 0
    public private(set) var parseMs: Double = 0

    private let scrollView = NSScrollView()
    private let textView: MarkdownTextView
    private let layoutManager = MarkdownLayoutManager()
    private let diagrams = DiagramCache()
    private var document = Document(parsing: "")
    private var stamp: (Date, Int)?
    private var poll: Timer?
    private var pendingZoom: CGFloat?

    public init(path: String, zoom: CGFloat = 1) {
        self.path = path
        self.zoom = zoom
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        super.init(frame: .zero)
        configureTextView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = MarkdownTheme.background
        addSubview(scrollView)
        textView.delegate = self
        textView.onMagnify = { [weak self] event in self?.pinch(event) }
        load()
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfChanged() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configureTextView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.drawsBackground = true
        textView.backgroundColor = MarkdownTheme.background
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // A text view made in code keeps its first frame as maxSize, and then never scrolls.
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.linkTextAttributes = [.foregroundColor: MarkdownTheme.accent, .cursor: NSCursor.pointingHand]
        textView.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
    }

    public func stop() {
        poll?.invalidate()
        poll = nil
    }

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
        updateInset()
    }

    /// Wide panes centre the text at its maximum width (scaled with the zoom).
    private func updateInset() {
        let width = scrollView.contentSize.width
        let inset = max(28 * min(zoom, 1), (width - (MarkdownTheme.maxTextWidth * zoom + 10)) / 2)
        let size = NSSize(width: inset, height: 22 * min(zoom, 1.5))
        if textView.textContainerInset != size { textView.textContainerInset = size }
        if textView.frame.width != width { textView.frame.size.width = width }
    }

    // MARK: Loading

    private func fileStamp() -> (Date, Int)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return ((attributes[.modificationDate] as? Date) ?? .distantPast, (attributes[.size] as? Int) ?? 0)
    }

    private func reloadIfChanged() {
        guard let now = fileStamp() else { return }
        if let stamp, stamp == now { return }
        load()
    }

    /// Reads and parses the file, then renders it where the reader was.
    private func load() {
        stamp = fileStamp()
        let text = FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let start = Date()
        document = Document(parsing: text, options: [.disableSmartOpts])
        parseMs = Date().timeIntervalSince(start) * 1000
        render()
    }

    private func render() {
        let start = Date()
        let position = readingPosition()
        var renderer = MarkdownRenderer(zoom: zoom, folder: URL(fileURLWithPath: path).deletingLastPathComponent(), diagrams: diagrams)
        let text = renderer.render(document)
        diagrams.keep(only: Set(renderer.diagramSources))
        layoutManager.zoom = zoom
        updateInset()
        textView.textStorage?.setAttributedString(text)
        if let position { restoreReadingPosition(position) }
        renderMs = Date().timeIntervalSince(start) * 1000
    }

    // MARK: Zoom

    /// One step in (1) or out (-1), or back to actual size (0).
    public func zoom(by step: Int) {
        let steps = Self.zoomSteps
        switch step {
        case 0: setZoom(1)
        case 1...: setZoom(steps.first { $0 > zoom + 0.001 } ?? steps.last!)
        default: setZoom(steps.last { $0 < zoom - 0.001 } ?? steps.first!)
        }
    }

    public func setZoom(_ value: CGFloat) {
        guard value.isFinite else { return }
        let value = min(Self.zoomSteps.last!, max(Self.zoomSteps.first!, value))
        guard value != zoom else { return }
        zoom = value
        render()
    }

    /// A pinch: the zoom follows the fingers. Events arrive faster than the
    /// text can be laid out, so they're folded into one render per turn of
    /// the run loop.
    func pinch(_ event: NSEvent) {
        let base = pendingZoom ?? zoom
        let target = min(Self.zoomSteps.last!, max(Self.zoomSteps.first!, base * (1 + event.magnification)))
        let scheduled = pendingZoom != nil
        pendingZoom = target
        guard !scheduled else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let target = self.pendingZoom else { return }
                self.pendingZoom = nil
                self.setZoom(target)
            }
        }
    }

    // MARK: Reading position (as in kanna-v3's doc view)

    private struct ReadingPosition {
        let index: Int
        let offset: CGFloat
    }

    private func lineTop(at index: Int) -> CGFloat {
        let length = textView.textStorage?.length ?? 0
        guard length > 0 else { return 0 }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(index, length - 1))
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textView.textContainerOrigin.y
    }

    /// The character at the top of the view, and how far its line sits from the top.
    private func readingPosition() -> ReadingPosition? {
        guard let container = textView.textContainer, (textView.textStorage?.length ?? 0) > 0 else { return nil }
        let visible = scrollView.contentView.bounds
        guard visible.minY > 1 else { return nil }
        layoutManager.ensureLayout(for: container)
        let point = NSPoint(x: 0, y: max(0, visible.minY - textView.textContainerOrigin.y))
        let index = layoutManager.characterIndexForGlyph(at: layoutManager.glyphIndex(for: point, in: container))
        return ReadingPosition(index: index, offset: lineTop(at: index) - visible.minY)
    }

    private func restoreReadingPosition(_ position: ReadingPosition) {
        guard let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        textView.scroll(NSPoint(x: 0, y: max(0, lineTop(at: position.index) - position.offset)))
    }

    /// Scrolls to the heading with this anchor; false if there is none.
    @discardableResult
    public func scroll(toAnchor fragment: String) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let wanted = fragment.removingPercentEncoding ?? fragment
        var found: Int?
        storage.enumerateAttribute(.kmuxHeading, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value as? String == wanted { found = range.location; stop.pointee = true }
        }
        guard let found, let container = textView.textContainer else { return false }
        layoutManager.ensureLayout(for: container)
        textView.scroll(NSPoint(x: 0, y: max(0, lineTop(at: found) - 8)))
        return true
    }

    // MARK: Links

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let target = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        if target.hasPrefix("#") {
            scroll(toAnchor: String(target.dropFirst()))
            return true
        }
        if let url = URL(string: target), let scheme = url.scheme?.lowercased(), scheme != "file" {
            if ["http", "https", "mailto"].contains(scheme) { NSWorkspace.shared.open(url) }
            return true
        }
        // A local file, relative to this one; a #fragment after it is dropped.
        var file = target.hasPrefix("file://") ? (URL(string: target)?.path ?? "") : target
        if let hash = file.firstIndex(of: "#") { file = String(file[..<hash]) }
        file = file.removingPercentEncoding ?? file
        guard !file.isEmpty else { return true }
        let url = file.hasPrefix("/") ? URL(fileURLWithPath: file) : URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(file)
        let resolved = url.standardizedFileURL.path
        if ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased()) {
            onOpenMarkdown?(resolved)
        } else if FileManager.default.fileExists(atPath: resolved) {
            NSWorkspace.shared.open(URL(fileURLWithPath: resolved))
        }
        return true
    }

    // MARK: For tests

    /// The rendered text, with diagrams and images shown as [diagram] and [image].
    public var text: String {
        guard let storage = textView.textStorage else { return "" }
        var out = ""
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                out += attachment.attachmentCell is DiagramCell ? "[diagram]" : "[image]"
            } else {
                out += (storage.string as NSString).substring(with: range)
            }
        }
        return out
    }

    /// Each drawn diagram's type and labels, in order.
    public var drawnDiagrams: [(type: String, labels: [String])] {
        guard let storage = textView.textStorage else { return [] }
        var out: [(String, [String])] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let cell = (value as? NSTextAttachment)?.attachmentCell as? DiagramCell { out.append((cell.diagramType, cell.scene.texts)) }
        }
        return out
    }

    /// The scroll position's top, in points (for tests).
    public var scrollTop: CGFloat { scrollView.contentView.bounds.minY }

    /// Scrolls so `y` (points from the top of the document) is at the top.
    public func scroll(toY y: CGFloat) { textView.scroll(NSPoint(x: 0, y: max(0, y))) }
}

/// The text view inside a markdown pane: reports focus, adds kmux's pane
/// menu to its own, and hands pinches to the pane.
final class MarkdownTextView: NSTextView {
    var onFocus: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?
    var onMagnify: ((NSEvent) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocus?() }
        return result
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let menu = super.menu(for: event) ?? NSMenu()
        if let extra = contextMenu?() {
            menu.addItem(.separator())
            for item in extra.items {
                extra.removeItem(item)
                menu.addItem(item)
            }
        }
        return menu
    }

    override func magnify(with event: NSEvent) {
        if let onMagnify { onMagnify(event) } else { super.magnify(with: event) }
    }
}

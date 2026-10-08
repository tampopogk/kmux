import AppKit
import UniformTypeIdentifiers
import WebKit

/// A markdown pane: a file rendered as a page (markdown-it, DOMPurify and
/// mermaid, bundled), reloaded whenever the file changes.
///
/// Everything is served over `kmux-md://`: `kmux-md://app/NAME` is the page
/// and its libraries from the app bundle, `kmux-md://file/PATH` a local file,
/// so a document's relative images work without opening the whole disk to
/// the page.
@MainActor
final class MarkdownPaneView: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    static let scheme = "kmux-md"

    let webView: FocusReportingWebView
    var onFocus: (() -> Void)? { didSet { webView.onFocus = onFocus } }
    /// A link to another markdown file: open it in this pane (absolute path).
    var onOpenMarkdown: ((String) -> Void)?
    private(set) var path: String
    private var loaded = false
    private var stamp: (Date, Int)?
    private var poll: Timer?
    private let notice = NSTextField(wrappingLabelWithString: "")

    init(path: String) {
        self.path = path
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(MarkdownSchemeHandler(), forURLScheme: Self.scheme)
        webView = FocusReportingWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        configuration.userContentController.add(WeakMessageHandler(self), name: "kmux")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        addSubview(webView)
        notice.alignment = .center
        notice.textColor = .secondaryLabelColor
        notice.isHidden = true
        addSubview(notice)
        webView.load(URLRequest(url: URL(string: "\(Self.scheme)://app/markdown.html")!))
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfChanged() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func stop() {
        poll?.invalidate()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "kmux")
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
        let size = notice.sizeThatFits(NSSize(width: min(bounds.width - 40, 420), height: .greatestFiniteMagnitude))
        notice.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// The document as plain text, as shown (for tests).
    func text() async -> String {
        (try? await webView.evaluateJavaScript("document.getElementById('page').innerText") as? String) ?? ""
    }

    // MARK: Rendering

    private func fileStamp() -> (Date, Int)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return ((attributes[.modificationDate] as? Date) ?? .distantPast, (attributes[.size] as? Int) ?? 0)
    }

    private func reloadIfChanged() {
        guard loaded, let now = fileStamp() else { return }
        if let stamp, stamp == now { return }
        render()
    }

    private func render() {
        stamp = fileStamp()
        guard let data = FileManager.default.contents(atPath: path) else {
            notice.stringValue = "Can't read \(path)"
            notice.isHidden = false
            return
        }
        notice.isHidden = true
        let text = String(decoding: data, as: UTF8.self)
        let folder = (path as NSString).deletingLastPathComponent
        let base = "\(Self.scheme)://file" + (folder.hasSuffix("/") ? folder : folder + "/")
        webView.callAsyncJavaScript("return await kmuxRender(text, base)", arguments: ["text": text, "base": base], in: nil, in: .page) { _ in }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        render()
    }

    // MARK: Links

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let resolved = (body["resolved"] as? String).flatMap(URL.init(string:)) else { return }
        if resolved.scheme == Self.scheme, resolved.host == "file" {
            let target = resolved.path.removingPercentEncoding ?? resolved.path
            if ["md", "markdown", "mdown"].contains((target as NSString).pathExtension.lowercased()) {
                onOpenMarkdown?(target)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: target))
            }
        } else if ["http", "https", "mailto"].contains(resolved.scheme ?? "") {
            NSWorkspace.shared.open(resolved)
        }
    }
}

/// Serves the page, its libraries and local files to markdown panes.
private final class MarkdownSchemeHandler: NSObject, WKURLSchemeHandler {
    /// The page and libraries: Contents/Resources/markdown in the app bundle.
    static let assets = Bundle.main.resourceURL?.appendingPathComponent("markdown")

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let file: URL?
        switch url.host {
        case "app": file = Self.assets?.appendingPathComponent(url.lastPathComponent)
        case "file": file = URL(fileURLWithPath: url.path.removingPercentEncoding ?? url.path)
        default: file = nil
        }
        guard let file, let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: type.hasPrefix("text/") ? "utf-8" : nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// WKUserContentController keeps its handlers alive; this breaks the cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

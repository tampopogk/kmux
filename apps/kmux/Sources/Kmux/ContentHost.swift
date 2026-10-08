import AppKit
import KmuxCore

/// Runs pane contents: Ghostty terminals for `term` panes and web views for
/// `web` panes, and reports their lifecycle to the core.
@MainActor
final class ContentHost: PaneHost {
    let runtime: GhosttyRuntime
    weak var core: Core?
    /// Terminals get `KMUX_INSTANCE`, `KMUX_SOCKET` and `KMUX_PANE`, so
    /// `kmux` run inside a pane talks to the kmux that owns it.
    var instance = Instance(name: Instance.defaultName)
    private(set) var views: [String: PaneView] = [:]
    var onFocus: ((String) -> Void)?
    var onCloseRequest: ((String) -> Void)?
    var onNavigate: ((String, String) -> Void)?
    /// A markdown pane followed a link to another markdown file.
    var onOpenMarkdown: ((String, String) -> Void)?
    /// The pane's ⋯ grip was pressed: a drag to move the pane begins.
    var onPaneDrag: ((String, NSEvent) -> Void)?
    /// The Pane menu, for right-clicks (acting on the pane, which takes focus first).
    var contextMenu: (() -> NSMenu?)?

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
        runtime.onChildExited = { [weak self] view, code in
            guard let id = self?.paneID(of: view) else { return }
            self?.core?.update(id, state: .exited, exitCode: code)
        }
        runtime.onClose = { [weak self] view in
            guard let id = self?.paneID(of: view) else { return }
            self?.onCloseRequest?(id)
        }
    }

    func terminal(_ id: String) -> TerminalSurfaceView? { views[id]?.content as? TerminalSurfaceView }
    func web(_ id: String) -> WebPaneView? { views[id]?.content as? WebPaneView }
    func ios(_ id: String) -> IosPaneView? { views[id]?.content as? IosPaneView }
    func markdown(_ id: String) -> MarkdownPaneView? { views[id]?.content as? MarkdownPaneView }

    /// The view that should have the keyboard when the pane is focused.
    func keyView(_ id: String) -> NSView? { terminal(id) ?? web(id)?.webView ?? ios(id) ?? markdown(id)?.webView }

    func start(_ pane: Pane) {
        let id = pane.id
        let content: NSView
        var started = true
        var failure = "Ghostty could not create a terminal"
        switch pane.type {
        case .md:
            let path = Self.absolute(pane.path ?? "")
            let markdown = MarkdownPaneView(path: path)
            markdown.onFocus = { [weak self] in self?.onFocus?(id) }
            markdown.onOpenMarkdown = { [weak self] target in self?.onOpenMarkdown?(id, target) }
            markdown.webView.contextMenu = { [weak self] in self?.contextMenu?() }
            content = markdown
            var directory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: path, isDirectory: &directory) || directory.boolValue {
                started = false
                failure = directory.boolValue ? "\(path) is a folder, not a markdown file" : "No such file: \(path)"
            }
        case .web:
            let web = WebPaneView(url: pane.url ?? "about:blank")
            web.onFocus = { [weak self] in self?.onFocus?(id) }
            web.onNavigate = { [weak self] url in self?.onNavigate?(id, url) }
            web.onURLChange = { [weak self] url in self?.core?.pageMoved(id, to: url) }
            web.webView.contextMenu = { [weak self] in self?.contextMenu?() }
            content = web
        case .ios:
            let ios = IosPaneView()
            ios.onFocus = { [weak self] in self?.onFocus?(id) }
            ios.contextMenu = { [weak self] in self?.contextMenu?() }
            content = ios
            startSimulator(pane, in: ios)
        default:
            let terminal = TerminalSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            terminal.onFocus = { [weak self] in self?.onFocus?(id) }
            terminal.contextMenu = { [weak self] in self?.contextMenu?() }
            let environment = [("KMUX_INSTANCE", instance.name), ("KMUX_SOCKET", instance.socketPath), ("KMUX_PANE", id)]
            started = runtime.attach(terminal, command: pane.command, cwd: pane.cwd, environment: environment)
            content = terminal
        }
        let view = PaneView(id: id, content: content)
        view.grip.onDrag = { [weak self] event in self?.onPaneDrag?(id, event) }
        views[id] = view
        guard pane.type != .ios else { return }
        DispatchQueue.main.async { [weak self] in
            if started { self?.core?.update(id, state: .running) } else { self?.core?.update(id, state: .failed, error: failure) }
        }
    }

    /// Boots the device, launches the app and shows the screen, reporting
    /// `running`, or `failed` with simctl's reason. The simulator stays booted
    /// when the pane closes (other panes or tools may be using it).
    private func startSimulator(_ pane: Pane, in view: IosPaneView) {
        let id = pane.id
        let app = pane.app ?? ""
        let appName = ((app as NSString).lastPathComponent as NSString).deletingPathExtension
        view.show(device: pane.device ?? "iPhone", app: appName)
        view.show(status: "Finding \(pane.device ?? "a device")…")
        Task { @MainActor [weak self] in
            // Still this pane's view? (It may have been closed or restarted meanwhile.)
            let current = { self?.views[id]?.content === view }
            do {
                let device = try await Simulator.resolve(pane.device)
                guard current() else { return }
                pane.device = device.name
                view.show(device: device.name, app: appName)
                view.show(status: "Booting \(device.name)…")
                try await Simulator.boot(device)
                guard current() else { return }
                view.show(status: "Launching \(appName)…")
                let name = try await Simulator.launch(app, on: device)
                guard current() else { return }
                view.show(device: device.name, app: name)
                try view.attach(udid: device.udid)
                self?.core?.update(id, state: .running)
            } catch {
                guard current() else { return }
                view.show(status: nil)
                self?.core?.update(id, state: .failed, error: (error as? Simulator.Failure)?.message ?? error.localizedDescription)
            }
        }
    }

    func stop(_ pane: Pane) {
        guard let view = views.removeValue(forKey: pane.id) else { return }
        if let terminal = view.content as? TerminalSurfaceView { runtime.detach(terminal) }
        (view.content as? WebPaneView)?.stop()
        (view.content as? IosPaneView)?.stop()
        (view.content as? MarkdownPaneView)?.stop()
        view.removeFromSuperview()
    }

    func send(_ pane: Pane, text: String) {
        terminal(pane.id)?.typeLine(text)
    }

    /// A path from a client: `~` expanded; relative paths are relative to home
    /// (the CLI sends absolute paths).
    static func absolute(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : (NSHomeDirectory() as NSString).appendingPathComponent(expanded)
    }

    func paneID(of terminal: TerminalSurfaceView) -> String? {
        views.first { $0.value.content === terminal }?.key
    }
}

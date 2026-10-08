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
    /// The pane's ⋯ grip was pressed: a drag to move the pane begins.
    var onPaneDrag: ((String, NSEvent) -> Void)?

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

    /// The view that should have the keyboard when the pane is focused.
    func keyView(_ id: String) -> NSView? { terminal(id) ?? web(id)?.webView }

    func start(_ pane: Pane) {
        let id = pane.id
        let content: NSView
        var started = true
        switch pane.type {
        case .web:
            let web = WebPaneView(url: pane.url ?? "about:blank")
            web.onFocus = { [weak self] in self?.onFocus?(id) }
            web.onNavigate = { [weak self] url in self?.onNavigate?(id, url) }
            web.onURLChange = { [weak self] url in self?.core?.model.panes[id]?.url = url }
            content = web
        default:
            let terminal = TerminalSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            terminal.onFocus = { [weak self] in self?.onFocus?(id) }
            let environment = [("KMUX_INSTANCE", instance.name), ("KMUX_SOCKET", instance.socketPath), ("KMUX_PANE", id)]
            started = runtime.attach(terminal, command: pane.command, cwd: pane.cwd, environment: environment)
            content = terminal
        }
        let view = PaneView(id: id, content: content)
        view.grip.onDrag = { [weak self] event in self?.onPaneDrag?(id, event) }
        views[id] = view
        DispatchQueue.main.async { [weak self] in
            if started { self?.core?.update(id, state: .running) } else { self?.core?.update(id, state: .failed, error: "Ghostty could not create a terminal") }
        }
    }

    func stop(_ pane: Pane) {
        guard let view = views.removeValue(forKey: pane.id) else { return }
        if let terminal = view.content as? TerminalSurfaceView { runtime.detach(terminal) }
        (view.content as? WebPaneView)?.stop()
        view.removeFromSuperview()
    }

    func send(_ pane: Pane, text: String) {
        terminal(pane.id)?.typeLine(text)
    }

    func paneID(of terminal: TerminalSurfaceView) -> String? {
        views.first { $0.value.content === terminal }?.key
    }
}

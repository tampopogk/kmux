import AppKit
import GhosttyKit
import KmuxCore

/// Owns the model, the control socket and one WindowController per window,
/// and keeps the windows in step with the model.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let core = Core()
    private var instance = Instance(name: Instance.defaultName)
    private var host: ContentHost!
    private var server: SocketServer?
    private var signalSources: [DispatchSourceSignal] = []
    private var controllers: [String: WindowController] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            host = ContentHost(runtime: try GhosttyRuntime())
        } catch {
            fatal("kmux: \(error.localizedDescription)")
        }
        do {
            instance = try Instance.current()
        } catch let error as KmuxError {
            fatal("kmux: \(error.message)")
        } catch {
            fatal("kmux: \(error)")
        }
        core.instance = instance
        host.core = core
        host.instance = instance
        host.onFocus = { [weak self] id in self?.focused(id) }
        host.onNavigate = { [weak self] id, url in self?.request(["cmd": "navigate", "args": ["pane": .string(id), "url": .string(url)]]) }
        host.onPaneDrag = { [weak self] id, _ in self?.dragPane(id) }
        host.onCloseRequest = { [weak self] id in self?.request(["cmd": "close", "args": ["pane": .string(id)]]) }
        core.host = host
        core.onChange = { [weak self] in self?.sync() }
        core.paneIsWide = { [weak self] id in
            guard let bounds = self?.host.views[id]?.bounds, bounds.height > 0 else { return true }
            return bounds.width >= bounds.height
        }
        core.extraCommands["debug.snapshot"] = { [weak self] args in try self?.snapshot(args) ?? [:] }
        core.extraCommands["debug.key"] = { [weak self] args in try self?.pressKey(args) ?? [:] }
        core.extraCommands["debug.click"] = { [weak self] args in try self?.click(args) ?? [:] }
        core.extraCommands["debug.drag"] = { [weak self] args in try await self?.debugDrag(args) ?? [:] }
        core.extraCommands["debug.web"] = { [weak self] args in
            guard let self, let web = try host.web(core.needPane(args["pane"]?.string).id) else { throw KmuxError("wrong_type", "not a web pane") }
            let text = try? await web.webView.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String
            return ["url": web.webView.url.map { .string($0.absoluteString) } ?? nil, "text": .string(text ?? "")]
        }
        core.extraCommands["debug.menu"] = { _ in
            let items = (NSApp.mainMenu?.items ?? []).flatMap { top in
                (top.submenu?.items ?? []).filter { !$0.isSeparatorItem }.map { item -> JSON in
                    let mods = item.keyEquivalentModifierMask
                    let shortcut = (mods.contains(.control) ? "⌃" : "") + (mods.contains(.option) ? "⌥" : "") + (mods.contains(.shift) ? "⇧" : "")
                        + (mods.contains(.command) ? "⌘" : "") + item.keyEquivalent.replacingOccurrences(of: "\r", with: "↩")
                    return ["menu": .string(top.submenu?.title ?? ""), "item": .string(item.title), "shortcut": .string(item.keyEquivalent.isEmpty ? "" : shortcut)]
                }
            }
            return ["items": .array(items)]
        }
        host.runtime.onMuxAction = { [weak self] view, action in
            guard let self, let id = host.paneID(of: view) else { return false }
            return ghosttyAction(id, action)
        }

        let server = SocketServer(path: instance.socketPath) { [weak self] request in await self?.core.handle(request) ?? nil }
        do {
            try server.start()
            self.server = server
        } catch let error as KmuxError {
            fatal("kmux: \(error.message)")
        } catch {
            fatal("kmux: \(error)")
        }
        // Quit cleanly (removing the socket) when killed, not only on ⌘Q.
        for signal in [SIGTERM, SIGINT, SIGHUP] {
            Darwin.signal(signal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
        installMenu()
        NSApp.activate()
        if ProcessInfo.processInfo.environment["KMUX_NO_INITIAL_WINDOW"] == nil { newWindow() }
    }

    func applicationWillTerminate(_ notification: Notification) { server?.stop() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if controllers.isEmpty { newWindow() }
        return true
    }

    // MARK: Model → windows

    private func sync() {
        let ids = Set(core.model.windows.map(\.id))
        for (id, controller) in controllers where !ids.contains(id) {
            controller.window.orderOut(nil)
            controllers[id] = nil
        }
        for state in core.model.windows {
            let controller = controllers[state.id] ?? makeController(state.id)
            controller.render(core.model, host)
        }
        if let key = core.model.key, let controller = controllers[key], !controller.window.isKeyWindow {
            controller.window.makeKeyAndOrderFront(nil)
        }
    }

    private func makeController(_ id: String) -> WindowController {
        let previous = controllers.values.map(\.window).max { $0.orderedIndex > $1.orderedIndex }
        let controller = WindowController(id: id, instance: instance, cascadeFrom: previous)
        controller.relayout = { [weak self, weak controller] in
            guard let self, let controller else { return }
            controller.render(core.model, host)
        }
        controller.tabBar.onSelect = { [weak self] tab in self?.request(["cmd": "focus", "args": ["tab": .string(tab)]]) }
        controller.tabBar.onClose = { [weak self] tab in self?.request(["cmd": "close", "args": ["tab": .string(tab)]]) }
        controller.tabBar.onNew = { [weak self] in self?.newTab(in: id) }
        controller.tabBar.onDrag = { [weak self] tab in self?.dragTab(tab) }
        controller.tabBar.onEditEnded = { [weak self, weak controller] in
            guard let self, let controller else { return }
            controller.render(core.model, host)
        }
        controller.tabBar.onRename = { [weak self] tab, title in
            self?.request(["cmd": "rename-tab", "args": ["tab": .string(tab), "title": .string(title)]])
        }
        controller.onCloseRequest = { [weak self] in self?.request(["cmd": "close", "args": ["window": .string(id)]]) }
        controller.onBecomeKey = { [weak self, weak controller] in
            guard let self, let controller else { return }
            if controller.window.isKeyWindow { core.model.key = id }
            controller.render(core.model, host)
        }
        controllers[id] = controller
        controller.window.makeKeyAndOrderFront(nil)
        return controller
    }

    private func focused(_ paneID: String) {
        guard let window = core.model.windows.first(where: { Model.paneIDs($0.activeTab?.root).contains(paneID) }) else { return }
        guard window.focused != paneID else { return }
        window.focused = paneID
        window.activeTab?.lastFocus = paneID
        controllers[window.id]?.render(core.model, host)
    }

    // MARK: Actions

    private func request(_ request: JSON) {
        Task { @MainActor in
            let reply = await core.handle(request)
            if reply["ok"] != true { NSLog("kmux: \(String(decoding: reply.encoded(), as: UTF8.self))") }
        }
    }

    // MARK: Shortcuts (docs/kmux-spec.md §5). Each acts on the key window.

    private var keyWindow: Window? { core.model.keyWindow }
    private var focusedPane: String? { keyWindow?.focused }

    @objc func splitRight() { split("right") }
    @objc func splitDown() { split("down") }
    @objc func webRight() { split("right", web: true) }
    @objc func webDown() { split("down", web: true) }

    /// ⌘L: edit the focused web pane's URL.
    @objc func openURL() {
        guard let pane = focusedPane else { return }
        host.web(pane)?.editURL()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(openURL) { return focusedPane.flatMap { host.web($0) } != nil }
        return true
    }

    private func split(_ direction: String, web: Bool = false) {
        var args: [String: JSON] = web ? ["type": "web", "url": "http://localhost:3000", "split": .string(direction)] : ["type": "term", "split": .string(direction)]
        if let window = keyWindow?.id { args["window"] = .string(window) }
        guard web else {
            request(["cmd": "open", "args": .object(args)])
            return
        }
        // As in the model: a new web pane starts with its URL selected for editing.
        Task { @MainActor in
            let reply = await core.handle(["cmd": "open", "args": .object(args)])
            if let id = reply["pane"]?["id"]?.string { host.web(id)?.editURL() }
        }
    }

    @objc func nextPane() { cyclePane(1) }
    @objc func previousPane() { cyclePane(-1) }
    private func cyclePane(_ step: Int) {
        guard let window = keyWindow, let pane = core.cyclePane(in: window, by: step) else { return }
        request(["cmd": "focus", "args": ["pane": .string(pane)]])
    }

    @objc func toggleZoom() {
        guard let pane = focusedPane else { return }
        request(["cmd": "zoom", "args": ["pane": .string(pane)]])
    }

    @objc func restartPane() {
        guard let pane = focusedPane else { return }
        request(["cmd": "restart", "args": ["pane": .string(pane)]])
    }

    @objc func closePane() {
        guard let pane = focusedPane else { return }
        request(["cmd": "close", "args": ["pane": .string(pane)]])
    }

    @objc func newTab() { newTab(in: keyWindow?.id) }
    private func newTab(in window: String?) {
        var args: [String: JSON] = ["type": "term", "tab": true]
        if let window { args["window"] = .string(window) }
        request(["cmd": "open", "args": .object(args)])
    }

    @objc func nextTab() { cycleTab(1) }
    @objc func previousTab() { cycleTab(-1) }
    private func cycleTab(_ step: Int) {
        guard let window = keyWindow, let tab = core.cycleTab(in: window, by: step) else { return }
        request(["cmd": "focus", "args": ["tab": .string(tab)]])
    }

    /// Starts another kmux, with its own windows and socket, named 2, 3, ….
    @objc func newInstance() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--instance", Instance.unusedName()]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error { NSLog("kmux: could not start a new instance: \(error)") }
        }
    }

    @objc func newWindow() { request(["cmd": "open", "args": ["type": "term", "window": "new"]]) }

    @objc func closeWindow() {
        guard let window = keyWindow?.id else { return }
        request(["cmd": "close", "args": ["window": .string(window)]])
    }

    @objc func nextWindow() { cycleWindow(1) }
    @objc func previousWindow() { cycleWindow(-1) }
    private func cycleWindow(_ step: Int) {
        let windows = core.model.windows
        guard !windows.isEmpty else { return }
        let at = windows.firstIndex { $0.id == core.model.key } ?? 0
        let next = windows[((at + step) % windows.count + windows.count) % windows.count]
        request(["cmd": "focus", "args": ["window": .string(next.id)]])
    }

    /// Mux actions from Ghostty keybindings that no menu item took.
    private func ghosttyAction(_ paneID: String, _ action: ghostty_action_s) -> Bool {
        let perform: (() -> Void)?
        switch action.tag {
        case GHOSTTY_ACTION_NEW_SPLIT:
            let direction = action.action.new_split
            perform = direction == GHOSTTY_SPLIT_DIRECTION_DOWN || direction == GHOSTTY_SPLIT_DIRECTION_UP ? splitDown : splitRight
        case GHOSTTY_ACTION_GOTO_SPLIT:
            let target = action.action.goto_split
            perform = target == GHOSTTY_GOTO_SPLIT_PREVIOUS || target == GHOSTTY_GOTO_SPLIT_LEFT || target == GHOSTTY_GOTO_SPLIT_UP ? previousPane : nextPane
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM: perform = toggleZoom
        case GHOSTTY_ACTION_NEW_TAB: perform = newTab
        case GHOSTTY_ACTION_GOTO_TAB:
            let target = action.action.goto_tab
            perform = target == GHOSTTY_GOTO_TAB_PREVIOUS ? previousTab : target == GHOSTTY_GOTO_TAB_NEXT ? nextTab : nil
        case GHOSTTY_ACTION_NEW_WINDOW: perform = newWindow
        case GHOSTTY_ACTION_CLOSE_WINDOW: perform = closeWindow
        case GHOSTTY_ACTION_GOTO_WINDOW:
            perform = action.action.goto_window == GHOSTTY_GOTO_WINDOW_PREVIOUS ? previousWindow : nextWindow
        default: perform = nil
        }
        guard let perform else { return false }
        focused(paneID)
        perform()
        return true
    }

    // MARK: Dragging (reference/kmux/index.html: startPaneDrag, startTabDrag)

    private enum Drop {
        case pane(String, side: String) // dock beside a pane, or swap with it
        case tab(String) // a pane into another tab
        case newTab(window: String) // a pane into a new tab (the + button)
        case index(window: String, Int) // a tab to a place in a tab bar
        case newWindow(NSPoint) // anything, outside every kmux window
    }

    /// The kmux window at `point` (screen coordinates), beneath the drop hint.
    private func controller(at point: NSPoint, below hint: DropHint) -> WindowController? {
        // The hint ignores the mouse, so the search normally skips it already.
        var number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        if number == hint.windowNumber { number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: number) }
        return controllers.values.first { $0.window.windowNumber == number }
    }

    /// Where a window torn off at `point` goes: its title bar under the mouse.
    private func newWindowFrame(at point: NSPoint, size: NSSize) -> NSRect {
        NSRect(x: point.x - 40, y: point.y - size.height + 12, width: size.width, height: size.height)
    }

    /// What dropping pane `id` at `point` would do, shown by `hint`: onto
    /// another pane's edge docks beside it, its middle swaps; onto a tab moves
    /// it there, onto + into a new tab; outside kmux into a new window.
    private func paneDrop(_ id: String, at point: NSPoint, hint: DropHint, size: NSSize) -> Drop? {
        guard let controller = controller(at: point, below: hint) else {
            hint.show(newWindowFrame(at: point, size: size), text: "new window", rounded: true)
            return .newWindow(point)
        }
        let window = controller.window, inWindow = window.convertPoint(fromScreen: point)
        let bar = controller.tabBar, inBar = bar.convert(inWindow, from: nil)
        if bar.bounds.contains(inBar) {
            let home = core.model.windows.flatMap(\.tabs).first { Model.paneIDs($0.root).contains(id) }?.id
            guard let (tab, frame) = bar.target(at: inBar), tab != home else {
                hint.hide()
                return nil
            }
            hint.show(window.convertToScreen(bar.convert(frame, to: nil)), text: tab == nil ? "+" : "")
            return tab.map(Drop.tab) ?? .newTab(window: controller.id)
        }
        for view in host.views.values where view.window === window && view.superview != nil && view.id != id {
            let p = view.convert(inWindow, from: nil), b = view.bounds
            guard b.contains(p) else { continue }
            let fx = p.x / b.width, fy = 1 - p.y / b.height
            var side = "swap"
            if !(fx > 0.3 && fx < 0.7 && fy > 0.3 && fy < 0.7) {
                side = [("left", fx), ("right", 1 - fx), ("top", fy), ("bottom", 1 - fy)].min { $0.1 < $1.1 }!.0
            }
            let area = switch side {
            case "left": NSRect(x: 0, y: 0, width: b.width / 2, height: b.height)
            case "right": NSRect(x: b.width / 2, y: 0, width: b.width / 2, height: b.height)
            case "top": NSRect(x: 0, y: b.height / 2, width: b.width, height: b.height / 2)
            case "bottom": NSRect(x: 0, y: 0, width: b.width, height: b.height / 2)
            default: b
            }
            hint.show(window.convertToScreen(view.convert(area, to: nil)), text: side == "swap" ? "swap" : "")
            return .pane(view.id, side: side)
        }
        hint.hide()
        return nil
    }

    /// What dropping tab `id` at `point` would do: into a tab bar at the gap
    /// nearest the mouse, or outside kmux into a new window.
    private func tabDrop(at point: NSPoint, hint: DropHint, size: NSSize) -> Drop? {
        guard let controller = controller(at: point, below: hint) else {
            hint.show(newWindowFrame(at: point, size: size), text: "new window", rounded: true)
            return .newWindow(point)
        }
        let bar = controller.tabBar, inBar = bar.convert(controller.window.convertPoint(fromScreen: point), from: nil)
        guard bar.bounds.contains(inBar) else {
            hint.hide()
            return nil
        }
        let (index, x) = bar.insertion(at: inBar.x)
        hint.show(controller.window.convertToScreen(bar.convert(NSRect(x: x - 1, y: 4, width: 3, height: TabBar.height - 8), to: nil)))
        return .index(window: controller.id, index)
    }

    @discardableResult
    private func dragPane(_ id: String) -> Task<Void, Never>? {
        guard let size = host.views[id]?.window?.frame.size else { return nil }
        let hint = DropHint()
        let end = trackMouse { _ = paneDrop(id, at: $0, hint: hint, size: size) }
        let drop = paneDrop(id, at: end, hint: hint, size: size)
        hint.hide()
        var args: [String: JSON] = ["pane": .string(id)]
        switch drop {
        case .pane(let to, let side): args["to"] = .string(to); args["side"] = .string(side)
        case .tab(let tab): args["tab"] = .string(tab)
        case .newTab(let window): args["tab"] = "new"; args["window"] = .string(window)
        case .newWindow: args["window"] = "new"
        case .index, nil: return nil
        }
        return perform(["cmd": "move", "args": .object(args)], tornOff: drop, size: size)
    }

    @discardableResult
    private func dragTab(_ id: String) -> Task<Void, Never>? {
        guard let window = core.model.windows.first(where: { $0.tabs.contains { $0.id == id } }), let size = controllers[window.id]?.window.frame.size else { return nil }
        let hint = DropHint()
        let end = trackMouse { _ = tabDrop(at: $0, hint: hint, size: size) }
        let drop = tabDrop(at: end, hint: hint, size: size)
        hint.hide()
        switch drop {
        case .index(let window, let index):
            return perform(["cmd": "move-tab", "args": ["tab": .string(id), "window": .string(window), "index": .number(Double(index))]], tornOff: nil, size: size)
        case .newWindow:
            return perform(["cmd": "move-tab", "args": ["tab": .string(id), "window": "new"]], tornOff: drop, size: size)
        default: return nil
        }
    }

    /// Sends a drag's request; a new window opens where the drag ended.
    private func perform(_ request: JSON, tornOff drop: Drop?, size: NSSize) -> Task<Void, Never> {
        Task { @MainActor in
            let reply = await core.handle(request)
            guard reply["ok"] == true else { return NSLog("kmux: \(String(decoding: reply.encoded(), as: UTF8.self))") }
            if case .newWindow(let point)? = drop, let id = reply["window"]?.string, let controller = controllers[id] {
                controller.window.setFrame(newWindowFrame(at: point, size: size), display: true)
            }
        }
    }

    /// Replays a drag along scripted mouse positions (for tests):
    /// `{pane: P, to: TARGET}`, `{tab: T, to: TARGET}` or `{divider: P, at: FRACTION}`
    /// (the divider after pane P, moved to that fraction of the pair). TARGET is
    /// `{pane: P, x, y}` (fractions from the top left), `{tab: T}`, `{plus: WINDOW}`
    /// or `{outside: true}` (beyond every kmux window).
    private func debugDrag(_ args: JSON) async throws -> [String: JSON] {
        func post(_ points: [NSPoint]) { scriptedDrag = points }
        func screen(_ view: NSView, _ point: NSPoint) throws -> NSPoint {
            guard let window = view.window else { throw KmuxError("not_found", "not on screen") }
            return window.convertPoint(toScreen: view.convert(point, to: nil))
        }
        // Other apps' windows may cover kmux's while tests run (and an inactive
        // app can't come to the front), so float above them for the drag.
        let windows = controllers.values.map(\.window)
        windows.forEach {
            $0.level = .popUpMenu
            $0.orderFrontRegardless()
        }
        DropHint.level = .screenSaver
        defer {
            windows.forEach { $0.level = .normal }
            DropHint.level = .floating
        }
        if let ref = args["divider"]?.string {
            let pane = try core.needPane(ref)
            guard let (controller, handle) = controllers.values.lazy.compactMap({ c in
                c.dividers.first { if case .pane(pane.id) = $0.split.kids[$0.index].node { true } else { false } }.map { (c, $0) }
            }).first, let stage = handle.superview else { throw KmuxError("not_found", "no divider after \(pane.id)") }
            let to = try screen(stage, handle.position(CGFloat(args["at"]?.number ?? 0.5)))
            post([to, to])
            handle.drag(in: stage)
            controller.render(core.model, host)
            return [:]
        }
        let to: NSPoint
        let target = args["to"] ?? [:]
        if let ref = target["pane"]?.string {
            guard let view = host.views[try core.needPane(ref).id] else { throw KmuxError("not_found", "no pane \(ref)") }
            let b = view.bounds
            to = try screen(view, NSPoint(x: b.width * CGFloat(target["x"]?.number ?? 0.5), y: b.height * (1 - CGFloat(target["y"]?.number ?? 0.5))))
        } else if let tab = target["tab"]?.string ?? target["plus"]?.string {
            guard let controller = controllers.values.first(where: { target["plus"] != nil ? $0.id == tab : $0.tabBar.center(of: tab) != nil }) else { throw KmuxError("not_found", "no tab bar for \(tab)") }
            let point = target["plus"] != nil ? controller.tabBar.plusCenter : controller.tabBar.convert(controller.tabBar.center(of: tab)!, from: nil)
            to = try screen(controller.tabBar, point)
        } else {
            let screenFrame = NSScreen.main?.visibleFrame ?? .zero
            let corners = [NSPoint(x: screenFrame.maxX - 30, y: screenFrame.minY + 30), NSPoint(x: screenFrame.minX + 30, y: screenFrame.minY + 30),
                           NSPoint(x: screenFrame.maxX - 30, y: screenFrame.maxY - 30), NSPoint(x: screenFrame.minX + 30, y: screenFrame.maxY - 30)]
            guard let free = corners.first(where: { p in !controllers.values.contains { $0.window.frame.contains(p) } }) else {
                throw KmuxError("bad_request", "every corner of the screen is covered by a kmux window")
            }
            to = free
        }
        try await Task.sleep(for: .milliseconds(150)) // let the window server catch up
        post([to, to])
        let task: Task<Void, Never>?
        if let ref = args["pane"]?.string {
            task = dragPane(try core.needPane(ref).id)
        } else if let tab = args["tab"]?.string {
            task = dragTab(tab)
        } else {
            throw KmuxError("bad_request", "debug.drag needs pane, tab or divider")
        }
        await task?.value
        let under = NSWindow.windowNumber(at: to, belowWindowWithWindowNumber: 0)
        let owner = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(under)) as? [[String: Any]])?.first?[kCGWindowOwnerName as String] as? String
        let window = controllers.values.first { $0.window.windowNumber == under }?.id
        return ["dropped": .bool(task != nil), "at": [.number(to.x), .number(to.y)], "under": .string(window ?? owner ?? "\(under)")]
    }

    private func snapshot(_ args: JSON) throws -> [String: JSON] {
        let window = try core.targetWindow(args["window"])
        guard let controller = controllers[window.id] else { throw KmuxError("not_found", "no window \"\(window.id)\"") }
        controller.window.displayIfNeeded()
        let panes = Model.paneIDs(window.activeTab?.root).compactMap { host.views[$0] }.filter { $0.window != nil }
        return try Snapshot.run(controller, panes: panes, path: args["path"]?.string, marker: args["marker"]?.string)
    }

    private func installMenu() {
        let runtime = host.runtime
        let main = NSMenu()
        func menu(_ title: String, _ items: [(String, Selector, String?, Shortcut?)?]) -> NSMenu {
            let item = NSMenuItem()
            let submenu = NSMenu(title: title)
            for entry in items {
                guard let (label, action, ghostty, fallback) = entry else {
                    submenu.addItem(.separator())
                    continue
                }
                let shortcut = ghostty.flatMap { runtime.shortcut(for: $0) } ?? fallback
                let menuItem = submenu.addItem(withTitle: label, action: action, keyEquivalent: shortcut?.key ?? "")
                menuItem.keyEquivalentModifierMask = shortcut?.modifiers ?? []
                menuItem.target = self
            }
            item.submenu = submenu
            main.addItem(item)
            return submenu
        }
        let app = menu("kmux", [("New Instance", #selector(newInstance), nil, nil)])
        if !instance.isDefault { app.insertItem(withTitle: "Instance: \(instance.name)", action: nil, keyEquivalent: "", at: 0) }
        app.addItem(.separator())
        app.addItem(withTitle: "Quit kmux", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        _ = menu("Pane", [
            ("Split Right", #selector(splitRight), "new_split:right", .cmd("d")),
            ("Split Down", #selector(splitDown), "new_split:down", .shiftCmd("d")),
            ("New Web Pane Right", #selector(webRight), nil, nil),
            ("New Web Pane Below", #selector(webDown), nil, nil),
            ("Open URL…", #selector(openURL), nil, .cmd("l")),
            nil,
            ("Next Pane", #selector(nextPane), "goto_split:next", .cmd("]")),
            ("Previous Pane", #selector(previousPane), "goto_split:previous", .cmd("[")),
            ("Zoom", #selector(toggleZoom), "toggle_split_zoom", .shiftCmd("\r")),
            nil,
            ("Restart", #selector(restartPane), nil, .cmd("r")),
            ("Close Pane", #selector(closePane), "close_surface", .cmd("w")),
        ])
        _ = menu("View", [
            ("New Tab", #selector(newTab as () -> Void), "new_tab", .cmd("t")),
            ("Next Tab", #selector(nextTab), "next_tab", .shiftCmd("]")),
            ("Previous Tab", #selector(previousTab), "previous_tab", .shiftCmd("[")),
        ])
        let windowMenu = menu("Window", [
            ("New Window", #selector(newWindow), "new_window", .cmd("n")),
            ("Close Window", #selector(closeWindow), "close_window", .shiftCmd("w")),
            nil,
            ("Next Window", #selector(nextWindow), nil, .cmd("`")),
            ("Previous Window", #selector(previousWindow), nil, .shiftCmd("`")),
            nil,
        ])
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    /// `debug.key`: delivers a key press through AppKit's normal event path,
    /// as if typed into the key window (e.g. "cmd+shift+d").
    private func pressKey(_ args: JSON) throws -> [String: JSON] {
        guard let name = args["key"]?.string else { throw KmuxError("bad_request", "debug.key needs a key") }
        let window = core.model.key.flatMap { controllers[$0]?.window }
        guard let event = SyntheticKey.event(name, window: window) else { throw KmuxError("bad_request", "unknown key \"\(name)\"") }
        NSApp.sendEvent(event)
        return ["characters": .string(event.characters ?? ""), "charactersIgnoringModifiers": .string(event.charactersIgnoringModifiers ?? "")]
    }

    /// `debug.click`: clicks a tab (`tab`, `clicks`) with mouse events sent
    /// through AppKit's normal event path.
    private func click(_ args: JSON) throws -> [String: JSON] {
        let id = args["tab"]?.string ?? ""
        guard let state = core.model.windows.first(where: { $0.tabs.contains { $0.id == id } }), let controller = controllers[state.id],
              let point = controller.tabBar.center(of: id) else { throw KmuxError("not_found", "no tab \"\(id)\" on screen") }
        let window = controller.window
        for count in 1...max(1, Int(args["clicks"]?.number ?? 1)) {
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)
            }
            // Queue the mouse-up first: a tab waits for it to tell a click from a drag.
            guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { continue }
            NSApp.postEvent(up, atStart: false)
            NSApp.sendEvent(down)
        }
        return [:]
    }

    private func fatal(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

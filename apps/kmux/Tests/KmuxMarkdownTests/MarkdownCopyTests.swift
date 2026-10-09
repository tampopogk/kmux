import AppKit
import Testing
@testable import KmuxMarkdown

/// kmux has no Edit menu, so a markdown pane answers ⌘C and ⌘A itself.
@MainActor
struct MarkdownCopyTests {
    private func key(_ characters: String, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
    }

    @Test func commandCCopiesTheSelection() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let text = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        text.isEditable = false
        text.string = "Hello, kmux"
        text.pasteboard = NSPasteboard(name: NSPasteboard.Name("kmux-test-\(UUID().uuidString)"))
        defer { text.pasteboard.releaseGlobally() }
        window.contentView = text
        #expect(window.makeFirstResponder(text))

        #expect(text.performKeyEquivalent(with: key("a", in: window)))
        #expect(text.selectedRange().length == 11)
        #expect(text.performKeyEquivalent(with: key("c", in: window)))
        #expect(text.pasteboard.string(forType: .string) == "Hello, kmux")
    }

    @Test func otherViewsKeepTheirKeys() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let text = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = NSView()
        window.contentView?.addSubview(text)
        // Not first responder (a terminal beside it is): ⌘C isn't the text view's.
        #expect(!text.performKeyEquivalent(with: key("c", in: window)))
    }
}

/// A two-finger swipe sideways navigates only once the page can't scroll that way.
struct MarkdownSwipeTests {
    @Test func swipesOnlyAtTheEdge() {
        let page = NSRect(x: 0, y: 0, width: 800, height: 2000)
        // Actual size: the whole width shows, so both ways navigate.
        #expect(MarkdownScrollView.swipes(back: true, visible: NSRect(x: 0, y: 0, width: 800, height: 600), page: page))
        #expect(MarkdownScrollView.swipes(back: false, visible: NSRect(x: 0, y: 0, width: 800, height: 600), page: page))
        // Magnified and panned to the middle: both ways pan instead.
        let middle = NSRect(x: 200, y: 0, width: 400, height: 300)
        #expect(!MarkdownScrollView.swipes(back: true, visible: middle, page: page))
        #expect(!MarkdownScrollView.swipes(back: false, visible: middle, page: page))
        // At the left edge: back navigates, forward pans.
        let left = NSRect(x: 0, y: 0, width: 400, height: 300)
        #expect(MarkdownScrollView.swipes(back: true, visible: left, page: page))
        #expect(!MarkdownScrollView.swipes(back: false, visible: left, page: page))
        // Zoomed out, the page sits in the middle of a wider view: both navigate.
        #expect(MarkdownScrollView.swipes(back: false, visible: NSRect(x: -200, y: 0, width: 1200, height: 900), page: page))
    }
}

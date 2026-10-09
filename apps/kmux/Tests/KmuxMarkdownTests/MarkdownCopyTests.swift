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

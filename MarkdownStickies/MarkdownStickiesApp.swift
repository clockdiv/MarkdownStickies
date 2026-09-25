import SwiftUI
import AppKit

@main
struct MarkdownStickiesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = NoteStore()

    var body: some Scene {
        Window("Markdown Stickies", id: "control") {
            ControlWindowView()
                .environmentObject(store)
                .background(ControlWindowIdentifier())
                .onAppear {
                    store.start()
                    appDelegate.noteStore = store
                }
        }
        .defaultSize(width: 360, height: 480)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note…") {
                    store.promptCreateNote()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Notes Window") {
                    AppDelegate.toggleControlWindow()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Close Note") {
                    store.windowManager.closeFocusedSticky()
                }
                .keyboardShortcut("w", modifiers: [.command])
            }
        }
    }
}

/// Identifies the overview window; traffic-light close hides instead of destroying it
/// so ⌘O can bring it back.
private struct ControlWindowIdentifier: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.identifier = NSUserInterfaceItemIdentifier("control")
            window.setFrameAutosaveName("ControlWindow")
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            context.coordinator.attach(to: window)
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var window: NSWindow?
        private weak var previousDelegate: NSWindowDelegate?

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            previousDelegate = window.delegate
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
            return false
        }

        override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) { return true }
            return previousDelegate?.responds(to: aSelector) ?? false
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            previousDelegate
        }
    }
}

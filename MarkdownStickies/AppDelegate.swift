import AppKit
import SwiftUI

extension Notification.Name {
    static let showControlWindow = Notification.Name("MarkdownStickies.showControlWindow")
    static let toggleControlWindow = Notification.Name("MarkdownStickies.toggleControlWindow")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var noteStore: NoteStore?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            AppDelegate.sharedIntercept(event)
        }
    }

    /// Stickies are panels — hiding the overview must not quit the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        noteStore?.prepareToTerminate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            Self.showControlWindow()
        }
        return true
    }

    static func showControlWindow() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = controlWindow() else { return }
        window.makeKeyAndOrderFront(nil)
    }

    static func toggleControlWindow() {
        guard let window = controlWindow() else { return }
        if window.isVisible {
            window.orderOut(nil)
        } else {
            showControlWindow()
        }
    }

    /// Called from the key monitor; hops to the main actor.
    private nonisolated static func sharedIntercept(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command,
              event.charactersIgnoringModifiers?.lowercased() == "w" else {
            return event
        }

        if Thread.isMainThread {
            return MainActor.assumeIsolated { Self.handleCommandW(event) }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { Self.handleCommandW(event) }
        }
    }

    private static func handleCommandW(_ event: NSEvent) -> NSEvent? {
        guard let key = NSApp.keyWindow else { return event }
        if isControlWindow(key) {
            return nil
        }
        let delegate = NSApp.delegate as? AppDelegate
        if delegate?.noteStore?.windowManager.closeFocusedSticky() == true {
            return nil
        }
        return event
    }

    static func isControlWindow(_ window: NSWindow?) -> Bool {
        guard let window, !(window is NSPanel) else { return false }
        if window.identifier?.rawValue == "control" { return true }
        return window.title == "Markdown Stickies"
    }

    static func controlWindow() -> NSWindow? {
        NSApp.windows.first(where: { isControlWindow($0) })
    }
}

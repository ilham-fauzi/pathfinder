import SwiftUI
import AppKit

/// Keeps the main window between the app's normal size and the visible area of the display it is on.
/// Native full-screen mode is turned off. Double-clicking the title bar (or the browser's address bar
/// background) fills the desktop; double-clicking again restores the previous size.
struct WindowSizer: NSViewRepresentable {
    /// The size a window starts at (and returns to after "fill the desktop"): enough for the home screen.
    static let normalSize = NSSize(width: 720, height: 500)
    /// The least the window may shrink to (content size). It follows the screen being shown.
    var minimum = WindowSizer.normalSize

    /// Home needs little room; results and lists need a thumbnail beside the quality rows, and the Advanced
    /// mode and the browser need the full layout. The window grows to the new minimum when the screen changes.
    @MainActor
    static func minimumSize(for state: AppState, downloadsHeight: CGFloat) -> NSSize {
        let large = NSSize(width: 900, height: 650)
        switch state.section {
        case .player: return NSSize(width: 560, height: 300)
        case .settings: return NSSize(width: 700, height: 480)
        case .browser: return large
        case .downloader:
            guard state.mode == .simple else { return large }
            if state.currentVideoInfo != nil || state.isAnalyzing || state.listing != nil {
                return NSSize(width: 900, height: 600 + max(0, downloadsHeight - 110))
            }
            // The downloads panel sits under the home screen and takes room from it.
            return NSSize(width: 700, height: downloadsHeight > 0 ? 480 + max(80, downloadsHeight - 30) : 480)
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = SizerView()
        view.minimum = minimum
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? SizerView)?.minimum = minimum }

    /// Fill the desktop, or go back to the size the window had before.
    @MainActor
    static func toggleFill(_ window: NSWindow? = NSApp.keyWindow ?? NSApp.mainWindow) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let isFilled = abs(window.frame.width - visible.width) < 3 && abs(window.frame.height - visible.height) < 3
        if isFilled {
            let target = savedFrames[ObjectIdentifier(window)] ?? NSRect(
                x: visible.midX - normalSize.width / 2, y: visible.midY - normalSize.height / 2,
                width: normalSize.width, height: normalSize.height)
            window.setFrame(target, display: true, animate: true)
            savedFrames[ObjectIdentifier(window)] = nil
        } else {
            savedFrames[ObjectIdentifier(window)] = window.frame
            window.setFrame(visible, display: true, animate: true)
        }
    }

    @MainActor private static var savedFrames: [ObjectIdentifier: NSRect] = [:]

    private final class SizerView: NSView {
        private var observers: [NSObjectProtocol] = []
        private var clickMonitor: Any?

        var minimum = WindowSizer.normalSize {
            didSet { if minimum != oldValue, let window { apply(to: window, grow: true) } }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
            guard let window else { return }
            apply(to: window)
            // Windows saved at the old, larger default start compact once; after that the user's size is kept.
            if !UserDefaults.standard.bool(forKey: "compactWindowApplied") {
                UserDefaults.standard.set(true, forKey: "compactWindowApplied")
                resize(window, toContent: NSSize(width: max(WindowSizer.normalSize.width, minimum.width),
                                                 height: max(WindowSizer.normalSize.height, minimum.height)), animate: false)
            }

            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reapply() }
                },
                center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reapply() }
                },
            ]
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                let swallow = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return swallow ? nil : event
            }
        }

        private func reapply() { if let window { apply(to: window) } }

        private func apply(to window: NSWindow, grow: Bool = false) {
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 3000, height: 2000)
            window.contentMinSize = minimum
            window.maxSize = NSSize(width: max(visible.width, minimum.width), height: max(visible.height, minimum.height))
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
            if grow {
                let content = window.contentRect(forFrameRect: window.frame).size
                let target = NSSize(width: max(content.width, minimum.width), height: max(content.height, minimum.height))
                if target != content { resize(window, toContent: target, animate: true) }
            }
        }

        /// Sets the content size, keeping the window's top-left corner where it is.
        private func resize(_ window: NSWindow, toContent size: NSSize, animate: Bool) {
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                frame.origin.y = max(frame.origin.y, visible.minY)
                frame.origin.x = min(frame.origin.x, visible.maxX - frame.width)
            }
            window.setFrame(frame, display: true, animate: animate)
        }

        /// A double-click on empty title-bar space toggles fill/restore. Clicks on toolbar controls pass through.
        /// Returns true when the click was used (and should not reach the system).
        private func handle(_ event: NSEvent) -> Bool {
            guard event.clickCount == 2, let window, event.window === window,
                  event.locationInWindow.y >= window.contentLayoutRect.maxY,
                  let frameView = window.contentView?.superview else { return false }
            var view = frameView.hitTest(frameView.convert(event.locationInWindow, from: nil))
            while let v = view {
                if v is NSControl { return false }
                view = v.superview
            }
            WindowSizer.toggleFill(window)
            return true
        }
    }
}

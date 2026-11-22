import AppKit
import Observation
import SwiftUI

/// Owns the floating preview panel and its player.
@MainActor @Observable
final class PreviewController: NSObject, NSWindowDelegate {
    private(set) var isOpen = false
    private(set) var isFullScreen = false
    /// `nil` when libmpv could not be started; the panel then explains why.
    @ObservationIgnored let player: MPVPlayer?
    @ObservationIgnored let playerError: String?
    @ObservationIgnored private var panel: PreviewPanel?
    @ObservationIgnored private var windowedFrame: NSRect?

    private static let frameName = "PreviewPanel"

    override init() {
        do {
            player = try MPVPlayer()
            playerError = nil
        } catch {
            player = nil
            playerError = error.localizedDescription
        }
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification, object: nil
        )
    }

    var window: NSWindow? { panel }

    func open(model: AppModel) {
        let panel = self.panel ?? makePanel(model: model)
        self.panel = panel
        panel.orderFront(nil)
        isOpen = true
    }

    func close() {
        panel?.close()
    }

    /// Puts a file in the preview, or clears it. See `MPVPlayer.present` for what `autoplay` means.
    func show(_ url: URL?, autoplay: Bool) {
        guard isOpen, let player else { return }
        if let url {
            player.present(url, autoplay: autoplay)
        } else {
            player.stop()
        }
    }

    /// Fills the panel's screen with the preview, or puts it back where it was.
    ///
    /// The panel covers the screen in place rather than using a full-screen Space, so it stays a
    /// floating panel and switching is instant. Its title bar ends up just above the top edge.
    func toggleFullScreen() {
        guard isOpen, let panel else { return }
        if isFullScreen {
            leaveFullScreen()
            return
        }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        windowedFrame = panel.frame
        isFullScreen = true
        panel.allowsFrameBeyondScreen = true
        panel.styleMask.remove(.resizable)
        panel.isMovable = false
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        panel.setFrame(panel.frameRect(forContentRect: screen.frame), display: true)
    }

    private func leaveFullScreen() {
        guard isFullScreen, let panel else { return }
        NSApp.presentationOptions = []
        panel.allowsFrameBeyondScreen = false
        panel.styleMask.insert(.resizable)
        panel.isMovable = true
        if let windowedFrame {
            panel.setFrame(windowedFrame, display: true)
        }
        windowedFrame = nil
        // Only now: frame changes reported while restoring must not be remembered as the panel's place.
        isFullScreen = false
        saveFrame()
    }

    private func makePanel(model: AppModel) -> PreviewPanel {
        let panel = PreviewPanel(
            contentRect: NSRect(origin: .zero, size: PreviewView.defaultSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        panel.title = "Preview"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // Clicking in the preview must not steal keyboard focus from the file list.
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self

        let content = ClickThroughHostingView(rootView: PreviewView(model: model, controller: self))
        // Keep the panel from shrinking below its controls, but let it grow freely.
        content.sizingOptions = [.minSize]
        panel.contentView = content

        // Size and position are remembered; the first time it opens in the top-right corner.
        if !panel.setFrameUsingName(Self.frameName), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - panel.frame.width - 24, y: visible.maxY - 24))
        }
        return panel
    }

    private func saveFrame() {
        guard !isFullScreen, let panel else { return }
        panel.saveFrame(usingName: Self.frameName)
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveFrame()
    }

    func windowWillClose(_ notification: Notification) {
        leaveFullScreen()
        saveFrame()
        isOpen = false
        player?.stop()
    }

    @objc private func applicationWillTerminate() {
        player?.shutdown()
    }
}

private final class PreviewPanel: NSPanel {
    /// Set while the panel covers the screen, where its title bar must be allowed off the top edge.
    var allowsFrameBeyondScreen = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsFrameBeyondScreen ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

/// The panel is rarely the key window, so its controls must act on the first click.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

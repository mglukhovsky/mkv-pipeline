import AppKit
import SwiftUI

@main
struct MKVPipelineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @LocalState private var model = AppModel()

    var body: some Scene {
        Window("MKV Pipeline", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1200, minHeight: 540)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    // Picks up changes made elsewhere, e.g. a title edited in MKVToolNix.
                    model.rescan()
                }
        }
        .defaultSize(width: 1280, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose MKV folder…") { model.chooseMKVFolder() }
                    .keyboardShortcut("o")
                Button("Choose archive folder…") { model.chooseArchiveFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Refresh metadata") { model.refreshMetadata() }
                    .keyboardShortcut("r")
                    .disabled(model.mkvFolder == nil)
            }
            CommandGroup(after: .textEditing) {
                Button("Filter files") { model.focusSearch() }
                    .keyboardShortcut("f")
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard shortcuts") { model.isShowingShortcuts.toggle() }
            }
            CommandMenu("MKV") {
                Button("Open") { model.selectedFile.map(model.openInDefaultApp) }
                    .disabled(model.selectedFile == nil)
                Button("Preview") { model.openPreview() }
                    .keyboardShortcut("y")
                Button("Edit MKV headers") { model.selectedFile.map(model.editHeaders) }
                    .keyboardShortcut("e")
                    .disabled(!model.canModifySelectedFile)
                Button("Archive…") { model.selectedFile.map(model.requestArchive) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!model.canModifySelectedFile)
                Divider()
                Button("Show in Finder") { model.selectedFile.map(model.revealInFinder) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.selectedFile == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets `swift run` behave like the bundled app: Dock icon, menu bar, key window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

import AppKit

enum MKVToolNix {
    private static let bundleIdentifier = "download.mkvtoolnix.MKVToolNix"

    @MainActor static var applicationURL: URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }
        let fallback = URL(fileURLWithPath: "/Applications/MKVToolNix.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    /// Opens the file in MKVToolNix GUI's header editor.
    @MainActor static func editHeaders(
        of file: URL, using application: URL, onFailure: @escaping @MainActor (String) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--edit-headers", file.path]
        // Arguments only reach a newly launched process. When MKVToolNix is
        // already running, the new instance hands them to it and exits.
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: application, configuration: configuration) { _, error in
            guard let message = error?.localizedDescription else { return }
            Task { @MainActor in onFailure(message) }
        }
    }
}

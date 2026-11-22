import Foundation

public enum MKVPropEditError: LocalizedError, Equatable {
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let reason): reason
        }
    }
}

/// Edits Matroska headers in place with MKVToolNix's `mkvpropedit`.
public enum MKVPropEdit {
    /// The copy inside MKVToolNix.app when there is one, otherwise a Homebrew install.
    public static func locateTool(mkvToolNixApp: URL? = nil) -> URL? {
        var candidates = [
            "/Applications/MKVToolNix.app/Contents/MacOS/mkvpropedit",
            "/opt/homebrew/bin/mkvpropedit",
            "/usr/local/bin/mkvpropedit",
        ].map { URL(fileURLWithPath: $0) }
        if let mkvToolNixApp {
            candidates.insert(mkvToolNixApp.appendingPathComponent("Contents/MacOS/mkvpropedit"), at: 0)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Writes the segment title; an empty title removes it. Returns when `mkvpropedit` has finished.
    public static func setSegmentTitle(_ title: String, of file: URL, tool: URL) throws {
        let process = Process()
        process.executableURL = tool
        // The charsets are spelled out because an app launched from Finder has no locale in its environment.
        process.arguments = ["--command-line-charset", "UTF-8", "--output-charset", "UTF-8", file.path, "--edit", "info"]
            + (title.isEmpty ? ["--delete", "title"] : ["--set", "title=\(title)"])
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw MKVPropEditError.failed("mkvpropedit could not be started: \(error.localizedDescription)")
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        // 0 is success and 1 is success with warnings; anything else left the file unchanged.
        guard process.terminationStatus > 1 else { return }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let reason = lines.last { $0.hasPrefix("Error:") }?.dropFirst("Error:".count).trimmingCharacters(in: .whitespaces)
            ?? lines.last
            ?? "mkvpropedit exited with status \(process.terminationStatus)."
        throw MKVPropEditError.failed(reason)
    }
}

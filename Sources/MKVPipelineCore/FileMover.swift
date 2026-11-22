import Foundation

public enum ArchiveCategory: String, CaseIterable, Identifiable, Sendable {
    case movies = "Movies"
    case documentaries = "Documentaries"
    case tvShows = "TV Shows"

    public var id: String { rawValue }
    /// Name of the child folder inside the archive folder.
    public var folderName: String { rawValue }
}

public enum FileMoveError: LocalizedError, Equatable {
    case destinationExists(URL)
    case cancelled
    case verificationFailed(URL)
    case sourceNotRemoved(source: URL, destination: URL, reason: String)
    case system(operation: String, path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .destinationExists(let url):
            "“\(url.lastPathComponent)” already exists in “\(url.deletingLastPathComponent().lastPathComponent)”."
        case .cancelled:
            "The move was cancelled."
        case .verificationFailed(let url):
            "The copy of “\(url.lastPathComponent)” did not match the original, so the original was left in place."
        case .sourceNotRemoved(let source, let destination, let reason):
            "“\(source.lastPathComponent)” was copied to \(destination.path), but the original could not be removed: \(reason)"
        case .system(let operation, let path, let code):
            "Could not \(operation) \(path): \(String(cString: strerror(code)))"
        }
    }
}

/// Moves a file into a directory without ever overwriting or leaving a
/// half-written file under the final name.
public enum FileMover {
    public enum Strategy: Sendable {
        /// Rename in place when possible, copy across volumes otherwise.
        case automatic
        /// Always take the cross-volume path. Exists so that path can be tested on one volume.
        case copy
    }

    public typealias Progress = (_ bytesCopied: Int64, _ totalBytes: Int64) -> Void

    @discardableResult
    public static func move(
        _ source: URL,
        intoDirectory directory: URL,
        strategy: Strategy = .automatic,
        progress: Progress = { _, _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> URL {
        let destination = directory.appendingPathComponent(source.lastPathComponent, isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if strategy == .automatic {
            do {
                try renameExclusively(from: source, to: destination)
                return destination
            } catch FileMoveError.system(_, _, EXDEV) {
                // Different volume: fall through to copy.
            }
        } else if FileManager.default.fileExists(atPath: destination.path) {
            throw FileMoveError.destinationExists(destination)
        }

        let partial = directory.appendingPathComponent(".\(source.lastPathComponent).mkvpipeline-partial", isDirectory: false)
        do {
            try copyContents(of: source, to: partial, progress: progress, isCancelled: isCancelled)
            try renameExclusively(from: partial, to: destination)
        } catch {
            unlink(partial.path)
            throw error
        }

        guard unlink(source.path) == 0 else {
            throw FileMoveError.sourceNotRemoved(
                source: source, destination: destination, reason: String(cString: strerror(errno))
            )
        }
        return destination
    }

    private static func renameExclusively(from source: URL, to destination: URL) throws {
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return }
        switch errno {
        case EEXIST:
            throw FileMoveError.destinationExists(destination)
        case ENOTSUP, EINVAL:
            // Volume without RENAME_EXCL support (e.g. some network shares).
            if FileManager.default.fileExists(atPath: destination.path) {
                throw FileMoveError.destinationExists(destination)
            }
            guard rename(source.path, destination.path) == 0 else {
                throw FileMoveError.system(operation: "move", path: source.path, code: errno)
            }
        default:
            throw FileMoveError.system(operation: "move", path: source.path, code: errno)
        }
    }

    private static func copyContents(
        of source: URL, to partial: URL, progress: Progress, isCancelled: () -> Bool
    ) throws {
        let input = open(source.path, O_RDONLY)
        guard input >= 0 else { throw FileMoveError.system(operation: "read", path: source.path, code: errno) }
        defer { close(input) }

        var info = stat()
        guard fstat(input, &info) == 0 else {
            throw FileMoveError.system(operation: "read", path: source.path, code: errno)
        }
        let total = Int64(info.st_size)

        // A leftover partial can only be ours, from an interrupted earlier attempt.
        unlink(partial.path)
        let output = open(partial.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard output >= 0 else { throw FileMoveError.system(operation: "write", path: partial.path, code: errno) }
        var outputIsOpen = true
        defer { if outputIsOpen { close(output) } }

        let bufferSize = 4 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16_384)
        defer { buffer.deallocate() }

        var copied: Int64 = 0
        var lastReport = Date.distantPast
        progress(0, total)
        while true {
            if isCancelled() { throw FileMoveError.cancelled }
            let readCount = read(input, buffer, bufferSize)
            if readCount == 0 { break }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw FileMoveError.system(operation: "read", path: source.path, code: errno)
            }
            var written = 0
            while written < readCount {
                let count = write(output, buffer + written, readCount - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw FileMoveError.system(operation: "write", path: partial.path, code: errno)
                }
                written += count
            }
            copied += Int64(readCount)
            if Date().timeIntervalSince(lastReport) > 0.1 {
                lastReport = Date()
                progress(copied, total)
            }
        }

        guard fsync(output) == 0 else {
            throw FileMoveError.system(operation: "write", path: partial.path, code: errno)
        }
        outputIsOpen = false
        guard close(output) == 0 else {
            throw FileMoveError.system(operation: "write", path: partial.path, code: errno)
        }

        var written = stat()
        guard stat(partial.path, &written) == 0, Int64(written.st_size) == total, copied == total else {
            throw FileMoveError.verificationFailed(source)
        }
        progress(total, total)

        // Best effort: extended attributes (Finder tags…), permissions and dates.
        // A destination volume that cannot hold them must not fail the move.
        copyfile(source.path, partial.path, nil, copyfile_flags_t(COPYFILE_METADATA))
        if let attributes = try? FileManager.default.attributesOfItem(atPath: source.path) {
            let dates = attributes.filter { $0.key == .creationDate || $0.key == .modificationDate }
            try? FileManager.default.setAttributes(dates, ofItemAtPath: partial.path)
        }
    }
}

import Foundation

public struct ScannedFile: Hashable, Sendable {
    public let url: URL
    public let relativePath: String
    public let fileSize: Int64
    public let created: Date?
    public let modified: Date?
}

public enum MKVScanner {
    /// Finds `.mkv` files under `root`, skipping hidden files and any directory in `excluding`.
    public static func scan(root: URL, recursive: Bool, excluding: [URL] = []) throws -> [ScannedFile] {
        let root = root.standardizedFileURL
        // Surfaces a real error (missing folder, no permission) instead of an empty listing.
        _ = try FileManager.default.contentsOfDirectory(atPath: root.path)

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }

        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: options, errorHandler: { _, _ in true }
        ) else { return [] }

        let rootComponents = root.pathComponents
        let excluded = Set(excluding.map { $0.standardizedFileURL.path })
        var files: [ScannedFile] = []

        for case let item as URL in enumerator {
            let url = item.standardizedFileURL
            if excluded.contains(url.path) {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "mkv",
                  let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }

            files.append(ScannedFile(
                url: url,
                relativePath: url.pathComponents.dropFirst(rootComponents.count).joined(separator: "/"),
                fileSize: Int64(values.fileSize ?? 0),
                created: values.creationDate,
                modified: values.contentModificationDate
            ))
        }
        return files
    }
}

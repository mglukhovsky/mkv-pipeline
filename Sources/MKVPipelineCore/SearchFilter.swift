import Foundation

/// Case-insensitive regular-expression filter over a file's name, relative path and segment title.
public struct SearchFilter: @unchecked Sendable {
    public let pattern: String
    // NSRegularExpression is immutable and documented as thread-safe.
    private let regex: NSRegularExpression

    public init(pattern: String) throws {
        self.pattern = pattern
        self.regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    public func matches(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public func matches(_ file: MKVFile) -> Bool {
        if matches(file.filename) || matches(file.relativePath) { return true }
        // An absent title is not an empty match target: `^$` should not select every untitled file.
        return !file.segmentTitle.isEmpty && matches(file.segmentTitle)
    }
}

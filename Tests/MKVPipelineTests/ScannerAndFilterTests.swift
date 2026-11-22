import Foundation
import Testing
@testable import MKVPipelineCore

@Suite struct MKVScannerTests {
    private func makeTree() throws -> TemporaryDirectory {
        let tree = try TemporaryDirectory()
        try tree.file("top.mkv", contents: "12345")
        try tree.file("UPPER.MKV")
        try tree.file("notes.txt")
        try tree.file(".hidden.mkv")
        try tree.file("Shows/Season 1/ep1.mkv")
        try tree.file("Archive/Movies/done.mkv")
        try FileManager.default.createDirectory(at: tree.url.appendingPathComponent("folder.mkv"), withIntermediateDirectories: true)
        return tree
    }

    @Test func nonRecursiveScanListsOnlyTopLevelMKVFiles() throws {
        let tree = try makeTree()
        let files = try MKVScanner.scan(root: tree.url, recursive: false)

        #expect(Set(files.map(\.relativePath)) == ["top.mkv", "UPPER.MKV"])
        let top = try #require(files.first { $0.relativePath == "top.mkv" })
        #expect(top.fileSize == 5)
        #expect(top.modified != nil)
        #expect(top.url.path == tree.url.standardizedFileURL.appendingPathComponent("top.mkv").path)
    }

    @Test func recursiveScanDescendsAndSkipsExcludedFolders() throws {
        let tree = try makeTree()
        let all = try MKVScanner.scan(root: tree.url, recursive: true)
        #expect(Set(all.map(\.relativePath)) == ["top.mkv", "UPPER.MKV", "Shows/Season 1/ep1.mkv", "Archive/Movies/done.mkv"])

        let withoutArchive = try MKVScanner.scan(
            root: tree.url, recursive: true, excluding: [tree.url.appendingPathComponent("Archive/Movies")]
        )
        #expect(Set(withoutArchive.map(\.relativePath)) == ["top.mkv", "UPPER.MKV", "Shows/Season 1/ep1.mkv"])
    }

    @Test func missingFolderIsAnErrorRatherThanAnEmptyResult() throws {
        let tree = try makeTree()
        #expect(throws: (any Error).self) {
            try MKVScanner.scan(root: tree.url.appendingPathComponent("nope"), recursive: true)
        }
    }
}

@Suite struct SearchFilterTests {
    private func file(_ relativePath: String, title: String? = nil) -> MKVFile {
        MKVFile(
            url: URL(fileURLWithPath: "/media/\(relativePath)"), relativePath: relativePath, fileSize: 1,
            media: .loaded(MediaDetails(segmentTitle: title))
        )
    }

    @Test func matchesNamePathAndTitleCaseInsensitively() throws {
        let episode = file("Shows/Season 1/Show S01E02.mkv", title: "Second Episode")

        #expect(try SearchFilter(pattern: #"s\d{2}e\d{2}"#).matches(episode))
        #expect(try SearchFilter(pattern: "^show").matches(episode), "anchors apply to the filename")
        #expect(try SearchFilter(pattern: "^shows/season").matches(episode), "…and to the relative path")
        #expect(try SearchFilter(pattern: "episode$").matches(episode), "…and to the segment title")
        #expect(try !SearchFilter(pattern: "(movie|film)").matches(episode))
    }

    @Test func missingTitleIsNotMatchedAsEmptyText() throws {
        #expect(try !SearchFilter(pattern: "^$").matches(file("a.mkv")))
    }

    @Test func invalidPatternThrows() {
        #expect(throws: (any Error).self) { try SearchFilter(pattern: "(unclosed") }
    }
}

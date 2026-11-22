import Foundation
import Testing
@testable import MKVPipelineCore

@Suite struct FileMoverTests {
    private func hiddenLeftovers(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".") }
    }

    @Test(arguments: [FileMover.Strategy.automatic, .copy])
    func movesFileIntoANewlyCreatedFolder(strategy: FileMover.Strategy) throws {
        let scratch = try TemporaryDirectory()
        let source = try scratch.file("incoming/film.mkv", contents: String(repeating: "matroska", count: 50_000))
        let folder = scratch.url.appendingPathComponent("Archive/TV Shows")
        let modified = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.path)

        let reported = ProgressLog()
        let destination = try FileMover.move(source, intoDirectory: folder, strategy: strategy) { copied, total in
            reported.append(copied, total)
        }

        #expect(destination == folder.appendingPathComponent("film.mkv"))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try String(contentsOf: destination, encoding: .utf8).count == 400_000)
        #expect(try hiddenLeftovers(in: folder).isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect(attributes[.modificationDate] as? Date == modified)
        if strategy == .copy {
            #expect(reported.last?.0 == 400_000)
            #expect(reported.last?.1 == 400_000)
        }
    }

    @Test(arguments: [FileMover.Strategy.automatic, .copy])
    func neverOverwritesAnExistingFile(strategy: FileMover.Strategy) throws {
        let scratch = try TemporaryDirectory()
        let source = try scratch.file("film.mkv", contents: "new")
        let existing = try scratch.file("Movies/film.mkv", contents: "already archived")

        #expect(throws: FileMoveError.destinationExists(existing)) {
            try FileMover.move(source, intoDirectory: existing.deletingLastPathComponent(), strategy: strategy)
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "already archived")
        #expect(try String(contentsOf: source, encoding: .utf8) == "new")
    }

    @Test func cancellingACopyLeavesTheSourceAndNoPartialFile() throws {
        let scratch = try TemporaryDirectory()
        let source = try scratch.file("film.mkv", contents: "payload")
        let folder = scratch.url.appendingPathComponent("Movies")

        #expect(throws: FileMoveError.cancelled) {
            try FileMover.move(source, intoDirectory: folder, strategy: .copy, isCancelled: { true })
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}

private final class ProgressLog: @unchecked Sendable {
    private var entries: [(Int64, Int64)] = []
    func append(_ copied: Int64, _ total: Int64) { entries.append((copied, total)) }
    var last: (Int64, Int64)? { entries.last }
}

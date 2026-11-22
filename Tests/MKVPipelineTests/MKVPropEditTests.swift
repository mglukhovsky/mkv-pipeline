import Foundation
import Testing
@testable import MKVPipeline
@testable import MKVPipelineCore

/// These need MKVToolNix's mkvpropedit (MKVToolNix.app or Homebrew) and are skipped without it.
@Suite(.enabled(if: MKVPropEdit.locateTool() != nil))
struct MKVPropEditTests {
    private func copyOfFixture(in directory: TemporaryDirectory, named name: String = "film.mkv") throws -> URL {
        let fixture = try #require(Bundle.module.url(forResource: "tiny", withExtension: "mkv", subdirectory: "Fixtures"))
        let file = directory.url.appendingPathComponent(name)
        try FileManager.default.copyItem(at: fixture, to: file)
        return file
    }

    private func title(of file: URL) -> String? {
        guard case .loaded(let details) = MediaInfoReader.read(file) else { return nil }
        return details.segmentTitle
    }

    @Test func writesReplacesAndRemovesTheSegmentTitle() throws {
        let directory = try TemporaryDirectory()
        let file = try copyOfFixture(in: directory, named: "Ünï film.mkv")
        let tool = try #require(MKVPropEdit.locateTool())

        try MKVPropEdit.setSegmentTitle("Amélie = 日本語 ✓ --set title=x", of: file, tool: tool)
        #expect(title(of: file) == "Amélie = 日本語 ✓ --set title=x")

        try MKVPropEdit.setSegmentTitle("", of: file, tool: tool)
        #expect(title(of: file) == nil)
        // The rest of the file is untouched.
        guard case .loaded(let details) = MediaInfoReader.read(file) else {
            Issue.record("the edited file no longer reads as Matroska")
            return
        }
        #expect(details.audioTracks.map(\.language) == ["en", "de"])
        #expect(details.video?.width == 64)
    }

    @Test func reportsWhyAFileCouldNotBeEdited() throws {
        let directory = try TemporaryDirectory()
        let garbage = try directory.file("garbage.mkv", contents: String(repeating: "not matroska ", count: 300))
        let tool = try #require(MKVPropEdit.locateTool())

        #expect {
            try MKVPropEdit.setSegmentTitle("x", of: garbage, tool: tool)
        } throws: { error in
            (error as? MKVPropEditError).map { "\($0.localizedDescription)".contains("not a Matroska file") } ?? false
        }
    }

    @MainActor @Test func editingATitleInTheAppUpdatesTheFileAndTheList() async throws {
        let directory = try TemporaryDirectory()
        let file = try copyOfFixture(in: directory)
        _ = try copyOfFixture(in: directory, named: "other.mkv")
        let model = AppModel(defaults: InMemoryDefaults())
        defer { model.preview.player?.shutdown() }
        model.mkvFolder = directory.url
        try await waitUntil { !model.isScanning && model.files.count == 2 && model.pendingMediaCount == 0 }
        let entry = try #require(model.visibleFiles.first { $0.filename == "film.mkv" })
        model.selection = entry.id

        model.setSegmentTitle("  Renamed Here  ", for: entry)
        #expect(!model.canModify(entry), "no archiving or second edit while the file is being written")
        #expect(model.activities.map(\.summary) == ["Updating the title of “film.mkv”"])

        try await waitUntil { model.titleWrites.isEmpty && !model.isScanning && model.pendingMediaCount == 0 }
        #expect(model.selectedFile?.segmentTitle == "Renamed Here")
        #expect(title(of: file) == "Renamed Here")
        #expect(model.files.first { $0.filename == "other.mkv" }?.segmentTitle == "Tiny Fixture")
        #expect(model.alert == nil)

        // Saving an unchanged title does nothing.
        let current = try #require(model.selectedFile)
        model.setSegmentTitle("Renamed Here", for: current)
        #expect(model.titleWrites.isEmpty)
    }
}

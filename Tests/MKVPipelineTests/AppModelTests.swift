import AppKit
import Testing
@testable import MKVPipeline
@testable import MKVPipelineCore

@MainActor @Suite struct AppModelTests {
    /// A model on in-memory preferences, with three copies of the fixture to list.
    private final class Scene {
        let tree: TemporaryDirectory
        let model: AppModel
        private let defaults = InMemoryDefaults()

        @MainActor init() throws {
            tree = try TemporaryDirectory()
            let fixture = try #require(Bundle.module.url(forResource: "tiny", withExtension: "mkv", subdirectory: "Fixtures"))
            for name in ["Alpha S01E01.mkv", "Beta (2019).mkv", "Sub/Gamma S01E02.mkv"] {
                let file = tree.url.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: fixture, to: file)
            }
            model = AppModel(defaults: defaults)
        }

        @MainActor func makeSecondModel() -> AppModel {
            AppModel(defaults: defaults)
        }

        @MainActor func settle(fileCount: Int) async throws {
            try await waitUntil { [model] in
                !model.isScanning && model.files.count == fileCount && model.pendingMediaCount == 0
            }
        }

        @MainActor func tearDown() {
            model.preview.player?.shutdown()
        }
    }

    @Test func listsFolderReadsMediaInfoAndFiltersByRegularExpression() async throws {
        let scene = try Scene()
        defer { scene.tearDown() }
        let model = scene.model

        model.mkvFolder = scene.tree.url
        try await scene.settle(fileCount: 2)
        #expect(model.visibleFiles.map(\.relativePath) == ["Alpha S01E01.mkv", "Beta (2019).mkv"])

        model.isRecursive = true
        try await scene.settle(fileCount: 3)
        #expect(model.visibleFiles.map(\.relativePath) == ["Alpha S01E01.mkv", "Beta (2019).mkv", "Sub/Gamma S01E02.mkv"])
        #expect(model.visibleFiles.allSatisfy { $0.segmentTitle == "Tiny Fixture" })
        #expect(model.visibleFiles.allSatisfy { $0.audioSummary == "en, de" && $0.resolutionText == "64×36" })

        model.selection = model.visibleFiles[1].id
        model.searchText = #"s\d\de\d\d"#
        #expect(model.visibleFiles.map(\.filename) == ["Alpha S01E01.mkv", "Gamma S01E02.mkv"])
        #expect(model.selection == nil, "a filtered-out file does not stay selected")

        model.searchText = #"s\d\de\d\d("#
        #expect(model.searchError != nil)
        #expect(model.visibleFiles.count == 2, "an unfinished pattern keeps the last valid filter")
        #expect(!model.canSaveCurrentSearch)

        model.searchText = ""
        #expect(model.visibleFiles.count == 3)
    }

    @Test func archivingMovesTheFileAndSelectsTheNextRow() async throws {
        let scene = try Scene()
        defer { scene.tearDown() }
        let model = scene.model
        let archive = scene.tree.url.appendingPathComponent("Archive")

        model.isRecursive = true
        model.mkvFolder = scene.tree.url
        model.archiveFolder = archive
        try await scene.settle(fileCount: 3)

        let alpha = try #require(model.visibleFiles.first)
        model.selection = alpha.id
        model.archive(alpha, to: .tvShows)
        try await waitUntil { model.archiveJobs.isEmpty && model.files.count == 2 }

        #expect(FileManager.default.fileExists(atPath: archive.appendingPathComponent("TV Shows/Alpha S01E01.mkv").path))
        #expect(!FileManager.default.fileExists(atPath: alpha.url.path))
        #expect(model.selectedFile?.filename == "Beta (2019).mkv")
        #expect(model.alert == nil)

        // The archive lives inside the scanned folder here; archived files must not be listed again.
        model.rescan()
        try await scene.settle(fileCount: 2)
    }

    @Test func typedFolderPathsAreAppliedOnlyWhenTheyNameAFolder() async throws {
        let scene = try Scene()
        defer { scene.tearDown() }
        let model = scene.model

        #expect(model.setMKVFolder(path: "  \(scene.tree.url.path)/ "))
        try await scene.settle(fileCount: 2)
        let folder = try #require(model.mkvFolder)

        #expect(!model.setMKVFolder(path: folder.appendingPathComponent("Beta (2019).mkv").path), "a file is not a folder")
        #expect(!model.setMKVFolder(path: "relative/path"))
        #expect(model.mkvFolder == folder)
        #expect(model.alert != nil)

        #expect(model.setArchiveFolder(path: folder.appendingPathComponent("Sub").path))
        #expect(model.archiveFolder?.lastPathComponent == "Sub")
        #expect(model.setArchiveFolder(path: ""))
        #expect(model.archiveFolder == nil)
    }

    @Test func refreshingMetadataReadsUnchangedFilesAgain() async throws {
        let scene = try Scene()
        defer { scene.tearDown() }
        let model = scene.model
        model.mkvFolder = scene.tree.url
        try await scene.settle(fileCount: 2)

        model.rescan()
        try await waitUntil { !model.isScanning }
        #expect(model.pendingMediaCount == 0, "an ordinary rescan keeps what it already knows")
        let reported = ActivityLog(model)
        model.refreshMetadata()
        #expect(model.pendingMediaCount == 2)
        #expect(model.activities.map(\.id) == ["scan"])
        #expect(model.activities.first?.fraction == nil, "listing a folder has no measurable progress")

        try await scene.settle(fileCount: 2)
        #expect(model.activities.isEmpty)
        // Once the folder has been listed, progress counts the files being read.
        let reading = reported.activities.filter { $0.id == "media" }
        #expect(reading.first?.summary == "Reading media info: 0 of 2 files")
        #expect(reading.first?.fraction == 0)
        #expect(reading.allSatisfy { ($0.fraction ?? -1) >= 0 && ($0.fraction ?? 2) <= 1 })
        #expect(model.visibleFiles.allSatisfy { $0.segmentTitle == "Tiny Fixture" })
    }

    @Test func archiveShortcutAsksWhereToArchiveTheSelectedFile() async throws {
        let scene = try Scene()
        defer { scene.tearDown() }
        let model = scene.model
        model.mkvFolder = scene.tree.url
        model.archiveFolder = scene.tree.url.appendingPathComponent("Archive")
        try await scene.settle(fileCount: 2)

        // Stands in for the main window; it is never shown.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        func press(_ key: String, modifiers: NSEvent.ModifierFlags = []) throws -> Bool {
            model.handleKeyDown(try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0
            )))
        }

        #expect(try press("a"))
        #expect(model.archiveRequest == nil, "nothing is selected")

        let file = try #require(model.visibleFiles.first)
        model.selection = file.id
        #expect(try !press("a", modifiers: .command), "⌘A stays Select All")
        #expect(model.archiveRequest == nil)
        #expect(try press("a"))
        #expect(model.archiveRequest == file)
    }

    @Test func savedSearchesPersistAcrossLaunches() throws {
        let scene = try Scene()
        defer { scene.tearDown() }

        scene.model.searchText = #"\.2160p\."#
        scene.model.saveCurrentSearch()
        scene.model.saveCurrentSearch()
        scene.model.searchText = "("
        scene.model.saveCurrentSearch()

        let relaunched = scene.makeSecondModel()
        defer { relaunched.preview.player?.shutdown() }
        #expect(relaunched.savedSearches == [#"\.2160p\."#])
    }
}

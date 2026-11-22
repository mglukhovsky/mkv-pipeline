import AppKit
import MKVPipelineCore
import Observation

struct AlertInfo: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// An archive move in flight for one file.
@MainActor @Observable
final class ArchiveJob {
    let filename: String
    let category: ArchiveCategory
    var fraction: Double = 0
    @ObservationIgnored var task: Task<Void, Never>?

    init(filename: String, category: ArchiveCategory) {
        self.filename = filename
        self.category = category
    }
}

/// Something the app is busy with, for the status bar.
struct Activity: Identifiable, Equatable {
    let id: String
    var summary: String
    /// 0…1, or `nil` when there is no way to tell how far along it is.
    var fraction: Double?
}

@MainActor @Observable
final class AppModel {
    private enum Key {
        static let mkvFolder = "mkvFolderPath"
        static let recursive = "scanRecursively"
        static let archiveFolder = "archiveFolderPath"
        static let savedSearches = "savedSearches"
    }

    // MARK: Settings

    var mkvFolder: URL? {
        didSet {
            guard mkvFolder != oldValue else { return }
            defaults.set(mkvFolder?.path, forKey: Key.mkvFolder)
            selection = nil
            files = []
            rescan()
        }
    }

    var isRecursive: Bool {
        didSet {
            guard isRecursive != oldValue else { return }
            defaults.set(isRecursive, forKey: Key.recursive)
            rescan()
        }
    }

    var archiveFolder: URL? {
        didSet {
            guard archiveFolder != oldValue else { return }
            defaults.set(archiveFolder?.path, forKey: Key.archiveFolder)
            // Archive destinations are excluded from the listing, so the set of files may change.
            rescan()
        }
    }

    private(set) var savedSearches: [String] {
        didSet { defaults.set(savedSearches, forKey: Key.savedSearches) }
    }

    // MARK: Search

    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            applySearch()
        }
    }
    /// Set while `searchText` is not a valid regular expression; the last valid filter stays in effect.
    private(set) var searchError: String?
    /// Incremented to ask the search field to take keyboard focus.
    private(set) var searchFocusRequests = 0

    // MARK: Files

    private(set) var files: [MKVFile] = [] {
        didSet { refreshVisibleFiles() }
    }
    /// `files` after filtering and sorting: what the grid shows.
    private(set) var visibleFiles: [MKVFile] = []

    var sortOrder = [KeyPathComparator(\MKVFile.filename, comparator: .localizedStandard)] {
        didSet { refreshVisibleFiles() }
    }

    var selection: MKVFile.ID? {
        didSet {
            guard selection != oldValue else { return }
            schedulePreviewUpdate()
        }
    }

    private(set) var isScanning = false
    /// Progress of the current pass over files whose media info is still to be read.
    private(set) var mediaLoad: (completed: Int, total: Int, latest: String?)?
    private(set) var scanError: String?
    private(set) var archiveJobs: [MKVFile.ID: ArchiveJob] = [:]
    /// Files whose segment title is being written right now.
    private(set) var titleWrites: Set<MKVFile.ID> = []

    /// File whose Archive dialog is showing.
    var archiveRequest: MKVFile?
    var alert: AlertInfo?
    /// The keyboard-shortcut list, shown over the preview when it is open and over the main window otherwise.
    var isShowingShortcuts = false

    let preview = PreviewController()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var activeFilter: SearchFilter?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var keyMonitor: Any?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mkvFolder = defaults.string(forKey: Key.mkvFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
        isRecursive = defaults.bool(forKey: Key.recursive)
        archiveFolder = defaults.string(forKey: Key.archiveFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
        savedSearches = defaults.stringArray(forKey: Key.savedSearches) ?? []
        rescan()
    }

    // MARK: - Derived state

    var selectedFile: MKVFile? {
        guard let selection else { return nil }
        return files.first { $0.id == selection }
    }

    func file(withID id: MKVFile.ID) -> MKVFile? {
        files.first { $0.id == id }
    }

    /// What is in progress right now, in the order it should be reported.
    var activities: [Activity] {
        var activities: [Activity] = []
        if isScanning, let folder = mkvFolder {
            activities.append(Activity(
                id: "scan", summary: "Scanning “\(folder.lastPathComponent)” for MKV files", fraction: nil
            ))
        } else if let load = mediaLoad, load.total > 0 {
            var summary = "Reading media info: \(load.completed) of \(load.total) files"
            if let latest = load.latest { summary += " (\(latest))" }
            activities.append(Activity(
                id: "media", summary: summary, fraction: Double(load.completed) / Double(load.total)
            ))
        }
        for id in titleWrites.sorted() {
            activities.append(Activity(
                id: "title:\(id)",
                summary: "Updating the title of “\((id as NSString).lastPathComponent)”",
                fraction: nil
            ))
        }
        for (id, job) in archiveJobs.sorted(by: { $0.value.filename < $1.value.filename }) {
            activities.append(Activity(
                id: "archive:\(id)",
                summary: "Archiving “\(job.filename)” to \(job.category.folderName)",
                fraction: job.fraction
            ))
        }
        return activities
    }

    var pendingMediaCount: Int {
        files.count { $0.media == .pending }
    }

    /// Editing or archiving is held off while the file is already being archived or written to.
    func canModify(_ file: MKVFile) -> Bool {
        archiveJobs[file.id] == nil && !titleWrites.contains(file.id)
    }

    var canModifySelectedFile: Bool {
        selectedFile.map(canModify) ?? false
    }

    var canSaveCurrentSearch: Bool {
        !searchText.isEmpty && searchError == nil && !savedSearches.contains(searchText)
    }

    // MARK: - Folders

    func chooseMKVFolder() {
        if let url = chooseFolder(message: "Choose the folder that contains your MKV files", current: mkvFolder) {
            mkvFolder = url
        }
    }

    func chooseArchiveFolder() {
        let message = "Choose the archive folder. Movies, Documentaries and TV Shows are created inside it."
        if let url = chooseFolder(message: message, current: archiveFolder) {
            archiveFolder = url
        }
    }

    /// Sets the MKV folder from a typed path. Returns false, leaving the setting alone, if it is not a folder.
    @discardableResult
    func setMKVFolder(path: String) -> Bool {
        guard let folder = folder(fromTypedPath: path) else { return false }
        mkvFolder = folder.url
        return true
    }

    /// Sets the archive folder from a typed path. Returns false, leaving the setting alone, if it is not a folder.
    @discardableResult
    func setArchiveFolder(path: String) -> Bool {
        guard let folder = folder(fromTypedPath: path) else { return false }
        archiveFolder = folder.url
        return true
    }

    private struct TypedFolder {
        /// `nil` when the field was emptied to clear the setting.
        var url: URL?
    }

    /// An empty path clears the setting; anything else must name an existing folder (`~` is expanded).
    private func folder(fromTypedPath text: String) -> TypedFolder? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return TypedFolder(url: nil) }
        let path = (trimmed as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            alert = AlertInfo(
                title: "“\(trimmed)” is not a folder",
                message: "Type the full path of an existing folder, or use Change… to pick one."
            )
            return nil
        }
        return TypedFolder(url: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL)
    }

    private func chooseFolder(message: String, current: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "Choose"
        panel.directoryURL = current
        return panel.runModal() == .OK ? panel.url?.standardizedFileURL : nil
    }

    // MARK: - Scanning

    /// Re-reads the folder and every file's media info, including files that look unchanged.
    func refreshMetadata() {
        files = files.map { file in
            var file = file
            file.media = .pending
            return file
        }
        rescan()
    }

    /// Re-reads the MKV folder. Files whose size and modification date are unchanged keep their media info.
    func rescan() {
        scanTask?.cancel()
        mediaLoad = nil
        guard let folder = mkvFolder else {
            files = []
            scanError = nil
            isScanning = false
            return
        }
        let recursive = isRecursive
        let excluded = ArchiveCategory.allCases.compactMap { category in
            archiveFolder?.appendingPathComponent(category.folderName, isDirectory: true)
        }
        isScanning = true
        scanTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> ScanOutcome in
                do {
                    return .found(try MKVScanner.scan(root: folder, recursive: recursive, excluding: excluded))
                } catch {
                    return .failed(error.localizedDescription)
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.isScanning = false
            switch outcome {
            case .found(let scanned):
                self.scanError = nil
                self.merge(scanned)
            case .failed(let message):
                self.scanError = message
                self.files = []
            }
            await self.loadPendingMedia()
        }
    }

    private enum ScanOutcome: Sendable {
        case found([ScannedFile])
        case failed(String)
    }

    private func merge(_ scanned: [ScannedFile]) {
        let existing = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        files = scanned.map { item in
            var file = MKVFile(
                url: item.url, relativePath: item.relativePath, fileSize: item.fileSize,
                created: item.created, modified: item.modified
            )
            if let known = existing[file.id], known.fileSize == item.fileSize, known.modified == item.modified {
                file.media = known.media
            }
            return file
        }
    }

    private func loadPendingMedia() async {
        let pending = files.filter { $0.media == .pending }.map(\.url)
        guard !pending.isEmpty else { return }
        mediaLoad = (0, pending.count, nil)
        let batchSize = 16
        for start in stride(from: 0, to: pending.count, by: batchSize) {
            let batch = pending[start..<min(start + batchSize, pending.count)]
            let results = await withTaskGroup(of: (String, MediaState).self) { group in
                for url in batch {
                    group.addTask { (url.path, MediaInfoReader.read(url)) }
                }
                var states: [String: MediaState] = [:]
                for await (id, state) in group {
                    states[id] = state
                    // A superseded pass must not report into the progress of the one that replaced it.
                    if !Task.isCancelled, let load = mediaLoad {
                        mediaLoad = (load.completed + 1, load.total, (id as NSString).lastPathComponent)
                    }
                }
                return states
            }
            if Task.isCancelled { return }
            // One assignment per batch: each one re-filters and re-sorts the grid.
            var updated = files
            for index in updated.indices {
                if let state = results[updated[index].id] { updated[index].media = state }
            }
            files = updated
        }
        mediaLoad = nil
    }

    private func refreshVisibleFiles() {
        var result = files
        if let activeFilter {
            result = result.filter(activeFilter.matches)
        }
        visibleFiles = result.sorted(using: sortOrder)
        if let selection, !visibleFiles.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    // MARK: - Search

    private func applySearch() {
        if searchText.isEmpty {
            activeFilter = nil
            searchError = nil
        } else {
            do {
                activeFilter = try SearchFilter(pattern: searchText)
                searchError = nil
            } catch {
                searchError = "Not a valid regular expression"
            }
        }
        refreshVisibleFiles()
    }

    func saveCurrentSearch() {
        guard canSaveCurrentSearch else { return }
        savedSearches.append(searchText)
    }

    func removeSavedSearch(_ search: String) {
        savedSearches.removeAll { $0 == search }
    }

    func focusSearch() {
        searchFocusRequests += 1
    }

    // MARK: - Preview

    /// An explicit request to preview: opens the panel if needed and plays the file.
    func openPreview(for file: MKVFile? = nil) {
        if let file { selection = file.id }
        preview.open(model: self)
        // Supersedes the paused load that changing the selection has just scheduled.
        previewTask?.cancel()
        preview.show(selectedFile?.url, autoplay: true)
    }

    func togglePreview() {
        if preview.isOpen {
            preview.close()
        } else {
            openPreview()
        }
    }

    /// Follows the selection without starting playback, briefly debounced so arrowing through the list does not open every file on the way.
    private func schedulePreviewUpdate() {
        guard preview.isOpen else { return }
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            self.preview.show(self.selectedFile?.url, autoplay: false)
        }
    }

    // MARK: - Keyboard shortcuts

    /// Starts handling the single-key shortcuts in the main window and the preview.
    func installKeyboardShortcuts() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // AppKit delivers key events on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
            return handled ? nil : event
        }
    }

    /// Returns true if the key press was a shortcut and has been dealt with.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let window = event.window, takesShortcuts(window),
              // Typing in the filter or a path field is never a shortcut.
              !(window.firstResponder is NSText)
        else { return false }

        if event.charactersIgnoringModifiers == "\u{1B}" {
            if isShowingShortcuts {
                isShowingShortcuts = false
                return true
            }
            if preview.isFullScreen {
                preview.toggleFullScreen()
                return true
            }
            return false
        }
        guard let shortcut = AppShortcut.matching(
            characters: event.charactersIgnoringModifiers, specialKey: event.specialKey
        ) else { return false }
        return perform(shortcut, isRepeat: event.isARepeat)
    }

    /// The main window and the preview, but not sheets, alerts or file dialogs.
    private func takesShortcuts(_ window: NSWindow) -> Bool {
        if window === preview.window { return true }
        return !(window is NSPanel) && window.sheetParent == nil && window.attachedSheet == nil
    }

    private func perform(_ shortcut: AppShortcut, isRepeat: Bool) -> Bool {
        // Without the preview, playback keys keep their normal meaning.
        if shortcut.needsPreview && !preview.isOpen { return false }
        // Holding a key down repeats skips and volume steps, nothing else.
        let repeats = [.skipBack, .skipForward, .volumeUp, .volumeDown].contains(shortcut)
        if isRepeat && !repeats { return true }

        let player = preview.player
        switch shortcut {
        case .help: isShowingShortcuts.toggle()
        case .togglePreview: togglePreview()
        case .open: selectedFile.map(openInDefaultApp)
        case .editHeaders: if canModifySelectedFile { selectedFile.map(editHeaders) }
        case .archive: if canModifySelectedFile { selectedFile.map(requestArchive) }
        case .fullScreen: preview.toggleFullScreen()
        case .playPause: player?.togglePlayPause()
        case .slower: player?.stepRate(by: -1)
        case .faster: player?.stepRate(by: 1)
        case .skipBack: player?.skip(by: -60)
        case .skipForward: player?.skip(by: 60)
        case .volumeUp: player?.adjustVolume(by: 10)
        case .volumeDown: player?.adjustVolume(by: -10)
        }
        return true
    }

    // MARK: - Actions

    /// Opens the file in whatever application is set to open MKV files.
    func openInDefaultApp(_ file: MKVFile) {
        if !NSWorkspace.shared.open(file.url) {
            alert = AlertInfo(
                title: "“\(file.filename)” could not be opened",
                message: "No application is set to open this kind of file, or the file is no longer there."
            )
        }
    }

    func revealInFinder(_ file: MKVFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    func editHeaders(_ file: MKVFile) {
        guard let application = MKVToolNix.applicationURL else {
            alert = AlertInfo(
                title: "MKVToolNix was not found",
                message: "Install MKVToolNix (https://mkvtoolnix.download) in the Applications folder to edit MKV headers."
            )
            return
        }
        MKVToolNix.editHeaders(of: file.url, using: application) { [weak self] message in
            self?.alert = AlertInfo(title: "MKVToolNix could not be opened", message: message)
        }
    }

    /// Writes a new segment title into the file's headers; an empty title removes it.
    func setSegmentTitle(_ newTitle: String, for file: MKVFile) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title != file.segmentTitle, canModify(file) else { return }
        guard let tool = MKVPropEdit.locateTool(mkvToolNixApp: MKVToolNix.applicationURL) else {
            alert = AlertInfo(
                title: "mkvpropedit was not found",
                message: "Install MKVToolNix (https://mkvtoolnix.download) in the Applications folder to change segment titles."
            )
            return
        }
        let url = file.url
        let fileID = file.id
        titleWrites.insert(fileID)
        Task { [weak self] in
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try MKVPropEdit.setSegmentTitle(title, of: url, tool: tool)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self else { return }
            self.titleWrites.remove(fileID)
            if let failure {
                self.alert = AlertInfo(title: "The title of “\(url.lastPathComponent)” could not be changed", message: failure)
            }
            // The file changed on disk; this reads its headers again.
            self.rescan()
        }
    }

    func requestArchive(_ file: MKVFile) {
        guard archiveJobs[file.id] == nil else { return }
        guard archiveFolder != nil else {
            alert = AlertInfo(
                title: "No archive folder is set",
                message: "Choose an archive folder in the top bar first. Movies, Documentaries and TV Shows are created inside it."
            )
            return
        }
        archiveRequest = file
    }

    func archive(_ file: MKVFile, to category: ArchiveCategory) {
        guard let archiveFolder, archiveJobs[file.id] == nil else { return }
        let source = file.url
        let fileID = file.id
        let destination = archiveFolder.appendingPathComponent(category.folderName, isDirectory: true)
        let job = ArchiveJob(filename: file.filename, category: category)
        archiveJobs[fileID] = job

        job.task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: ArchiveOutcome
            do {
                try FileMover.move(
                    source, intoDirectory: destination,
                    progress: { copied, total in
                        let fraction = total > 0 ? Double(copied) / Double(total) : 1
                        Task { @MainActor in job.fraction = fraction }
                    },
                    isCancelled: { Task.isCancelled }
                )
                outcome = .moved
            } catch FileMoveError.cancelled {
                outcome = .cancelled
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            await self?.finishArchive(of: fileID, named: source.lastPathComponent, outcome: outcome)
        }
    }

    func cancelArchive(of file: MKVFile) {
        archiveJobs[file.id]?.task?.cancel()
    }

    private enum ArchiveOutcome: Sendable {
        case moved, cancelled
        case failed(String)
    }

    private func finishArchive(of fileID: MKVFile.ID, named name: String, outcome: ArchiveOutcome) {
        archiveJobs[fileID] = nil
        switch outcome {
        case .moved:
            // Keep the pipeline moving: the row that takes the archived file's place becomes selected.
            let wasSelected = selection == fileID
            let row = visibleFiles.firstIndex { $0.id == fileID }
            files.removeAll { $0.id == fileID }
            if wasSelected, let row, !visibleFiles.isEmpty {
                selection = visibleFiles[min(row, visibleFiles.count - 1)].id
            }
        case .cancelled:
            break
        case .failed(let message):
            alert = AlertInfo(title: "“\(name)” could not be archived", message: message)
            // A failed move can leave the source in either place; show what is really on disk.
            rescan()
        }
    }
}

import MKVPipelineCore
import SwiftUI

/// The grid of MKV files. Columns can be dragged to reorder and shown or
/// hidden from the header's context menu; both are remembered.
struct FileTable: View {
    @Bindable var model: AppModel
    @AppStorage("fileTableColumns") private var columns = TableColumnCustomization<MKVFile>()

    var body: some View {
        Table(
            model.visibleFiles, selection: $model.selection,
            sortOrder: $model.sortOrder, columnCustomization: $columns
        ) {
            TableColumn("Filename", value: \.filename) { file in
                FilenameCell(file: file, isArchiving: model.archiveJobs[file.id] != nil)
            }
            .width(min: 160, ideal: 320)
            .customizationID("filename")

            TableColumn("File size", value: \.fileSize) { file in
                Text(ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90, max: 130)
            .customizationID("fileSize")

            TableColumn("Relative path", value: \.relativePath) { file in
                Text(file.relativePath)
                    .truncationMode(.middle)
                    .help(file.relativePath)
            }
            .width(min: 120, ideal: 260)
            .customizationID("relativePath")

            TableColumn("Segment title", value: \.segmentTitle) { file in
                MediaCell(file: file, text: file.segmentTitle)
            }
            .width(min: 120, ideal: 240)
            .customizationID("segmentTitle")

            TableColumn("Video resolution", value: \.resolutionPixels) { file in
                MediaCell(file: file, text: file.resolutionText)
                    .monospacedDigit()
            }
            .width(min: 90, ideal: 110, max: 160)
            .customizationID("videoResolution")

            TableColumn("Audio tracks", value: \.audioSummary) { file in
                AudioTracksCell(file: file)
            }
            .width(min: 70, ideal: 170)
            .customizationID("audioTracks")
        }
        .contextMenu(forSelectionType: MKVFile.ID.self) { ids in
            if let file = ids.first.flatMap(model.file(withID:)) {
                Button("Open") { model.openInDefaultApp(file) }
                Divider()
                Button("Preview") { model.openPreview(for: file) }
                Button("Edit MKV headers") { model.editHeaders(file) }
                    .disabled(!model.canModify(file))
                Button("Archive…") { model.requestArchive(file) }
                    .disabled(!model.canModify(file))
                Divider()
                Button("Show in Finder") { model.revealInFinder(file) }
            }
        } primaryAction: { ids in
            if let file = ids.first.flatMap(model.file(withID:)) {
                model.openPreview(for: file)
            }
        }
        .overlay {
            if model.visibleFiles.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor))
                    // Leaves the column headers visible and clickable above the message.
                    .padding(.top, 28)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.mkvFolder == nil {
            ContentUnavailableView {
                Label("Choose an MKV folder", systemImage: "folder.badge.plus")
            } description: {
                Text("Pick the folder that holds the MKV files you want to work through.")
            } actions: {
                Button("Choose MKV folder…") { model.chooseMKVFolder() }
            }
        } else if let error = model.scanError {
            ContentUnavailableView(
                "The folder could not be read", systemImage: "exclamationmark.triangle", description: Text(error)
            )
        } else if model.isScanning && model.files.isEmpty {
            ContentUnavailableView("Scanning…", systemImage: "magnifyingglass", description: Text("Looking for MKV files."))
        } else if model.files.isEmpty {
            ContentUnavailableView(
                "No MKV files", systemImage: "film",
                description: Text(
                    model.isRecursive
                        ? "This folder and its subfolders contain no .mkv files."
                        : "This folder contains no .mkv files. Turn on “Include subfolders” to look deeper."
                )
            )
        } else {
            ContentUnavailableView(
                "No matches", systemImage: "line.3.horizontal.decrease.circle",
                description: Text("No file matches the current filter.")
            )
        }
    }
}

private struct FilenameCell: View {
    let file: MKVFile
    let isArchiving: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isArchiving {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
            } else if case .failed(let reason) = file.media {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(reason)
            } else {
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
            }
            Text(file.filename)
                .truncationMode(.middle)
                .help(file.filename)
        }
        .opacity(isArchiving ? 0.5 : 1)
    }
}

/// Audio languages with the number of tracks in each as a badge. Every language takes a slot of
/// the same width, so the first, second… languages line up down the column.
private struct AudioTracksCell: View {
    let file: MKVFile

    /// Fits a three-letter code such as "und"; longer codes widen their own slot.
    private static let codeWidth: CGFloat = 26
    /// As wide as a two-digit badge, so one- and two-digit counts share a slot.
    private static let badgeSlotWidth: CGFloat = CountBadge.width(for: 10)

    var body: some View {
        let languages = file.audioLanguageCounts
        if languages.isEmpty {
            MediaCell(file: file, text: "")
        } else {
            HStack(spacing: 10) {
                ForEach(languages, id: \.code) { language in
                    HStack(spacing: 4) {
                        Text(language.code)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(minWidth: Self.codeWidth, alignment: .leading)
                        CountBadge(count: language.count)
                            .frame(minWidth: Self.badgeSlotWidth, alignment: .leading)
                    }
                }
            }
            // Never squeezed: in a narrow column the row is cut at the edge instead of the numbers.
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(
                languages
                    .map { "\(MediaFormatting.languageName($0.code)): \($0.count) \($0.count == 1 ? "track" : "tracks")" }
                    .joined(separator: "\n")
            )
        }
    }
}

private struct CountBadge: View {
    let count: Int

    /// Wide enough for one digit, or for two; larger counts grow with their text.
    static func width(for count: Int) -> CGFloat {
        count < 10 ? 18 : 26
    }

    var body: some View {
        Text("\(count)")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .frame(minWidth: Self.width(for: count))
            .background(.quaternary, in: Capsule())
    }
}

/// A cell whose value comes from MediaInfo and may still be loading.
private struct MediaCell: View {
    let file: MKVFile
    let text: String

    var body: some View {
        switch file.media {
        case .pending:
            Text("…").foregroundStyle(.tertiary)
        case .failed:
            Text(MediaFormatting.placeholder).foregroundStyle(.tertiary)
        case .loaded:
            if text.isEmpty {
                Text(MediaFormatting.placeholder).foregroundStyle(.tertiary)
            } else {
                Text(text).help(text)
            }
        }
    }
}

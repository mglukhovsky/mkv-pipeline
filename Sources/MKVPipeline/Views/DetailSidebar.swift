import MKVPipelineCore
import SwiftUI

/// Details and actions for the selected file.
struct DetailSidebar: View {
    let model: AppModel

    var body: some View {
        Group {
            if let file = model.selectedFile {
                VStack(spacing: 0) {
                    ScrollView {
                        FileDetails(model: model, file: file)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    FileActions(model: model, file: file)
                        .padding(12)
                }
            } else {
                ContentUnavailableView(
                    "No file selected", systemImage: "film",
                    description: Text("Select an MKV file to see its details and actions.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct FileDetails: View {
    let model: AppModel
    let file: MKVFile

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                SegmentTitleEditor(model: model, file: file)
                    // A half-typed title must not carry over to another file.
                    .id(file.id)
                Text(file.filename)
                Text(ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            FileFacts(file: file)
            Divider()

            SectionTitle("Media details")
            switch file.media {
            case .pending:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading media info…").foregroundStyle(.secondary)
                }
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .loaded(let details):
                VideoDetails(details: details)
                AudioTracks(tracks: details.audioTracks)
            }
        }
    }
}

/// The segment title with a pencil button that turns it into a text field. Return writes the new
/// title into the file; Esc leaves it as it was.
private struct SegmentTitleEditor: View {
    let model: AppModel
    let file: MKVFile

    @LocalState private var draft: String?
    @FocusState private var isFieldFocused: Bool

    private var isWriting: Bool { model.titleWrites.contains(file.id) }

    var body: some View {
        if let draft {
            HStack(spacing: 6) {
                TextField("Segment title", text: Binding(get: { draft }, set: { self.draft = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .focused($isFieldFocused)
                    .onSubmit(save)
                    .onExitCommand(perform: cancel)
                    .onAppear { isFieldFocused = true }
                Button(action: save) {
                    Image(systemName: "checkmark")
                }
                .help("Save the title to the file")
                Button(action: cancel) {
                    Image(systemName: "xmark")
                }
                .help("Keep the current title")
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(file.segmentTitle.isEmpty ? "No segment title" : file.segmentTitle)
                    .font(.title2.bold())
                    .foregroundStyle(file.segmentTitle.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                if isWriting {
                    ProgressView()
                        .controlSize(.small)
                        .help("Writing the title to the file…")
                } else {
                    Button {
                        self.draft = file.segmentTitle
                    } label: {
                        Image(systemName: "pencil")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.canModify(file))
                    .help("Edit segment title")
                }
            }
        }
    }

    private func save() {
        if let draft { model.setSegmentTitle(draft, for: file) }
        draft = nil
    }

    private func cancel() {
        draft = nil
    }
}

private struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// Two-column label/value table.
private struct FactGrid: View {
    let rows: [(label: String, value: String)]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(rows, id: \.label) { row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(row.value)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct FileFacts: View {
    let file: MKVFile

    var body: some View {
        FactGrid(rows: [
            ("Path", file.url.path),
            ("Created", format(file.created)),
            ("Modified", format(file.modified)),
        ])
    }

    private func format(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? MediaFormatting.placeholder
    }
}

private struct VideoDetails: View {
    let details: MediaDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Video").font(.headline)
            FactGrid(rows: rows)
        }
    }

    private var rows: [(label: String, value: String)] {
        var rows = [("Duration", MediaFormatting.duration(details.duration))]
        guard let video = details.video else {
            return rows + [("Codec", "No video track")]
        }
        let bitRate = video.bitRate.map { MediaFormatting.bitRate($0) }
            ?? details.overallBitRate.map { "\(MediaFormatting.bitRate($0)) (whole file)" }
            ?? MediaFormatting.placeholder
        rows += [
            ("Codec", MediaFormatting.videoCodec(video)),
            ("Bitrate", bitRate),
            ("Dimensions", MediaFormatting.dimensions(width: video.width, height: video.height)),
            ("Source", video.source ?? MediaFormatting.placeholder),
        ]
        return rows
    }
}

private struct AudioTracks: View {
    let tracks: [AudioTrack]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tracks.isEmpty ? "Audio tracks" : "Audio tracks (\(tracks.count))").font(.headline)
            if tracks.isEmpty {
                Text("No audio tracks").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("Title")
                        Text("Codec")
                        Text("Language")
                        Text("Channels")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Divider()
                    ForEach(tracks) { track in
                        GridRow {
                            Text(track.title ?? MediaFormatting.placeholder)
                            Text(track.codec ?? MediaFormatting.placeholder)
                            Text(MediaFormatting.languageName(track.language))
                            Text(MediaFormatting.channels(count: track.channels, layout: track.channelLayout))
                        }
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct FileActions: View {
    let model: AppModel
    let file: MKVFile

    var body: some View {
        VStack(spacing: 8) {
            if let job = model.archiveJobs[file.id] {
                HStack(spacing: 8) {
                    ProgressView(value: job.fraction) {
                        Text("Archiving to \(job.category.folderName)…")
                            .font(.callout)
                    }
                    Button("Cancel") { model.cancelArchive(of: file) }
                        .controlSize(.small)
                }
            }
            actionButton("Preview", systemImage: "play.rectangle") {
                model.openPreview(for: file)
            }
            .help("Play this file in the floating preview window")

            actionButton("Edit MKV headers", systemImage: "slider.horizontal.3") {
                model.editHeaders(file)
            }
            .disabled(!model.canModify(file))
            .help("Open this file in MKVToolNix's header editor")

            actionButton("Archive…", systemImage: "archivebox") {
                model.requestArchive(file)
            }
            .disabled(!model.canModify(file))
            .help("Move this file into Movies, Documentaries or TV Shows in the archive folder")
        }
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.large)
    }
}

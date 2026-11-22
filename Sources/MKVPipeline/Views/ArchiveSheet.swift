import MKVPipelineCore
import SwiftUI

/// Asks which archive folder the file should be moved into.
struct ArchiveSheet: View {
    let file: MKVFile
    let archiveFolder: URL?
    let onChoose: (ArchiveCategory) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Archive “\(file.segmentTitle.isEmpty ? file.filename : file.segmentTitle)”")
                    .font(.headline)
                Text("Move \(file.filename) into a folder in \(archiveFolder?.path ?? "the archive folder"):")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                ForEach(ArchiveCategory.allCases) { category in
                    Button {
                        onChoose(category)
                        dismiss()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: symbol(for: category))
                                .font(.system(size: 26))
                            Text(category.folderName)
                        }
                        .frame(maxWidth: .infinity, minHeight: 76)
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func symbol(for category: ArchiveCategory) -> String {
        switch category {
        case .movies: "film"
        case .documentaries: "binoculars"
        case .tvShows: "tv"
        }
    }
}

import MKVPipelineCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @AppStorage("sidebarVisible") private var isSidebarVisible = true
    @FocusState private var isFileListFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model, isSidebarVisible: $isSidebarVisible)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    FileTable(model: model)
                        .focused($isFileListFocused)
                    Divider()
                    StatusBar(model: model)
                }
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

                if isSidebarVisible {
                    DetailSidebar(model: model)
                        .frame(minWidth: 300, idealWidth: 350, maxWidth: 560, maxHeight: .infinity)
                }
            }
        }
        // Start in the file list rather than a path field, so arrow keys and shortcuts work right away.
        .defaultFocus($isFileListFocused, true)
        .overlay {
            // While the preview is open the list is shown there instead.
            if model.isShowingShortcuts && !model.preview.isOpen {
                ShortcutsOverlay { model.isShowingShortcuts = false }
            }
        }
        .onAppear { model.installKeyboardShortcuts() }
        .sheet(item: $model.archiveRequest) { file in
            ArchiveSheet(file: file, archiveFolder: model.archiveFolder) { category in
                model.archive(file, to: category)
            }
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }
}

struct StatusBar: View {
    let model: AppModel

    var body: some View {
        let activities = model.activities
        HStack(spacing: 10) {
            Text(summary)
                .fixedSize()
            Spacer(minLength: 16)
            if !activities.isEmpty {
                Text(activities.map(\.summary).joined(separator: "  ·  "))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(activities.map(\.summary).joined(separator: "\n"))
                progressBar(for: activities)
                    .frame(width: 140)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
    }

    /// One bar for everything in progress: the average when every task can report how far along it
    /// is, otherwise an indeterminate bar.
    @ViewBuilder private func progressBar(for activities: [Activity]) -> some View {
        let fractions = activities.compactMap(\.fraction)
        if fractions.count == activities.count {
            ProgressView(value: fractions.reduce(0, +) / Double(fractions.count))
                .progressViewStyle(.linear)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
        }
    }

    private var summary: String {
        let shown = model.visibleFiles.count
        let total = model.files.count
        let size = ByteCountFormatter.string(
            fromByteCount: model.visibleFiles.reduce(0) { $0 + $1.fileSize }, countStyle: .file
        )
        let count = shown == total ? "\(total) \(total == 1 ? "file" : "files")" : "\(shown) of \(total) files"
        return total == 0 ? "No files" : "\(count) · \(size)"
    }
}

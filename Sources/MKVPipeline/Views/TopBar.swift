import SwiftUI

/// Settings across the top of the window: the two folders, the filter, and refresh.
struct TopBar: View {
    @Bindable var model: AppModel
    @Binding var isSidebarVisible: Bool

    var body: some View {
        HStack(spacing: 8) {
            FolderField(
                title: "MKV folder", prompt: "Folder to list MKV files from",
                path: { model.mkvFolder?.path ?? "" },
                commit: { model.setMKVFolder(path: $0) },
                change: { model.chooseMKVFolder() }
            )
            Toggle("Include subfolders", isOn: $model.isRecursive)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Find MKV files in all subfolders of the MKV folder")

            Divider().frame(height: 18)

            FolderField(
                title: "Archive folder", prompt: "Parent of Movies, Documentaries, TV Shows",
                path: { model.archiveFolder?.path ?? "" },
                commit: { model.setArchiveFolder(path: $0) },
                change: { model.chooseArchiveFolder() }
            )

            // Fixed, so the two folder boxes are the only flexible items and split the spare width evenly.
            FilterField(model: model)
                .frame(width: 210)

            Button { model.refreshMetadata() } label: {
                Label("Refresh metadata", systemImage: "arrow.clockwise")
                    .labelStyle(.titleAndIcon)
            }
            .fixedSize()
            .disabled(model.mkvFolder == nil)
            .help("Look for new or removed files and read every file's media info again")

            Button { isSidebarVisible.toggle() } label: {
                Image(systemName: "sidebar.trailing")
            }
            .help(isSidebarVisible ? "Hide the details sidebar" : "Show the details sidebar")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// The frame of a text field, drawn by hand so that buttons can sit inside it next to the text.
private struct FieldBox<Content: View>: View {
    let isFocused: Bool
    @ViewBuilder let content: Content

    private let shape = RoundedRectangle(cornerRadius: 6)

    var body: some View {
        HStack(spacing: 5) {
            content
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(Color(nsColor: .textBackgroundColor), in: shape)
        .overlay {
            shape.strokeBorder(
                isFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                lineWidth: isFocused ? 2 : 1
            )
        }
    }
}

/// A labelled folder setting: the path can be typed or pasted, or picked with Change….
private struct FolderField: View {
    let title: String
    let prompt: String
    /// The setting's current path; empty when none is set.
    let path: () -> String
    /// Applies a typed path. Returns false if it was rejected.
    let commit: (String) -> Bool
    let change: () -> Void

    @LocalState private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(.secondary)
                .fixedSize()
            FieldBox(isFocused: isFocused) {
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    // The end of a path says more than its beginning.
                    .truncationMode(.head)
                    .focused($isFocused)
                    .onSubmit(apply)
                    .help(text.isEmpty ? prompt : text)
                Button("Change…", action: change)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Choose a folder…")
            }
            .frame(minWidth: 190, maxWidth: .infinity)
        }
        .onAppear { text = path() }
        .onChange(of: path()) { _, newPath in text = newPath }
        // Leaving the field applies what was typed, like pressing Return.
        .onChange(of: isFocused) { _, focused in
            if !focused { apply() }
        }
    }

    private func apply() {
        guard text != path() else { return }
        _ = commit(text)
        // Shows the folder as stored, or puts the old one back if the typed path was rejected.
        text = path()
    }
}

/// The filter box: saved filters under the magnifying glass, the expression, and a star to save it.
private struct FilterField: View {
    @Bindable var model: AppModel
    @LocalState private var isFocused = false

    var body: some View {
        FieldBox(isFocused: isFocused) {
            savedFiltersMenu
            RegexTextField(
                text: $model.searchText,
                placeholder: "Filter MKV files...",
                focusRequests: model.searchFocusRequests,
                onFocusChange: { isFocused = $0 }
            )
            .help("Case-insensitive regular expression matched against filename, relative path and segment title")

            if let error = model.searchError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help("\(error). Showing results for the last valid filter.")
            }
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Clear filter")

                saveButton
            }
        }
    }

    private var savedFiltersMenu: some View {
        Menu {
            if model.savedSearches.isEmpty {
                Text("No saved filters")
            } else {
                Section("Saved filters") {
                    ForEach(model.savedSearches, id: \.self) { search in
                        Toggle(search, isOn: Binding(
                            get: { model.searchText == search },
                            set: { model.searchText = $0 ? search : "" }
                        ))
                    }
                }
            }
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("Saved filters")
    }

    /// An outlined star saves the current filter; a filled one marks a saved filter and removes it.
    private var saveButton: some View {
        let isSaved = model.savedSearches.contains(model.searchText)
        return Button {
            if isSaved {
                model.removeSavedSearch(model.searchText)
            } else {
                model.saveCurrentSearch()
            }
        } label: {
            Image(systemName: isSaved ? "star.fill" : "star")
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSaved ? Color.yellow : Color.secondary)
        .disabled(!isSaved && !model.canSaveCurrentSearch)
        .help(isSaved ? "Remove saved filter" : "Save filter")
    }
}

/// Bare text field for the filter. Typing substitutions are switched off because smart quotes and
/// dashes silently corrupt regular expressions.
private struct RegexTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusRequests: Int
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = LiteralTextField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.onFocusChange = onFocusChange
        context.coordinator.handledFocusRequests = focusRequests
        return field
    }

    /// Takes the width it is offered. Left to itself the field would insist on the width of its text.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 120, height: nsView.intrinsicContentSize.height)
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        (field as? LiteralTextField)?.onFocusChange = onFocusChange
        if field.stringValue != text {
            field.stringValue = text
        }
        if context.coordinator.handledFocusRequests != focusRequests {
            context.coordinator.handledFocusRequests = focusRequests
            field.window?.makeFirstResponder(field)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var handledFocusRequests = 0

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        /// Esc clears the filter, as it does in a search field.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)), !control.stringValue.isEmpty else {
                return false
            }
            control.stringValue = ""
            text.wrappedValue = ""
            return true
        }
    }

    private final class LiteralTextField: NSTextField {
        var onFocusChange: ((Bool) -> Void)?

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became {
                if let editor = currentEditor() as? NSTextView {
                    editor.isAutomaticQuoteSubstitutionEnabled = false
                    editor.isAutomaticDashSubstitutionEnabled = false
                    editor.isAutomaticTextReplacementEnabled = false
                    editor.isAutomaticSpellingCorrectionEnabled = false
                }
                reportFocus(true)
            }
            return became
        }

        override func textDidEndEditing(_ notification: Notification) {
            super.textDidEndEditing(notification)
            reportFocus(false)
        }

        /// Deferred: focus can change while SwiftUI is in the middle of updating its views.
        private func reportFocus(_ focused: Bool) {
            DispatchQueue.main.async { [weak self] in
                self?.onFocusChange?(focused)
            }
        }
    }
}

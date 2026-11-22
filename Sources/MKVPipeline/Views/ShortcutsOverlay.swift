import SwiftUI

/// The list of keyboard shortcuts, dimming whatever it covers. A click anywhere dismisses it.
struct ShortcutsOverlay: View {
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
            // Scrolls only when the preview has been resized too small to show the whole list.
            ViewThatFits(in: .vertical) {
                list
                ScrollView { list }
            }
            .padding(12)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }

    private var list: some View {
        let shortcuts = AppShortcut.allCases
        let half = (shortcuts.count + 1) / 2
        return VStack(alignment: .leading, spacing: 10) {
            Text("Keyboard shortcuts")
                .font(.headline)
            HStack(alignment: .top, spacing: 28) {
                column(Array(shortcuts[..<half]))
                column(Array(shortcuts[half...]))
            }
            Text("Playback keys need the preview open; O, E and A act on the selected file. Esc closes this list and leaves full screen.")
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420, alignment: .leading)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
        .fixedSize()
    }

    private func column(_ shortcuts: [AppShortcut]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            ForEach(shortcuts, id: \.self) { shortcut in
                GridRow {
                    Text(shortcut.keyLabel)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .frame(minWidth: 30)
                        .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                        .gridColumnAlignment(.center)
                    Text(shortcut.title)
                }
            }
        }
    }
}

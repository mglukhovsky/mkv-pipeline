import MKVPipelineCore
import SwiftUI

/// Content of the floating preview panel: video on top, transport controls below.
struct PreviewView: View {
    /// Content size the first time the panel opens; after that the user's size is remembered.
    static let defaultSize = CGSize(width: 720, height: 500)

    let model: AppModel
    let controller: PreviewController

    var body: some View {
        VStack(spacing: 0) {
            // The video takes whatever the controls leave, so resizing the panel resizes the picture.
            video
                .frame(minWidth: 480, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
            if let player = controller.player {
                PlayerControls(player: player, file: model.selectedFile)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(controller.playerError ?? "Playback is unavailable.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var video: some View {
        ZStack {
            Color.black
            if let player = controller.player, let layer = player.videoLayer {
                VideoSurface(videoLayer: layer) { player.togglePlayPause() }
            }
            if let message = overlayMessage, !model.isShowingShortcuts {
                Text(message)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding()
                    // Clicks and drags belong to the video underneath.
                    .allowsHitTesting(false)
            }
            if model.isShowingShortcuts {
                ShortcutsOverlay { model.isShowingShortcuts = false }
            }
        }
    }

    private var overlayMessage: String? {
        guard let player = controller.player else { return "Playback is unavailable" }
        if let error = player.errorMessage { return error }
        if player.currentURL == nil { return "Select a file to preview" }
        if player.videoLayer == nil { return "Video output is unavailable; playing audio only" }
        return nil
    }
}

private struct VideoSurface: NSViewRepresentable {
    let videoLayer: MPVVideoLayer
    let onClick: () -> Void

    func makeNSView(context: Context) -> MPVVideoView {
        let view = MPVVideoView(videoLayer: videoLayer)
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: MPVVideoView, context: Context) {
        view.onClick = onClick
    }
}

private struct PlayerControls: View {
    @Bindable var player: MPVPlayer
    let file: MKVFile?

    @LocalState private var scrubPosition: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titles
            timeline
            transport
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!player.isLoaded)
    }

    private var titles: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(segmentTitle ?? "No segment title")
                .font(.headline)
                .foregroundStyle(segmentTitle == nil ? .secondary : .primary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 0)
            Text(player.currentURL?.lastPathComponent ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// Metadata comes from the grid's file while it is the one playing.
    private var segmentTitle: String? {
        guard let file, file.url == player.currentURL, !file.segmentTitle.isEmpty else { return nil }
        return file.segmentTitle
    }

    private var timeline: some View {
        HStack(spacing: 8) {
            Text(MediaFormatting.timecode(scrubPosition ?? player.position))
                .frame(width: 58, alignment: .leading)
            Slider(
                value: Binding(
                    get: { scrubPosition ?? player.position },
                    set: { newValue in
                        scrubPosition = newValue
                        player.seek(to: newValue, precise: false)
                    }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { isEditing in
                    guard !isEditing, let target = scrubPosition else { return }
                    player.seek(to: target, precise: true)
                    scrubPosition = nil
                }
            )
            .controlSize(.small)
            Text(MediaFormatting.timecode(player.duration))
                .frame(width: 58, alignment: .trailing)
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Group {
                Button { player.shuttle(reverse: true) } label: {
                    Image(systemName: "backward.fill")
                }
                .help("Rewind at 2×, 3×, 4×")

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlayingNormally ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .help(player.isPlayingNormally ? "Pause" : "Play at normal speed")

                Button { player.shuttle(reverse: false) } label: {
                    Image(systemName: "forward.fill")
                }
                .help("Fast-forward at 2×, 3×, 4×")
            }
            .buttonStyle(.borderless)
            .font(.title3)

            Picker("Speed", selection: Binding(get: { player.rate }, set: { player.setRate($0) })) {
                ForEach(PlaybackRate.all) { rate in
                    Text(rate.label).tag(rate)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Playback speed; negative values play backwards")

            Spacer(minLength: 8)

            trackMenu(
                systemImage: "waveform",
                current: player.audioTracks.first { $0.id == player.audioTrackID }?.shortLabel ?? "None",
                help: "Audio track"
            ) {
                ForEach(player.audioTracks) { track in
                    Toggle(track.label, isOn: Binding(
                        get: { player.audioTrackID == track.id },
                        set: { if $0 { player.selectAudioTrack(track.id) } }
                    ))
                }
            }
            .disabled(player.audioTracks.isEmpty)

            trackMenu(
                systemImage: "captions.bubble",
                current: player.subtitleTracks.first { $0.id == player.subtitleTrackID }?.shortLabel ?? "Off",
                help: "Subtitle track"
            ) {
                Toggle("Off", isOn: Binding(
                    get: { player.subtitleTrackID == nil },
                    set: { if $0 { player.selectSubtitleTrack(nil) } }
                ))
                Divider()
                ForEach(player.subtitleTracks) { track in
                    Toggle(track.label, isOn: Binding(
                        get: { player.subtitleTrackID == track.id },
                        set: { if $0 { player.selectSubtitleTrack(track.id) } }
                    ))
                }
            }
            .disabled(player.subtitleTracks.isEmpty)

            Button { player.isMuted.toggle() } label: {
                Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.borderless)
            .help(player.isMuted ? "Unmute" : "Mute")

            Slider(value: $player.volume, in: 0...100)
                .controlSize(.mini)
                .frame(width: 70)
                .help("Volume")
        }
    }

    private func trackMenu<Items: View>(
        systemImage: String, current: String, help: String, @ViewBuilder items: () -> Items
    ) -> some View {
        Menu {
            items()
        } label: {
            Label(current, systemImage: systemImage)
        }
        .fixedSize()
        .help(help)
    }
}

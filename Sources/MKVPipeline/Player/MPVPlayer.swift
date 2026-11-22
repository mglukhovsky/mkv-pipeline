import CMPV
import Foundation
import MKVPipelineCore
import Observation

struct PlaybackRate: Hashable, Identifiable {
    var speed: Int
    var isReverse: Bool

    var id: Int { isReverse ? -speed : speed }
    var label: String { isReverse ? "−\(speed)×" : "\(speed)×" }
    var isNormal: Bool { self == .normal }

    static let normal = PlaybackRate(speed: 1, isReverse: false)
    static let shuttleSpeeds = [2, 3, 4]
    /// Slowest-reverse to fastest-forward: −4× −3× −2× 1× 2× 3× 4×.
    static let all: [PlaybackRate] =
        shuttleSpeeds.reversed().map { PlaybackRate(speed: $0, isReverse: true) }
        + [.normal]
        + shuttleSpeeds.map { PlaybackRate(speed: $0, isReverse: false) }

    /// The rate `offset` places along `all`, stopping at either end.
    func stepped(by offset: Int) -> PlaybackRate {
        guard let index = Self.all.firstIndex(of: self) else { return .normal }
        return Self.all[min(max(index + offset, 0), Self.all.count - 1)]
    }
}

struct PlayerTrack: Identifiable, Hashable {
    enum Kind: String { case audio, sub }

    let id: Int
    let kind: Kind
    var title: String?
    var language: String?
    var codec: String?
    var channelCount: Int?
    var isDefault = false
    var isForced = false
    var isSelected = false

    /// Menu label, e.g. "1. English — Surround 5.1 (ac3, 5.1)".
    var label: String {
        var text = "\(id). \(MediaFormatting.languageName(language))"
        if let title, !title.isEmpty { text += " — \(title)" }
        var details: [String] = []
        if let codec { details.append(codec) }
        if kind == .audio, let channelCount {
            details.append(MediaFormatting.channels(count: channelCount, layout: nil).lowercased())
        }
        if isForced { details.append("forced") }
        if !details.isEmpty { text += " (\(details.joined(separator: ", ")))" }
        return text
    }

    var shortLabel: String { MediaFormatting.languageCode(language) }
}

/// Playback state for the preview window, backed by libmpv.
@MainActor @Observable
final class MPVPlayer {
    private(set) var currentURL: URL?
    private(set) var isLoaded = false
    private(set) var isPaused = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var rate = PlaybackRate.normal
    private(set) var reachedEnd = false
    private(set) var audioTracks: [PlayerTrack] = []
    private(set) var subtitleTracks: [PlayerTrack] = []
    private(set) var audioTrackID: Int?
    private(set) var subtitleTrackID: Int?
    private(set) var errorMessage: String?

    var volume: Double = 100 {
        didSet { core.set("volume", String(volume)) }
    }
    var isMuted = false {
        didSet { core.set("mute", isMuted ? "yes" : "no") }
    }

    /// `nil` when OpenGL rendering could not be set up; audio still plays.
    @ObservationIgnored let videoLayer: MPVVideoLayer?
    @ObservationIgnored private let core: MPVCore
    @ObservationIgnored private let relay = WakeupRelay()
    /// Target of a seek mpv has not finished yet.
    @ObservationIgnored private var pendingSeek: Double?

    /// Normal play is shown as "playing"; shuttling or paused shows a play button.
    var isPlayingNormally: Bool { isLoaded && !isPaused && rate.isNormal }

    init() throws {
        core = try MPVCore(options: [
            "config": "no",
            "terminal": "no",
            "vo": "libmpv",
            "hwdec": "auto-safe",
            "idle": "yes",
            // Stay on the last frame instead of unloading, so the window keeps its content.
            "keep-open": "yes",
            "osc": "no",
            "osd-level": "0",
            "audio-display": "no",
            "input-default-bindings": "no",
            "input-vo-keyboard": "no",
            "input-media-keys": "no",
            "ytdl": "no",
            "volume-max": "100",
            // Reverse playback decodes whole GOPs up front and seeks backwards through the demuxer cache.
            "video-reversal-buffer": "2GiB",
            "demuxer-max-bytes": "256MiB",
            "demuxer-max-back-bytes": "256MiB",
        ])
        videoLayer = MPVVideoLayer(core: core)

        core.observe("time-pos", format: MPV_FORMAT_DOUBLE)
        core.observe("duration", format: MPV_FORMAT_DOUBLE)
        core.observe("pause", format: MPV_FORMAT_FLAG)
        core.observe("eof-reached", format: MPV_FORMAT_FLAG)
        core.observe("track-list", format: MPV_FORMAT_NODE)

        relay.player = self
        mpv_set_wakeup_callback(core.handle, mpvDidWakeUp, Unmanaged.passUnretained(relay).toOpaque())
    }

    func shutdown() {
        guard core.isAlive else { return }
        mpv_set_wakeup_callback(core.handle, nil, nil)
        videoLayer?.destroyRenderContext()
        core.destroy()
        resetFileState()
        currentURL = nil
    }

    // MARK: - Transport

    /// Makes `url` the file in the player without disturbing it if it already is.
    ///
    /// Following the grid's selection passes `autoplay: false`: a new file comes up paused, and the
    /// current one is left exactly as it is. An explicit Preview passes `autoplay: true`: a new file
    /// starts playing, and the current one starts playing if it was waiting.
    func present(_ url: URL, autoplay: Bool) {
        if currentURL != url {
            load(url, paused: !autoplay)
        } else if autoplay, isPaused {
            togglePlayPause()
        }
    }

    /// Opens a file at its start. Paused, it shows the first frame and waits.
    func load(_ url: URL, paused: Bool) {
        guard core.isAlive else { return }
        resetFileState()
        currentURL = url
        rate = .normal
        core.set("play-direction", "forward")
        core.set("speed", "1")
        core.set("aid", "auto")
        core.set("sid", "auto")
        setPaused(paused)
        // mpv only adopts a changed play-direction when a seek runs, and loading a file discards the
        // seek that the change queued. Without the explicit start position, a file selected while
        // rewinding (and every file after it) would play backwards from its end.
        core.command("loadfile", url.path, "replace", "-1", "start=0")
    }

    func stop() {
        guard currentURL != nil else { return }
        core.command("stop")
        resetFileState()
        currentURL = nil
    }

    /// Pauses normal playback; otherwise (paused, shuttling, or at the end) returns to normal playback.
    func togglePlayPause() {
        guard isLoaded else { return }
        if isPlayingNormally {
            setPaused(true)
            return
        }
        let restart = reachedEnd && !rate.isReverse
        apply(.normal)
        if restart { seek(to: 0, precise: true) }
        setPaused(false)
    }

    /// Selecting any rate other than 1× starts playback at that rate.
    func setRate(_ newRate: PlaybackRate) {
        guard isLoaded else { return }
        apply(newRate)
        setPaused(false)
    }

    /// Rewind / fast-forward buttons: 2× → 3× → 4× → 2× in the given direction.
    func shuttle(reverse: Bool) {
        let speeds = PlaybackRate.shuttleSpeeds
        var speed = speeds[0]
        if rate.isReverse == reverse, let index = speeds.firstIndex(of: rate.speed) {
            speed = speeds[(index + 1) % speeds.count]
        }
        setRate(PlaybackRate(speed: speed, isReverse: reverse))
    }

    /// One step slower (through 1× into reverse) or faster.
    func stepRate(by offset: Int) {
        setRate(rate.stepped(by: offset))
    }

    func skip(by seconds: Double) {
        seek(to: (pendingSeek ?? position) + seconds, precise: false)
    }

    func adjustVolume(by amount: Double) {
        volume = min(max(volume + amount, 0), 100)
        if amount > 0 { isMuted = false }
    }

    func seek(to seconds: Double, precise: Bool) {
        guard isLoaded else { return }
        let target = min(max(seconds, 0), duration)
        // Show the target immediately and ignore mpv's stale positions until the seek lands.
        pendingSeek = target
        position = target
        core.command("seek", String(target), precise ? "absolute+exact" : "absolute+keyframes")
    }

    func selectAudioTrack(_ id: Int) {
        audioTrackID = id
        // Audio is switched off while reversing; the choice takes effect when forward playback resumes.
        if !rate.isReverse { core.set("aid", String(id)) }
    }

    func selectSubtitleTrack(_ id: Int?) {
        subtitleTrackID = id
        core.set("sid", id.map(String.init) ?? "no")
    }

    /// Reflected immediately so back-to-back commands see the state they just asked for; mpv confirms it.
    private func setPaused(_ paused: Bool) {
        isPaused = paused
        core.set("pause", paused ? "yes" : "no")
    }

    private func apply(_ newRate: PlaybackRate) {
        let oldRate = rate
        rate = newRate
        if newRate.isReverse != oldRate.isReverse {
            // Reversed audio is unintelligible and destabilises A/V sync, so it is dropped while rewinding.
            core.set("aid", newRate.isReverse ? "no" : (audioTrackID.map(String.init) ?? "auto"))
            core.set("play-direction", newRate.isReverse ? "backward" : "forward")
            // Changing direction makes mpv seek to the current position, replacing a seek still in flight.
            if let pendingSeek {
                core.command("seek", String(pendingSeek), "absolute+exact")
            }
        }
        if newRate.speed != oldRate.speed {
            core.set("speed", String(newRate.speed))
        }
    }

    private func resetFileState() {
        isLoaded = false
        pendingSeek = nil
        position = 0
        duration = 0
        reachedEnd = false
        audioTracks = []
        subtitleTracks = []
        audioTrackID = nil
        subtitleTrackID = nil
        errorMessage = nil
    }

    // MARK: - Events

    fileprivate func drainEvents() {
        // A wakeup can already be queued when the core is destroyed.
        guard core.isAlive else { return }
        while let event = mpv_wait_event(core.handle, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
            switch event.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                if let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee {
                    handle(property)
                }
            case MPV_EVENT_FILE_LOADED:
                isLoaded = true
                errorMessage = nil
            case MPV_EVENT_PLAYBACK_RESTART:
                pendingSeek = nil
            case MPV_EVENT_END_FILE:
                if let end = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee,
                   end.reason == MPV_END_FILE_REASON_ERROR {
                    isLoaded = false
                    errorMessage = "Could not play this file (\(MPVCore.describe(end.error)))."
                }
            case MPV_EVENT_LOG_MESSAGE:
                if let message = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee,
                   let prefix = message.prefix, let text = message.text {
                    playerLog.notice("[\(String(cString: prefix), privacy: .public)] \(String(cString: text), privacy: .public)")
                }
            default:
                break
            }
        }
    }

    private func handle(_ property: mpv_event_property) {
        let name = String(cString: property.name)
        let data = property.format == MPV_FORMAT_NONE ? nil : property.data

        switch name {
        case "time-pos":
            guard isLoaded, pendingSeek == nil, let time = data?.assumingMemoryBound(to: Double.self).pointee else { return }
            // mpv reports every frame; the UI only needs a few updates a second while playing.
            if isPaused || abs(time - position) >= 0.2 { position = time }
        case "duration":
            duration = data?.assumingMemoryBound(to: Double.self).pointee ?? 0
        case "pause":
            isPaused = (data?.assumingMemoryBound(to: Int32.self).pointee ?? 0) != 0
        case "eof-reached":
            reachedEnd = (data?.assumingMemoryBound(to: Int32.self).pointee ?? 0) != 0
            if reachedEnd {
                pendingSeek = nil
                if rate.isReverse {
                    // Rewound to the beginning: rest there, ready for normal playback.
                    position = 0
                    apply(.normal)
                } else if duration > 0 {
                    position = duration
                }
            }
        case "track-list":
            guard let node = data?.assumingMemoryBound(to: mpv_node.self).pointee,
                  let entries = MPVCore.value(of: node) as? [Any] else { return }
            updateTracks(entries.compactMap { $0 as? [String: Any] })
        default:
            break
        }
    }

    private func updateTracks(_ entries: [[String: Any]]) {
        let tracks = entries.compactMap { entry -> PlayerTrack? in
            guard let id = entry["id"] as? Int,
                  let kind = (entry["type"] as? String).flatMap(PlayerTrack.Kind.init(rawValue:)) else { return nil }
            return PlayerTrack(
                id: id, kind: kind,
                title: entry["title"] as? String,
                language: entry["lang"] as? String,
                codec: entry["codec"] as? String,
                channelCount: entry["demux-channel-count"] as? Int,
                isDefault: entry["default"] as? Bool ?? false,
                isForced: entry["forced"] as? Bool ?? false,
                isSelected: entry["selected"] as? Bool ?? false
            )
        }
        audioTracks = tracks.filter { $0.kind == .audio }
        subtitleTracks = tracks.filter { $0.kind == .sub }
        subtitleTrackID = subtitleTracks.first(where: \.isSelected)?.id
        // While reversing, mpv has no audio track selected; keep showing the one that will resume.
        if !rate.isReverse {
            audioTrackID = audioTracks.first(where: \.isSelected)?.id
        }
    }
}

/// A free function so the C callback carries no actor isolation: mpv calls it on its own threads.
private func mpvDidWakeUp(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<WakeupRelay>.fromOpaque(context).takeUnretainedValue().wake()
}

/// Hops mpv's wakeup callback onto the main actor.
private final class WakeupRelay: @unchecked Sendable {
    weak var player: MPVPlayer?

    func wake() {
        Task { @MainActor [weak self] in
            self?.player?.drainEvents()
        }
    }
}

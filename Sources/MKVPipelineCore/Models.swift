import Foundation

public struct VideoTrack: Hashable, Sendable {
    public var codec: String?
    public var profile: String?
    /// Bits per second.
    public var bitRate: Double?
    public var width: Int?
    public var height: Int?
    /// MediaInfo's "Original source medium", e.g. "Blu-ray" for MakeMKV rips.
    public var source: String?

    public init(
        codec: String? = nil, profile: String? = nil, bitRate: Double? = nil,
        width: Int? = nil, height: Int? = nil, source: String? = nil
    ) {
        self.codec = codec
        self.profile = profile
        self.bitRate = bitRate
        self.width = width
        self.height = height
        self.source = source
    }
}

public struct AudioTrack: Hashable, Sendable, Identifiable {
    /// Zero-based position among the file's audio tracks.
    public var id: Int
    public var title: String?
    public var codec: String?
    /// Language code as reported by MediaInfo, e.g. "en" or "pt-BR".
    public var language: String?
    public var channels: Int?
    public var channelLayout: String?

    public init(
        id: Int, title: String? = nil, codec: String? = nil, language: String? = nil,
        channels: Int? = nil, channelLayout: String? = nil
    ) {
        self.id = id
        self.title = title
        self.codec = codec
        self.language = language
        self.channels = channels
        self.channelLayout = channelLayout
    }
}

public struct MediaDetails: Hashable, Sendable {
    public var container: String?
    public var segmentTitle: String?
    public var duration: TimeInterval?
    /// Bits per second for the whole file.
    public var overallBitRate: Double?
    public var video: VideoTrack?
    public var audioTracks: [AudioTrack]
    public var subtitleTrackCount: Int

    public init(
        container: String? = nil, segmentTitle: String? = nil, duration: TimeInterval? = nil,
        overallBitRate: Double? = nil, video: VideoTrack? = nil, audioTracks: [AudioTrack] = [],
        subtitleTrackCount: Int = 0
    ) {
        self.container = container
        self.segmentTitle = segmentTitle
        self.duration = duration
        self.overallBitRate = overallBitRate
        self.video = video
        self.audioTracks = audioTracks
        self.subtitleTrackCount = subtitleTrackCount
    }
}

public enum MediaState: Hashable, Sendable {
    case pending
    case loaded(MediaDetails)
    case failed(String)
}

public struct MKVFile: Identifiable, Hashable, Sendable {
    public let url: URL
    /// Path relative to the scanned MKV folder, including the filename.
    public let relativePath: String
    public var fileSize: Int64
    public var created: Date?
    public var modified: Date?
    public var media: MediaState

    public init(
        url: URL, relativePath: String, fileSize: Int64,
        created: Date? = nil, modified: Date? = nil, media: MediaState = .pending
    ) {
        self.url = url
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.created = created
        self.modified = modified
        self.media = media
    }

    public var id: String { url.path }
    public var filename: String { url.lastPathComponent }

    public var details: MediaDetails? {
        if case .loaded(let details) = media { return details }
        return nil
    }

    // Non-optional projections so every grid column has a sortable key.
    public var segmentTitle: String { details?.segmentTitle ?? "" }
    public var audioSummary: String { MediaFormatting.audioSummary(details?.audioTracks ?? []) }
    public var audioLanguageCounts: [AudioLanguageCount] {
        MediaFormatting.audioLanguageCounts(details?.audioTracks ?? [])
    }

    public var resolutionText: String {
        guard let width = details?.video?.width, let height = details?.video?.height else { return "" }
        return "\(width)×\(height)"
    }

    public var resolutionPixels: Int {
        (details?.video?.width ?? 0) * (details?.video?.height ?? 0)
    }
}

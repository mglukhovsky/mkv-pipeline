import Foundation

public struct AudioLanguageCount: Hashable, Sendable {
    /// Lowercase language code; "und" when the track has none.
    public var code: String
    public var count: Int
}

public enum MediaFormatting {
    public static let placeholder = "—"

    /// Number of audio tracks per language, in first-appearance order.
    public static func audioLanguageCounts(_ tracks: [AudioTrack]) -> [AudioLanguageCount] {
        var counts: [AudioLanguageCount] = []
        for track in tracks {
            let code = languageCode(track.language)
            if let index = counts.firstIndex(where: { $0.code == code }) {
                counts[index].count += 1
            } else {
                counts.append(AudioLanguageCount(code: code, count: 1))
            }
        }
        return counts
    }

    /// The same information as plain text, e.g. "en×2, fr, ja".
    public static func audioSummary(_ tracks: [AudioTrack]) -> String {
        audioLanguageCounts(tracks)
            .map { $0.count > 1 ? "\($0.code)×\($0.count)" : $0.code }
            .joined(separator: ", ")
    }

    public static func languageCode(_ language: String?) -> String {
        let trimmed = language?.trimmingCharacters(in: .whitespaces) ?? ""
        return (trimmed.isEmpty ? "und" : trimmed).lowercased()
    }

    public static func languageName(_ language: String?, locale: Locale = .current) -> String {
        let code = language?.trimmingCharacters(in: .whitespaces) ?? ""
        if code.isEmpty || code.lowercased() == "und" { return "Undetermined" }
        return locale.localizedString(forIdentifier: code) ?? code
    }

    /// "1:42:07" / "4:05"; rounds to the nearest second.
    public static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return placeholder }
        return clock(Int(seconds.rounded()))
    }

    /// Playback position; truncates so it never shows a second that has not started.
    public static func timecode(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return clock(0) }
        return clock(Int(seconds))
    }

    private static func clock(_ total: Int) -> String {
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    public static func bitRate(_ bitsPerSecond: Double?) -> String {
        guard let bps = bitsPerSecond, bps.isFinite, bps > 0 else { return placeholder }
        return bps >= 1_000_000
            ? String(format: "%.1f Mb/s", bps / 1_000_000)
            : String(format: "%.0f kb/s", bps / 1_000)
    }

    public static func dimensions(width: Int?, height: Int?) -> String {
        guard let width, let height else { return placeholder }
        return "\(width) × \(height)"
    }

    /// "Mono", "Stereo", "5.1", "7.1"… derived from the channel count and,
    /// when MediaInfo reports one, the layout's LFE channels.
    public static func channels(count: Int?, layout: String?) -> String {
        guard let count, count > 0 else { return placeholder }
        let lfe: Int
        if let layout, !layout.isEmpty {
            lfe = layout.split(separator: " ").filter { $0.uppercased().hasPrefix("LFE") }.count
        } else {
            lfe = (count == 6 || count == 8) ? 1 : 0
        }
        if lfe > 0, lfe < count { return "\(count - lfe).\(lfe)" }
        switch count {
        case 1: return "Mono"
        case 2: return "Stereo"
        default: return "\(count).0"
        }
    }

    public static func videoCodec(_ video: VideoTrack) -> String {
        guard let codec = video.codec else { return placeholder }
        if let profile = video.profile { return "\(codec) (\(profile))" }
        return codec
    }
}

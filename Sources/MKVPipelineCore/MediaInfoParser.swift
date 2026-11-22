import Foundation

public enum MediaInfoError: LocalizedError, Equatable {
    case unreadable
    case unrecognized
    case malformedReport

    public var errorDescription: String? {
        switch self {
        case .unreadable: "MediaInfo could not open the file."
        case .unrecognized: "MediaInfo did not recognize this as a media file."
        case .malformedReport: "MediaInfo returned a report that could not be read."
        }
    }
}

/// Turns MediaInfo's JSON report (`--Output=JSON`) into `MediaDetails`.
public enum MediaInfoParser {
    public static func parse(json: Data) throws -> MediaDetails {
        guard
            let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let media = root["media"] as? [String: Any],
            let tracks = media["track"] as? [[String: Any]]
        else { throw MediaInfoError.malformedReport }

        func tracksOfType(_ type: String) -> [[String: Any]] {
            tracks.filter { ($0["@type"] as? String) == type }
        }

        // MediaInfo emits a bare General track (size and dates only) for files it cannot parse.
        guard let general = tracksOfType("General").first, let container = string(general, "Format") else {
            throw MediaInfoError.unrecognized
        }

        var details = MediaDetails(container: container)
        details.segmentTitle = string(general, "Title") ?? string(general, "Movie")
        details.duration = number(general, "Duration")
        details.overallBitRate = number(general, "OverallBitRate")
        details.subtitleTrackCount = tracksOfType("Text").count

        if let video = tracksOfType("Video").first {
            details.video = VideoTrack(
                codec: string(video, "Format"),
                profile: string(video, "Format_Profile"),
                bitRate: number(video, "BitRate"),
                width: number(video, "Width").map(Int.init),
                height: number(video, "Height").map(Int.init),
                source: string(video, "OriginalSourceMedium") ?? string(general, "OriginalSourceMedium")
            )
            if details.duration == nil { details.duration = number(video, "Duration") }
        }

        details.audioTracks = tracksOfType("Audio").enumerated().map { index, audio in
            AudioTrack(
                id: index,
                title: string(audio, "Title"),
                codec: string(audio, "Format_Commercial_IfAny") ?? string(audio, "Format"),
                language: string(audio, "Language"),
                channels: number(audio, "Channels").map(Int.init),
                channelLayout: string(audio, "ChannelLayout")
            )
        }
        return details
    }

    /// Looks in the track itself and then in its `extra` object, where MediaInfo's JSON puts
    /// less common fields such as `OriginalSourceMedium`.
    private static func string(_ track: [String: Any], _ key: String) -> String? {
        guard let value = (track[key] ?? (track["extra"] as? [String: Any])?[key]) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// MediaInfo reports numbers as strings, occasionally as "a / b" when a
    /// stream carries several values (e.g. a DTS core and its extension).
    private static func number(_ track: [String: Any], _ key: String) -> Double? {
        guard let text = string(track, key) else { return nil }
        let first = text.split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? text
        guard let value = Double(first), value.isFinite else { return nil }
        return value
    }
}

import Foundation
import Testing
@testable import MKVPipelineCore

@Suite struct MediaInfoParserTests {
    private let makeMKVReport = """
    {"media":{"@ref":"/rips/title_t00.mkv","track":[
      {"@type":"General","Format":"Matroska","Duration":"6127.456","OverallBitRate":"31250000","Title":"The Test Movie","Movie":"The Test Movie","extra":{"ErrorDetectionType":"Per level 1"}},
      {"@type":"Video","Format":"HEVC","Format_Profile":"Main 10","BitRate":"28400000","Width":"3840","Height":"2160","FrameRate":"23.976","OriginalSourceMedium_ID":"4113","extra":{"OriginalSourceMedium":"Blu-ray"}},
      {"@type":"Audio","@typeorder":"1","Format":"MLP FBA","Format_Commercial_IfAny":"Dolby TrueHD with Dolby Atmos","Channels":"8","ChannelLayout":"L R C LFE Ls Rs Lb Rb","Title":"Surround 7.1","Language":"en"},
      {"@type":"Audio","@typeorder":"2","Format":"DTS","BitRate":"1509000 / 1509000","Channels":"6 / 6","Language":"fr"},
      {"@type":"Audio","@typeorder":"3","Format":"AAC","Channels":"2","ChannelLayout":"L R","Title":"  "},
      {"@type":"Text","Format":"PGS","Language":"en"},
      {"@type":"Menu"}
    ]}}
    """

    @Test func readsGeneralVideoAndAudioFields() throws {
        let details = try MediaInfoParser.parse(json: Data(makeMKVReport.utf8))

        #expect(details.segmentTitle == "The Test Movie")
        #expect(details.duration == 6127.456)
        #expect(details.subtitleTrackCount == 1)
        #expect(details.video == VideoTrack(
            codec: "HEVC", profile: "Main 10", bitRate: 28_400_000,
            width: 3840, height: 2160, source: "Blu-ray"
        ))
        #expect(details.audioTracks.map(\.codec) == ["Dolby TrueHD with Dolby Atmos", "DTS", "AAC"])
        #expect(details.audioTracks.map(\.language) == ["en", "fr", nil])
        #expect(details.audioTracks.map(\.channels) == [8, 6, 2])
        #expect(details.audioTracks.map(\.title) == ["Surround 7.1", nil, nil])
    }

    @Test func rejectsFilesMediaInfoCouldNotIdentify() {
        let bare = #"{"media":{"@ref":"/x/corrupt.mkv","track":[{"@type":"General","FileExtension":"mkv","FileSize":"2000"}]}}"#
        #expect(throws: MediaInfoError.unrecognized) { try MediaInfoParser.parse(json: Data(bare.utf8)) }
        #expect(throws: MediaInfoError.malformedReport) { try MediaInfoParser.parse(json: Data(#"{"media":null}"#.utf8)) }
    }
}

@Suite struct MediaInfoReaderTests {
    @Test func readsARealFileThroughLibmediainfoAtANonASCIIPath() throws {
        let fixture = try #require(Bundle.module.url(forResource: "tiny", withExtension: "mkv", subdirectory: "Fixtures"))
        let directory = try TemporaryDirectory()
        let file = directory.url.appendingPathComponent("Ünïcödé ✓ 日本語 S01E01.mkv")
        try FileManager.default.copyItem(at: fixture, to: file)

        let state = MediaInfoReader.read(file)
        guard case .loaded(let details) = state else {
            Issue.record("expected the fixture to load, got \(state)")
            return
        }
        #expect(details.container == "Matroska")
        #expect(details.segmentTitle == "Tiny Fixture")
        #expect(details.video?.width == 64)
        #expect(details.video?.height == 36)
        #expect(details.audioTracks.map(\.language) == ["en", "de"])
        #expect(details.audioTracks.map(\.channels) == [1, 2])
        #expect(details.audioTracks.first?.title == "Main")
    }

    @Test func reportsFailureForMissingAndNonMediaFiles() throws {
        let directory = try TemporaryDirectory()
        let garbage = directory.url.appendingPathComponent("garbage.mkv")
        try Data((0..<2000).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: garbage)

        for url in [garbage, directory.url.appendingPathComponent("missing.mkv")] {
            guard case .failed = MediaInfoReader.read(url) else {
                Issue.record("expected \(url.lastPathComponent) to fail")
                continue
            }
        }
    }
}

@Suite struct MediaFormattingTests {
    private func track(_ language: String?) -> AudioTrack { AudioTrack(id: 0, language: language) }

    @Test func audioSummaryCountsTracksPerLanguageInOrderOfAppearance() {
        #expect(MediaFormatting.audioSummary([track("en"), track("fr"), track("EN"), track("ja")]) == "en×2, fr, ja")
        #expect(MediaFormatting.audioSummary([track(nil), track("en"), track(" ")]) == "und×2, en")
        #expect(MediaFormatting.audioSummary([track("pt-BR")]) == "pt-br")
        #expect(MediaFormatting.audioSummary([]) == "")
        #expect(MediaFormatting.audioLanguageCounts([track("en"), track("fr"), track("en")]) == [
            AudioLanguageCount(code: "en", count: 2), AudioLanguageCount(code: "fr", count: 1),
        ])
    }

    @Test(arguments: [
        (6, "L R C LFE Ls Rs", "5.1"), (8, "L R C LFE Ls Rs Lb Rb", "7.1"), (2, "L R", "Stereo"),
        (1, "C", "Mono"), (6, nil, "5.1"), (8, nil, "7.1"), (3, "L R C", "3.0"), (3, "L R LFE", "2.1"),
    ] as [(Int, String?, String)])
    func channelDescriptions(count: Int, layout: String?, expected: String) {
        #expect(MediaFormatting.channels(count: count, layout: layout) == expected)
    }

    @Test func formatsRatesAndDurations() {
        #expect(MediaFormatting.bitRate(28_400_000) == "28.4 Mb/s")
        #expect(MediaFormatting.bitRate(448_000) == "448 kb/s")
        #expect(MediaFormatting.bitRate(nil) == "—")
        #expect(MediaFormatting.duration(6127.456) == "1:42:07")
        #expect(MediaFormatting.duration(59.6) == "1:00")
        #expect(MediaFormatting.timecode(59.6) == "0:59")
        #expect(MediaFormatting.languageName("fr", locale: Locale(identifier: "en_US")) == "French")
        #expect(MediaFormatting.languageName(nil) == "Undetermined")
    }
}

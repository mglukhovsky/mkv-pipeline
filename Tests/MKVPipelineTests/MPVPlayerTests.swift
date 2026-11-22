import Foundation
import Testing
@testable import MKVPipeline

@MainActor @Suite struct MPVPlayerTests {
    @Test func fileSelectedWhileRewindingPlaysForwardFromItsStart() async throws {
        let file = try #require(Bundle.module.url(forResource: "ten-seconds", withExtension: "mkv", subdirectory: "Fixtures"))
        let player = try MPVPlayer()
        defer { player.shutdown() }
        player.isMuted = true

        player.load(file, paused: false)
        try await waitUntil { player.isLoaded && player.duration > 9 }
        player.seek(to: 8, precise: false)
        player.setRate(PlaybackRate(speed: 2, isReverse: true))
        // Reached only if the seek survived the direction change and playback is counting down from it.
        try await waitUntil { player.position > 3 && player.position < 7.5 }

        player.load(file, paused: false)
        try await waitUntil { player.isLoaded && player.position >= 0.2 }
        #expect(player.position < 3, "playback starts at the beginning, not at the end")
        let start = player.position
        try await waitUntil { player.position > start + 0.5 || player.reachedEnd }
        #expect(player.position > start, "…and runs forward")
        #expect(player.isPlayingNormally)
    }
}

extension MPVPlayerTests {
    @Test func aFileLoadedPausedWaitsOnItsFirstFrameUntilPlayed() async throws {
        let file = try #require(Bundle.module.url(forResource: "ten-seconds", withExtension: "mkv", subdirectory: "Fixtures"))
        let player = try MPVPlayer()
        defer { player.shutdown() }
        player.isMuted = true

        // Even when the previous file was rewinding, the next one must come up paused at its start.
        player.load(file, paused: false)
        try await waitUntil { player.isLoaded && player.duration > 9 }
        player.seek(to: 8, precise: false)
        player.setRate(PlaybackRate(speed: 2, isReverse: true))
        try await waitUntil { player.position > 3 && player.position < 7.5 }

        player.load(file, paused: true)
        try await waitUntil { player.isLoaded && player.duration > 9 }
        try await Task.sleep(for: .milliseconds(700))
        #expect(player.isPaused && !player.isPlayingNormally)
        #expect(player.position < 0.2, "nothing plays until asked")
        #expect(!player.reachedEnd)

        player.togglePlayPause()
        try await waitUntil { player.position > 0.5 }
        #expect(player.isPlayingNormally)
    }


    @Test func selectingLoadsPausedAndAnExplicitPreviewPlays() async throws {
        let file = try #require(Bundle.module.url(forResource: "ten-seconds", withExtension: "mkv", subdirectory: "Fixtures"))
        let other = try #require(Bundle.module.url(forResource: "tiny", withExtension: "mkv", subdirectory: "Fixtures"))
        let player = try MPVPlayer()
        defer { player.shutdown() }
        player.isMuted = true

        // Selecting a row.
        player.present(file, autoplay: false)
        try await waitUntil { player.isLoaded }
        try await Task.sleep(for: .milliseconds(400))
        #expect(player.isPaused && player.position < 0.2)

        // Preview on the file that is already waiting: it plays, without being loaded again.
        player.present(file, autoplay: true)
        try await waitUntil { player.position > 0.6 }
        #expect(player.isPlayingNormally)

        // Neither the selection settling on the same file nor a second Preview interrupts it.
        let reached = player.position
        player.present(file, autoplay: false)
        player.present(file, autoplay: true)
        try await waitUntil { player.position > reached + 0.4 }
        #expect(player.isPlayingNormally && player.currentURL == file)

        // Preview on a different file plays it straight away; selecting another one does not.
        player.present(other, autoplay: true)
        try await waitUntil { player.isLoaded && player.currentURL == other }
        #expect(!player.isPaused)
        player.present(file, autoplay: false)
        try await waitUntil { player.isLoaded && player.currentURL == file }
        #expect(player.isPaused)
    }

    /// Quitting shuts the player down before AppKit closes the preview window, which then stops playback.
    @Test func closingThePreviewAfterShutdownDoesNotTouchTheDestroyedPlayer() async throws {
        let file = try #require(Bundle.module.url(forResource: "ten-seconds", withExtension: "mkv", subdirectory: "Fixtures"))
        let player = try MPVPlayer()
        player.isMuted = true
        player.load(file, paused: false)
        try await waitUntil { player.isLoaded }

        player.shutdown()
        player.stop()
        player.volume = 40
        player.load(file, paused: false)
        player.shutdown()
        #expect(player.currentURL == nil)
    }
}

@Suite struct AppShortcutTests {
    @Test func bracketKeysStepThroughReverseNormalAndFastRates() {
        let ladder = PlaybackRate.all.map(\.label)
        #expect(ladder == ["−4×", "−3×", "−2×", "1×", "2×", "3×", "4×"])
        #expect(PlaybackRate.normal.stepped(by: -1).label == "−2×")
        #expect(PlaybackRate(speed: 2, isReverse: true).stepped(by: 1) == .normal)
        #expect(PlaybackRate(speed: 4, isReverse: false).stepped(by: 1).label == "4×")
        #expect(PlaybackRate(speed: 4, isReverse: true).stepped(by: -1).label == "−4×")
    }

    @Test func keysMapToShortcuts() {
        func shortcut(_ characters: String) -> AppShortcut? {
            AppShortcut.matching(characters: characters, specialKey: nil)
        }
        #expect(shortcut(" ") == .playPause)
        #expect(shortcut("[") == .slower)
        #expect(shortcut("]") == .faster)
        #expect(shortcut("+") == .volumeUp)
        #expect(shortcut("=") == .volumeUp)
        #expect(shortcut("-") == .volumeDown)
        #expect(shortcut("f") == .fullScreen)
        #expect(shortcut("P") == .togglePreview)
        #expect(shortcut("o") == .open)
        #expect(shortcut("e") == .editHeaders)
        #expect(shortcut("a") == .archive)
        #expect(shortcut("?") == .help)
        #expect(shortcut("x") == nil)
        #expect(AppShortcut.matching(characters: "\u{F702}", specialKey: .leftArrow) == .skipBack)
        #expect(AppShortcut.matching(characters: "\u{F703}", specialKey: .rightArrow) == .skipForward)
    }
}

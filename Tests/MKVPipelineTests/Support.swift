import Foundation
import Observation
@testable import MKVPipeline

/// A scratch directory that is removed when the value goes away.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MKVPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ relativePath: String, contents: String = "x") throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }
}

struct TimedOut: Error {}

/// Polls a main-actor condition; the app model finishes its work asynchronously.
@MainActor
func waitUntil(timeout: Duration = .seconds(15), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TimedOut() }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Preferences that live only in memory, so tests never write to ~/Library/Preferences.
final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    private var storage: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? { storage[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { storage[defaultName] = value }
    override func removeObject(forKey defaultName: String) { storage[defaultName] = nil }
}

/// Records every distinct state of `AppModel.activities` from the moment it is created.
@MainActor
final class ActivityLog {
    private(set) var activities: [Activity] = []
    private let model: AppModel

    init(_ model: AppModel) {
        self.model = model
        observe()
    }

    private func observe() {
        let current = withObservationTracking {
            model.activities
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        for activity in current where activities.last != activity {
            activities.append(activity)
        }
    }
}

import CMPV
import Foundation
import os

let playerLog = Logger(subsystem: "io.github.mglukhovsky.MKVPipeline", category: "player")

enum MPVError: LocalizedError {
    case unavailable
    case initializationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "libmpv could not be started."
        case .initializationFailed(let reason): "libmpv failed to initialize: \(reason)"
        }
    }
}

/// Thin wrapper over an mpv client handle. libmpv's client API is thread-safe,
/// and every mutation here goes through its asynchronous entry points so the
/// UI never waits on the playback core (e.g. while it opens a slow network file).
final class MPVCore: @unchecked Sendable {
    let handle: OpaquePointer
    /// False once `destroy()` has run; the handle must not be used after that.
    private(set) var isAlive = true

    init(options: KeyValuePairs<String, String>) throws {
        guard let handle = mpv_create() else { throw MPVError.unavailable }
        self.handle = handle
        for (name, value) in options {
            let status = mpv_set_option_string(handle, name, value)
            if status < 0 {
                playerLog.warning("mpv option \(name, privacy: .public)=\(value, privacy: .public) rejected: \(Self.describe(status), privacy: .public)")
            }
        }
        let status = mpv_initialize(handle)
        guard status >= 0 else {
            mpv_destroy(handle)
            throw MPVError.initializationFailed(Self.describe(status))
        }
        mpv_request_log_messages(handle, "warn")
    }

    static func describe(_ status: Int32) -> String {
        String(cString: mpv_error_string(status))
    }

    /// Stops playback and frees the mpv instance. Later commands and property changes are ignored,
    /// because windows are still being closed (and stopping playback) after the app has shut the player down.
    func destroy() {
        guard isAlive else { return }
        isAlive = false
        mpv_terminate_destroy(handle)
    }

    func command(_ arguments: String...) {
        guard isAlive else { return }
        var pointers: [UnsafePointer<CChar>?] = arguments.map { UnsafePointer(strdup($0)) }
        pointers.append(nil)
        defer { pointers.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        let status = mpv_command_async(handle, 0, &pointers)
        if status < 0 {
            playerLog.error("mpv command \(arguments.first ?? "", privacy: .public) failed: \(Self.describe(status), privacy: .public)")
        }
    }

    func set(_ property: String, _ value: String) {
        guard isAlive else { return }
        let status = value.withCString { text -> Int32 in
            var pointer: UnsafePointer<CChar>? = text
            return mpv_set_property_async(handle, 0, property, MPV_FORMAT_STRING, &pointer)
        }
        if status < 0 {
            playerLog.error("mpv property \(property, privacy: .public) rejected: \(Self.describe(status), privacy: .public)")
        }
    }

    func observe(_ property: String, format: mpv_format) {
        guard isAlive else { return }
        mpv_observe_property(handle, 0, property, format)
    }

    /// Converts an mpv node tree into plain Swift values.
    static func value(of node: mpv_node) -> Any? {
        switch node.format {
        case MPV_FORMAT_STRING:
            return node.u.string.map { String(cString: $0) }
        case MPV_FORMAT_FLAG:
            return node.u.flag != 0
        case MPV_FORMAT_INT64:
            return Int(node.u.int64)
        case MPV_FORMAT_DOUBLE:
            return node.u.double_
        case MPV_FORMAT_NODE_ARRAY:
            guard let list = node.u.list?.pointee, let values = list.values else { return [Any]() }
            return (0..<Int(list.num)).compactMap { value(of: values[$0]) }
        case MPV_FORMAT_NODE_MAP:
            guard let list = node.u.list?.pointee, let values = list.values, let keys = list.keys else {
                return [String: Any]()
            }
            var map: [String: Any] = [:]
            for index in 0..<Int(list.num) {
                guard let key = keys[index] else { continue }
                map[String(cString: key)] = value(of: values[index])
            }
            return map
        default:
            return nil
        }
    }
}

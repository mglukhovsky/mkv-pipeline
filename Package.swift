// swift-tools-version: 6.0
import Foundation
import PackageDescription

// libmpv and libmediainfo come from Homebrew. pkg-config supplies the search
// paths when it is on PATH; these flags cover shells and IDEs where it is not.
let homebrewPrefix: String = {
    if let prefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"], !prefix.isEmpty {
        return prefix
    }
    return FileManager.default.fileExists(atPath: "/opt/homebrew/include") ? "/opt/homebrew" : "/usr/local"
}()
let homebrewHeaders: [SwiftSetting] = [.unsafeFlags(["-I\(homebrewPrefix)/include"])]
let homebrewLibraries: [LinkerSetting] = [.unsafeFlags(["-L\(homebrewPrefix)/lib"])]

let package = Package(
    name: "MKVPipeline",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CMPV", pkgConfig: "mpv", providers: [.brew(["mpv"])]),
        // No pkgConfig here: the shim declares the C API itself, so only the library path is needed.
        .systemLibrary(name: "CMediaInfo", providers: [.brew(["libmediainfo"])]),
        .target(
            name: "MKVPipelineCore",
            dependencies: ["CMediaInfo"],
            swiftSettings: homebrewHeaders,
            linkerSettings: homebrewLibraries
        ),
        .executableTarget(
            name: "MKVPipeline",
            dependencies: ["MKVPipelineCore", "CMPV"],
            // mpv's embedding API renders through OpenGL, which macOS deprecates wholesale.
            swiftSettings: homebrewHeaders + [.unsafeFlags(["-Xcc", "-DGL_SILENCE_DEPRECATION"])],
            linkerSettings: homebrewLibraries
        ),
        .testTarget(
            name: "MKVPipelineTests",
            dependencies: ["MKVPipelineCore", "MKVPipeline"],
            resources: [.copy("Fixtures")],
            swiftSettings: homebrewHeaders,
            linkerSettings: homebrewLibraries
        ),
    ]
)

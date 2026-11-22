import CMediaInfo
import Foundation

/// Reads a file's MediaInfo report in-process through libmediainfo.
public enum MediaInfoReader {
    public static func read(_ url: URL) -> MediaState {
        do {
            return .loaded(try MediaInfoParser.parse(json: Data(try report(for: url).utf8)))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The JSON document `mediainfo --ParseSpeed=0 --Output=JSON <file>` prints, minus the
    /// file-system fields.
    ///
    /// The file is read here and handed to libmediainfo in chunks. Letting the
    /// library open the path itself would route it through the C locale, which
    /// fails for non-ASCII names unless the process-wide locale is changed.
    public static func report(for url: URL) throws -> String {
        let file = open(url.path, O_RDONLY)
        guard file >= 0 else { throw MediaInfoError.unreadable }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw MediaInfoError.unreadable }
        let fileSize = UInt64(info.st_size)

        guard let handle = MediaInfo_New() else { throw MediaInfoError.unreadable }
        defer { MediaInfo_Delete(handle) }
        setOption(handle, "Inform", "JSON")
        // Fastest mode: headers and the first packets only, instead of the default's 15–25 seconds of
        // every stream. That is a few MB per file rather than tens. It gives up measured values the
        // app does not show, such as the frame rate of files whose header carries no frame duration.
        setOption(handle, "ParseSpeed", "0")

        let chunkSize = 256 << 10
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { chunk.deallocate() }

        let finished = 0x08
        let noSeekRequested = UInt64.max
        var offset: UInt64 = 0
        _ = MediaInfo_Open_Buffer_Init(handle, fileSize, 0)
        while true {
            let count = pread(file, chunk, chunkSize, off_t(offset))
            if count < 0 {
                if errno == EINTR { continue }
                throw MediaInfoError.unreadable
            }
            if count == 0 { break }
            offset += UInt64(count)

            if MediaInfo_Open_Buffer_Continue(handle, chunk, count) & finished != 0 { break }
            // The parser jumps around (e.g. to the tags at the end of the file) instead of reading everything.
            let target = MediaInfo_Open_Buffer_Continue_GoTo_Get(handle)
            if target != noSeekRequested {
                offset = target
                _ = MediaInfo_Open_Buffer_Init(handle, fileSize, offset)
            }
        }
        _ = MediaInfo_Open_Buffer_Finalize(handle)

        guard let text = MediaInfo_Inform(handle, 0) else { throw MediaInfoError.malformedReport }
        return string(fromWide: text)
    }

    private static func setOption(_ handle: UnsafeMutableRawPointer, _ name: String, _ value: String) {
        wide(name).withUnsafeBufferPointer { name in
            wide(value).withUnsafeBufferPointer { value in
                _ = MediaInfo_Option(handle, name.baseAddress, value.baseAddress)
            }
        }
    }

    // libmediainfo's Unicode build takes UTF-32 wchar_t strings on macOS.
    private static func wide(_ string: String) -> [wchar_t] {
        string.unicodeScalars.map { wchar_t(bitPattern: $0.value) } + [0]
    }

    private static func string(fromWide pointer: UnsafePointer<wchar_t>) -> String {
        var scalars = String.UnicodeScalarView()
        var cursor = pointer
        while cursor.pointee != 0 {
            scalars.append(Unicode.Scalar(UInt32(bitPattern: cursor.pointee)) ?? "\u{FFFD}")
            cursor += 1
        }
        return String(scalars)
    }
}

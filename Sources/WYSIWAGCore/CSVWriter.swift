import Foundation
import Darwin

public enum CSV {
    public static let header = "timestamp,active_app,window_title,visible_text,dwell_seconds\r\n"
    public static func quote(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    public static func encode(_ row: CaptureRow) -> String {
        row.fields.map(quote).joined(separator: ",") + "\r\n"
    }
}

public actor CSVWriter {
    public let folder: URL
    public init(folder: URL) { self.folder = folder }

    public func append(_ row: CaptureRow) throws {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let url = folder.appendingPathComponent("wysiwag-\(row.day).csv")
            let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw SafeFailure.localWrite }
            defer { close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { throw SafeFailure.localWrite }
            defer { flock(fd, LOCK_UN) }
            let originalSize = lseek(fd, 0, SEEK_END)
            guard originalSize >= 0 else { throw SafeFailure.localWrite }
            let data = Data(((originalSize == 0 ? CSV.header : "") + CSV.encode(row)).utf8)
            do {
                try data.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let written = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { throw SafeFailure.localWrite }
                        offset += written
                    }
                }
                guard fsync(fd) == 0 else { throw SafeFailure.localWrite }
            } catch {
                // Roll back a partial row so the next launch does not append onto corrupt CSV.
                _ = ftruncate(fd, originalSize)
                _ = fsync(fd)
                throw SafeFailure.localWrite
            }
        } catch { throw SafeFailure.localWrite }
    }
}

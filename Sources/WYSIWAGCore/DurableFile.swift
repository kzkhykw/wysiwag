import Foundation
import Darwin

/// Ordered data + metadata persistence. Unsupported full-flush filesystems fail explicitly.
enum DurableFile {
    static func sync(_ fd: Int32) throws {
        guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw SafeFailure.localWrite }
    }
    static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw SafeFailure.localWrite }
        defer { close(fd) }
        try sync(fd)
    }
    static func directory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { return }
        try directory(url.deletingLastPathComponent())
        guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw SafeFailure.localWrite }
        try syncDirectory(url.deletingLastPathComponent())
    }
    static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SafeFailure.localWrite }
                offset += count
            }
        }
    }
    static func replace(_ data: Data, at url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try directory(parent)
        let temporary = parent.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SafeFailure.localWrite }
        defer { close(fd); _ = unlink(temporary.path) }
        try writeAll(data, to: fd)
        try sync(fd)
        guard rename(temporary.path, url.path) == 0 else { throw SafeFailure.localWrite }
        try syncDirectory(parent)
    }
    static func remove(_ url: URL) throws {
        guard unlink(url.path) == 0 || errno == ENOENT else { throw SafeFailure.localWrite }
        try syncDirectory(url.deletingLastPathComponent())
    }
}

struct OutboxBatch: Codable {
    var jobs: [CloudJob]
}

/// Write-ahead transaction: CSV bytes and all destination intents share one durable identity.
/// Recovery rolls forward before publishing the batch. A batch with a matching .txn is never sent.
struct CSVTransaction: Codable {
    let id: UUID
    let csvURL: URL
    let offset: Int64
    let row: CaptureRow
    let bytes: Data
    let jobs: [CloudJob]

    static func pending(in folder: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "txn" }.sorted { $0.path < $1.path }
    }
    static func read(_ url: URL) throws -> Self { try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
    static func withCSV<T>(_ url: URL, _ body: (Int32) throws -> T) throws -> T {
        try DurableFile.directory(url.deletingLastPathComponent())
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SafeFailure.localWrite }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw SafeFailure.localWrite }
        defer { flock(fd, LOCK_UN) }
        return try body(fd)
    }
    static func recover(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let transaction: CSVTransaction
        do { transaction = try read(url) }
        catch { if !FileManager.default.fileExists(atPath: url.path) { return }; throw error }
        try withCSV(transaction.csvURL) { fd in
            // Another actor may have recovered it while we waited for the file lock.
            if FileManager.default.fileExists(atPath: url.path) { try transaction.finish(at: url, fd: fd) }
        }
    }
    func finish(at journal: URL, fd: Int32) throws {
        let size = lseek(fd, 0, SEEK_END)
        guard offset >= 0, size >= offset, size <= offset + Int64(bytes.count),
              bytes == Data(((offset == 0 ? CSV.header : "") + CSV.encode(row)).utf8) else { throw SafeFailure.localWrite }
        guard ftruncate(fd, offset) == 0, lseek(fd, offset, SEEK_SET) == offset else { throw SafeFailure.localWrite }
        try DurableFile.writeAll(bytes, to: fd)
        try DurableFile.sync(fd)
        try DurableFile.syncDirectory(csvURL.deletingLastPathComponent())
        try DurableFile.replace(JSONEncoder().encode(offset + Int64(bytes.count)), at: csvURL.appendingPathExtension("offset"))
        if !jobs.isEmpty {
            try DurableFile.replace(JSONEncoder().encode(OutboxBatch(jobs: jobs)),
                                    at: journal.deletingPathExtension().appendingPathExtension("json"))
        }
        try DurableFile.remove(journal)
    }
}

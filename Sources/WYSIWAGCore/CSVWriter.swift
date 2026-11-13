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
    private var unsettled: (transaction: CSVTransaction, journal: URL)?
    public init(folder: URL) { self.folder = folder }

    /// Reconcile an uncertain append before the live recorder compares its next screen.
    public func reconcile() throws -> ScreenSnapshot? {
        guard let pending = unsettled else { return nil }
        try CSVTransaction.recover(pending.journal)
        unsettled = nil
        return pending.transaction.row.screen
    }

    public func append(_ row: CaptureRow, jobs: [CloudJob] = [], outbox: URL? = nil) throws {
        do {
            _ = try reconcile()
            let journals = outbox ?? folder.appendingPathComponent(".wysiwag-journal")
            let url = folder.appendingPathComponent("wysiwag-\(row.day).csv")
            try CSVTransaction.withCSV(url) { fd in
                for pending in try CSVTransaction.pending(in: journals) {
                    let transaction: CSVTransaction?
                    do { transaction = try CSVTransaction.read(pending, forCSV: url) }
                    catch { if !FileManager.default.fileExists(atPath: pending.path) { continue }; throw error }
                    if let transaction { try transaction.finish(at: pending, fd: fd) }
                }
                let size = lseek(fd, 0, SEEK_END)
                let checkpoint = url.appendingPathExtension("offset")
                let committed: Int64
                if let data = try? Data(contentsOf: checkpoint), let offset = try? JSONDecoder().decode(Int64.self, from: data), offset >= 0, offset <= size {
                    committed = offset
                } else {
                    // Import/recover a legacy file once, respecting quoted multiline records.
                    committed = try Self.completePrefix(Data(contentsOf: url))
                }
                guard ftruncate(fd, committed) == 0 else { throw SafeFailure.localWrite }
                try DurableFile.sync(fd)
                let transaction = CSVTransaction(id: UUID(), csvURL: url, offset: committed, row: row,
                    bytes: Data(((committed == 0 ? CSV.header : "") + CSV.encode(row)).utf8), jobs: jobs)
                let journal = journals.appendingPathComponent(transaction.id.uuidString + ".txn")
                do { try DurableFile.replace(JSONEncoder().encode(transaction), at: journal) }
                catch {
                    // A directory-flush failure can occur after the journal was renamed.
                    if FileManager.default.fileExists(atPath: journal.path) { unsettled = (transaction, journal) }
                    throw error
                }
                unsettled = (transaction, journal)
                // From this point, errors/cancellation leave a recoverable transaction, not a partial CSV.
                try transaction.finish(at: journal, fd: fd)
                unsettled = nil
            }
        } catch { throw SafeFailure.localWrite }
    }

    static func completePrefix(_ data: Data) throws -> Int64 {
        let header = Data(CSV.header.utf8)
        if data.count < header.count {
            guard header.starts(with: data) else { throw SafeFailure.localWrite }
            return 0
        }
        guard data.starts(with: header) else { throw SafeFailure.localWrite }
        enum State { case start, plain, quoted, endQuote }
        var state = State.start, fields = 1, last = header.count, i = header.count
        let bytes = Array(data)
        while i < bytes.count {
            let byte = bytes[i]
            if state == .quoted {
                if byte == 34 { state = .endQuote }
            } else if state == .endQuote && byte == 34 { state = .quoted }
            else if byte == 44 { fields += 1; state = .start }
            else if byte == 13 && i + 1 < bytes.count && bytes[i + 1] == 10 {
                guard fields == 5 else { return Int64(last) }
                i += 1; last = i + 1; fields = 1; state = .start
            } else if byte == 34 && state == .start { state = .quoted }
            else if state == .endQuote || byte == 34 || byte == 10 || byte == 13 { return Int64(last) }
            else { state = .plain }
            i += 1
        }
        return Int64(last)
    }
}

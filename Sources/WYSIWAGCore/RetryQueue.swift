import Foundation

public struct QueueStatus: Sendable {
    public var pending: Int
    public var blocked: Int
}

/// One small JSON file per pending row/destination. Credentials are looked up only at send time.
/// Never deletes a failed job. The CSV remains authoritative even if queue storage itself fails.
public actor RetryQueue {
    public let folder: URL
    private let notion: any CloudWriting
    private let sheets: any CloudWriting
    private var draining = false
    private var cooldowns: [CloudDestination: Date] = [:]
    private let clock: @Sendable () -> Date

    public init(folder: URL, notion: any CloudWriting, sheets: any CloudWriting,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.folder = folder; self.notion = notion; self.sheets = sheets; self.clock = clock
    }

    private func files() throws -> [URL] {
        if !FileManager.default.fileExists(atPath: folder.path) { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func restoreCooldowns() throws {
        let url = folder.appendingPathComponent("cooldowns.state")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let saved = try JSONDecoder().decode([String: Date].self, from: Data(contentsOf: url))
            for (name, date) in saved {
                if let destination = CloudDestination(rawValue: name) {
                    cooldowns[destination] = max(cooldowns[destination] ?? .distantPast, date)
                }
            }
        } catch { throw SafeFailure.queueWrite }
    }
    private func saveCooldowns() throws {
        do {
            let saved = Dictionary(uniqueKeysWithValues: cooldowns.map { ($0.key.rawValue, $0.value) })
            try JSONEncoder().encode(saved).write(to: folder.appendingPathComponent("cooldowns.state"), options: .atomic)
        } catch { throw SafeFailure.queueWrite }
    }
    private func read(_ url: URL) throws -> CloudJob {
        do { return try JSONDecoder().decode(CloudJob.self, from: Data(contentsOf: url)) }
        catch { throw SafeFailure.queueWrite }
    }
    private func save(_ job: CloudJob) throws {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = folder.appendingPathComponent(job.id.uuidString + ".json")
            let data = try JSONEncoder().encode(job)
            // write atomically with restrictive permissions on the temporary file as well.
            let temp = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw SafeFailure.queueWrite }
            defer { try? FileManager.default.removeItem(at: temp) }
            let handle = try FileHandle(forWritingTo: temp)
            do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
            catch { try? handle.close(); throw error }
            guard rename(temp.path, url.path) == 0 else { throw SafeFailure.queueWrite }
        } catch { throw SafeFailure.queueWrite }
    }

    public func enqueue(row: CaptureRow, settings: AppSettings) throws {
        if settings.notionEnabled { try save(CloudJob(row: row, destination: .notion, settings: settings)) }
        if settings.googleEnabled { try save(CloudJob(row: row, destination: .sheets, settings: settings)) }
    }
    public func status() throws -> QueueStatus {
        let jobs = try files().map(read)
        return QueueStatus(pending: jobs.count, blocked: jobs.filter(\.blocked).count)
    }
    public func retryBlocked() throws {
        for url in try files() {
            var job = try read(url)
            guard job.blocked else { continue }
            job.blocked = false; job.attempts = 0; job.nextAttempt = .distantPast
            try save(job)
        }
    }

    public func drain(settings: AppSettings, now: Date? = nil) async throws {
        guard !draining else { return }
        draining = true; defer { draining = false }
        let started = clock(), now = now ?? clock()
        try restoreCooldowns()
        var processed = 0
        for url in try files() {
            try Task.checkCancellation()
            var job = try read(url)
            guard job.isEnabled(in: settings), !job.blocked, job.nextAttempt <= now,
                  (cooldowns[job.destination] ?? .distantPast) <= now else { continue }
            let writer = job.destination == .notion ? notion : sheets
            do {
                let remaining = try await writer.deliver(job)
                // Always checkpoint an acknowledged write, even if cancellation arrived during it.
                if let remaining { try save(remaining) }
                else { try FileManager.default.removeItem(at: url) }
            } catch {
                if case SafeFailure.queueWrite = error { throw error }
                if Task.isCancelled { return }
                let responseTime = now.addingTimeInterval(max(0, clock().timeIntervalSince(started)))
                job.attempts += 1
                var delay = min(3600, pow(2, Double(min(job.attempts, 11))))
                if case let SafeFailure.http(status, retryAfter) = error {
                    job.lastStatus = status
                    if status == 429 || status == 529 {
                        delay = max(delay, retryAfter ?? 30)
                        cooldowns[job.destination] = responseTime.addingTimeInterval(delay)
                        try saveCooldowns()
                    } else if (400..<500).contains(status) && status != 408 {
                        job.blocked = true
                    }
                } else if let failure = error as? SafeFailure, failure == .invalidConfiguration || failure == .authentication {
                    job.blocked = true
                }
                if job.attempts >= 12 { job.blocked = true }
                job.nextAttempt = responseTime.addingTimeInterval(delay)
                try save(job)
            }
            processed += 1
            if processed >= 2 { break }
        }
    }
}

public actor CaptureRecorder {
    private var previous: ScreenSnapshot?
    private let csv: CSVWriter
    private let queue: RetryQueue
    public init(csv: CSVWriter, queue: RetryQueue) { self.csv = csv; self.queue = queue }
    public init(csv: CSVWriter, queue: RetryQueue, previous: ScreenSnapshot?) {
        self.csv = csv; self.queue = queue; self.previous = previous
    }
    public func lastWrittenScreen() -> ScreenSnapshot? { previous }

    public func record(_ screen: ScreenSnapshot, settings: AppSettings, classifier: any ScreenChangeClassifier) async throws -> Bool {
        if settings.mode != .all {
            let detector: any ScreenChangeClassifier = settings.mode == .auto ? AutoClassifier(threshold: settings.similarityThreshold) : classifier
            let baseline = previous ?? ScreenSnapshot(timestamp: screen.timestamp, app: "", bundleID: "", title: "", text: "")
            let decision = await detector.classify(previous: baseline, current: screen)
            if previous != nil && decision == .unchanged { return false }
        }
        try Task.checkCancellation()
        let row = CaptureRow(screen: screen, previousWrittenAt: previous?.timestamp)
        try await csv.append(row)
        previous = screen // advance only after the local append succeeds
        try await queue.enqueue(row: row, settings: settings)
        return true
    }
}

import Foundation

public struct QueueStatus: Sendable {
    public var pending: Int
    public var blocked: Int
    public var quarantined: Int
    public var recovering: Int
}

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
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func quarantine(_ url: URL) throws {
        let destination = folder.appendingPathComponent("Quarantine")
        try DurableFile.directory(destination)
        guard rename(url.path, destination.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent).path) == 0 else { throw SafeFailure.queueWrite }
        try DurableFile.syncDirectory(destination); try DurableFile.syncDirectory(folder)
    }
    private func read(_ url: URL) throws -> OutboxBatch? {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { try quarantine(url); return nil }
        let batch: OutboxBatch
        if let decoded = try? JSONDecoder().decode(OutboxBatch.self, from: data) { batch = decoded }
        else if let legacy = try? JSONDecoder().decode(CloudJob.self, from: data) { batch = OutboxBatch(jobs: [legacy]) }
        else { try quarantine(url); return nil }
        let valid = batch.jobs.filter { (try? $0.validateProgress()) != nil }
        guard valid.count != batch.jobs.count else { return batch }
        guard !valid.isEmpty else { try quarantine(url); return nil }
        // Preserve the complete original bytes BEFORE replacing a mixed batch. A crash
        // cannot discard its valid siblings between quarantine and republication.
        let retained = folder.appendingPathComponent("Quarantine").appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try DurableFile.replace(data, at: retained)
        let repaired = OutboxBatch(jobs: valid)
        try save(repaired, at: url)
        return repaired
    }
    private func save(_ batch: OutboxBatch, at url: URL) throws {
        do {
            if batch.jobs.isEmpty { try DurableFile.remove(url) }
            else { try DurableFile.replace(JSONEncoder().encode(batch), at: url) }
        } catch { throw SafeFailure.queueWrite }
    }
    private func restoreCooldowns() throws {
        let url = folder.appendingPathComponent("cooldowns.state")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let saved = try JSONDecoder().decode([String: Date].self, from: Data(contentsOf: url))
        for (name, date) in saved {
            if let destination = CloudDestination(rawValue: name) { cooldowns[destination] = max(cooldowns[destination] ?? .distantPast, date) }
        }
    }
    private func saveCooldowns() throws {
        let saved = Dictionary(uniqueKeysWithValues: cooldowns.map { ($0.key.rawValue, $0.value) })
        try DurableFile.replace(JSONEncoder().encode(saved), at: folder.appendingPathComponent("cooldowns.state"))
    }
    public static func jobs(row: CaptureRow, settings: AppSettings) -> [CloudJob] {
        var jobs: [CloudJob] = []
        if settings.notionEnabled { jobs.append(CloudJob(row: row, destination: .notion, settings: settings)) }
        if settings.googleEnabled { jobs.append(CloudJob(row: row, destination: .sheets, settings: settings)) }
        return jobs
    }
    public func enqueue(row: CaptureRow, settings: AppSettings) throws {
        let jobs = Self.jobs(row: row, settings: settings)
        if !jobs.isEmpty { try save(OutboxBatch(jobs: jobs), at: folder.appendingPathComponent(UUID().uuidString + ".json")) }
    }
    public func status() throws -> QueueStatus {
        let jobs = try files().compactMap(read).flatMap(\.jobs)
        let quarantine = folder.appendingPathComponent("Quarantine")
        let count = (try? FileManager.default.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil).count) ?? 0
        let recovering = try CSVTransaction.pending(in: folder).count
        return QueueStatus(pending: jobs.count, blocked: jobs.filter(\.blocked).count + count + recovering,
                           quarantined: count, recovering: recovering)
    }
    public func retryBlocked() throws {
        for url in try files() {
            guard !FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("txn").path) else { continue }
            guard var batch = try read(url) else { continue }
            for index in batch.jobs.indices where batch.jobs[index].blocked {
                batch.jobs[index].blocked = false; batch.jobs[index].attempts = 0; batch.jobs[index].nextAttempt = .distantPast
            }
            try save(batch, at: url)
        }
    }
    public func drain(settings: AppSettings, now: Date? = nil) async throws {
        guard !draining else { return }
        draining = true; defer { draining = false }
        let started = clock(), now = now ?? clock()
        for journal in try CSVTransaction.pending(in: folder) {
            // Keep an unresolved transaction and its batch gated, but let independent jobs drain.
            // status() reports retained journals, including unavailable CSV folders/invalid bytes.
            do { try CSVTransaction.recover(journal) } catch { continue }
        }
        try restoreCooldowns()
        var processed = 0
        outer: for url in try files() {
            guard !FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("txn").path),
                  var batch = try read(url) else { continue }
            var index = 0
            while index < batch.jobs.count {
                try Task.checkCancellation()
                var job = batch.jobs[index]
                guard job.isEnabled(in: settings), !job.blocked, job.nextAttempt <= now,
                      (cooldowns[job.destination] ?? .distantPast) <= now else { index += 1; continue }
                do {
                    let remaining = try await (job.destination == .notion ? notion : sheets).deliver(job)
                    if let remaining { batch.jobs[index] = remaining; index += 1 }
                    else { batch.jobs.remove(at: index) }
                    // Checkpoint even when cancellation arrived during an acknowledged write.
                    try save(batch, at: url)
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
                        } else if (400..<500).contains(status) && status != 408 { job.blocked = true }
                    } else if let failure = error as? SafeFailure, failure == .invalidConfiguration || failure == .authentication { job.blocked = true }
                    if job.attempts >= 12 { job.blocked = true }
                    job.nextAttempt = responseTime.addingTimeInterval(delay)
                    batch.jobs[index] = job; index += 1
                    try save(batch, at: url)
                }
                processed += 1
                if processed >= 2 { break outer }
            }
        }
    }
}

actor AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { locked = false }
        else { waiters.removeFirst().resume() }
    }
}

/// Retains retiring tasks; a replacement cannot execute until its predecessor finishes.
@MainActor public final class SerialTask {
    private var task: Task<Void, Never>?
    public init() {}
    public func start(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        let previous = task
        previous?.cancel()
        task = Task {
            await previous?.value
            if !Task.isCancelled { await operation() }
        }
    }
    public func cancel() { task?.cancel() }
    public func wait() async { await task?.value }
}

public actor CaptureRecorder {
    private var previous: ScreenSnapshot?
    private let csv: CSVWriter
    private let queue: RetryQueue
    private let mutex = AsyncMutex()
    public init(csv: CSVWriter, queue: RetryQueue, previous: ScreenSnapshot? = nil) {
        self.csv = csv; self.queue = queue; self.previous = previous
    }
    public func lastWrittenScreen() async throws -> ScreenSnapshot? {
        await mutex.acquire(); defer { Task { await mutex.release() } }
        if let recovered = try await csv.reconcile() { previous = recovered }
        return previous
    }
    public func record(_ screen: ScreenSnapshot, settings: AppSettings, classifier: any ScreenChangeClassifier) async throws -> Bool {
        await mutex.acquire(); defer { Task { await mutex.release() } }
        try Task.checkCancellation()
        if let recovered = try await csv.reconcile() { previous = recovered }
        if settings.mode != .all {
            let detector: any ScreenChangeClassifier = settings.mode == .auto ? AutoClassifier(threshold: settings.similarityThreshold) : classifier
            let baseline = previous ?? ScreenSnapshot(timestamp: screen.timestamp, app: "", bundleID: "", title: "", text: "")
            let decision = await detector.classify(previous: baseline, current: screen)
            if previous != nil && decision == .unchanged { return false }
        }
        try Task.checkCancellation()
        let row = CaptureRow(screen: screen, previousWrittenAt: previous?.timestamp)
        try await csv.append(row, jobs: RetryQueue.jobs(row: row, settings: settings), outbox: queue.folder)
        previous = screen
        return true
    }
}

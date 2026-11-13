import Foundation
import Testing
@testable import WYSIWAGCore

private actor DeliveryProbe: CloudWriting {
    var received: [UUID] = []
    let csv: URL?
    let expected: String?
    init(csv: URL? = nil, expected: String? = nil) { self.csv = csv; self.expected = expected }
    func deliver(_ job: CloudJob) async throws -> CloudJob? {
        if let csv, let expected { #expect(try String(contentsOf: csv, encoding: .utf8) == expected) }
        received.append(job.id)
        return nil
    }
}

actor AsyncGate {
    var entered = false
    var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { released = true; for waiter in waiters { waiter.resume() }; waiters.removeAll() }
    func untilEntered() async throws {
        for _ in 0..<200 {
            if entered { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SafeFailure.network
    }
}
private actor GatedClassifier: ScreenChangeClassifier {
    let gate = AsyncGate()
    var baselines: [String] = []
    func classify(previous: ScreenSnapshot, current: ScreenSnapshot) async -> ChangeDecision {
        baselines.append(previous.text)
        if baselines.count == 1 { await gate.wait() }
        return .changed
    }
}

extension CoreTests {
    @Test func csvJournalRecoversCrashAtEveryCommitBoundary() async throws {
        // Kill/crash states: prepared only, partial quoted multiline bytes, CSV complete,
        // batch published but journal not removed. No ordinary catch/rollback runs.
        for phase in 0..<4 {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let first = CaptureRow(screen: sample("baseline"), previousWrittenAt: nil)
            try await CSVWriter(folder: folder).append(first)
            let file = folder.appendingPathComponent("wysiwag-\(first.day).csv")
            let committed = try Data(contentsOf: file)
            let row = CaptureRow(screen: sample("before, \"quoted\"\n日本語\nafter", date: first.screen.timestamp.addingTimeInterval(5)), previousWrittenAt: first.screen.timestamp)
            var settings = AppSettings(); settings.notionEnabled = true; settings.googleEnabled = true
            let jobs = RetryQueue.jobs(row: row, settings: settings)
            let bytes = Data(CSV.encode(row).utf8)
            let transaction = CSVTransaction(id: UUID(), csvURL: file, offset: Int64(committed.count), row: row, bytes: bytes, jobs: jobs)
            let outbox = folder.appendingPathComponent("outbox")
            let journal = outbox.appendingPathComponent(transaction.id.uuidString + ".txn")
            try DurableFile.replace(JSONEncoder().encode(transaction), at: journal)
            let cut = phase == 0 ? 0 : (phase == 1 ? bytes.count - 8 : bytes.count)
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: bytes.prefix(cut)); try handle.close()
            if phase == 3 {
                try DurableFile.replace(JSONEncoder().encode(OutboxBatch(jobs: jobs)), at: journal.deletingPathExtension().appendingPathExtension("json"))
            }
            let expected = CSV.header + CSV.encode(first) + CSV.encode(row)
            let writer = DeliveryProbe(csv: file, expected: expected)
            let queue = RetryQueue(folder: outbox, notion: writer, sheets: writer)
            try await queue.drain(settings: settings)
            #expect(try String(contentsOf: file, encoding: .utf8) == expected)
            #expect(await writer.received == jobs.map(\.id))
            #expect(try await queue.status().pending == 0)
            #expect(try CSVTransaction.pending(in: outbox).isEmpty)
            try await queue.drain(settings: settings)
            #expect(await writer.received.count == 2)
            let next = CaptureRow(screen: sample("next", date: row.screen.timestamp.addingTimeInterval(5)), previousWrittenAt: row.screen.timestamp)
            try await CSVWriter(folder: folder).append(next, outbox: outbox)
            #expect(try String(contentsOf: file, encoding: .utf8) == expected + CSV.encode(next))
        }
    }
    @Test func legacyAndCheckpointedCSVRecoverMultilineTail() async throws {
        for hasCheckpoint in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let first = CaptureRow(screen: sample("first, \"quoted\"\n日本語"), previousWrittenAt: nil)
            try await CSVWriter(folder: folder).append(first)
            let file = folder.appendingPathComponent("wysiwag-\(first.day).csv")
            if !hasCheckpoint { try FileManager.default.removeItem(at: file.appendingPathExtension("offset")) }
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: Data("2026,App,Title,\"partial\nquoted\"\"tail".utf8)); try handle.close()
            let next = CaptureRow(screen: sample("next"), previousWrittenAt: first.screen.timestamp)
            try await CSVWriter(folder: folder).append(next)
            #expect(try String(contentsOf: file, encoding: .utf8) == CSV.header + CSV.encode(first) + CSV.encode(next))
        }
    }
    @Test func malformedJobIsQuarantinedWithoutStarvingOtherDestinations() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try DurableFile.replace(Data("{broken".utf8), at: folder.appendingPathComponent("000.json"))
        var settings = AppSettings(); settings.notionEnabled = true; settings.googleEnabled = true
        let writer = DeliveryProbe()
        let queue = RetryQueue(folder: folder, notion: writer, sheets: writer)
        try await queue.enqueue(row: CaptureRow(screen: sample(), previousWrittenAt: nil), settings: settings)
        let state = try await queue.status()
        #expect(state.pending == 2 && state.quarantined == 1 && state.blocked == 1)
        try await queue.retryBlocked()
        try await queue.drain(settings: settings)
        #expect(await writer.received.count == 2)
        #expect(try await queue.status().pending == 0)
        let preserved = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("Quarantine"), includingPropertiesForKeys: nil)
        #expect(try Data(contentsOf: preserved[0]) == Data("{broken".utf8))
    }
    @Test @MainActor func retiringCaptureCompletesBeforeResumeAndReplacement() async throws {
        let lifetime = SerialTask(), gate = AsyncGate()
        var events: [String] = []
        lifetime.start { await gate.wait(); events.append("old commit") }
        try await gate.untilEntered()
        lifetime.cancel()
        lifetime.start { events.append("resume") }
        // Model a second pause/apply while the retiring commit ignores cancellation.
        lifetime.cancel()
        let waiter = Task { await lifetime.wait(); events.append("replace recorder") }
        await Task.yield()
        #expect(events.isEmpty)
        await gate.release(); await waiter.value
        #expect(events == ["old commit", "replace recorder"])
        lifetime.start { events.append("new commit") }
        await lifetime.wait()
        #expect(events.last == "new commit")
    }
    @Test func recorderSerializesBaselineAndDwellAcrossSuspensions() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = DeliveryProbe(), classifier = GatedClassifier()
        let queue = RetryQueue(folder: folder.appendingPathComponent("outbox"), notion: probe, sheets: probe)
        let recorder = CaptureRecorder(csv: CSVWriter(folder: folder), queue: queue)
        var settings = AppSettings(); settings.mode = .smart
        let config = settings, first = sample("first"), second = sample("second", date: sample().timestamp.addingTimeInterval(5))
        let one = Task { try await recorder.record(first, settings: config, classifier: classifier) }
        try await classifier.gate.untilEntered()
        let two = Task { try await recorder.record(second, settings: config, classifier: classifier) }
        await Task.yield()
        #expect(await classifier.baselines.count == 1)
        await classifier.gate.release()
        #expect(try await one.value)
        #expect(try await two.value)
        #expect(await classifier.baselines == ["", "first"])
        let day = CaptureRow(screen: first, previousWrittenAt: nil).day
        let contents = try String(contentsOf: folder.appendingPathComponent("wysiwag-\(day).csv"), encoding: .utf8)
        #expect(contents.hasSuffix(",second,5.000\r\n"))
    }
}

extension CoreTests {
    @Test func malformedJournalDoesNotBlockCapturesToAnotherDayOrFolder() async throws {
        for anotherFolder in [false, true] {
            for opaque in [false, true] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let folder = root.appendingPathComponent("csv"), outbox = root.appendingPathComponent("outbox")
                let probe = DeliveryProbe(), queue = RetryQueue(folder: outbox, notion: probe, sheets: probe)
                var settings = AppSettings(); settings.mode = .all; settings.notionEnabled = true; settings.googleEnabled = true
                let first = CaptureRow(screen: sample("old day"), previousWrittenAt: nil)
                try await CSVWriter(folder: folder).append(first)
                let original = folder.appendingPathComponent("wysiwag-\(first.day).csv")
                let oldBytes = try Data(contentsOf: original)
                let jobs = RetryQueue.jobs(row: first, settings: settings)
                let id = UUID(), journal = outbox.appendingPathComponent(id.uuidString + ".txn")
                let badBytes = opaque ? Data("{damaged".utf8) : try JSONSerialization.data(withJSONObject: ["csvURL": original.absoluteString, "row": "damaged"])
                try DurableFile.replace(badBytes, at: journal)
                let batch = journal.deletingPathExtension().appendingPathExtension("json")
                let batchBytes = try JSONEncoder().encode(OutboxBatch(jobs: jobs))
                try DurableFile.replace(batchBytes, at: batch)
                let target = anotherFolder ? root.appendingPathComponent("other-csv") : folder
                let next = sample("new capture", date: first.screen.timestamp.addingTimeInterval(anotherFolder ? 5 : 86_400))
                let recorder = CaptureRecorder(csv: CSVWriter(folder: target), queue: queue)
                #expect(try await recorder.record(next, settings: settings, classifier: AutoClassifier()))
                try await queue.retryBlocked(); try await queue.drain(settings: settings)
                let delivered = await probe.received
                #expect(delivered.count == 2 && Set(delivered).isDisjoint(with: Set(jobs.map(\.id))))
                let row = CaptureRow(screen: next, previousWrittenAt: nil)
                #expect(try String(contentsOf: target.appendingPathComponent("wysiwag-\(row.day).csv"), encoding: .utf8) == CSV.header + CSV.encode(row))
                #expect(try Data(contentsOf: original) == oldBytes)
                #expect(try Data(contentsOf: journal) == badBytes)
                #expect(try Data(contentsOf: batch) == batchBytes)
                #expect(try await queue.status().recovering == 1)
            }
        }
    }
    @Test func invalidNotionProgressIsQuarantinedWhileValidJobsContinue() async throws {
        for entryPoint in ["status", "retry", "drain"] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let probe = DeliveryProbe(), queue = RetryQueue(folder: folder, notion: probe, sheets: probe)
            var settings = AppSettings(); settings.notionEnabled = true; settings.googleEnabled = true
            let row = CaptureRow(screen: sample(String(repeating: "x", count: 4_001)), previousWrittenAt: nil)
            let pageID = UUID().uuidString
            let invalidProgress: [(String?, Int)] = [(nil, -1), (pageID, -1), (pageID, 4), (pageID, Int.max), (pageID, 3), (nil, 1), (pageID, 0), ("", 1)]
            var invalidJobs: [CloudJob] = []
            for (page, next) in invalidProgress {
                var job = CloudJob(row: row, destination: .notion, settings: settings)
                job.pageID = page; job.nextBlock = next; invalidJobs.append(job)
            }
            var invalidAttempts = CloudJob(row: row, destination: .notion, settings: settings)
            invalidAttempts.attempts = Int.max; invalidJobs.append(invalidAttempts)
            var invalidSheets = CloudJob(row: row, destination: .sheets, settings: settings)
            invalidSheets.nextBlock = 1; invalidJobs.append(invalidSheets)
            let sibling = CloudJob(row: row, destination: .sheets, settings: settings)
            let batchData = try JSONEncoder().encode(OutboxBatch(jobs: invalidJobs + [sibling]))
            try DurableFile.replace(batchData, at: folder.appendingPathComponent("000-batch.json"))
            let legacyData = try JSONEncoder().encode(invalidJobs[0])
            try DurableFile.replace(legacyData, at: folder.appendingPathComponent("001-legacy.json"))
            var valid = CloudJob(row: row, destination: .notion, settings: settings)
            valid.pageID = pageID; valid.nextBlock = 1
            try DurableFile.replace(JSONEncoder().encode(valid), at: folder.appendingPathComponent("002-valid.json"))
            if entryPoint == "status" { _ = try await queue.status() }
            if entryPoint == "retry" { try await queue.retryBlocked() }
            for _ in 0..<6 { try await queue.drain(settings: settings) }
            #expect(Set(await probe.received) == Set([sibling.id, valid.id]))
            let state = try await queue.status()
            #expect(state.pending == 0 && state.quarantined == 2)
            let quarantined = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("Quarantine"), includingPropertiesForKeys: nil)
            let preserved = try quarantined.map { try Data(contentsOf: $0) }
            #expect(preserved.contains(batchData) && preserved.contains(legacyData))
        }
    }
    @Test func damagedJournalWithMatchingTargetStillStopsThatCSV() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = CaptureRow(screen: sample("first"), previousWrittenAt: nil)
        let csv = CSVWriter(folder: folder), outbox = folder.appendingPathComponent("outbox")
        try await csv.append(first, outbox: outbox)
        let file = folder.appendingPathComponent("wysiwag-\(first.day).csv")
        let before = try Data(contentsOf: file)
        let journal = outbox.appendingPathComponent(UUID().uuidString + ".txn")
        let bytes = try JSONSerialization.data(withJSONObject: ["csvURL": file.absoluteString, "row": "damaged"])
        try DurableFile.replace(bytes, at: journal)
        await #expect(throws: SafeFailure.localWrite) {
            try await csv.append(CaptureRow(screen: sample("second"), previousWrittenAt: first.screen.timestamp), outbox: outbox)
        }
        #expect(try Data(contentsOf: file) == before)
        #expect(try Data(contentsOf: journal) == bytes)
    }
    @Test func recoveredCommitReconcilesLiveBaselineBeforeResumeOrReplacement() async throws {
        for replaceRecorder in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let probe = DeliveryProbe(), outbox = folder.appendingPathComponent("outbox")
            let queue = RetryQueue(folder: outbox, notion: probe, sheets: probe)
            var recorder = CaptureRecorder(csv: CSVWriter(folder: folder), queue: queue)
            let settings = AppSettings(), detector = AutoClassifier(threshold: 1)
            let a = sample("A", date: sample().timestamp)
            let b = sample("B", date: a.timestamp.addingTimeInterval(5))
            let c = sample("A", date: a.timestamp.addingTimeInterval(10))
            #expect(try await recorder.record(a, settings: settings, classifier: detector))
            let file = folder.appendingPathComponent("wysiwag-\(CaptureRow(screen: a, previousWrittenAt: nil).day).csv")
            let checkpoint = file.appendingPathExtension("offset")
            try FileManager.default.removeItem(at: checkpoint)
            // Real persistence failure AFTER B's CSV write, BEFORE its checkpoint/publication.
            try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: false)
            await #expect(throws: SafeFailure.localWrite) { try await recorder.record(b, settings: settings, classifier: detector) }
            #expect(try CSVTransaction.pending(in: outbox).count == 1)
            try FileManager.default.removeItem(at: checkpoint)
            if replaceRecorder {
                // Queue has already completed recovery before apply obtains the old baseline.
                try await queue.drain(settings: settings)
                let previous = try await recorder.lastWrittenScreen()
                #expect(previous?.text == "B")
                recorder = CaptureRecorder(csv: CSVWriter(folder: folder), queue: queue, previous: previous)
            }
            #expect(try await recorder.record(c, settings: settings, classifier: detector))
            let expected = CSV.header + CSV.encode(CaptureRow(screen: a, previousWrittenAt: nil))
                + CSV.encode(CaptureRow(screen: b, previousWrittenAt: a.timestamp))
                + CSV.encode(CaptureRow(screen: c, previousWrittenAt: b.timestamp))
            #expect(try String(contentsOf: file, encoding: .utf8) == expected)
        }
    }
    @Test func unrecoverableTransactionsDoNotBlockIndependentJobs() async throws {
        for malformed in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let probe = DeliveryProbe(), outbox = folder.appendingPathComponent("outbox")
            let queue = RetryQueue(folder: outbox, notion: probe, sheets: probe)
            var settings = AppSettings(); settings.notionEnabled = true; settings.googleEnabled = true
            let row = CaptureRow(screen: sample(), previousWrittenAt: nil)
            let jobs = RetryQueue.jobs(row: row, settings: settings)
            // An unavailable/truncated CSV cannot satisfy this committed prefix.
            let transaction = CSVTransaction(id: UUID(), csvURL: folder.appendingPathComponent("missing.csv"),
                offset: 100, row: row, bytes: Data(CSV.encode(row).utf8), jobs: jobs)
            let journal = outbox.appendingPathComponent(transaction.id.uuidString + ".txn")
            try DurableFile.replace(malformed ? Data("{invalid".utf8) : JSONEncoder().encode(transaction), at: journal)
            try DurableFile.replace(JSONEncoder().encode(OutboxBatch(jobs: jobs)), at: journal.deletingPathExtension().appendingPathExtension("json"))
            try await queue.enqueue(row: row, settings: settings)
            try await queue.drain(settings: settings)
            let delivered = await probe.received
            #expect(delivered.count == 2 && Set(delivered).isDisjoint(with: Set(jobs.map(\.id))))
            let status = try await queue.status()
            #expect(status.recovering == 1 && status.blocked == 1 && status.pending == 2)
            #expect(FileManager.default.fileExists(atPath: journal.path))
            try await queue.retryBlocked(); try await queue.drain(settings: settings)
            #expect(await probe.received.count == 2)
        }
    }
    @Test func concurrentRecordingAndJournalRecoveryPreserveAllRowsAndJobs() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = DeliveryProbe(), outbox = folder.appendingPathComponent("outbox")
        let queue = RetryQueue(folder: outbox, notion: probe, sheets: probe)
        let csv = CSVWriter(folder: folder)
        var settings = AppSettings(); settings.notionEnabled = true; settings.googleEnabled = true
        let config = settings
        let rows = (0..<12).map { CaptureRow(screen: sample("row \($0)\n日本語", date: sample().timestamp.addingTimeInterval(Double($0) * 5)), previousWrittenAt: nil) }
        async let producer: Void = {
            for row in rows { try await csv.append(row, jobs: RetryQueue.jobs(row: row, settings: config), outbox: outbox) }
        }()
        async let consumer: Void = {
            for _ in 0..<24 { try await queue.drain(settings: config); await Task.yield() }
        }()
        try await producer; try await consumer
        for _ in 0..<24 { try await queue.drain(settings: settings) }
        #expect(try await queue.status().pending == 0)
        let ids = await probe.received
        #expect(ids.count == 24 && Set(ids).count == 24)
        #expect(try String(contentsOf: folder.appendingPathComponent("wysiwag-\(rows[0].day).csv"), encoding: .utf8) == CSV.header + rows.map(CSV.encode).joined())
    }
}

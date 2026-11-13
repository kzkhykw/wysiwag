import Foundation
import WYSIWAGCore

/// This driver never loads a saved credential and refuses non-loopback mock origins.
enum VerificationDriver {
    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else {
            FileHandle.standardError.write(Data(("FAIL: " + label + "\n").utf8))
            throw SafeFailure.invalidResponse
        }
    }
    static func control(_ base: URL, path: String) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path)); request.httpMethod = "POST"
        return try await HTTPClient().send(request)
    }
    static func run() async throws {
        guard let raw = WYSIWAGCLI.argument("--mock-base"), let base = URL(string: raw),
              base.scheme == "http", base.host == "127.0.0.1", base.user == nil, base.password == nil,
              let output = WYSIWAGCLI.argument("--output") else { throw SafeFailure.invalidConfiguration }
        let folder = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = try OCR.recognize(file: OCR.fixtureURL)
        let changed = try OCR.recognize(file: OCR.changedFixtureURL)
        try check(original.contains("WYSIWAG") && original.contains("日本語"), "English and Japanese OCR")
        try check(changed != original && changed.contains("画面"), "changed screenshot OCR")
        var report: [[String: Any]] = []
        for mode in CaptureMode.allCases {
            _ = try await control(base, path: "control/reset")
            let runFolder = folder.appendingPathComponent(mode.rawValue)
            var settings = AppSettings(); settings.mode = mode
            settings.localFolder = runFolder.path; settings.notionEnabled = true; settings.googleEnabled = true
            settings.notionDatabaseID = "00000000-0000-0000-0000-000000000001"
            settings.spreadsheetID = "fixture-sheet"; settings.sheetName = "A '日本語' sheet"
            let notion = NotionWriter(baseURL: base.appendingPathComponent("v1"), token: { "e2e-placeholder" })
            let sheets = SheetsWriter(mockBaseURL: base) { _ in "e2e-placeholder" }
            let queueFolder = runFolder.appendingPathComponent("outbox")
            let queue = RetryQueue(folder: queueFolder, notion: notion, sheets: sheets)
            let recorder = CaptureRecorder(csv: CSVWriter(folder: runFolder), queue: queue)
            let jev = JevClassifier(endpoint: base.appendingPathComponent("v1/systemone"), key: { "e2e-placeholder" })
            let frames = [(original, "Editor", "Document"), (original, "Editor", "Document"),
                          (changed, "Editor", "Document"), (changed, "Browser", "Document"),
                          (changed, "Browser", "Second tab"), (changed, "Browser", "Second tab")]
            var written = 0
            for (i, frame) in frames.enumerated() {
                let screen = ScreenSnapshot(timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(i * 5)),
                                            app: frame.1, bundleID: "fixture." + frame.1, title: frame.2, text: frame.0)
                if try await recorder.record(screen, settings: settings, classifier: jev) { written += 1 }
            }
            let expected = mode == .all ? 6 : 4
            try check(written == expected, mode.rawValue + " row count")
            // All CSV rows already exist before even attempting the cloud.
            try check(try await queue.status().pending == expected * 2, "durable jobs before network")
            _ = try await control(base, path: "control/down")
            try await queue.drain(settings: settings)
            try check(try await queue.status().pending == expected * 2, "outage retains jobs")
            _ = try await control(base, path: "control/up")
            // New instance proves disk replay; advance scheduler time without sleeping for backoff.
            let resumed = RetryQueue(folder: queueFolder, notion: notion, sheets: sheets)
            for i in 0..<40 {
                try await resumed.drain(settings: settings, now: Date().addingTimeInterval(Double(120 + i * 120)))
                if try await resumed.status().pending == 0 { break }
            }
            try check(try await resumed.status().pending == 0, "queue drains after recovery")
            let metricsData = try await control(base, path: "control/metrics")
            let metrics = try JSONSerialization.jsonObject(with: metricsData) as! [String: Int]
            try check(metrics["jev"] == (mode == .smart ? 6 : 0), "SMART every capture; ALL/AUTO no classifier network")
            try check(metrics["pages"] == expected && metrics["sheets"] == expected, "both cloud writers")
            report.append(["mode": mode.rawValue, "rows": written, "jevRequests": metrics["jev"] ?? -1, "outageRecovery": "passed"])
        }
        // Exercise actual HTTP chunk continuation, UTF-16 cell limits and Retry-After.
        _ = try await control(base, path: "control/reset")
        var settings = AppSettings(); settings.notionEnabled = true; settings.googleEnabled = true
        settings.notionDatabaseID = "00000000-0000-0000-0000-000000000001"; settings.spreadsheetID = "long-sheet"
        let row = CaptureRow(screen: ScreenSnapshot(app: "Fixture", bundleID: "fixture", title: "Long text", text: String(repeating: original + "\n", count: 3000)), previousWrittenAt: nil)
        try await CSVWriter(folder: folder.appendingPathComponent("long")).append(row)
        let queue = RetryQueue(folder: folder.appendingPathComponent("long/outbox"),
                               notion: NotionWriter(baseURL: base.appendingPathComponent("v1"), token: { "e2e-placeholder" }),
                               sheets: SheetsWriter(mockBaseURL: base) { _ in "e2e-placeholder" })
        try await queue.enqueue(row: row, settings: settings)
        _ = try await control(base, path: "control/rate-limit")
        try await queue.drain(settings: settings)
        let before = try await control(base, path: "control/metrics")
        try await queue.drain(settings: settings)
        let after = try await control(base, path: "control/metrics")
        try check(before == after, "Retry-After blocks new destination requests")
        for i in 0..<40 {
            try await queue.drain(settings: settings, now: Date().addingTimeInterval(Double(120 + i * 120)))
            if try await queue.status().pending == 0 { break }
        }
        try check(try await queue.status().pending == 0, "long text chunk queue drains")
        let metrics = try JSONSerialization.jsonObject(with: await control(base, path: "control/metrics")) as! [String: Int]
        try check((metrics["appends"] ?? 0) >= 1 && metrics["rateLimits"] == 2, "append continuation and 429 exercised")
        let data = try JSONSerialization.data(withJSONObject: ["results": report, "longText": "passed", "retryAfter": "passed"], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("core-e2e.json"))
        print("PASS: OCR → ALL/AUTO/SMART → CSV + Notion + Sheets; outage recovery, limits and Retry-After")
    }
}

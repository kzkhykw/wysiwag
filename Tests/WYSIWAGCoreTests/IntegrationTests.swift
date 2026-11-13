import Foundation
import Testing
@testable import WYSIWAGCore

extension CoreTests {
    @Test func notionRejectsInvalidProgressBeforeTokenOrHTTPAccess() async throws {
        let settings = AppSettings()
        let row = CaptureRow(screen: sample(String(repeating: "x", count: 4_001)), previousWrittenAt: nil)
        let writer = NotionWriter(http: MockProtocol.client { _ in
            Issue.record("Invalid progress reached HTTP")
            return .init(body: Data("{}".utf8))
        }, token: { Issue.record("Invalid progress reached token access"); return nil })
        let page = UUID().uuidString
        for (pageID, next) in [(nil, -1), (page, -1), (page, 4), (page, Int.max), (page, 3), (nil, 1), (page, 0), ("", 1)] as [(String?, Int)] {
            var job = CloudJob(row: row, destination: .notion, settings: settings)
            job.pageID = pageID; job.nextBlock = next
            let invalid = job
            await #expect(throws: SafeFailure.invalidConfiguration) { try await writer.deliver(invalid) }
        }
        let blocks = NotionPayload.paragraphs(row.screen.text)
        for start in [-1, blocks.count + 1, Int.max] {
            #expect(throws: SafeFailure.invalidConfiguration) { try NotionPayload.batch(blocks, start: start) }
        }
        #expect(try NotionPayload.batch(blocks, start: blocks.count).isEmpty)
    }
    @Test func validNotionContinuationSendsAllRemainingText() async throws {
        let prefix = String(repeating: "a", count: 2_000), remaining = String(repeating: "日", count: 2_001)
        let page = UUID().uuidString
        let writer = NotionWriter(http: MockProtocol.client { request in
            #expect(request.httpMethod == "PATCH" && request.url?.path == "/v1/blocks/\(page)/children")
            let body = try JSONSerialization.jsonObject(with: MockProtocol.body(request)) as! [String: Any]
            let children = body["children"] as! [[String: Any]]
            let text = children.map { child in
                let paragraph = child["paragraph"] as! [String: Any]
                let richText = paragraph["rich_text"] as! [[String: Any]]
                return (richText[0]["text"] as! [String: String])["content"]!
            }.joined()
            #expect(children.count == 2 && text == remaining)
            return .init(body: Data("{}".utf8))
        }, token: { "unit-test-placeholder" })
        var job = CloudJob(row: CaptureRow(screen: sample(prefix + remaining), previousWrittenAt: nil), destination: .notion, settings: AppSettings())
        job.pageID = page; job.nextBlock = 1
        #expect(try await writer.deliver(job) == nil)
    }
    @Test func notionUnicodeChunkingAndBatching() throws {
        let text = String(repeating: "日本語🙂\n", count: 40_001)
        let chunks = TextChunks.split(text, limit: 2000)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.utf16.count <= 2000 })
        let blocks = NotionPayload.paragraphs(text)
        var start = 0
        while start < blocks.count {
            let batch = try NotionPayload.batch(blocks, start: start)
            #expect(!batch.isEmpty && batch.count <= 100)
            #expect(try JSONSerialization.data(withJSONObject: batch).count < 500_000)
            start += batch.count
        }
        let ascii = NotionPayload.paragraphs(String(repeating: "x", count: 202_000))
        #expect(try NotionPayload.batch(ascii, start: 0).count == 100)
        #expect(try NotionPayload.batch(ascii, start: 100).count == 1)
    }
    @Test func sheetsTruncationAndRAW() throws {
        let text = String(repeating: "🙂日本語", count: 15_000)
        let cell = SheetsPayload.cell(text)
        #expect(cell.utf16.count <= 49_000)
        #expect(cell.hasSuffix(SheetsPayload.marker))
        #expect(SheetsPayload.cell("=SUM(A1:A2)") == "=SUM(A1:A2)")
        let row = CaptureRow(screen: sample(text), previousWrittenAt: nil)
        #expect(row.screen.text == text)
        let url = try SheetsPayload.url(spreadsheetID: "abc-123", sheetName: "Team's 日本語 / ?")
        #expect(url.absoluteString.contains("valueInputOption=RAW"))
        #expect(url.path.contains("'Team''s 日本語 / ?'!A:E"))
        #expect(throws: SafeFailure.self) { try SheetsPayload.url(spreadsheetID: "../bad", sheetName: "x") }
    }
    @Test func autoDefaultsAndThreshold() async {
        #expect(AppSettings().mode == .auto)
        let baseline = sample("one two three four five six")
        #expect(await AutoClassifier().classify(previous: baseline, current: baseline) == .unchanged)
        #expect(await AutoClassifier().classify(previous: baseline, current: sample(baseline.text, app: "Other")) == .changed)
        #expect(await AutoClassifier().classify(previous: baseline, current: sample(baseline.text, title: "Other")) == .changed)
        #expect(await AutoClassifier(threshold: 1).classify(previous: baseline, current: sample(baseline.text + "!")) == .changed)
        #expect(await AutoClassifier(threshold: 0.1).classify(previous: baseline, current: sample(baseline.text + "!")) == .unchanged)
    }
    @Test func privacyExclusionsAndValidation() {
        let settings = AppSettings()
        #expect(PrivacyGuard.isExcluded(app: "System Settings", bundleID: "com.apple.systempreferences", exclusions: settings.excludedApps))
        #expect(PrivacyGuard.isExcluded(app: "1Password", bundleID: "com.1password.1password", exclusions: settings.excludedApps))
        #expect(PrivacyGuard.isExcluded(app: "Private App", bundleID: "private", exclusions: ["private app"]))
        #expect(!PrivacyGuard.isExcluded(app: "Editor", bundleID: "editor", exclusions: settings.excludedApps))
        var invalid = settings; invalid.interval = .nan; invalid.idleMinutes = -1; invalid.similarityThreshold = 50
        invalid.validate()
        #expect(invalid.interval == 5 && invalid.idleMinutes == 1 && invalid.similarityThreshold == 0.97)
    }
    @Test func pkceAndCallbackValidation() throws {
        // RFC 7636 Appendix B public test vector (not a credential).
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.challenge(verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(try PKCE.random().count == 43)
        let url = PKCE.authorizationURL(clientID: "client", redirect: "http://127.0.0.1:42/oauth/callback", state: "nonce", verifier: verifier)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.contains(URLQueryItem(name: "code_challenge_method", value: "S256")))
        #expect(items.contains(URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/spreadsheets")))
        #expect(OAuthLoopback.parseCode(request: "GET /oauth/callback?state=nonce&code=fixture HTTP/1.1\r\n\r\n", expectedState: "nonce") == "fixture")
        for path in ["/oauth/callback?state=wrong&code=x", "/oauth/callback?state=nonce&state=nonce&code=x", "/wrong?state=nonce&code=x", "/oauth/callback?state=nonce&error=denied"] {
            #expect(OAuthLoopback.parseCode(request: "GET \(path) HTTP/1.1\r\n\r\n", expectedState: "nonce") == nil)
        }
    }
    @Test func realLoopbackRoundTrip() async throws {
        let listener = try OAuthLoopback()
        let receiver = Task { try await listener.code(expectedState: "nonce", timeout: 5) }
        let url = URL(string: listener.redirectURI + "?state=nonce&code=fixture")!
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await receiver.value == "fixture")
    }
    @Test func notionOAuthExchangeRefreshAndDatabasePicker() async throws {
        let store = KeychainStore(service: "com.wysiwag.tests.\(UUID().uuidString)")
        defer { for account in SecretAccount.allCases { try? store.delete(account) } }
        try store.set("unit-test-placeholder", for: .notionClientSecret)
        let client = MockProtocol.client { request in
            if request.url!.path.hasSuffix("oauth/token") {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("client:unit-test-placeholder".utf8).base64EncodedString())
                let body = try JSONSerialization.jsonObject(with: MockProtocol.body(request)) as! [String: String]
                if body["grant_type"] == "authorization_code" { #expect(body["redirect_uri"] == NotionOAuth.redirectURI) }
                return .init(body: Data("{\"access_token\":\"mock-access\",\"refresh_token\":\"mock-refresh\"}".utf8))
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer mock-access")
            #expect(request.value(forHTTPHeaderField: "Notion-Version") == "2026-03-11")
            return .init(body: Data("{\"results\":[{\"id\":\"source\",\"parent\":{\"database_id\":\"database\"},\"title\":[{\"plain_text\":\"Granted table\"}]}],\"has_more\":false}".utf8))
        }
        let oauth = NotionOAuth(http: client, keychain: store)
        try await oauth.exchangeCode("mock-code", clientID: "client")
        #expect(try await oauth.accessToken(clientID: "client") == "mock-access")
        try await oauth.refresh(clientID: "client")
        let databases = try await oauth.databases(clientID: "client")
        #expect(databases.count == 1 && databases[0].databaseID == "database")
        let url = NotionOAuth.authorizationURL(clientID: "client", state: "nonce")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.contains(URLQueryItem(name: "state", value: "nonce")))
    }
    @Test func ocrFixtureIncludesBothLanguages() throws {
        let text = try OCR.recognize(file: OCR.fixtureURL)
        #expect(text.contains("WYSIWAG OCR verification"))
        #expect(text.contains("日本語の画面を記録します。"))
        #expect(text.components(separatedBy: "\n").count == 4)
    }
    @Test func retryAfterDate() {
        #expect(HTTPClient.retryAfter("42") == 42)
        #expect(HTTPClient.retryAfter("invalid") == nil)
        #expect(HTTPClient.retryAfter("Thu, 01 Jan 1970 00:01:00 GMT", now: Date(timeIntervalSince1970: 0)) == 60)
    }
}

private actor RateLimitedWriter: CloudWriting {
    var calls = 0
    func deliver(_ job: CloudJob) async throws -> CloudJob? {
        calls += 1
        if calls == 1 { throw SafeFailure.http(429, retryAfter: 60) }
        return nil
    }
}
extension CoreTests {
    @Test func retryAfterPersistsAcrossRelaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var settings = AppSettings(); settings.notionEnabled = true
        let writer = RateLimitedWriter()
        let first = RetryQueue(folder: folder, notion: writer, sheets: writer)
        try await first.enqueue(row: CaptureRow(screen: sample(), previousWrittenAt: nil), settings: settings)
        try await first.enqueue(row: CaptureRow(screen: sample("Second row"), previousWrittenAt: nil), settings: settings)
        let now = Date()
        try await first.drain(settings: settings, now: now)
        let restarted = RetryQueue(folder: folder, notion: writer, sheets: writer)
        try await restarted.drain(settings: settings, now: now.addingTimeInterval(30))
        #expect(await writer.calls == 1)
        try await restarted.drain(settings: settings, now: now.addingTimeInterval(61))
        #expect(try await restarted.status().pending == 0)
    }
    @Test func recorderPreservesDwellWhenSettingsAreApplied() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = RateLimitedWriter()
        let queue = RetryQueue(folder: folder.appendingPathComponent("outbox"), notion: writer, sheets: writer)
        var settings = AppSettings(); settings.mode = .auto
        let first = CaptureRecorder(csv: CSVWriter(folder: folder), queue: queue)
        let baseline = sample()
        #expect(try await first.record(baseline, settings: settings, classifier: AutoClassifier()))
        #expect(try await !first.record(sample(date: baseline.timestamp.addingTimeInterval(5)), settings: settings, classifier: AutoClassifier()))
        let second = CaptureRecorder(csv: CSVWriter(folder: folder), queue: queue, previous: try await first.lastWrittenScreen())
        #expect(try await second.record(sample("Entirely changed", date: baseline.timestamp.addingTimeInterval(10)), settings: settings, classifier: AutoClassifier()))
        let file = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.pathExtension == "csv" }!
        #expect(try String(contentsOf: file, encoding: .utf8).hasSuffix(",10.000\r\n"))
    }
}

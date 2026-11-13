import Foundation
import Testing
@testable import WYSIWAGCore

final class MockProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { var status = 200; var headers: [String: String] = [:]; var body = Data() }
    final class Registry: @unchecked Sendable {
        let lock = NSLock()
        private var handler: (@Sendable (URLRequest) throws -> Reply)?
        func set(_ value: @escaping @Sendable (URLRequest) throws -> Reply) { lock.withLock { handler = value } }
        func reply(_ request: URLRequest) throws -> Reply {
            let callback = lock.withLock { handler }
            return try callback!(request)
        }
    }
    static let registry = Registry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DispatchQueue.global().async { [self] in
            do {
                let reply = try Self.registry.reply(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: reply.body)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
    static func client(_ handler: @escaping @Sendable (URLRequest) throws -> Reply) -> HTTPClient {
        registry.set(handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        return HTTPClient(session: URLSession(configuration: config))
    }
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

func sample(_ text: String = "Hello, world", app: String = "Editor", title: String = "Document", date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> ScreenSnapshot {
    ScreenSnapshot(timestamp: date, app: app, bundleID: "test.\(app)", title: title, text: text)
}

@Suite(.serialized) struct CoreTests {
    @Test func csvQuotingNormalizationAndDwell() {
        #expect(CSV.header == "timestamp,active_app,window_title,visible_text,dwell_seconds\r\n")
        #expect(CSV.quote("a,\"b\"\nc") == "\"a,\"\"b\"\"\nc\"")
        #expect(CSV.quote("日本語") == "日本語")
        #expect(TextNormalizer.normalize(" a\t b \r\n\r\n 日本語  ") == "a b\n日本語")
        let screen = sample()
        #expect(CaptureRow(screen: screen, previousWrittenAt: nil).dwellSeconds == 0)
        let row = CaptureRow(screen: screen, previousWrittenAt: screen.timestamp.addingTimeInterval(-12.5), timeZone: TimeZone(secondsFromGMT: 9 * 3600)!)
        #expect(row.dwellSeconds == 12.5)
        #expect(row.timestamp.hasSuffix("+09:00"))
        #expect(CaptureRow(screen: screen, previousWrittenAt: screen.timestamp.addingTimeInterval(1)).dwellSeconds == 0)
    }

    @Test func csvDailyAppendAndPermissions() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = CSVWriter(folder: folder)
        let row = CaptureRow(screen: sample("one\ntwo,\"three\""), previousWrittenAt: nil)
        try await writer.append(row)
        try await writer.append(row)
        let url = folder.appendingPathComponent("wysiwag-\(row.day).csv")
        #expect(try String(contentsOf: url, encoding: .utf8) == CSV.header + CSV.encode(row) + CSV.encode(row))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func heuristicCases() {
        let heuristic = HeuristicClassifier()
        let previous = sample("The quick brown fox jumps over the lazy dog. This is a document about screen capture and local privacy.")
        #expect(heuristic.decision(previous: previous, current: sample(previous.text, app: "Browser")) == .changed)
        #expect(heuristic.decision(previous: previous, current: sample(previous.text, title: "Tab 2")) == .changed)
        #expect(heuristic.decision(previous: previous, current: previous) == .unchanged)
        #expect(heuristic.decision(previous: previous, current: sample(previous.text + "!")) == .unchanged)
        #expect(heuristic.decision(previous: previous, current: sample(previous.text + " New")) == .ambiguous)
        #expect(heuristic.decision(previous: previous, current: sample("全く異なる日本語の画面です。")) == .changed)
        #expect(heuristic.decision(previous: sample(""), current: sample("")) == .unchanged)
    }

    @Test func jevEncodingResponseAndNoPrefilter() async throws {
        let client = MockProtocol.client { request in
            #expect(request.url?.absoluteString == "https://api.typesafe.ai/v1/systemone")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer unit-test-placeholder")
            let body = try JSONDecoder().decode(JevRequest.self, from: MockProtocol.body(request))
            #expect(body.model == "jev-latest")
            #expect(body.questions["changed"]?.type == "noul")
            #expect(body.state.previous.app == "Editor")
            return MockProtocol.Reply(body: Data("{\"answers\":{\"changed\":{\"noul\":0.7}}}".utf8))
        }
        let jev = JevClassifier(http: client, key: { "unit-test-placeholder" })
        #expect(await jev.classify(previous: sample(), current: sample("changed")) == .changed)
        let strict = JevClassifier(http: client, probabilityThreshold: 0.8, key: { "unit-test-placeholder" })
        #expect(await strict.classify(previous: sample(), current: sample("changed")) == .unchanged)
        let smart = SmartClassifier(remote: jev)
        #expect(await smart.classify(previous: sample(), current: sample()) == .changed)
        let request = JevRequest(previous: sample(String(repeating: "日本語", count: 50_000)), current: sample())
        #expect(request.state.previous.text.utf8.count <= 22_000)
        #expect(request.state.previous.text.hasSuffix("[Truncated for context limit]"))
    }

    @Test func jevFailureFallbackAndCooldown() async {
        let previous = sample("The quick brown fox jumps over the lazy dog. This is a document about screen capture and local privacy.")
        let current = sample(previous.text + " New")
        for status in [400, 401, 413, 429, 529] {
            let client = MockProtocol.client { _ in
                MockProtocol.Reply(status: status, headers: ["Retry-After": "120"], body: Data("untrusted server details".utf8))
            }
            let remote = JevClassifier(http: client, key: { "unit-test-placeholder" })
            let smart = SmartClassifier(remote: remote)
            #expect(await smart.classify(previous: previous, current: current) == .changed)
            MockProtocol.registry.set { _ in Issue.record("Cooldown was not honored"); return MockProtocol.Reply() }
            #expect(await smart.classify(previous: previous, current: current) == .changed)
        }
    }

    @Test func keychainRoundTripAndDeletion() throws {
        let store = KeychainStore(service: "com.wysiwag.tests.\(UUID().uuidString)")
        defer { try? store.delete(.jevKey) }
        let value = UUID().uuidString
        try store.set(value, for: .jevKey)
        #expect(try store.read(.jevKey) == value)
        try store.set(value + "updated", for: .jevKey)
        #expect(try store.read(.jevKey) == value + "updated")
        try store.delete(.jevKey)
        #expect(try store.read(.jevKey) == nil)
    }

    @Test func diagnosticsNeverEchoSecrets() async {
        let secret = UUID().uuidString
        let error = NSError(domain: secret, code: 1, userInfo: [NSLocalizedDescriptionKey: secret])
        #expect(!Diagnostics.message(for: error).contains(secret))
        let client = MockProtocol.client { _ in MockProtocol.Reply(status: 401, body: Data(secret.utf8)) }
        do {
            _ = try await client.send(HTTPClient.jsonRequest(url: URL(string: "https://example.invalid")!, bearer: secret, body: Data()))
            Issue.record("Expected HTTP failure")
        } catch {
            #expect(!String(describing: error).contains(secret))
            #expect(!Diagnostics.message(for: error).contains(secret))
        }
    }
}

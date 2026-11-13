import Foundation
import Testing
@testable import WYSIWAGCore

private final class RequestCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}
private func callback(_ authorization: URL) -> Bool {
    let items = URLComponents(url: authorization, resolvingAgainstBaseURL: false)!.queryItems!
    var redirect = URLComponents(string: items.first { $0.name == "redirect_uri" }!.value!)!
    redirect.queryItems = [URLQueryItem(name: "state", value: items.first { $0.name == "state" }!.value!), URLQueryItem(name: "code", value: "mock-new-code")]
    let url = redirect.url!
    Task { _ = try? await URLSession.shared.data(from: url) }
    return true
}

extension CoreTests {
    @Test func googleOldRefreshCannotOverwriteReauthorization() async throws {
        let store = KeychainStore(service: "com.wysiwag.tests.\(UUID().uuidString)")
        defer { try? store.delete(.googleRefreshToken) }
        let clientID = "test.apps.googleusercontent.com"
        try store.set("{\"clientID\":\"\(clientID)\",\"refreshToken\":\"mock-old-refresh\"}", for: .googleRefreshToken)
        let gate = ResponseGate(); defer { gate.release() }
        let oauth = GoogleOAuth(http: MockProtocol.client { request in
            let body = String(decoding: MockProtocol.body(request), as: UTF8.self)
            if body.contains("grant_type=refresh_token") {
                gate.hold()
                return .init(body: Data("{\"access_token\":\"mock-stale-access\",\"refresh_token\":\"mock-stale-refresh\"}".utf8))
            }
            #expect(body.contains("code_verifier="))
            return .init(body: Data("{\"access_token\":\"mock-new-access\",\"refresh_token\":\"mock-new-refresh\"}".utf8))
        }, keychain: store)
        let old = Task { try await oauth.accessToken(clientID: clientID) }
        try await gate.waitUntilStarted()
        try await oauth.authorize(clientID: clientID, openBrowser: { callback($0) })
        gate.release()
        do { _ = try await old.value; Issue.record("Superseded refresh returned a credential") } catch {}
        #expect(try await oauth.accessToken(clientID: clientID) == "mock-new-access")
        let saved = try JSONSerialization.jsonObject(with: Data(store.read(.googleRefreshToken)!.utf8)) as! [String: String]
        #expect(saved["refreshToken"] == "mock-new-refresh" && saved["revision"] != nil)
    }
    @Test func notionOldRefreshCannotOverwriteReauthorization() async throws {
        let store = KeychainStore(service: "com.wysiwag.tests.\(UUID().uuidString)")
        defer { try? store.delete(.notionAccessToken); try? store.delete(.notionClientSecret) }
        try store.set("unit-test-placeholder", for: .notionClientSecret)
        try store.set("{\"clientID\":\"client\",\"access\":\"mock-old-access\",\"refresh\":\"mock-old-refresh\"}", for: .notionAccessToken)
        let gate = ResponseGate(); defer { gate.release() }
        let oauth = NotionOAuth(http: MockProtocol.client { request in
            let body = try JSONSerialization.jsonObject(with: MockProtocol.body(request)) as! [String: String]
            if body["grant_type"] == "refresh_token" {
                gate.hold()
                return .init(body: Data("{\"access_token\":\"mock-stale-access\",\"refresh_token\":\"mock-stale-refresh\"}".utf8))
            }
            return .init(body: Data("{\"access_token\":\"mock-new-access\",\"refresh_token\":\"mock-new-refresh\"}".utf8))
        }, keychain: store)
        let old = Task { try await oauth.refresh(clientID: "client") }
        try await gate.waitUntilStarted()
        try await oauth.authorize(clientID: "client", openBrowser: { callback($0) })
        gate.release()
        do { try await old.value; Issue.record("Superseded Notion refresh succeeded") } catch {}
        #expect(try await oauth.accessToken(clientID: "client") == "mock-new-access")
        let saved = try JSONSerialization.jsonObject(with: Data(store.read(.notionAccessToken)!.utf8)) as! [String: String]
        #expect(saved["refresh"] == "mock-new-refresh" && saved["revision"] != nil)
    }
    @Test func providersCoalesceConcurrentRefreshes() async throws {
        for notion in [false, true] {
            let store = KeychainStore(service: "com.wysiwag.tests.\(UUID().uuidString)")
            defer { for account in SecretAccount.allCases { try? store.delete(account) } }
            try store.set("unit-test-placeholder", for: .notionClientSecret)
            try store.set("{\"clientID\":\"client\",\"access\":\"mock-access\",\"refresh\":\"mock-refresh\"}", for: .notionAccessToken)
            try store.set("{\"clientID\":\"client\",\"refreshToken\":\"mock-refresh\"}", for: .googleRefreshToken)
            let gate = ResponseGate(), count = RequestCount(); defer { gate.release() }
            let http = MockProtocol.client { _ in
                _ = count.increment(); gate.hold()
                return .init(body: Data("{\"access_token\":\"mock-refreshed-access\",\"refresh_token\":\"mock-rotated-refresh\"}".utf8))
            }
            let google = GoogleOAuth(http: http, keychain: store), provider = NotionOAuth(http: http, keychain: store)
            let operation: @Sendable () async throws -> Void = {
                if notion { try await provider.refresh(clientID: "client") }
                else { _ = try await google.accessToken(clientID: "client") }
            }
            let first = Task { try await operation() }
            try await gate.waitUntilStarted()
            let second = Task { try await operation() }
            try await Task.sleep(for: .milliseconds(50))
            #expect(count.value == 1)
            gate.release(); try await first.value; try await second.value
            #expect(count.value == 1)
        }
    }
    @Test func notionCancelThenReconnectAwaitsListenerShutdown() async throws {
        let store = KeychainStore(service: "com.wysiwag.tests.\(UUID().uuidString)")
        defer { try? store.delete(.notionClientSecret); try? store.delete(.notionAccessToken) }
        try store.set("unit-test-placeholder", for: .notionClientSecret)
        let oauth = NotionOAuth(http: MockProtocol.client { _ in
            .init(body: Data("{\"access_token\":\"mock-access\",\"refresh_token\":\"mock-refresh\"}".utf8))
        }, keychain: store)
        let browserOpened = AsyncGate()
        let first = Task {
            try await oauth.authorize(clientID: "client", openBrowser: { _ in await browserOpened.release(); return true })
        }
        for _ in 0..<200 {
            if await browserOpened.released { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        first.cancel()
        // Deliberately do not await first: the provider must retire its own socket before bind.
        try await oauth.authorize(clientID: "client", openBrowser: { callback($0) })
        _ = await first.result
        #expect(try await oauth.accessToken(clientID: "client") == "mock-access")
    }
    @Test func jevCooldownSurvivesThresholdChangesRebuildAndRelaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock(), count = RequestCount(), state = folder.appendingPathComponent("jev.state")
        let http = MockProtocol.client { _ in
            if count.increment() == 1 { return .init(status: 429, headers: ["Retry-After": "120"]) }
            return .init(body: Data("{\"answers\":{\"changed\":{\"noul\":0.1}}}".utf8))
        }
        let first = JevClassifier(http: http, stateURL: state, clock: { clock.now() }, key: { "unit-test-placeholder" })
        #expect(await first.classify(previous: sample(), current: sample()) == .changed)
        await first.setThreshold(0.7)
        #expect(await first.classify(previous: sample(), current: sample()) == .changed)
        let rebuilt = JevClassifier(http: http, probabilityThreshold: 0.8, stateURL: state, clock: { clock.now() }, key: { "unit-test-placeholder" })
        clock.advance(119)
        #expect(await rebuilt.classify(previous: sample(), current: sample()) == .changed)
        #expect(count.value == 1)
        #expect(await rebuilt.lastFailure == .http(429, retryAfter: 120))
        clock.advance(2)
        #expect(await rebuilt.classify(previous: sample(), current: sample()) == .unchanged)
        #expect(count.value == 2)
    }
}

import Foundation
import Testing
@testable import WYSIWAGCore

private final class ResponseGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false
    var hasStarted: Bool { condition.lock(); defer { condition.unlock() }; return started }
    func hold() {
        condition.lock(); defer { condition.unlock() }
        started = true
        let deadline = Date().addingTimeInterval(5)
        while !released && condition.wait(until: deadline) {}
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func waitUntilStarted() async throws {
        for _ in 0..<200 {
            if hasStarted { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SafeFailure.network
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}
private actor SlowRateLimitedWriter: CloudWriting {
    let clock: TestClock
    var calls = 0
    init(clock: TestClock) { self.clock = clock }
    func deliver(_ job: CloudJob) async throws -> CloudJob? {
        calls += 1
        if calls == 1 {
            clock.advance(40) // Simulate a 40-second request without slowing the test.
            throw SafeFailure.http(429, retryAfter: 60)
        }
        return nil
    }
}

extension CoreTests {
    @Test func clearingNotionSelectionClearsTargetAndDisablesWrites() {
        var settings = AppSettings()
        settings.selectNotionDatabase(NotionDatabase(id: "source", databaseID: "database", title: "Fixture"))
        settings.notionEnabled = true
        #expect(settings.notionDatabaseID == "database" && settings.notionDataSourceID == "source")
        settings.selectNotionDatabase(nil)
        #expect(settings.notionDatabaseID.isEmpty && settings.notionDataSourceID.isEmpty && !settings.notionEnabled)
    }
    @Test func googleSignOutRejectsInFlightRefresh() async throws {
        let store = KeychainStore(service: "com.wysiwag.tests.\(UUID().uuidString)")
        defer { try? store.delete(.googleRefreshToken) }
        try store.set("{\"clientID\":\"client\",\"refreshToken\":\"mock-refresh\"}", for: .googleRefreshToken)
        let gate = ResponseGate(); defer { gate.release() }
        let oauth = GoogleOAuth(http: MockProtocol.client { _ in
            gate.hold()
            return .init(body: Data("{\"access_token\":\"mock-access\",\"refresh_token\":\"mock-rotated\",\"expires_in\":3600}".utf8))
        }, keychain: store)
        let request = Task { try await oauth.accessToken(clientID: "client") }
        try await gate.waitUntilStarted()
        try await oauth.signOut()
        gate.release()
        do { _ = try await request.value; Issue.record("Stale Google response survived sign-out") } catch {}
        #expect(!store.contains(.googleRefreshToken))
        do { _ = try await oauth.accessToken(clientID: "client"); Issue.record("Google cache survived sign-out") } catch {}
    }

    @Test func notionSignOutAndCancellationRejectInFlightExchange() async throws {
        let store = KeychainStore(service: "com.wysiwag.tests.\(UUID().uuidString)")
        defer { try? store.delete(.notionClientSecret); try? store.delete(.notionAccessToken) }
        try store.set("unit-test-placeholder", for: .notionClientSecret)
        for cancel in [false, true] {
            let gate = ResponseGate(); defer { gate.release() }
            let oauth = NotionOAuth(http: MockProtocol.client { _ in
                gate.hold()
                return .init(body: Data("{\"access_token\":\"mock-access\",\"refresh_token\":\"mock-refresh\"}".utf8))
            }, keychain: store)
            let request = Task { try await oauth.exchangeCode("mock-code", clientID: "client") }
            try await gate.waitUntilStarted()
            if cancel { request.cancel() } else { try await oauth.signOut() }
            gate.release()
            do { try await request.value; Issue.record("Stale Notion exchange survived cancellation/sign-out") } catch {}
            #expect(!store.contains(.notionAccessToken))
        }
    }

    @Test func retryAfterStartsWhenSlowResponseArrives() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock(), start = Date(timeIntervalSince1970: 1_800_000_000)
        let writer = SlowRateLimitedWriter(clock: clock)
        var settings = AppSettings(); settings.notionEnabled = true
        let queue = RetryQueue(folder: folder, notion: writer, sheets: writer, clock: { clock.now() })
        try await queue.enqueue(row: CaptureRow(screen: sample(), previousWrittenAt: nil), settings: settings)
        try await queue.drain(settings: settings)
        clock.advance(21) // 61 seconds after request start, only 21 after the 429.
        let restarted = RetryQueue(folder: folder, notion: writer, sheets: writer, clock: { clock.now() })
        try await restarted.drain(settings: settings)
        #expect(await writer.calls == 1)
        #expect(clock.now() == start.addingTimeInterval(61))
        clock.advance(40)
        try await restarted.drain(settings: settings)
        #expect(await writer.calls == 2)
        #expect(try await restarted.status().pending == 0)
    }

    @Test func fixedLoopbackPortCanBeReusedAfterCallback() async throws {
        func roundTrip(port: UInt16) async throws -> UInt16 {
            let listener = try OAuthLoopback(port: port)
            let receiver = Task { try await listener.code(expectedState: "nonce", timeout: 5) }
            let url = URL(string: listener.redirectURI + "?state=nonce&code=fixture")!
            _ = try await URLSession.shared.data(from: url)
            #expect(try await receiver.value == "fixture")
            return UInt16(url.port!)
        }
        let port = try await roundTrip(port: 0)
        _ = try await roundTrip(port: port)
    }
}

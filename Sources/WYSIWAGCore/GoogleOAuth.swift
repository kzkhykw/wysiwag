import Foundation
import CryptoKit
import Security
import Darwin

public enum PKCE {
    public static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw SafeFailure.authentication }
        return base64URL(Data(bytes))
    }
    public static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func authorizationURL(clientID: String, redirect: String, state: String, verifier: String) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/spreadsheets"),
            URLQueryItem(name: "access_type", value: "offline"), URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state), URLQueryItem(name: "code_challenge", value: challenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components.url!
    }
    public static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(fields.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
}

/// A short-lived listener bound only to IPv4 loopback, on a kernel-selected port.
/// Blocking socket work runs on a detached worker, with a timeout and cancellation checks.
public final class OAuthLoopback: @unchecked Sendable {
    private let fd: Int32
    public let redirectURI: String
    private let lock = NSLock()
    private var cancelled = false
    private var worker: Task<String, Error>?
    private var closed = false

    public init(port: UInt16 = 0, host: String = "127.0.0.1") throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw SafeFailure.authentication }
        fd = socketFD
        var reuse: Int32 = 1
        guard setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(socketFD); throw SafeFailure.authentication
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, listen(fd, 4) == 0 else { close(fd); throw SafeFailure.authentication }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let name = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &size) }
        }
        guard name == 0 else { close(fd); throw SafeFailure.authentication }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        redirectURI = "http://\(host):\(UInt16(bigEndian: address.sin_port))/oauth/callback"
    }
    deinit { closeOnce() }
    private func closeOnce() { lock.withLock { if !closed { close(fd); closed = true } } }
    public func shutdown() async {
        cancel()
        let pending = lock.withLock { worker }
        if let pending { _ = await pending.result }
        else { closeOnce() }
    }
    public func cancel() { lock.withLock { cancelled = true } }
    public static func parseCode(request: String, expectedState: String) -> String? {
        let first = request.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
        guard first.count == 3, first[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1" + first[1]),
              components.path == "/oauth/callback" else { return nil }
        let items = components.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == expectedState,
              items.first(where: { $0.name == "error" }) == nil,
              items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return nil }
        return code
    }

    public func code(expectedState: String, timeout: Double = 180) async throws -> String {
        let worker: Task<String, Error> = try lock.withLock {
            guard self.worker == nil, !closed, !cancelled else { throw SafeFailure.cancelled }
            let task = Task.detached { [self] in
                defer { closeOnce() }
                return try receive(expectedState: expectedState, timeout: timeout)
            }
            self.worker = task
            return task
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { self.cancel() }
    }

    private func receive(expectedState: String, timeout: Double) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ cancelled }) { throw SafeFailure.cancelled }
            var readiness = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&readiness, 1, 250) > 0 else { continue }
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else { continue }
            defer { close(connection) }
            // Darwin inherits O_NONBLOCK from the listener; wait for the actual HTTP bytes.
            _ = fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) & ~O_NONBLOCK)
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            _ = setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var data = Data(), buffer = [UInt8](repeating: 0, count: 2048)
            while data.count < 8192 && Date() < deadline && !lock.withLock({ cancelled }) {
                let count = recv(connection, &buffer, buffer.count, 0)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
                if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
            }
            let code = Self.parseCode(request: String(decoding: data, as: UTF8.self), expectedState: expectedState)
            let body = code == nil ? "Invalid authorization response. Return to WYSIWAG." : "Authorization received. Return to WYSIWAG. / WYSIWAGに戻ってください。"
            let response = "HTTP/1.1 \(code == nil ? "400 Bad Request" : "200 OK")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n\(body)"
            _ = response.withCString { send(connection, $0, response.utf8.count, 0) }
            if let code { return code }
        }
        throw SafeFailure.authentication
    }
}

public actor GoogleOAuth {
    private struct StoredRefresh: Codable { let clientID: String; let refreshToken: String; var revision: UUID? = nil }
    private struct TokenResponse: Decodable, Sendable {
        let access_token: String
        let expires_in: Double?
        let refresh_token: String?
    }
    private let http: HTTPClient
    private let keychain: KeychainStore
    private var cached: (clientID: String, token: String, expiry: Date)?
    private var generation = 0
    private var authorizing: Int?
    private var listener: OAuthLoopback?
    private var refreshFlight: (id: UUID, clientID: String, task: Task<Void, Error>)?
    public init(http: HTTPClient = HTTPClient(), keychain: KeychainStore = KeychainStore()) {
        self.http = http; self.keychain = keychain
    }
    public func invalidate() {
        generation += 1; cached = nil; authorizing = nil
        refreshFlight?.task.cancel(); refreshFlight = nil; listener?.cancel()
    }
    public func signOut() throws { invalidate(); try keychain.delete(.googleRefreshToken) }
    private func requireCurrent(_ expected: Int) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw SafeFailure.cancelled }
    }
    private func exchange(_ fields: [String: String]) async throws -> TokenResponse {
        var fields = fields
        if let secret = try keychain.read(.googleClientSecret), !secret.isEmpty { fields["client_secret"] = secret }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = PKCE.form(fields)
        let data = try await http.send(request)
        guard let result = try? JSONDecoder().decode(TokenResponse.self, from: data), !result.access_token.isEmpty else { throw SafeFailure.invalidResponse }
        return result
    }
    private func commit(_ result: TokenResponse, refresh: String, clientID: String) throws {
        let stored = StoredRefresh(clientID: clientID, refreshToken: refresh, revision: UUID())
        try keychain.set(String(decoding: JSONEncoder().encode(stored), as: UTF8.self), for: .googleRefreshToken)
        cached = (clientID, result.access_token, Date().addingTimeInterval(max(0, (result.expires_in ?? 3600) - 60)))
    }
    public func authorize(clientID: String, openBrowser: @Sendable (URL) async -> Bool) async throws {
        guard clientID.hasSuffix(".apps.googleusercontent.com") else { throw SafeFailure.invalidConfiguration }
        invalidate()
        let expected = generation, retiring = listener
        authorizing = expected
        defer { if authorizing == expected { authorizing = nil } }
        await retiring?.shutdown()
        try requireCurrent(expected)
        let current = try OAuthLoopback(); listener = current
        do {
            let verifier = try PKCE.random(), state = try PKCE.random()
            guard await openBrowser(PKCE.authorizationURL(clientID: clientID, redirect: current.redirectURI, state: state, verifier: verifier)) else { throw SafeFailure.authentication }
            let code = try await current.code(expectedState: state)
            await current.shutdown()
            try requireCurrent(expected)
            let result = try await exchange(["client_id": clientID, "code": code, "code_verifier": verifier,
                                             "redirect_uri": current.redirectURI, "grant_type": "authorization_code"])
            try requireCurrent(expected)
            guard let refresh = result.refresh_token, !refresh.isEmpty else { throw SafeFailure.authentication }
            try commit(result, refresh: refresh, clientID: clientID)
        } catch { await current.shutdown(); throw error }
    }
    private func performRefresh(clientID: String, raw: String, stored: StoredRefresh, expected: Int) async throws {
        let result = try await exchange(["client_id": clientID, "refresh_token": stored.refreshToken, "grant_type": "refresh_token"])
        try requireCurrent(expected)
        guard authorizing == nil, try keychain.read(.googleRefreshToken) == raw else { throw SafeFailure.cancelled }
        try commit(result, refresh: result.refresh_token ?? stored.refreshToken, clientID: clientID)
    }
    public func accessToken(clientID: String) async throws -> String {
        let expected = generation
        guard authorizing == nil else { throw SafeFailure.cancelled }
        if let cached, cached.clientID == clientID, cached.expiry > Date() { return cached.token }
        if let flight = refreshFlight, flight.clientID == clientID {
            try await flight.task.value
        } else {
            guard let raw = try keychain.read(.googleRefreshToken),
                  let stored = try? JSONDecoder().decode(StoredRefresh.self, from: Data(raw.utf8)),
                  stored.clientID == clientID else { throw SafeFailure.authentication }
            let id = UUID()
            let task = Task { try await self.performRefresh(clientID: clientID, raw: raw, stored: stored, expected: expected) }
            refreshFlight = (id, clientID, task)
            defer { if refreshFlight?.id == id { refreshFlight = nil } }
            try await task.value
        }
        try requireCurrent(expected)
        guard let cached, cached.clientID == clientID else { throw SafeFailure.authentication }
        return cached.token
    }
}

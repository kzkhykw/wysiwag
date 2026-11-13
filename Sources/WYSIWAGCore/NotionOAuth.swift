import Foundation

public struct NotionDatabase: Identifiable, Sendable, Equatable {
    public let id: String
    public let databaseID: String
    public let title: String
}

public actor NotionOAuth {
    public static let redirectURI = "http://localhost:43871/oauth/callback"
    private struct TokenPair: Codable { let clientID: String; let access: String; let refresh: String? }
    private struct Response: Decodable { let access_token: String; let refresh_token: String? }
    private let http: HTTPClient
    private let keychain: KeychainStore
    private let baseURL: URL
    private var generation = 0
    public init(http: HTTPClient = HTTPClient(), keychain: KeychainStore = KeychainStore(),
                baseURL: URL = URL(string: "https://api.notion.com/v1/")!) {
        self.http = http; self.keychain = keychain; self.baseURL = baseURL
    }
    public func invalidate() { generation += 1 }
    public func signOut() throws { invalidate(); try keychain.delete(.notionAccessToken) }
    private func requireCurrent(_ expected: Int) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw SafeFailure.cancelled }
    }

    public static func authorizationURL(clientID: String, state: String) -> URL {
        var parts = URLComponents(string: "https://api.notion.com/v1/oauth/authorize")!
        parts.queryItems = [URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "response_type", value: "code"),
                            URLQueryItem(name: "owner", value: "user"), URLQueryItem(name: "redirect_uri", value: redirectURI),
                            URLQueryItem(name: "state", value: state)]
        return parts.url!
    }

    public func authorize(clientID: String, openBrowser: @Sendable (URL) async -> Bool) async throws {
        let expected = generation
        guard !clientID.isEmpty, keychain.contains(.notionClientSecret) else { throw SafeFailure.authentication }
        // Notion matches a registered redirect exactly, so unlike Google this uses a fixed port.
        let listener = try OAuthLoopback(port: 43871, host: "localhost")
        defer { listener.cancel() }
        let state = try PKCE.random()
        guard await openBrowser(Self.authorizationURL(clientID: clientID, state: state)) else { throw SafeFailure.authentication }
        let code = try await listener.code(expectedState: state)
        try requireCurrent(expected)
        try await exchangeCode(code, clientID: clientID)
    }

    public func exchangeCode(_ code: String, clientID: String) async throws {
        try await exchange(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI], clientID: clientID)
    }

    private func exchange(_ body: [String: String], clientID: String) async throws {
        let expected = generation
        try Task.checkCancellation()
        guard let secret = try keychain.read(.notionClientSecret), !secret.isEmpty else { throw SafeFailure.authentication }
        var request = URLRequest(url: baseURL.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.setValue("Basic " + Data((clientID + ":" + secret).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(NotionPayload.version, forHTTPHeaderField: "Notion-Version")
        request.httpBody = try JSONEncoder().encode(body)
        let data = try await http.send(request)
        try requireCurrent(expected)
        guard let response = try? JSONDecoder().decode(Response.self, from: data), !response.access_token.isEmpty else { throw SafeFailure.invalidResponse }
        // Save the pair atomically in a single Keychain item; refresh rotation cannot split it.
        let pair = TokenPair(clientID: clientID, access: response.access_token, refresh: response.refresh_token)
        try keychain.set(String(decoding: JSONEncoder().encode(pair), as: UTF8.self), for: .notionAccessToken)
    }

    public func accessToken(clientID: String) throws -> String {
        try storedPair(clientID: clientID).access
    }
    private func storedPair(clientID: String) throws -> TokenPair {
        guard let raw = try keychain.read(.notionAccessToken),
              let pair = try? JSONDecoder().decode(TokenPair.self, from: Data(raw.utf8)), pair.clientID == clientID else { throw SafeFailure.authentication }
        return pair
    }
    public func refresh(clientID: String) async throws {
        guard let token = try storedPair(clientID: clientID).refresh else { throw SafeFailure.authentication }
        try await exchange(["grant_type": "refresh_token", "refresh_token": token], clientID: clientID)
    }

    public func databases(clientID: String) async throws -> [NotionDatabase] {
        let expected = generation
        var results: [NotionDatabase] = [], cursor: String?
        repeat {
            var body: [String: Any] = ["filter": ["value": "data_source", "property": "object"], "page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            var request = HTTPClient.jsonRequest(url: baseURL.appendingPathComponent("search"), bearer: try accessToken(clientID: clientID),
                                                body: try JSONSerialization.data(withJSONObject: body))
            request.setValue(NotionPayload.version, forHTTPHeaderField: "Notion-Version")
            let data: Data
            do { data = try await http.send(request) }
            catch SafeFailure.http(401, _) {
                try await refresh(clientID: clientID)
                request.setValue("Bearer " + (try accessToken(clientID: clientID)), forHTTPHeaderField: "Authorization")
                data = try await http.send(request)
            }
            try requireCurrent(expected)
            guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = response["results"] as? [[String: Any]] else { throw SafeFailure.invalidResponse }
            for item in items {
                guard let id = item["id"] as? String,
                      let parent = item["parent"] as? [String: Any], let database = parent["database_id"] as? String else { continue }
                let titles = item["title"] as? [[String: Any]] ?? []
                let title = titles.compactMap { $0["plain_text"] as? String ?? ($0["text"] as? [String: Any])?["content"] as? String }.joined()
                results.append(NotionDatabase(id: id, databaseID: database, title: title.isEmpty ? id : title))
            }
            cursor = response["has_more"] as? Bool == true ? response["next_cursor"] as? String : nil
            try Task.checkCancellation()
        } while cursor != nil
        return results.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

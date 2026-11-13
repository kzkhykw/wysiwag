import Foundation

public enum CloudDestination: String, Codable, Sendable { case notion, sheets }

public struct CloudJob: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var row: CaptureRow
    public var destination: CloudDestination
    public var target: String
    public var dataSourceID: String
    public var sheetName: String
    public var clientID: String
    public var pageID: String?
    public var nextBlock = 0
    public var attempts = 0
    public var nextAttempt = Date.distantPast
    public var blocked = false
    public var lastStatus: Int?

    public init(row: CaptureRow, destination: CloudDestination, settings: AppSettings) {
        self.row = row
        self.destination = destination
        target = destination == .notion ? settings.notionDatabaseID : settings.spreadsheetID
        dataSourceID = settings.notionDataSourceID
        sheetName = settings.sheetName
        clientID = destination == .notion ? settings.notionClientID : settings.googleClientID
    }

    public func isEnabled(in settings: AppSettings) -> Bool {
        switch destination {
        case .notion:
            settings.notionEnabled && target == settings.notionDatabaseID && dataSourceID == settings.notionDataSourceID && clientID == settings.notionClientID
        case .sheets:
            settings.googleEnabled && target == settings.spreadsheetID && sheetName == settings.sheetName && clientID == settings.googleClientID
        }
    }
}

public protocol CloudWriting: Sendable {
    /// One checkpointable operation. nil means delivered; otherwise persist progress before continuing.
    func deliver(_ job: CloudJob) async throws -> CloudJob?
}

public enum TextChunks {
    // Count UTF-16 units conservatively; never split a surrogate pair or drop text.
    public static func split(_ text: String, limit: Int) -> [String] {
        precondition(limit >= 2)
        var chunks: [String] = [], current = "", length = 0
        for scalar in text.unicodeScalars {
            let units = scalar.utf16.count
            if length + units > limit { chunks.append(current); current = ""; length = 0 }
            current.unicodeScalars.append(scalar)
            length += units
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
    public static func prefix(_ text: String, limit: Int) -> String {
        var output = "", count = 0
        for scalar in text.unicodeScalars {
            if count + scalar.utf16.count > limit { break }
            output.unicodeScalars.append(scalar)
            count += scalar.utf16.count
        }
        return output
    }
}

public enum NotionPayload {
    public static let version = "2026-03-11"
    public static func paragraphs(_ text: String) -> [[String: Any]] {
        TextChunks.split(text, limit: 2000).map { chunk in
            ["object": "block", "type": "paragraph", "paragraph": ["rich_text": richText(chunk)]]
        }
    }
    public static func richText(_ text: String) -> [[String: Any]] {
        [["type": "text", "text": ["content": text]]]
    }
    public static func batch(_ blocks: [[String: Any]], start: Int) throws -> [[String: Any]] {
        var output: [[String: Any]] = [], bytes = 0
        for block in blocks.dropFirst(start).prefix(100) {
            let size = try JSONSerialization.data(withJSONObject: block).count
            // Also honor Notion's 500 KB body cap for multibyte text and escaped characters.
            if bytes + size > 400_000 { break }
            output.append(block); bytes += size
        }
        return output
    }
    public static func page(row: CaptureRow, sourceID: String, appIsSelect: Bool, children: [[String: Any]]) -> [String: Any] {
        let name = TextChunks.prefix(row.screen.app + " " + row.timestamp, limit: 2000)
        let app = TextChunks.prefix(row.screen.app, limit: appIsSelect ? 100 : 2000)
        return [
            "parent": ["type": "data_source_id", "data_source_id": sourceID],
            "properties": [
                "Name": ["title": richText(name)],
                "Timestamp": ["date": ["start": row.timestamp]],
                "App": appIsSelect ? ["select": ["name": app]] : ["rich_text": richText(app)],
                "Dwell": ["number": row.dwellSeconds]
            ],
            "children": children
        ]
    }
}

public actor NotionWriter: CloudWriting {
    private let http: HTTPClient
    private let token: @Sendable () async throws -> String?
    private let refresh: (@Sendable () async throws -> Void)?
    private struct Schema { let source: String; let appIsSelect: Bool }
    private var schemas: [String: Schema] = [:]

    private let baseURL: URL
    public init(http: HTTPClient = HTTPClient(), baseURL: URL = URL(string: "https://api.notion.com/v1/")!,
                refresh: (@Sendable () async throws -> Void)? = nil,
                token: @escaping @Sendable () async throws -> String?) {
        self.http = http; self.token = token; self.baseURL = baseURL; self.refresh = refresh
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let token = try await token(), !token.isEmpty else { throw SafeFailure.authentication }
        let url = baseURL.appendingPathComponent(path)
        var request = HTTPClient.jsonRequest(url: url, method: method, bearer: token,
                                            body: try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data())
        if body == nil { request.httpBody = nil }
        request.setValue(NotionPayload.version, forHTTPHeaderField: "Notion-Version")
        let data: Data
        do { data = try await http.send(request) }
        catch SafeFailure.http(401, _) {
            guard let refresh else { throw SafeFailure.authentication }
            try await refresh()
            guard let refreshed = try await self.token() else { throw SafeFailure.authentication }
            request.setValue("Bearer " + refreshed, forHTTPHeaderField: "Authorization")
            data = try await http.send(request)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SafeFailure.invalidResponse }
        return object
    }

    private func schema(for job: CloudJob) async throws -> Schema {
        let cacheKey = job.target + ":" + job.dataSourceID
        if let schema = schemas[cacheKey] { return schema }
        guard UUID(uuidString: job.target) != nil || Self.compactUUID(job.target) != nil else { throw SafeFailure.invalidConfiguration }
        let database = try await request("databases/\(job.target)")
        guard let sources = database["data_sources"] as? [[String: Any]] else { throw SafeFailure.invalidResponse }
        let ids = sources.compactMap { $0["id"] as? String }
        let source: String
        if job.dataSourceID.isEmpty {
            guard ids.count == 1, let first = ids.first else { throw SafeFailure.invalidConfiguration }
            source = first
        } else {
            guard let match = ids.first(where: { $0.replacingOccurrences(of: "-", with: "") == job.dataSourceID.replacingOccurrences(of: "-", with: "") }) else { throw SafeFailure.invalidConfiguration }
            source = match
        }
        let object = try await request("data_sources/\(source)")
        guard let properties = object["properties"] as? [String: [String: Any]],
              properties["Name"]?["type"] as? String == "title",
              properties["Timestamp"]?["type"] as? String == "date",
              properties["Dwell"]?["type"] as? String == "number",
              let appType = properties["App"]?["type"] as? String,
              ["select", "rich_text"].contains(appType) else { throw SafeFailure.invalidConfiguration }
        let schema = Schema(source: source, appIsSelect: appType == "select")
        schemas[cacheKey] = schema
        return schema
    }

    private static func compactUUID(_ id: String) -> String? {
        id.count == 32 && id.allSatisfy(\.isHexDigit) ? id : nil
    }

    public func deliver(_ job: CloudJob) async throws -> CloudJob? {
        let blocks = NotionPayload.paragraphs(job.row.screen.text)
        let batch = try NotionPayload.batch(blocks, start: job.nextBlock)
        var updated = job
        if let pageID = job.pageID {
            guard !batch.isEmpty else { return nil }
            _ = try await request("blocks/\(pageID)/children", method: "PATCH", body: ["children": batch])
        } else {
            let schema = try await schema(for: job)
            let object = try await request("pages", method: "POST", body: NotionPayload.page(
                row: job.row, sourceID: schema.source, appIsSelect: schema.appIsSelect, children: batch))
            guard let id = object["id"] as? String, UUID(uuidString: id) != nil else { throw SafeFailure.invalidResponse }
            updated.pageID = id
        }
        updated.nextBlock += batch.count
        return updated.nextBlock >= blocks.count ? nil : updated
    }
}

public enum SheetsPayload {
    public static let marker = "\n[Truncated for Google Sheets; full text in local CSV]"
    public static func cell(_ text: String) -> String {
        guard text.utf16.count > 49_000 else { return text }
        return TextChunks.prefix(text, limit: 49_000 - marker.utf16.count) + marker
    }
    public static func url(spreadsheetID: String, sheetName: String) throws -> URL {
        guard !spreadsheetID.isEmpty, spreadsheetID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              !sheetName.isEmpty else { throw SafeFailure.invalidConfiguration }
        let range = "'" + sheetName.replacingOccurrences(of: "'", with: "''") + "'!A:E"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = range.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://sheets.googleapis.com/v4/spreadsheets/\(spreadsheetID)/values/\(encoded):append?valueInputOption=RAW&insertDataOption=INSERT_ROWS") else { throw SafeFailure.invalidConfiguration }
        return url
    }
    public static func body(_ row: CaptureRow) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["majorDimension": "ROWS", "values": [[
            cell(row.timestamp), cell(row.screen.app), cell(row.screen.title), cell(row.screen.text), row.dwellSeconds
        ] as [Any]]])
    }
}

public actor SheetsWriter: CloudWriting {
    private let http: HTTPClient
    private let accessToken: @Sendable (String) async throws -> String
    private let mockBaseURL: URL?
    public init(http: HTTPClient = HTTPClient(), mockBaseURL: URL? = nil, accessToken: @escaping @Sendable (String) async throws -> String) {
        self.http = http; self.accessToken = accessToken; self.mockBaseURL = mockBaseURL
    }
    public func deliver(_ job: CloudJob) async throws -> CloudJob? {
        let token = try await accessToken(job.clientID)
        let original = try SheetsPayload.url(spreadsheetID: job.target, sheetName: job.sheetName)
        let url = mockBaseURL.map { URL(string: original.path(percentEncoded: true) + "?" + (original.query ?? ""), relativeTo: $0)!.absoluteURL } ?? original
        let request = HTTPClient.jsonRequest(url: url,
                                            bearer: token, body: try SheetsPayload.body(job.row))
        _ = try await http.send(request)
        return nil
    }
}

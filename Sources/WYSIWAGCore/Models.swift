import Foundation

public struct ScreenSnapshot: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var app: String
    public var bundleID: String
    public var title: String
    public var text: String

    public init(timestamp: Date = Date(), app: String, bundleID: String, title: String, text: String) {
        self.timestamp = timestamp
        self.app = app
        self.bundleID = bundleID
        self.title = title
        self.text = TextNormalizer.normalize(text)
    }
}

public enum TextNormalizer {
    public static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

public struct CaptureRow: Codable, Sendable, Equatable {
    public var id: UUID
    public var screen: ScreenSnapshot
    public var dwellSeconds: Double
    // Freeze the local offset/day at capture time, including across queue replay/time-zone changes.
    public var timestamp: String
    public var day: String

    public init(screen: ScreenSnapshot, previousWrittenAt: Date?, timeZone: TimeZone = .current) {
        id = UUID()
        self.screen = screen
        dwellSeconds = previousWrittenAt.map { max(0, screen.timestamp.timeIntervalSince($0)) } ?? 0
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestamp = iso.string(from: screen.timestamp)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        day = formatter.string(from: screen.timestamp)
    }

    public var fields: [String] {
        [timestamp, screen.app, screen.title, screen.text,
         String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), dwellSeconds)]
    }
}

public enum CaptureMode: String, Codable, CaseIterable, Sendable { case all = "ALL", smart = "SMART" }

/// Deliberately contains no credentials. Only Keychain account names are used elsewhere.
public struct AppSettings: Codable, Sendable, Equatable {
    public var interval: Double = 5
    public var mode: CaptureMode = .smart
    public var similarityThreshold: Double = 0.90
    public var jevEnabled = false
    public var jevProbabilityThreshold: Double = 0.5
    public var localFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/WYSIWAG").path
    public var notionEnabled = false
    public var notionDatabaseID = ""
    public var notionDataSourceID = ""
    public var googleEnabled = false
    public var googleClientID = ""
    public var spreadsheetID = ""
    public var sheetName = "Sheet1"
    public var excludedApps = ["com.1password.1password", "com.agilebits.onepassword7",
                               "com.apple.keychainaccess", "com.apple.systempreferences"]
    public var idleMinutes: Double = 5
    public var language = "system"
    public init() {}

    public mutating func validate() {
        interval = interval.isFinite ? min(3600, max(1, interval)) : 5
        idleMinutes = idleMinutes.isFinite ? min(240, max(1, idleMinutes)) : 5
        similarityThreshold = similarityThreshold.isFinite ? min(0.97, max(0.1, similarityThreshold)) : 0.9
        jevProbabilityThreshold = jevProbabilityThreshold.isFinite ? min(1, max(0, jevProbabilityThreshold)) : 0.5
    }
}

public enum SafeFailure: Error, Sendable, Equatable {
    case permission, noWindow, privacySkip, capture, localWrite, queueWrite, invalidConfiguration
    case keychain(Int32), network, invalidResponse, authentication, cancelled
    case http(Int, retryAfter: Double?)
}

/// Only allowlisted messages can reach diagnostics; never interpolate Error, request, URL or text.
public enum Diagnostics {
    public static func message(for error: any Error) -> String {
        switch error as? SafeFailure {
        case .permission: "Screen Recording permission is required. Restart after granting access."
        case .noWindow: "No capturable active window."
        case .privacySkip: "Capture skipped by privacy controls."
        case .localWrite: "Local CSV write failed. Capture paused."
        case .queueWrite: "Local CSV is safe. Cloud queue storage needs attention."
        case .invalidConfiguration: "Check destination configuration and database properties."
        case .keychain: "Keychain operation failed."
        case .authentication: "Replace the credential or sign in again."
        case .http(let status, _): "Cloud request failed (HTTP \(status)). Local CSV is safe."
        case .cancelled: "Operation cancelled."
        default: "Operation failed. No sensitive details were logged."
        }
    }
}

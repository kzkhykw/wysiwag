import Foundation

public enum ChangeDecision: Sendable, Equatable { case changed, unchanged, ambiguous }

/// An additional HTTP classifier only needs to implement this protocol.
public protocol ScreenChangeClassifier: Sendable {
    func classify(previous: ScreenSnapshot, current: ScreenSnapshot) async -> ChangeDecision
}

public struct HeuristicClassifier: ScreenChangeClassifier {
    public let threshold: Double
    public let highThreshold: Double
    public init(threshold: Double = 0.90, highThreshold: Double = 0.98) {
        self.threshold = min(0.97, max(0.1, threshold))
        self.highThreshold = max(self.threshold, min(1, highThreshold))
    }
    public func decision(previous: ScreenSnapshot, current: ScreenSnapshot) -> ChangeDecision {
        if previous.bundleID != current.bundleID || previous.app != current.app || previous.title != current.title {
            return .changed
        }
        let old = TextNormalizer.normalize(previous.text)
        let new = TextNormalizer.normalize(current.text)
        if old == new { return .unchanged }
        let score = Self.similarity(old, new)
        if score < threshold { return .changed }
        if score >= highThreshold { return .unchanged }
        return .ambiguous
    }
    public func classify(previous: ScreenSnapshot, current: ScreenSnapshot) async -> ChangeDecision {
        decision(previous: previous, current: current)
    }
    // Character bigrams also work for Japanese without word boundaries. Bounded linear work.
    public static func similarity(_ a: String, _ b: String) -> Double {
        func grams(_ text: String) -> Set<String> {
            let chars = Array(text)
            if chars.count < 2 { return Set(chars.map(String.init)) }
            return Set(zip(chars, chars.dropFirst()).map { String([$0, $1]) })
        }
        let left = grams(a), right = grams(b)
        let union = left.union(right).count
        return union == 0 ? 1 : Double(left.intersection(right).count) / Double(union)
    }
}

public struct JevRequest: Codable, Sendable {
    public struct Screen: Codable, Sendable { public let app: String; public let title: String; public let text: String }
    public struct State: Codable, Sendable { public let previous: Screen; public let current: Screen }
    public struct Question: Codable, Sendable { public let type: String; public let instructions: String }
    public let model: String
    public let state: State
    public let questions: [String: Question]

    public init(previous: ScreenSnapshot, current: ScreenSnapshot) {
        func screen(_ value: ScreenSnapshot) -> Screen {
            // < 48k UTF-8 bytes total (before JSON escaping), conservatively below 64k tokens
            // even for Japanese. Reserve context for metadata and the question.
            Screen(app: Self.truncate(value.app, bytes: 512), title: Self.truncate(value.title, bytes: 1024),
                   text: Self.truncate(value.text, bytes: 22_000))
        }
        model = "jev-latest"
        state = State(previous: screen(previous), current: screen(current))
        questions = ["changed": Question(type: "noul", instructions:
            "Has the visible screen meaningfully changed (different screen, app switch, tab switch, or displayed text change)?")]
    }

    public static func truncate(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        let note = "\n[Truncated for context limit]"
        var result = "", count = 0
        for scalar in text.unicodeScalars {
            let size = scalar.utf8.count
            if count + size > bytes - note.utf8.count { break }
            result.unicodeScalars.append(scalar)
            count += size
        }
        return result + note
    }
}

public struct JevResponse: Decodable, Sendable {
    public struct Answer: Decodable, Sendable { public let noul: Double }
    public let answers: [String: Answer]
}

public actor JevClassifier: ScreenChangeClassifier {
    private let http: HTTPClient
    private let key: @Sendable () throws -> String?
    private let threshold: Double
    private var nextAttempt = Date.distantPast
    private var failures = 0
    private let endpoint: URL
    public private(set) var lastFailure: SafeFailure?

    public init(http: HTTPClient = HTTPClient(), probabilityThreshold: Double = 0.5,
                endpoint: URL = URL(string: "https://api.typesafe.ai/v1/systemone")!,
                key: @escaping @Sendable () throws -> String? = { try KeychainStore().read(.jevKey) }) {
        self.http = http
        threshold = min(1, max(0, probabilityThreshold))
        self.key = key
        self.endpoint = endpoint
    }

    public func classify(previous: ScreenSnapshot, current: ScreenSnapshot) async -> ChangeDecision {
        guard Date() >= nextAttempt else { return .changed }
        do {
            guard let key = try key(), !key.isEmpty else { throw SafeFailure.authentication }
            let body = try JSONEncoder().encode(JevRequest(previous: previous, current: current))
            let request = HTTPClient.jsonRequest(url: endpoint, bearer: key, body: body)
            let data = try await http.send(request)
            let result = try JSONDecoder().decode(JevResponse.self, from: data)
            guard let probability = result.answers["changed"]?.noul, probability.isFinite,
                  (0...1).contains(probability) else { throw SafeFailure.invalidResponse }
            failures = 0; lastFailure = nil
            return probability >= threshold ? .changed : .unchanged
        } catch {
            failures += 1
            lastFailure = error as? SafeFailure ?? .invalidResponse
            let backoff = min(300, pow(2, Double(min(failures, 8))))
            if case let SafeFailure.http(status, retryAfter) = error {
                let delay: Double = (status == 429 || status == 529) ? max(backoff, retryAfter ?? 5) : max(backoff, 30)
                nextAttempt = Date().addingTimeInterval(delay)
            } else { nextAttempt = Date().addingTimeInterval(backoff) }
            return .changed
        }
    }
}

public struct SmartClassifier: ScreenChangeClassifier {
    public let remote: any ScreenChangeClassifier
    public init(remote: any ScreenChangeClassifier) {
        self.remote = remote
    }
    public func classify(previous: ScreenSnapshot, current: ScreenSnapshot) async -> ChangeDecision {
        let result = await remote.classify(previous: previous, current: current)
        return result == .ambiguous ? .changed : result
    }
}

public struct AutoClassifier: ScreenChangeClassifier {
    public let threshold: Double
    public init(threshold: Double = 0.90) { self.threshold = min(1, max(0, threshold)) }
    public func classify(previous: ScreenSnapshot, current: ScreenSnapshot) async -> ChangeDecision {
        if previous.app != current.app || previous.bundleID != current.bundleID || previous.title != current.title { return .changed }
        return HeuristicClassifier.similarity(TextNormalizer.normalize(previous.text), TextNormalizer.normalize(current.text)) < threshold ? .changed : .unchanged
    }
}

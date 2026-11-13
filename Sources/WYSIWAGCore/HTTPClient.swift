import Foundation

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct HTTPClient: Sendable {
    public let session: URLSession
    public init(session: URLSession? = nil) {
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        }
    }

    public func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SafeFailure.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                // Never attach the response body: servers may echo credentials or captured text.
                throw SafeFailure.http(http.statusCode, retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
            }
            return data
        } catch let error as SafeFailure { throw error }
        catch is CancellationError { throw SafeFailure.cancelled }
        catch { throw SafeFailure.network }
    }

    public static func retryAfter(_ value: String?, now: Date = Date()) -> Double? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    public static func jsonRequest(url: URL, method: String = "POST", bearer: String, body: Data) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }
}

import Foundation

enum Network {
    /// Name, version and homepage, as LRCLIB (and GitHub) ask clients to identify themselves.
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "YihaosNotch/\(version) (https://github.com/liuy7713/YihaosNotch)"
    }()

    /// One in-memory session for lyrics and artwork. Ephemeral, so responses (which
    /// together amount to a listening history) are never written to the disk cache.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        // An overall limit too: the request timeout alone resets on every trickle of data.
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    /// Downloads at most `limit` bytes. A response that announces, or turns out, to be
    /// larger is abandoned as soon as that's known, not after it has all arrived.
    static func data(for request: URLRequest, limit: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard response.expectedContentLength <= Int64(limit) else {
            bytes.task.cancel()
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        data.reserveCapacity(Int(max(response.expectedContentLength, 0)))
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit {
                bytes.task.cancel()
                throw URLError(.dataLengthExceedsMaximum)
            }
        }
        return (data, response)
    }
}

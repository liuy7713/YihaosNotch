import Foundation

enum Network {
    /// One in-memory session for lyrics and artwork. Ephemeral, so responses (which
    /// together amount to a listening history) are never written to the disk cache.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()
}

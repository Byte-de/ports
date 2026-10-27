import Foundation

enum BoundedDownloadError: Error, Sendable {
    case tooLarge, rejected
}

/// Loads one response body in chunks and stops as soon as the declared or received size exceeds the limit, so an
/// oversized or unexpected answer is never read into memory.
final class BoundedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let accept: @Sendable (HTTPURLResponse) -> Bool
    // Mutated only on the session's serial delegate queue.
    private var body = Data()
    private var failure: BoundedDownloadError?
    private var result: Result<Data, any Error>?
    private var continuation: CheckedContinuation<Data, any Error>?

    private init(limit: Int, accept: @escaping @Sendable (HTTPURLResponse) -> Bool) {
        self.limit = limit
        self.accept = accept
    }

    static func fetch(
        _ request: URLRequest, configuration: URLSessionConfiguration, limit: Int,
        accept: @escaping @Sendable (HTTPURLResponse) -> Bool
    ) async throws -> Data {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let download = BoundedDownload(limit: limit, accept: accept)
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // A task cancelled before it starts can complete before this block runs, so the result waits.
                queue.addOperation {
                    download.continuation = continuation
                    download.deliver()
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // The async variant would run outside the delegate queue.
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, accept(http) else {
            failure = .rejected
            return completionHandler(.cancel)
        }
        guard response.expectedContentLength <= Int64(limit) else {
            failure = .tooLarge
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard data.count <= limit - body.count else {
            failure = .tooLarge
            return dataTask.cancel()
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard result == nil else { return }
        if let failure {
            result = .failure(failure)
        } else if let error {
            result = .failure(error)
        } else {
            result = .success(body)
        }
        deliver()
    }

    private func deliver() {
        guard let result, let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

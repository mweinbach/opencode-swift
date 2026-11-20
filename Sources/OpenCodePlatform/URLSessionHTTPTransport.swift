#if !os(WASI)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#endif
import Synchronization

/// Errors surfaced by cross-platform `HTTPTransport` implementations.
public enum HTTPTransportError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidURL(String)
    case invalidResponse(String)
    case networkFailure(String)
    case cancelled
    case noStubbedResponse(method: String, url: String)
    case unsupportedPlatform(PlatformOS)

    public var description: String {
        switch self {
        case .invalidURL(let url):
            return "Invalid HTTP URL: \(url)"
        case .invalidResponse(let detail):
            return "Invalid HTTP response: \(detail)"
        case .networkFailure(let detail):
            return "HTTP network failure: \(detail)"
        case .cancelled:
            return "HTTP request cancelled"
        case let .noStubbedResponse(method, url):
            return "No stubbed HTTP response available for \(method) \(url)"
        case .unsupportedPlatform(let os):
            return "Native HTTP transport is unsupported on \(os.rawValue)"
        }
    }
}

// MARK: - Native URLSession HTTP Transport

/// Native `URLSession`-backed `HTTPTransport` supporting both unary `send(_:)`
/// and incremental chunk-by-chunk `stream(_:)` across Apple, Linux, and Windows.
/// On WASI, requests fail with `HTTPTransportError.unsupportedPlatform(.wasi)`.
public final class URLSessionHTTPTransport: HTTPTransport, Sendable {
    public struct Configuration: Equatable, Sendable {
        public let timeoutIntervalForRequest: Double
        public let timeoutIntervalForResource: Double
        public let defaultHeaders: [String: String]

        public init(
            timeoutIntervalForRequest: Double = 60,
            timeoutIntervalForResource: Double = 3600,
            defaultHeaders: [String: String] = [:]
        ) {
            self.timeoutIntervalForRequest = timeoutIntervalForRequest
            self.timeoutIntervalForResource = timeoutIntervalForResource
            self.defaultHeaders = defaultHeaders
        }
    }

    public static let shared = URLSessionHTTPTransport()

    public let configuration: Configuration

    #if !os(WASI)
    private let session: URLSession
    private let delegate: StreamingSessionDelegate
    #endif

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        #if !os(WASI)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = configuration.timeoutIntervalForRequest
        sessionConfig.timeoutIntervalForResource = configuration.timeoutIntervalForResource
        let delegate = StreamingSessionDelegate()
        self.delegate = delegate
        let queue = OperationQueue()
        queue.name = "opencode.http.transport"
        queue.maxConcurrentOperationCount = 1
        self.session = URLSession(
            configuration: sessionConfig,
            delegate: delegate,
            delegateQueue: queue
        )
        #endif
    }

    #if !os(WASI)
    /// Wraps a caller-supplied `URLSessionConfiguration` (for example with custom proxies or TLS settings).
    public init(
        sessionConfiguration: URLSessionConfiguration,
        defaultHeaders: [String: String] = [:]
    ) {
        self.configuration = Configuration(
            timeoutIntervalForRequest: sessionConfiguration.timeoutIntervalForRequest,
            timeoutIntervalForResource: sessionConfiguration.timeoutIntervalForResource,
            defaultHeaders: defaultHeaders
        )
        let delegate = StreamingSessionDelegate()
        self.delegate = delegate
        let queue = OperationQueue()
        queue.name = "opencode.http.transport"
        queue.maxConcurrentOperationCount = 1
        self.session = URLSession(
            configuration: sessionConfiguration,
            delegate: delegate,
            delegateQueue: queue
        )
    }
    #endif

    deinit {
        #if !os(WASI)
        session.finishTasksAndInvalidate()
        #endif
    }

    /// Cancels all in-flight tasks and invalidates the underlying session.
    public func invalidateAndCancel() {
        #if !os(WASI)
        session.invalidateAndCancel()
        delegate.cancelAll()
        #endif
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        #if os(WASI)
        throw HTTPTransportError.unsupportedPlatform(.wasi)
        #else
        let urlRequest = try buildURLRequest(from: request)
        #if canImport(Darwin)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            let head = try extractHead(from: response)
            return HTTPResponse(head: head, body: Array(data))
        } catch let error as HTTPTransportError {
            throw error
        } catch is CancellationError {
            throw HTTPTransportError.cancelled
        } catch {
            throw HTTPTransportError.networkFailure(String(describing: error))
        }
        #else
        let streaming = try await stream(request)
        var collected: [UInt8] = []
        for try await chunk in streaming.chunks {
            collected.append(contentsOf: chunk)
        }
        return HTTPResponse(head: streaming.head, body: collected)
        #endif
        #endif
    }

    public func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        #if os(WASI)
        throw HTTPTransportError.unsupportedPlatform(.wasi)
        #else
        let urlRequest = try buildURLRequest(from: request)
        let dataTask = session.dataTask(with: urlRequest)
        let taskID = dataTask.taskIdentifier
        let (chunks, streamContinuation) = AsyncThrowingStream<[UInt8], Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        let cancelBox = TaskCancelBox(task: dataTask)
        streamContinuation.onTermination = { @Sendable _ in
            cancelBox.cancel()
        }

        let delegate = self.delegate
        let head = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (headContinuation: CheckedContinuation<HTTPResponseHead, any Error>) in
                delegate.register(
                    taskID: taskID,
                    headContinuation: headContinuation,
                    streamContinuation: streamContinuation
                )
                dataTask.resume()
            }
        } onCancel: {
            cancelBox.cancel()
        }

        return HTTPStreamingResponse(head: head, chunks: chunks)
        #endif
    }

    #if !os(WASI)
    private func buildURLRequest(from request: HTTPRequest) throws -> URLRequest {
        guard let url = URL(string: request.url),
              let scheme = url.scheme?.lowercased(),
              !scheme.isEmpty else {
            throw HTTPTransportError.invalidURL(request.url)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = configuration.timeoutIntervalForRequest

        for (key, value) in configuration.defaultHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if let body = request.body {
            urlRequest.httpBody = Data(body)
        }
        return urlRequest
    }
    #endif
}

#if !os(WASI)
private func extractHead(from response: URLResponse) throws -> HTTPResponseHead {
    guard let httpResponse = response as? HTTPURLResponse else {
        throw HTTPTransportError.invalidResponse("Expected HTTPURLResponse, got \(type(of: response))")
    }
    var headers: [String: String] = [:]
    headers.reserveCapacity(httpResponse.allHeaderFields.count)
    for (rawKey, rawValue) in httpResponse.allHeaderFields {
        headers[String(describing: rawKey)] = String(describing: rawValue)
    }
    return HTTPResponseHead(statusCode: httpResponse.statusCode, headers: headers)
}

private final class TaskCancelBox: @unchecked Sendable {
    private let task: URLSessionDataTask

    init(task: URLSessionDataTask) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

private final class StreamingSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Entry {
        var headContinuation: CheckedContinuation<HTTPResponseHead, any Error>?
        let streamContinuation: AsyncThrowingStream<[UInt8], Error>.Continuation
        #if !canImport(Darwin)
        var rejectedAuthChallenge: Bool = false
        #endif
    }

    private let entries = Mutex<[Int: Entry]>([:])

    func register(
        taskID: Int,
        headContinuation: CheckedContinuation<HTTPResponseHead, any Error>,
        streamContinuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    ) {
        entries.withLock { map in
            map[taskID] = Entry(
                headContinuation: headContinuation,
                streamContinuation: streamContinuation
            )
        }
    }

    func cancelAll() {
        let pending = entries.withLock { map -> [Entry] in
            let all = Array(map.values)
            map.removeAll()
            return all
        }
        for entry in pending {
            entry.headContinuation?.resume(throwing: HTTPTransportError.cancelled)
            entry.streamContinuation.finish(throwing: HTTPTransportError.cancelled)
        }
    }

    private func handleResponse(
        taskID: Int,
        response: URLResponse
    ) -> URLSession.ResponseDisposition {
        do {
            let head = try extractHead(from: response)
            let headCont = entries.withLock { map -> CheckedContinuation<HTTPResponseHead, any Error>? in
                guard var entry = map[taskID] else { return nil }
                let cont = entry.headContinuation
                entry.headContinuation = nil
                map[taskID] = entry
                return cont
            }
            headCont?.resume(returning: head)
            return .allow
        } catch {
            let entry = entries.withLock { $0.removeValue(forKey: taskID) }
            entry?.headContinuation?.resume(throwing: error)
            entry?.streamContinuation.finish(throwing: error)
            return .cancel
        }
    }

    #if canImport(Darwin)
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(handleResponse(taskID: dataTask.taskIdentifier, response: response))
    }
    #else
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(handleResponse(taskID: dataTask.taskIdentifier, response: response))
    }
    #endif

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard !data.isEmpty else { return }
        let streamCont = entries.withLock { $0[dataTask.taskIdentifier]?.streamContinuation }
        streamCont?.yield(Array(data))
    }

    #if !canImport(Darwin)
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // On swift-corelibs-foundation (Linux/Windows), returning `.performDefaultHandling` (or
        // omitting this delegate method) for an HTTP 401 `WWW-Authenticate` challenge causes the
        // data task to hang indefinitely after headers and body have already been delivered.
        // Rejecting the protection space completes the task promptly so callers receive the 401.
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodHTTPBasic
            || method == NSURLAuthenticationMethodHTTPDigest
            || method == NSURLAuthenticationMethodDefault {
            entries.withLock { map in
                map[task.taskIdentifier]?.rejectedAuthChallenge = true
            }
            completionHandler(.rejectProtectionSpace, nil)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
    #endif

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let entry = entries.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        guard let entry else { return }
        if let error {
            let nsError = error as NSError
            #if !canImport(Darwin)
            if entry.rejectedAuthChallenge
                && entry.headContinuation == nil
                && nsError.domain == NSURLErrorDomain
                && nsError.code == NSURLErrorCancelled {
                entry.streamContinuation.finish()
                return
            }
            #endif
            let mappedError: any Error
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                mappedError = HTTPTransportError.cancelled
            } else {
                mappedError = HTTPTransportError.networkFailure(error.localizedDescription)
            }
            if let headCont = entry.headContinuation {
                headCont.resume(throwing: mappedError)
            }
            entry.streamContinuation.finish(throwing: mappedError)
        } else {
            if let headCont = entry.headContinuation {
                let err = HTTPTransportError.invalidResponse("Connection completed before HTTP headers arrived")
                headCont.resume(throwing: err)
                entry.streamContinuation.finish(throwing: err)
            } else {
                entry.streamContinuation.finish()
            }
        }
    }
}
#endif

// MARK: - Deterministic Cross-Platform Mock HTTP Transport

/// Deterministic, thread-safe mock `HTTPTransport` with a FIFO stub queue and request recorder.
/// Works identically across every Swift 6 platform including WASI.
public final class MockHTTPTransport: HTTPTransport, Sendable {
    public enum Stub: Sendable {
        case response(HTTPResponse)
        case stream(head: HTTPResponseHead, chunks: [[UInt8]], trailingError: (any Error)? = nil)
        case failure(any Error)
        case handler(@Sendable (HTTPRequest) async throws -> HTTPResponse)
        case streamHandler(@Sendable (HTTPRequest) async throws -> HTTPStreamingResponse)
    }

    private struct State: Sendable {
        var stubs: [Stub] = []
        var requests: [HTTPRequest] = []
        var fallbackHandler: (@Sendable (HTTPRequest) async throws -> HTTPResponse)?
    }

    private let state = Mutex(State())

    public init(
        stubs: [Stub] = [],
        fallbackHandler: (@Sendable (HTTPRequest) async throws -> HTTPResponse)? = nil
    ) {
        state.withLock { s in
            s.stubs = stubs
            s.fallbackHandler = fallbackHandler
        }
    }

    /// Appends a stub to the back of the deterministic FIFO queue.
    public func enqueue(_ stub: Stub) {
        state.withLock { $0.stubs.append(stub) }
    }

    /// Convenience helper to enqueue a unary byte response.
    public func enqueueResponse(
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: [UInt8] = []
    ) {
        enqueue(.response(HTTPResponse(
            head: HTTPResponseHead(statusCode: statusCode, headers: headers),
            body: body
        )))
    }

    /// Convenience helper to enqueue a UTF-8 text response.
    public func enqueueResponse(
        statusCode: Int = 200,
        headers: [String: String] = [:],
        text: String
    ) {
        enqueueResponse(statusCode: statusCode, headers: headers, body: Array(text.utf8))
    }

    /// Convenience helper to enqueue an incremental streaming response.
    public func enqueueStream(
        statusCode: Int = 200,
        headers: [String: String] = [:],
        chunks: [[UInt8]],
        trailingError: (any Error)? = nil
    ) {
        enqueue(.stream(
            head: HTTPResponseHead(statusCode: statusCode, headers: headers),
            chunks: chunks,
            trailingError: trailingError
        ))
    }

    /// Convenience helper to enqueue a failure error.
    public func enqueueError(_ error: any Error) {
        enqueue(.failure(error))
    }

    /// Sets or clears a fallback handler used when the stub queue is empty.
    public func setFallbackHandler(_ handler: (@Sendable (HTTPRequest) async throws -> HTTPResponse)?) {
        state.withLock { $0.fallbackHandler = handler }
    }

    /// Returns all requests recorded in arrival order.
    public var recordedRequests: [HTTPRequest] {
        state.withLock { $0.requests }
    }

    /// Number of queued stubs not yet consumed.
    public var remainingStubCount: Int {
        state.withLock { $0.stubs.count }
    }

    /// Clears recorded requests, queued stubs, and fallback handler.
    public func reset() {
        state.withLock { $0 = State() }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let (stub, fallback) = dequeue(recording: request)
        guard let stub else {
            if let fallback {
                return try await fallback(request)
            }
            throw HTTPTransportError.noStubbedResponse(method: request.method, url: request.url)
        }
        switch stub {
        case .response(let response):
            return response
        case let .stream(head, chunks, trailingError):
            if let trailingError {
                throw trailingError
            }
            var body: [UInt8] = []
            for chunk in chunks {
                body.append(contentsOf: chunk)
            }
            return HTTPResponse(head: head, body: body)
        case .failure(let error):
            throw error
        case .handler(let fn):
            return try await fn(request)
        case .streamHandler(let fn):
            let streaming = try await fn(request)
            var body: [UInt8] = []
            for try await chunk in streaming.chunks {
                body.append(contentsOf: chunk)
            }
            return HTTPResponse(head: streaming.head, body: body)
        }
    }

    public func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        let (stub, fallback) = dequeue(recording: request)
        guard let stub else {
            if let fallback {
                let response = try await fallback(request)
                return makeSingleChunkStream(response)
            }
            throw HTTPTransportError.noStubbedResponse(method: request.method, url: request.url)
        }
        switch stub {
        case .response(let response):
            return makeSingleChunkStream(response)
        case let .stream(head, chunks, trailingError):
            let (stream, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
            for chunk in chunks {
                continuation.yield(chunk)
            }
            if let trailingError {
                continuation.finish(throwing: trailingError)
            } else {
                continuation.finish()
            }
            return HTTPStreamingResponse(head: head, chunks: stream)
        case .failure(let error):
            throw error
        case .handler(let fn):
            let response = try await fn(request)
            return makeSingleChunkStream(response)
        case .streamHandler(let fn):
            return try await fn(request)
        }
    }

    private func dequeue(recording request: HTTPRequest) -> (Stub?, (@Sendable (HTTPRequest) async throws -> HTTPResponse)?) {
        state.withLock { s in
            s.requests.append(request)
            if !s.stubs.isEmpty {
                return (s.stubs.removeFirst(), s.fallbackHandler)
            }
            return (nil, s.fallbackHandler)
        }
    }

    private func makeSingleChunkStream(_ response: HTTPResponse) -> HTTPStreamingResponse {
        let (stream, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
        if !response.body.isEmpty {
            continuation.yield(response.body)
        }
        continuation.finish()
        return HTTPStreamingResponse(head: response.head, chunks: stream)
    }
}

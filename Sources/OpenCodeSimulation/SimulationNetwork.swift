#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer
import OpenCodeUtil

/// Simulated in-memory HTTP network replacing `LayerNodePlatform.httpClient` in simulation mode
/// (`packages/simulation/src/backend/network.ts`).
///
/// All outbound HTTP resolves against an explicit route table; unknown destinations fail loudly
/// with a `TransportError` so no simulation run can silently reach the real network.
public enum SimulationNetwork {
    /// Parsed URL components exposed to simulated network routes (origin + pathname + query).
    public struct ParsedURL: Equatable, Hashable, Sendable {
        public let raw: String
        public let scheme: String
        public let host: String
        public let port: Int?
        public let pathname: String
        public let search: String

        /// Scheme + host (+ non-default port) matching WHATWG `URL.origin`.
        public var origin: String {
            guard !scheme.isEmpty, !host.isEmpty else { return "" }
            let defaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
            if let port, !defaultPort {
                return "\(scheme)://\(host):\(port)"
            }
            return "\(scheme)://\(host)"
        }

        public init(_ raw: String) {
            self.raw = raw
            var rest = raw[...]
            if let schemeRange = rest.range(of: "://") {
                self.scheme = String(rest[..<schemeRange.lowerBound]).lowercased()
                rest = rest[schemeRange.upperBound...]
            } else {
                self.scheme = ""
            }
            let authEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
            let authority = String(rest[..<authEnd])
            rest = rest[authEnd...]

            if !scheme.isEmpty && !authority.isEmpty {
                let hostPort: String
                if let atIdx = authority.lastIndex(of: "@") {
                    hostPort = String(authority[authority.index(after: atIdx)...])
                } else {
                    hostPort = authority
                }
                if hostPort.hasPrefix("["), let close = hostPort.firstIndex(of: "]") {
                    let h = String(hostPort[...close]).lowercased()
                    let afterClose = hostPort[hostPort.index(after: close)...]
                    if afterClose.hasPrefix(":"), let p = Int(afterClose.dropFirst()) {
                        self.host = h
                        self.port = p
                    } else {
                        self.host = h
                        self.port = nil
                    }
                } else if let colon = hostPort.lastIndex(of: ":"),
                          let p = Int(hostPort[hostPort.index(after: colon)...])
                {
                    self.host = String(hostPort[..<colon]).lowercased()
                    self.port = p
                } else {
                    self.host = hostPort.lowercased()
                    self.port = nil
                }
            } else {
                self.host = ""
                self.port = nil
            }

            if let hashIdx = rest.firstIndex(of: "#") {
                rest = rest[..<hashIdx]
            }
            if let qIdx = rest.firstIndex(of: "?") {
                let p = String(rest[..<qIdx])
                self.pathname = p.isEmpty ? "/" : p
                self.search = String(rest[qIdx...])
            } else {
                let p = String(rest)
                self.pathname = p.isEmpty ? "/" : p
                self.search = ""
            }
        }
    }

    /// Transport-level error raised by the simulated network for denied destinations, malformed payloads, or injected faults.
    public struct TransportError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "TransportError"

        public let requestMethod: String
        public let requestURL: String
        public let detail: String
        public let causeDescription: String?

        public init(
            requestMethod: String,
            requestURL: String,
            detail: String,
            causeDescription: String? = nil
        ) {
            self.requestMethod = requestMethod
            self.requestURL = requestURL
            self.detail = detail
            self.causeDescription = causeDescription
        }

        public var description: String { detail }
    }

    /// Fault injection descriptor for simulating network errors, HTTP error codes, and artificial latency.
    public enum Fault: Equatable, Hashable, Sendable {
        case transportError(String)
        case httpStatus(Int, body: String = "", headers: [String: String] = [:])
        case disconnectMidStream(afterBytes: Int, message: String = "Simulated connection reset")
    }

    /// A route matcher that either claims a request and returns a streaming response producer, or returns `nil` to pass.
    // parity: simulation/src/backend/network.ts#Route [status=implemented hash=1bcd66af51f4]
    public struct Route: Sendable {
        public let match: @Sendable (HTTPRequest, ParsedURL) -> (@Sendable () async throws -> HTTPStreamingResponse)?

        public init(
            match: @escaping @Sendable (HTTPRequest, ParsedURL) -> (@Sendable () async throws -> HTTPStreamingResponse)?
        ) {
            self.match = match
        }
    }

    /// Request log entry recorded for every outbound simulated HTTP attempt.
    // parity: simulation/src/backend/network.ts#LogEntry [status=implemented hash=1d331db0af62]
    public typealias LogEntry = OpenCodeProtocol.Backend.NetworkLogEntry

    /// Maximum number of log entries retained per simulated network run.
    public static let logLimit = 1000

    /// Static JSON route: exact method + origin/path match answered with a fixed 200 JSON body.
    // parity: simulation/src/backend/network.ts#json [status=implemented hash=623a27188331]
    public static func json(method: String, url: String, body: JSONValue) -> Route {
        let normalizedMethod = method.uppercased()
        return Route { request, requestURL in
            guard request.method.uppercased() == normalizedMethod else { return nil }
            guard requestURL.origin + requestURL.pathname == url else { return nil }
            return {
                let encoded = try ServerCodec.encode(body)
                let head = HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"])
                let stream = AsyncThrowingStream<[UInt8], Error> { continuation in
                    if !encoded.isEmpty { continuation.yield(encoded) }
                    continuation.finish()
                }
                return HTTPStreamingResponse(head: head, chunks: stream)
            }
        }
    }

    /// Convenience overload encoding any `Encodable & Sendable` body as a static JSON route.
    public static func json<T: Encodable & Sendable>(method: String, url: String, body: T) -> Route {
        let normalizedMethod = method.uppercased()
        return Route { request, requestURL in
            guard request.method.uppercased() == normalizedMethod else { return nil }
            guard requestURL.origin + requestURL.pathname == url else { return nil }
            return {
                let encoded = try ServerCodec.encode(body)
                let head = HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"])
                let stream = AsyncThrowingStream<[UInt8], Error> { continuation in
                    if !encoded.isEmpty { continuation.yield(encoded) }
                    continuation.finish()
                }
                return HTTPStreamingResponse(head: head, chunks: stream)
            }
        }
    }

    /// Wraps an existing `Route` with deterministic artificial latency before returning headers.
    public static func withLatency(_ route: Route, delayMs: Int) -> Route {
        let clamped = max(0, delayMs)
        return Route { request, url in
            guard let producer = route.match(request, url) else { return nil }
            return {
                if clamped > 0 {
                    try await Task.sleep(for: .milliseconds(clamped))
                }
                return try await producer()
            }
        }
    }

    /// Creates a fault-injecting route matching `method` (or `"*"` for any) and `urlPrefix`.
    public static func fault(
        method: String = "*",
        urlPrefix: String,
        fault: Fault,
        delayMs: Int = 0
    ) -> Route {
        let normalizedMethod = method.uppercased()
        let clamped = max(0, delayMs)
        return Route { request, url in
            if normalizedMethod != "*", request.method.uppercased() != normalizedMethod {
                return nil
            }
            guard url.raw.hasPrefix(urlPrefix) || (url.origin + url.pathname).hasPrefix(urlPrefix) else {
                return nil
            }
            return {
                if clamped > 0 {
                    try await Task.sleep(for: .milliseconds(clamped))
                }
                switch fault {
                case .transportError(let message):
                    throw TransportError(requestMethod: request.method, requestURL: request.url, detail: message)
                case .httpStatus(let status, let body, let headers):
                    let bytes = Array(body.utf8)
                    let stream = AsyncThrowingStream<[UInt8], Error> { continuation in
                        if !bytes.isEmpty { continuation.yield(bytes) }
                        continuation.finish()
                    }
                    return HTTPStreamingResponse(head: HTTPResponseHead(statusCode: status, headers: headers), chunks: stream)
                case .disconnectMidStream(let afterBytes, let message):
                    let stream = AsyncThrowingStream<[UInt8], Error> { continuation in
                        if afterBytes > 0 {
                            continuation.yield(Array(repeating: 0x20, count: afterBytes))
                        }
                        continuation.finish(
                            throwing: TransportError(
                                requestMethod: request.method,
                                requestURL: request.url,
                                detail: message
                            )
                        )
                    }
                    return HTTPStreamingResponse(head: HTTPResponseHead(statusCode: 200), chunks: stream)
                }
            }
        }
    }

    /// Acquired simulated network instance owning its `HTTPTransport` client and isolated request log.
    // parity: simulation/src/backend/network.ts#Run [status=implemented hash=6464f68b0bff]
    public struct Run: Sendable {
        public let client: any HTTPTransport
        public let log: @Sendable () async -> [LogEntry]

        public init(
            client: any HTTPTransport,
            log: @escaping @Sendable () async -> [LogEntry]
        ) {
            self.client = client
            self.log = log
        }
    }

    private final class SimulatedTransport: HTTPTransport, Sendable {
        private let routes: [Route]
        private let clockMs: @Sendable () -> Double
        private let entries = Mutex<[LogEntry]>([])

        init(routes: [Route], clockMs: @escaping @Sendable () -> Double) {
            self.routes = routes
            self.clockMs = clockMs
        }

        func logSnapshot() -> [LogEntry] {
            entries.withLock { $0 }
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let streaming = try await stream(request)
            var collected: [UInt8] = []
            for try await chunk in streaming.chunks {
                collected.append(contentsOf: chunk)
            }
            return HTTPResponse(head: streaming.head, body: collected)
        }

        func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
            let parsedURL = ParsedURL(request.url)
            var matched: (@Sendable () async throws -> HTTPStreamingResponse)?
            for route in routes {
                if let producer = route.match(request, parsedURL) {
                    matched = producer
                    break
                }
            }
            let entry = LogEntry(
                time: clockMs(),
                method: request.method.uppercased(),
                url: request.url,
                matched: matched != nil
            )
            entries.withLock { log in
                log.append(entry)
                if log.count > SimulationNetwork.logLimit {
                    log.removeFirst(log.count - SimulationNetwork.logLimit)
                }
            }
            if let matched {
                return try await matched()
            }
            throw TransportError(
                requestMethod: request.method,
                requestURL: request.url,
                detail: "Simulation denied unregistered network destination: \(request.method) \(request.url)"
            )
        }
    }

    /// Creates an isolated simulated network run with its own route table and bounded request log.
    // parity: simulation/src/backend/network.ts#make [status=implemented hash=ab5fa7484c87]
    public static func make(
        routes: [Route] = [],
        clockMs: @escaping @Sendable () -> Double = { Double(Flock.currentEpochMs()) }
    ) -> Run {
        let transport = SimulatedTransport(routes: routes, clockMs: clockMs)
        return Run(
            client: transport,
            log: { transport.logSnapshot() }
        )
    }

    /// Builds a `LayerNode.ExecutableLayer` providing the simulated `HTTPTransport` under `LayerNodePlatform.httpClientKey`.
    // parity: simulation/src/backend/network.ts#layer [status=implemented hash=55b91eea73c2]
    public static func layer(
        routes: [Route] = [],
        clockMs: @escaping @Sendable () -> Double = { Double(Flock.currentEpochMs()) }
    ) -> LayerNode.ExecutableLayer {
        LayerNode.ExecutableLayer { _, _ in
            let run = make(routes: routes, clockMs: clockMs)
            return LayerNode.Output([LayerNodePlatform.httpClientKey: run.client])
        }
    }
}

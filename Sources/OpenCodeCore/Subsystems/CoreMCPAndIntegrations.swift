#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - CoreMCP (`mcp/*` — JSON-RPC 2.0 Client, Stdio/HTTP/WebSocket Transports, Pool, OAuth, Registry)

public enum CoreMCP {
    // MARK: - JSON-RPC 2.0 Wire Framing

    public enum JSONRPCID: Equatable, Hashable, Sendable, Codable {
        case int(Int64)
        case string(String)

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let i = try? single.decode(Int64.self) {
                self = .int(i)
            } else if let s = try? single.decode(String.self) {
                self = .string(s)
            } else {
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "Invalid JSON-RPC id")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .int(let i): try single.encode(i)
            case .string(let s): try single.encode(s)
            }
        }
    }

    public struct JSONRPCErrorObject: Equatable, Hashable, Sendable, Codable, Swift.Error, CustomStringConvertible {
        public let code: Int
        public let message: String
        public let data: JSONValue?

        public init(code: Int, message: String, data: JSONValue? = nil) {
            self.code = code
            self.message = message
            self.data = data
        }

        public var description: String { "JSON-RPC error \(code): \(message)" }
    }

    public struct JSONRPCRequest: Equatable, Hashable, Sendable, Codable {
        public let jsonrpc: String
        public let id: JSONRPCID
        public let method: String
        public let params: JSONValue?

        public init(id: JSONRPCID, method: String, params: JSONValue? = nil) {
            self.jsonrpc = "2.0"
            self.id = id
            self.method = method
            self.params = params
        }
    }

    public struct JSONRPCNotification: Equatable, Hashable, Sendable, Codable {
        public let jsonrpc: String
        public let method: String
        public let params: JSONValue?

        public init(method: String, params: JSONValue? = nil) {
            self.jsonrpc = "2.0"
            self.method = method
            self.params = params
        }
    }

    public struct JSONRPCResponse: Equatable, Hashable, Sendable, Codable {
        public let jsonrpc: String
        public let id: JSONRPCID?
        public let result: JSONValue?
        public let error: JSONRPCErrorObject?

        public init(id: JSONRPCID?, result: JSONValue? = nil, error: JSONRPCErrorObject? = nil) {
            self.jsonrpc = "2.0"
            self.id = id
            self.result = result
            self.error = error
        }
    }

    public enum JSONRPCMessage: Equatable, Hashable, Sendable, Codable {
        case request(JSONRPCRequest)
        case notification(JSONRPCNotification)
        case response(JSONRPCResponse)

        public init(from decoder: Decoder) throws {
            let value = try JSONValue(from: decoder)
            guard case .object(let obj) = value else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected JSON-RPC object"))
            }
            let data = try JSONEncoder().encode(value)
            let dec = JSONDecoder()
            if obj["method"] != nil {
                if obj["id"] != nil {
                    self = .request(try dec.decode(JSONRPCRequest.self, from: data))
                } else {
                    self = .notification(try dec.decode(JSONRPCNotification.self, from: data))
                }
            } else if obj["result"] != nil || obj["error"] != nil {
                self = .response(try dec.decode(JSONRPCResponse.self, from: data))
            } else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unrecognized JSON-RPC message"))
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .request(let r): try r.encode(to: encoder)
            case .notification(let n): try n.encode(to: encoder)
            case .response(let resp): try resp.encode(to: encoder)
            }
        }

        public static func encodeLine(_ message: JSONRPCMessage) throws -> String {
            let data = try JSONEncoder().encode(message)
            return String(decoding: data, as: UTF8.self) + "\n"
        }

        public static func decodeLine(_ text: String) throws -> JSONRPCMessage {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return try JSONDecoder().decode(JSONRPCMessage.self, from: Data(trimmed.utf8))
        }
    }

    /// Transport contract for bidirectional MCP JSON-RPC 2.0 exchanges.
    public protocol Transport: Sendable {
        func start() async throws
        func send(_ message: JSONRPCMessage) async throws
        func close() async throws
        func setHandlers(
            onMessage: (@Sendable (JSONRPCMessage) -> Void)?,
            onError: (@Sendable (any Error) -> Void)?,
            onClose: (@Sendable () -> Void)?
        )
    }

    // MARK: - core/src/mcp/event-errors.ts

    public enum EventErrors {
        // parity: core/src/mcp/event-errors.ts#EventStreamRejectedError [status=implemented hash=2f7188e82873]
        public struct EventStreamRejectedError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "MCP.EventStreamRejectedError"
            public let server: String
            public let code: Int
            public let message: String

            public init(server: String, code: Int, message: String) {
                self.server = server
                self.code = code
                self.message = message
            }

            public var description: String { "MCP event stream rejected by \(server) (\(code)): \(message)" }
        }

        // parity: core/src/mcp/event-errors.ts#EventStreamTerminatedError [status=implemented hash=71e2affbf99a]
        public struct EventStreamTerminatedError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "MCP.EventStreamTerminatedError"
            public let server: String
            public let code: Int
            public let message: String
            public let data: JSONValue?

            public init(server: String, code: Int, message: String, data: JSONValue? = nil) {
                self.server = server
                self.code = code
                self.message = message
                self.data = data
            }

            public var description: String { "MCP event stream terminated by \(server) (\(code)): \(message)" }
        }
    }

    // MARK: - core/src/mcp/stdio.ts

    public enum Stdio {
        public static let maxFrameBytes: Int = 16 * 1024 * 1024

        // parity: core/src/mcp/stdio.ts#Options [status=implemented hash=a456e26eeaa7]
        public struct Options: Equatable, Hashable, Sendable {
            public let server: String
            public let command: String
            public let args: [String]
            public let cwd: String
            public let environment: [String: String]

            public init(
                server: String,
                command: String,
                args: [String] = [],
                cwd: String,
                environment: [String: String] = [:]
            ) {
                self.server = server
                self.command = command
                self.args = args
                self.cwd = cwd
                self.environment = environment
            }
        }

        // parity: core/src/mcp/stdio.ts#resolveCwd [status=implemented hash=a1c84e79d84f]
        public static func resolveCwd(
            directory: String,
            cwd: String?,
            homeDirectory: String? = SystemEnvironment.shared.homeDirectory
        ) -> String {
            guard let cwd, !cwd.isEmpty else { return directory }
            if cwd == "~", let home = homeDirectory { return home }
            if cwd.hasPrefix("~/"), let home = homeDirectory {
                return "\(home)/\(cwd.dropFirst(2))"
            }
            if cwd.hasPrefix("/") { return cwd }
            let cleanBase = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
            return CoreSubsystems.Util.GitExecutable.normalizePosix("\(cleanBase)/\(cwd)")
        }

        /// Newline-delimited JSON-RPC 2.0 Stdio transport backed by `OpenCodePlatform.ProcessSpawner`
        /// (and direct byte-chunk feeding for streaming/test harnesses).
        public final class StdioTransport: Transport, Sendable {
            private struct State: Sendable {
                var phase: String = "ready" // ready, open, closed
                var pendingBytes: [UInt8] = []
                var outgoingLines: [String] = []
                var onMessage: (@Sendable (JSONRPCMessage) -> Void)?
                var onError: (@Sendable (any Error) -> Void)?
                var onClose: (@Sendable () -> Void)?
            }

            public let options: Options
            private let spawner: any ProcessSpawner
            private let state = Mutex(State())

            public init(options: Options, spawner: any ProcessSpawner = CrossSpawnSpawner.HostProcessSpawner.shared) {
                self.options = options
                self.spawner = spawner
            }

            public func setHandlers(
                onMessage: (@Sendable (JSONRPCMessage) -> Void)?,
                onError: (@Sendable (any Error) -> Void)?,
                onClose: (@Sendable () -> Void)?
            ) {
                state.withLock { s in
                    s.onMessage = onMessage
                    s.onError = onError
                    s.onClose = onClose
                }
            }

            public func start() async throws {
                let canStart = state.withLock { s -> Bool in
                    guard s.phase == "ready" else { return false }
                    s.phase = "open"
                    return true
                }
                guard canStart else {
                    throw PlatformError.ioFailure("Stdio transport already started")
                }
            }

            public func send(_ message: JSONRPCMessage) async throws {
                let isOpen = state.withLock { $0.phase == "open" }
                guard isOpen else { throw PlatformError.ioFailure("Not connected") }
                let line = try JSONRPCMessage.encodeLine(message)
                state.withLock { $0.outgoingLines.append(line) }
                // Execute request/response via spawner when an external stdio command is configured.
                if !options.command.isEmpty {
                    let spec = ProcessSpec(
                        executable: options.command,
                        arguments: options.args,
                        workingDirectory: options.cwd,
                        environment: options.environment.isEmpty ? nil : options.environment,
                        stdin: Array(line.utf8)
                    )
                    let output = try await spawner.run(spec)
                    if !output.stdout.isEmpty {
                        feedStdout(output.stdout)
                    }
                    if output.exitCode != 0 && output.stdout.isEmpty {
                        let stderrText = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        let err = PlatformError.ioFailure(
                            stderrText.isEmpty
                                ? "MCP server process exited with code \(output.exitCode)"
                                : "MCP server process exited with code \(output.exitCode): \(stderrText)"
                        )
                        state.withLock { $0.onError }?(err)
                        throw err
                    }
                }
            }

            /// Feeds raw stdout bytes into the newline-delimited JSON-RPC frame parser (enforcing 16 MiB cap).
            public func feedStdout(_ chunk: [UInt8]) {
                var callbacksToRun: [@Sendable () -> Void] = []
                state.withLock { s in
                    guard s.phase != "closed" else { return }
                    var start = 0
                    while start < chunk.count, s.phase != "closed" {
                        if let nl = chunk[start...].firstIndex(of: 0x0A) {
                            let piece = chunk[start..<nl]
                            let totalSize = s.pendingBytes.count + piece.count
                            if totalSize > Stdio.maxFrameBytes {
                                let err = PlatformError.ioFailure(
                                    "MCP server \(options.server) wrote more than 16 MiB to stdout without a message boundary"
                                )
                                s.phase = "closed"
                                s.pendingBytes.removeAll()
                                if let onErr = s.onError { callbacksToRun.append { onErr(err) } }
                                if let onCl = s.onClose { callbacksToRun.append(onCl) }
                                return
                            }
                            var frame = s.pendingBytes
                            frame.append(contentsOf: piece)
                            s.pendingBytes.removeAll()
                            if frame.last == 0x0D { frame.removeLast() }
                            let text = String(decoding: frame, as: UTF8.self)
                            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                do {
                                    let msg = try JSONRPCMessage.decodeLine(text)
                                    if let onMsg = s.onMessage { callbacksToRun.append { onMsg(msg) } }
                                } catch {
                                    let err = PlatformError.ioFailure("Invalid MCP stdio message from \(options.server): \(error)")
                                    if let onErr = s.onError { callbacksToRun.append { onErr(err) } }
                                }
                            }
                            start = nl + 1
                        } else {
                            let tail = chunk[start...]
                            if s.pendingBytes.count + tail.count > Stdio.maxFrameBytes {
                                let err = PlatformError.ioFailure(
                                    "MCP server \(options.server) wrote more than 16 MiB to stdout without a message boundary"
                                )
                                s.phase = "closed"
                                s.pendingBytes.removeAll()
                                if let onErr = s.onError { callbacksToRun.append { onErr(err) } }
                                if let onCl = s.onClose { callbacksToRun.append(onCl) }
                                return
                            }
                            s.pendingBytes.append(contentsOf: tail)
                            break
                        }
                    }
                }
                for cb in callbacksToRun { cb() }
            }

            public func close() async throws {
                let onClose = state.withLock { s -> (@Sendable () -> Void)? in
                    guard s.phase != "closed" else { return nil }
                    s.phase = "closed"
                    s.pendingBytes.removeAll()
                    return s.onClose
                }
                onClose?()
            }
        }

        // parity: core/src/mcp/stdio.ts#make [status=implemented hash=d14f402d1a5c]
        public static func make(
            _ options: Options,
            spawner: any ProcessSpawner = CrossSpawnSpawner.HostProcessSpawner.shared
        ) -> StdioTransport {
            StdioTransport(options: options, spawner: spawner)
        }
    }

    // MARK: - Streamable HTTP MCP Transport (via OpenCodePlatform.HTTPTransport)

    /// Streamable HTTP JSON-RPC 2.0 MCP client transport supporting `Mcp-Session-Id` negotiation,
    /// JSON & `text/event-stream` SSE response decoding, 401 -> `NeedsAuthError`, and 404 -> `SessionExpiredError`.
    public final class StreamableHTTPTransport: Transport, Sendable {
        private struct State: Sendable {
            var started = false
            var closed = false
            var sessionID: String?
            var protocolVersion: String?
            var onMessage: (@Sendable (JSONRPCMessage) -> Void)?
            var onError: (@Sendable (any Error) -> Void)?
            var onClose: (@Sendable () -> Void)?
        }

        public let server: String
        public let url: String
        public let headers: [String: String]
        private let http: any HTTPTransport
        private let bearerTokenProvider: (@Sendable () async throws -> String?)?
        private let state = Mutex(State())

        public init(
            server: String,
            url: String,
            headers: [String: String] = [:],
            http: any HTTPTransport,
            bearerTokenProvider: (@Sendable () async throws -> String?)? = nil
        ) {
            self.server = server
            self.url = url
            self.headers = headers
            self.http = http
            self.bearerTokenProvider = bearerTokenProvider
        }

        public var currentSessionID: String? {
            state.withLock { $0.sessionID }
        }

        public func setHandlers(
            onMessage: (@Sendable (JSONRPCMessage) -> Void)?,
            onError: (@Sendable (any Error) -> Void)?,
            onClose: (@Sendable () -> Void)?
        ) {
            state.withLock { s in
                s.onMessage = onMessage
                s.onError = onError
                s.onClose = onClose
            }
        }

        public func start() async throws {
            state.withLock { s in
                s.started = true
                s.closed = false
            }
        }

        public func send(_ message: JSONRPCMessage) async throws {
            let (isOpen, sessionID, protoVersion) = state.withLock { s in
                (s.started && !s.closed, s.sessionID, s.protocolVersion)
            }
            guard isOpen else { throw PlatformError.ioFailure("Streamable HTTP transport is not open") }

            var reqHeaders = headers
            reqHeaders["content-type"] = "application/json"
            reqHeaders["accept"] = "application/json, text/event-stream"
            if let sessionID { reqHeaders["mcp-session-id"] = sessionID }
            if let protoVersion { reqHeaders["mcp-protocol-version"] = protoVersion }
            if let token = try await bearerTokenProvider?() {
                reqHeaders["authorization"] = "Bearer \(token)"
            }

            let bodyBytes = Array(try JSONEncoder().encode(message))
            let response = try await http.send(HTTPRequest(
                method: "POST",
                url: url,
                headers: reqHeaders,
                body: bodyBytes
            ))

            // Capture Mcp-Session-Id case-insensitively
            for (k, v) in response.head.headers where k.lowercased() == "mcp-session-id" {
                state.withLock { $0.sessionID = v }
            }

            let status = response.head.statusCode
            if status == 401 || status == 403 {
                throw Client.NeedsAuthError(server: server, message: "MCP server \"\(url)\" requires authorization (HTTP \(status))")
            }
            if status == 404 && sessionID != nil {
                throw Client.SessionExpiredError(server: server)
            }
            if status == 202 || status == 204 {
                return
            }
            guard (200..<300).contains(status) else {
                let errBody = String(decoding: response.body, as: UTF8.self)
                throw Client.ConnectError(server: server, message: "HTTP \(status): \(errBody)", answered: true)
            }

            let contentType = response.head.headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? "application/json"
            let onMsg = state.withLock { $0.onMessage }
            if contentType.contains("text/event-stream") {
                let raw = String(decoding: response.body, as: UTF8.self)
                for line in raw.split(separator: "\n") {
                    if line.hasPrefix("data:") {
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                        if payload.isEmpty || payload == "[DONE]" { continue }
                        if let decoded = try? JSONRPCMessage.decodeLine(payload) {
                            onMsg?(decoded)
                        }
                    }
                }
            } else if !response.body.isEmpty {
                let decoded = try JSONDecoder().decode(JSONRPCMessage.self, from: Data(response.body))
                onMsg?(decoded)
            }
        }

        public func close() async throws {
            let (sessionID, onClose) = state.withLock { s -> (String?, (@Sendable () -> Void)?) in
                if s.closed { return (nil, nil) }
                s.closed = true
                let sid = s.sessionID
                s.sessionID = nil
                return (sid, s.onClose)
            }
            if let sessionID {
                var delHeaders = headers
                delHeaders["mcp-session-id"] = sessionID
                _ = try? await http.send(HTTPRequest(method: "DELETE", url: url, headers: delHeaders))
            }
            onClose?()
        }
    }

    // MARK: - core/src/mcp/socket-client.ts

    public enum SocketClient {
        // parity: core/src/mcp/socket-client.ts#Socket [status=implemented hash=7ca3212a65d4]
        public protocol Socket: Sendable {
            func send(_ text: String) throws
            func close(code: Int?, reason: String?) throws
        }

        // parity: core/src/mcp/socket-client.ts#SocketTransport [status=implemented hash=ca1f07639c3e]
        public protocol SocketTransport: Transport {
            func deliver(_ text: String)
            func ended()
        }

        public final class TransportImpl: SocketTransport, Sendable {
            private struct State: Sendable {
                var phase: String = "ready" // ready, open, closed
                var pending: [String] = []
                var onMessage: (@Sendable (JSONRPCMessage) -> Void)?
                var onError: (@Sendable (any Error) -> Void)?
                var onClose: (@Sendable () -> Void)?
            }

            private let socket: any Socket
            private let state = Mutex(State())

            public init(socket: any Socket) {
                self.socket = socket
            }

            public func setHandlers(
                onMessage: (@Sendable (JSONRPCMessage) -> Void)?,
                onError: (@Sendable (any Error) -> Void)?,
                onClose: (@Sendable () -> Void)?
            ) {
                state.withLock { s in
                    s.onMessage = onMessage
                    s.onError = onError
                    s.onClose = onClose
                }
            }

            public func start() async throws {
                let toFlush: [String] = try state.withLock { s in
                    if s.phase == "closed" { throw PlatformError.ioFailure("Not connected") }
                    if s.phase == "open" { throw PlatformError.ioFailure("Socket transport already started") }
                    s.phase = "open"
                    let buffered = s.pending
                    s.pending.removeAll()
                    return buffered
                }
                for frame in toFlush {
                    receive(frame)
                }
            }

            public func send(_ message: JSONRPCMessage) async throws {
                let isOpen = state.withLock { $0.phase == "open" }
                guard isOpen else { throw PlatformError.ioFailure("Not connected") }
                let data = try JSONEncoder().encode(message)
                try socket.send(String(decoding: data, as: UTF8.self))
            }

            public func close() async throws {
                let alreadyClosed = state.withLock { $0.phase == "closed" }
                if alreadyClosed { return }
                var closeError: (any Error)?
                do {
                    try socket.close(code: 1000, reason: nil)
                } catch {
                    closeError = error
                }
                ended()
                if let closeError { throw closeError }
            }

            public func deliver(_ text: String) {
                let immediate = state.withLock { s -> Bool in
                    if s.phase == "closed" { return false }
                    if s.phase == "ready" || !s.pending.isEmpty {
                        s.pending.append(text)
                        return false
                    }
                    return true
                }
                if immediate {
                    receive(text)
                }
            }

            public func ended() {
                let cb = state.withLock { s -> (@Sendable () -> Void)? in
                    if s.phase == "closed" { return nil }
                    s.phase = "closed"
                    s.pending.removeAll()
                    return s.onClose
                }
                cb?()
            }

            private func receive(_ text: String) {
                let (onMsg, onErr) = state.withLock { ($0.onMessage, $0.onError) }
                do {
                    let msg = try JSONRPCMessage.decodeLine(text)
                    onMsg?(msg)
                } catch {
                    onErr?(PlatformError.ioFailure("Invalid MCP socket frame: \(error)"))
                }
            }
        }

        // parity: core/src/mcp/socket-client.ts#make [status=implemented hash=75971f566f0f]
        public static func make(_ socket: any Socket) -> SocketTransport {
            TransportImpl(socket: socket)
        }
    }

    // MARK: - core/src/mcp/client.ts

    public enum Client {
        public static let latestProtocolVersion = "2026-07-28"

        // parity: core/src/mcp/client.ts#EventType [status=implemented hash=9cc7b833eca6]
        public struct EventType: Equatable, Hashable, Sendable, Codable {
            public let name: String
            public let description: String?
            public let delivery: [String]?
            public let inputSchema: [String: JSONValue]?
            public let payloadSchema: [String: JSONValue]?

            public init(
                name: String,
                description: String? = nil,
                delivery: [String]? = nil,
                inputSchema: [String: JSONValue]? = nil,
                payloadSchema: [String: JSONValue]? = nil
            ) {
                self.name = name
                self.description = description
                self.delivery = delivery
                self.inputSchema = inputSchema
                self.payloadSchema = payloadSchema
            }
        }

        // parity: core/src/mcp/client.ts#EventError [status=implemented hash=2bb6f82e1eca]
        public struct EventError: Equatable, Hashable, Sendable, Codable {
            public let code: Int
            public let message: String
            public let data: JSONValue?

            public init(code: Int, message: String, data: JSONValue? = nil) {
                self.code = code
                self.message = message
                self.data = data
            }
        }

        // parity: core/src/mcp/client.ts#EventMessage [status=implemented hash=7a7a23eb5729]
        public enum EventMessage: Equatable, Hashable, Sendable {
            case active(cursor: String?, truncated: Bool)
            case event(eventId: String, name: String, timestamp: String, data: JSONValue, cursor: String?)
            case heartbeat(cursor: String?)
            case error(EventError)
        }

        // parity: core/src/mcp/client.ts#ResourceTemplate [status=implemented hash=0496e6bf922e]
        public struct ResourceTemplate: Equatable, Hashable, Sendable, Codable {
            public let name: String
            public let uriTemplate: String
            public let description: String?
            public let mimeType: String?

            public init(name: String, uriTemplate: String, description: String? = nil, mimeType: String? = nil) {
                self.name = name
                self.uriTemplate = uriTemplate
                self.description = description
                self.mimeType = mimeType
            }
        }

        public struct Resource: Equatable, Hashable, Sendable, Codable {
            public let name: String
            public let uri: String
            public let description: String?
            public let mimeType: String?

            public init(name: String, uri: String, description: String? = nil, mimeType: String? = nil) {
                self.name = name
                self.uri = uri
                self.description = description
                self.mimeType = mimeType
            }
        }

        public struct Prompt: Equatable, Hashable, Sendable, Codable {
            public struct Argument: Equatable, Hashable, Sendable, Codable {
                public let name: String
                public let description: String?
                public let required: Bool?

                public init(name: String, description: String? = nil, required: Bool? = nil) {
                    self.name = name
                    self.description = description
                    self.required = required
                }
            }

            public let name: String
            public let description: String?
            public let arguments: [Argument]?

            public init(name: String, description: String? = nil, arguments: [Argument]? = nil) {
                self.name = name
                self.description = description
                self.arguments = arguments
            }
        }

        public struct GetPromptResult: Equatable, Hashable, Sendable, Codable {
            public let description: String?
            public let messages: [JSONValue]

            public init(description: String? = nil, messages: [JSONValue] = []) {
                self.description = description
                self.messages = messages
            }
        }

        public struct ReadResourceResult: Equatable, Hashable, Sendable, Codable {
            public let contents: [JSONValue]

            public init(contents: [JSONValue] = []) {
                self.contents = contents
            }
        }

        // parity: core/src/mcp/client.ts#Tool [status=implemented hash=27f5a135408f]
        public struct Tool: Equatable, Hashable, Sendable, Codable {
            public let name: String
            public let title: String?
            public let description: String?
            public let inputSchema: [String: JSONValue]
            public let outputSchema: [String: JSONValue]?
            public let annotations: [String: JSONValue]?
            public let execution: [String: JSONValue]?
            public let meta: [String: JSONValue]?

            public init(
                name: String,
                title: String? = nil,
                description: String? = nil,
                inputSchema: [String: JSONValue] = ["type": .string("object")],
                outputSchema: [String: JSONValue]? = nil,
                annotations: [String: JSONValue]? = nil,
                execution: [String: JSONValue]? = nil,
                meta: [String: JSONValue]? = nil
            ) {
                self.name = name
                self.title = title
                self.description = description
                self.inputSchema = inputSchema
                self.outputSchema = outputSchema
                self.annotations = annotations
                self.execution = execution
                self.meta = meta
            }

            enum CodingKeys: String, CodingKey {
                case name, title, description, inputSchema, outputSchema, annotations, execution
                case meta = "_meta"
            }
        }

        // parity: core/src/mcp/client.ts#NeedsAuthError [status=implemented hash=c211a065310e]
        public struct NeedsAuthError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "MCP.NeedsAuthError"
            public let server: String
            public let message: String

            public init(server: String, message: String) {
                self.server = server
                self.message = message
            }

            public var description: String { message }
        }

        // parity: core/src/mcp/client.ts#ConnectError [status=implemented hash=2dac8622951c]
        public struct ConnectError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "MCP.ConnectError"
            public let server: String
            public let message: String
            public let answered: Bool?

            public init(server: String, message: String, answered: Bool? = nil) {
                self.server = server
                self.message = message
                self.answered = answered
            }

            public var description: String { message }
        }

        // parity: core/src/mcp/client.ts#SessionExpiredError [status=implemented hash=b74c53d13810]
        public struct SessionExpiredError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "MCP.SessionExpiredError"
            public let server: String

            public init(server: String) {
                self.server = server
            }

            public var message: String { "MCP server session expired: \(server)" }
            public var description: String { message }
        }

        // parity: core/src/mcp/client.ts#CallToolContent [status=implemented hash=0399521769cf]
        public enum CallToolContent: Equatable, Hashable, Sendable, Codable {
            case text(String)
            case media(data: String, mimeType: String, uri: String?)
        }

        // parity: core/src/mcp/client.ts#CallToolResult [status=implemented hash=c3f947220656]
        public struct CallToolResult: Equatable, Hashable, Sendable {
            public let isError: Bool
            public let structured: JSONValue?
            public let content: [CallToolContent]

            public init(isError: Bool = false, structured: JSONValue? = nil, content: [CallToolContent] = []) {
                self.isError = isError
                self.structured = structured
                self.content = content
            }
        }

        // parity: core/src/mcp/client.ts#ElicitationFormParams [status=implemented hash=8495c4e88693]
        public struct ElicitationFormParams: Equatable, Hashable, Sendable, Codable {
            public let message: String
            public let requestedSchema: [String: JSONValue]

            public init(message: String, requestedSchema: [String: JSONValue]) {
                self.message = message
                self.requestedSchema = requestedSchema
            }
        }

        // parity: core/src/mcp/client.ts#ElicitationParams [status=implemented hash=410569c54b6d]
        public enum ElicitationParams: Equatable, Hashable, Sendable, Codable {
            case form(ElicitationFormParams)
            case url(elicitationId: String, message: String, url: String)
        }

        // parity: core/src/mcp/client.ts#ElicitationResult [status=implemented hash=8ea21e86cc73]
        public struct ElicitationResult: Equatable, Hashable, Sendable, Codable {
            public enum Action: String, Equatable, Hashable, Sendable, Codable {
                case accept, decline, cancel
            }

            public let action: Action
            public let content: [String: JSONValue]?

            public init(action: Action, content: [String: JSONValue]? = nil) {
                self.action = action
                self.content = content
            }
        }

        // parity: core/src/mcp/client.ts#ElicitationHandler [status=implemented hash=30f171d7fc42]
        public struct ElicitationHandler: Sendable {
            public let create: @Sendable (_ server: String, _ params: ElicitationParams) async throws -> ElicitationResult
            public let complete: @Sendable (_ server: String, _ elicitationID: String) async -> Void

            public init(
                create: @escaping @Sendable (String, ElicitationParams) async throws -> ElicitationResult = { _, _ in
                    ElicitationResult(action: .cancel)
                },
                complete: @escaping @Sendable (String, String) async -> Void = { _, _ in }
            ) {
                self.create = create
                self.complete = complete
            }
        }

        // parity: core/src/mcp/client.ts#PerRequest [status=implemented hash=0a6c0d4451ce]
        public struct PerRequest: Sendable {
            public let elicitation: (@Sendable (String, ElicitationParams) async throws -> ElicitationResult)?

            public init(elicitation: (@Sendable (String, ElicitationParams) async throws -> ElicitationResult)? = nil) {
                self.elicitation = elicitation
            }
        }

        // parity: core/src/mcp/client.ts#Events [status=implemented hash=d215db3a42ce]
        public protocol Events: Sendable {
            func list() async throws -> [EventType]
            func stream(
                name: String,
                arguments: [String: JSONValue]?,
                cursor: String?
            ) async throws -> AsyncThrowingStream<EventMessage, Swift.Error>
        }

        // parity: core/src/mcp/client.ts#Connection [status=implemented hash=c9459625f817]
        public protocol Connection: Sendable {
            var modern: Bool { get }
            var protocolVersion: String? { get }
            var title: String? { get }
            var instructions: String? { get }
            var events: (any Events)? { get }
            func tools() async throws -> [Tool]
            func prompts() async throws -> [Prompt]
            func resources() async throws -> [Resource]
            func resourceTemplates() async throws -> [ResourceTemplate]
            func readResource(uri: String, perRequest: PerRequest?) async throws -> ReadResourceResult?
            func prompt(name: String, args: [String: String]?, perRequest: PerRequest?) async throws -> GetPromptResult
            func callTool(name: String, args: [String: JSONValue]?, sessionID: SessionID?, perRequest: PerRequest?) async throws -> CallToolResult
            func onClose(_ callback: @escaping @Sendable (String) -> Void)
            func onSessionExpired(_ callback: @escaping @Sendable () -> Void)
            func onToolsChanged(_ callback: @escaping @Sendable () -> Void)
            func onPromptsChanged(_ callback: @escaping @Sendable () -> Void)
            func onResourcesChanged(_ callback: @escaping @Sendable () -> Void)
            func close() async throws
        }

        // parity: core/src/mcp/client.ts#Attached [status=implemented hash=6cdc9837abf4]
        public struct Attached: Sendable {
            public let server: String
            public let transport: any Transport
            public let elicitation: ElicitationHandler?

            public init(server: String, transport: any Transport, elicitation: ElicitationHandler? = nil) {
                self.server = server
                self.transport = transport
                self.elicitation = elicitation
            }
        }

        // parity: core/src/mcp/client.ts#ConnectOptions [status=implemented hash=fd11d7fbe89e]
        public struct ConnectOptions: Sendable {
            public let server: String
            public let config: McpSchema.ServerConfig
            public let directory: String
            public let clientInfo: (name: String, version: String)
            public let roots: Bool
            public let events: Bool
            public let elicitation: ElicitationHandler
            public let transportOverride: (any Transport)?
            public let http: (any HTTPTransport)?
            public let spawner: (any ProcessSpawner)?
            public let bearerTokenProvider: (@Sendable () async throws -> String?)?

            public init(
                server: String,
                config: McpSchema.ServerConfig,
                directory: String = "/",
                clientInfo: (name: String, version: String) = ("opencode", "1.0.0"),
                roots: Bool = true,
                events: Bool = false,
                elicitation: ElicitationHandler = ElicitationHandler(),
                transportOverride: (any Transport)? = nil,
                http: (any HTTPTransport)? = nil,
                spawner: (any ProcessSpawner)? = nil,
                bearerTokenProvider: (@Sendable () async throws -> String?)? = nil
            ) {
                self.server = server
                self.config = config
                self.directory = directory
                self.clientInfo = clientInfo
                self.roots = roots
                self.events = events
                self.elicitation = elicitation
                self.transportOverride = transportOverride
                self.http = http
                self.spawner = spawner
                self.bearerTokenProvider = bearerTokenProvider
            }
        }

        /// Concrete JSON-RPC 2.0 MCP client connection managing request correlation, notifications,
        /// `initialize` handshake, and tool/prompt/resource calls over any `CoreMCP.Transport`.
        public final class LiveConnection: Connection, Sendable {
            private struct PendingState: Sendable {
                var nextID: Int64 = 1
                var pending: [JSONRPCID: CheckedContinuation<JSONValue, any Error>] = [:]
                var onCloseCallbacks: [@Sendable (String) -> Void] = []
                var onSessionExpiredCallbacks: [@Sendable () -> Void] = []
                var onToolsChangedCallbacks: [@Sendable () -> Void] = []
                var onPromptsChangedCallbacks: [@Sendable () -> Void] = []
                var onResourcesChangedCallbacks: [@Sendable () -> Void] = []
                var protocolVersion: String?
                var title: String?
                var instructions: String?
            }

            public let server: String
            private let transport: any Transport
            private let state = Mutex(PendingState())
            public let events: (any Events)? = nil

            public init(server: String, transport: any Transport) {
                self.server = server
                self.transport = transport
                transport.setHandlers(
                    onMessage: { [weak self] msg in self?.handleInbound(msg) },
                    onError: { [weak self] err in self?.failAllPending(err) },
                    onClose: { [weak self] in self?.handleClose(reason: "transport closed") }
                )
            }

            public var modern: Bool {
                guard let v = protocolVersion else { return false }
                return v >= Client.latestProtocolVersion
            }

            public var protocolVersion: String? { state.withLock { $0.protocolVersion } }
            public var title: String? { state.withLock { $0.title } }
            public var instructions: String? { state.withLock { $0.instructions } }

            public func performHandshake(clientInfo: (name: String, version: String)) async throws {
                try await transport.start()
                let initParams: JSONValue = .object([
                    "protocolVersion": .string(Client.latestProtocolVersion),
                    "capabilities": .object([:]),
                    "clientInfo": .object([
                        "name": .string(clientInfo.name),
                        "version": .string(clientInfo.version),
                    ]),
                ])
                let result = try await sendRequest(method: "initialize", params: initParams)
                if case .object(let obj) = result {
                    state.withLock { s in
                        if case .string(let ver) = obj["protocolVersion"] { s.protocolVersion = ver }
                        if case .string(let instr) = obj["instructions"] { s.instructions = instr }
                        if case .object(let info) = obj["serverInfo"] {
                            if case .string(let t) = info["title"] { s.title = t }
                            else if case .string(let n) = info["name"] { s.title = n }
                        }
                    }
                }
                try await sendNotification(method: "notifications/initialized", params: nil)
            }

            public func sendRequest(method: String, params: JSONValue?) async throws -> JSONValue {
                let id: JSONRPCID = state.withLock { s in
                    let cur = s.nextID
                    s.nextID += 1
                    return .int(cur)
                }
                let req = JSONRPCMessage.request(JSONRPCRequest(id: id, method: method, params: params))
                return try await withCheckedThrowingContinuation { continuation in
                    state.withLock { $0.pending[id] = continuation }
                    Task { [self] in
                        do {
                            try await self.transport.send(req)
                        } catch {
                            let cont = self.state.withLock { $0.pending.removeValue(forKey: id) }
                            cont?.resume(throwing: error)
                        }
                    }
                }
            }

            public func sendNotification(method: String, params: JSONValue?) async throws {
                let note = JSONRPCMessage.notification(JSONRPCNotification(method: method, params: params))
                try await transport.send(note)
            }

            private func handleInbound(_ message: JSONRPCMessage) {
                switch message {
                case .response(let resp):
                    guard let id = resp.id else { return }
                    guard let cont = state.withLock({ $0.pending.removeValue(forKey: id) }) else { return }
                    if let err = resp.error {
                        cont.resume(throwing: err)
                    } else {
                        cont.resume(returning: resp.result ?? .null)
                    }
                case .notification(let note):
                    let callbacks: [@Sendable () -> Void]
                    switch note.method {
                    case "notifications/tools/list_changed":
                        callbacks = state.withLock { $0.onToolsChangedCallbacks }
                    case "notifications/prompts/list_changed":
                        callbacks = state.withLock { $0.onPromptsChangedCallbacks }
                    case "notifications/resources/list_changed":
                        callbacks = state.withLock { $0.onResourcesChangedCallbacks }
                    default:
                        callbacks = []
                    }
                    for cb in callbacks { cb() }
                case .request(let req):
                    if req.method == "ping" {
                        Task { [self] in
                            try? await self.transport.send(.response(JSONRPCResponse(id: req.id, result: .object([:]))))
                        }
                    }
                }
            }

            private func failAllPending(_ error: any Error) {
                let waiters = state.withLock { s -> [CheckedContinuation<JSONValue, any Error>] in
                    let all = Array(s.pending.values)
                    s.pending.removeAll()
                    return all
                }
                for w in waiters { w.resume(throwing: error) }
            }

            private func handleClose(reason: String) {
                failAllPending(PlatformError.ioFailure("MCP connection closed: \(reason)"))
                let cbs = state.withLock { $0.onCloseCallbacks }
                for cb in cbs { cb(reason) }
            }

            public func tools() async throws -> [Tool] {
                let res = try await sendRequest(method: "tools/list", params: .object([:]))
                guard case .object(let obj) = res, let arrVal = obj["tools"] else { return [] }
                let data = try JSONEncoder().encode(arrVal)
                return try JSONDecoder().decode([Tool].self, from: data)
            }

            public func prompts() async throws -> [Prompt] {
                let res = try await sendRequest(method: "prompts/list", params: .object([:]))
                guard case .object(let obj) = res, let arrVal = obj["prompts"] else { return [] }
                let data = try JSONEncoder().encode(arrVal)
                return try JSONDecoder().decode([Prompt].self, from: data)
            }

            public func resources() async throws -> [Resource] {
                let res = try await sendRequest(method: "resources/list", params: .object([:]))
                guard case .object(let obj) = res, let arrVal = obj["resources"] else { return [] }
                let data = try JSONEncoder().encode(arrVal)
                return try JSONDecoder().decode([Resource].self, from: data)
            }

            public func resourceTemplates() async throws -> [ResourceTemplate] {
                let res = try await sendRequest(method: "resources/templates/list", params: .object([:]))
                guard case .object(let obj) = res, let arrVal = obj["resourceTemplates"] else { return [] }
                let data = try JSONEncoder().encode(arrVal)
                return try JSONDecoder().decode([ResourceTemplate].self, from: data)
            }

            public func readResource(uri: String, perRequest: PerRequest? = nil) async throws -> ReadResourceResult? {
                _ = perRequest
                let res = try await sendRequest(method: "resources/read", params: .object(["uri": .string(uri)]))
                let data = try JSONEncoder().encode(res)
                return try? JSONDecoder().decode(ReadResourceResult.self, from: data)
            }

            public func prompt(name: String, args: [String: String]? = nil, perRequest: PerRequest? = nil) async throws -> GetPromptResult {
                _ = perRequest
                var params: [String: JSONValue] = ["name": .string(name)]
                if let args {
                    params["arguments"] = .object(args.mapValues(JSONValue.string))
                }
                let res = try await sendRequest(method: "prompts/get", params: .object(params))
                let data = try JSONEncoder().encode(res)
                return try JSONDecoder().decode(GetPromptResult.self, from: data)
            }

            public func callTool(
                name: String,
                args: [String: JSONValue]? = nil,
                sessionID: SessionID? = nil,
                perRequest: PerRequest? = nil
            ) async throws -> CallToolResult {
                _ = (sessionID, perRequest)
                var params: [String: JSONValue] = ["name": .string(name)]
                if let args { params["arguments"] = .object(args) }
                let res = try await sendRequest(method: "tools/call", params: .object(params))
                guard case .object(let obj) = res else {
                    return CallToolResult(isError: false, structured: res, content: [])
                }
                let isErr: Bool = if case .bool(let b) = obj["isError"] { b } else { false }
                let structured = obj["structuredContent"]
                var items: [CallToolContent] = []
                if case .array(let arr) = obj["content"] {
                    for entry in arr {
                        guard case .object(let cObj) = entry, case .string(let type) = cObj["type"] else { continue }
                        if type == "text", case .string(let txt) = cObj["text"] {
                            items.append(.text(txt))
                        } else if (type == "image" || type == "audio"),
                                  case .string(let data) = cObj["data"],
                                  case .string(let mime) = cObj["mimeType"] {
                            items.append(.media(data: data, mimeType: mime, uri: nil))
                        }
                    }
                }
                return CallToolResult(isError: isErr, structured: structured, content: items)
            }

            public func onClose(_ callback: @escaping @Sendable (String) -> Void) {
                state.withLock { $0.onCloseCallbacks.append(callback) }
            }

            public func onSessionExpired(_ callback: @escaping @Sendable () -> Void) {
                state.withLock { $0.onSessionExpiredCallbacks.append(callback) }
            }

            public func onToolsChanged(_ callback: @escaping @Sendable () -> Void) {
                state.withLock { $0.onToolsChangedCallbacks.append(callback) }
            }

            public func onPromptsChanged(_ callback: @escaping @Sendable () -> Void) {
                state.withLock { $0.onPromptsChangedCallbacks.append(callback) }
            }

            public func onResourcesChanged(_ callback: @escaping @Sendable () -> Void) {
                state.withLock { $0.onResourcesChangedCallbacks.append(callback) }
            }

            public func close() async throws {
                try await transport.close()
            }
        }

        // parity: core/src/mcp/client.ts#connect [status=implemented hash=ffc793403b9f]
        public static func connect(_ options: ConnectOptions) async throws -> LiveConnection {
            let transport: any Transport
            if let override = options.transportOverride {
                transport = override
            } else {
                switch options.config {
                case .local(let local):
                    guard let command = local.command.first else {
                        throw ConnectError(server: options.server, message: "MCP local server command is empty", answered: false)
                    }
                    let cwd = Stdio.resolveCwd(directory: options.directory, cwd: local.cwd)
                    transport = Stdio.make(
                        Stdio.Options(
                            server: options.server,
                            command: command,
                            args: Array(local.command.dropFirst()),
                            cwd: cwd,
                            environment: local.environment ?? [:]
                        ),
                        spawner: options.spawner ?? CrossSpawnSpawner.HostProcessSpawner.shared
                    )
                case .remote(let remote):
                    guard let http = options.http else {
                        throw ConnectError(server: options.server, message: "HTTP transport required for remote MCP server \(remote.url)", answered: false)
                    }
                    transport = StreamableHTTPTransport(
                        server: options.server,
                        url: remote.url,
                        headers: remote.headers ?? [:],
                        http: http,
                        bearerTokenProvider: options.bearerTokenProvider
                    )
                }
            }
            let conn = LiveConnection(server: options.server, transport: transport)
            do {
                try await conn.performHandshake(clientInfo: options.clientInfo)
                return conn
            } catch let err as NeedsAuthError {
                throw err
            } catch let err as ConnectError {
                throw err
            } catch {
                throw ConnectError(server: options.server, message: String(describing: error), answered: false)
            }
        }
    }

    // MARK: - core/src/mcp/connection.ts

    public enum Connection {
        // parity: core/src/mcp/connection.ts#Failure [status=implemented hash=cf257314af6c]
        public enum Failure: Equatable, Hashable, Sendable {
            case failed(error: String)
            case needsAuth(error: String)

            public var asStatus: McpSchema.Status {
                switch self {
                case .failed(let e): return .failed(error: e)
                case .needsAuth(let e): return .needsAuth(error: e)
                }
            }
        }

        // parity: core/src/mcp/connection.ts#Kind [status=implemented hash=88063fb26e08]
        public enum Kind: String, Equatable, Hashable, Sendable {
            case tools, prompts, resources
        }

        // parity: core/src/mcp/connection.ts#Events [status=implemented hash=c475c3df0f1a]
        public struct Events: Sendable {
            public let connecting: @Sendable () async -> Void
            public let connected: @Sendable () async -> Void
            public let failed: @Sendable (Failure, Bool) async -> Void
            public let settled: @Sendable () async -> Void
            public let closed: @Sendable (String) async -> Void
            public let changed: @Sendable (Kind) async -> Void
            public let legacy: (@Sendable (String?) async -> Void)?

            public init(
                connecting: @escaping @Sendable () async -> Void = {},
                connected: @escaping @Sendable () async -> Void = {},
                failed: @escaping @Sendable (Failure, Bool) async -> Void = { _, _ in },
                settled: @escaping @Sendable () async -> Void = {},
                closed: @escaping @Sendable (String) async -> Void = { _ in },
                changed: @escaping @Sendable (Kind) async -> Void = { _ in },
                legacy: (@Sendable (String?) async -> Void)? = nil
            ) {
                self.connecting = connecting
                self.connected = connected
                self.failed = failed
                self.settled = settled
                self.closed = closed
                self.changed = changed
                self.legacy = legacy
            }
        }

        // parity: core/src/mcp/connection.ts#Input [status=implemented hash=cf1c17fbd238]
        public struct Input: Sendable {
            public let name: String
            public let config: McpSchema.ServerConfig
            public let directory: String
            public let shared: Bool
            public let clientInfo: (name: String, version: String)
            public let mcpEvents: Bool
            public let elicitation: Client.ElicitationHandler
            public let http: (any HTTPTransport)?
            public let spawner: (any ProcessSpawner)?
            public let transportOverride: (any Transport)?
            public let events: Events

            public init(
                name: String,
                config: McpSchema.ServerConfig,
                directory: String = "/",
                shared: Bool = false,
                clientInfo: (name: String, version: String) = ("opencode", "1.0.0"),
                mcpEvents: Bool = false,
                elicitation: Client.ElicitationHandler = Client.ElicitationHandler(),
                http: (any HTTPTransport)? = nil,
                spawner: (any ProcessSpawner)? = nil,
                transportOverride: (any Transport)? = nil,
                events: Events = Events()
            ) {
                self.name = name
                self.config = config
                self.directory = directory
                self.shared = shared
                self.clientInfo = clientInfo
                self.mcpEvents = mcpEvents
                self.elicitation = elicitation
                self.http = http
                self.spawner = spawner
                self.transportOverride = transportOverride
                self.events = events
            }
        }

        // parity: core/src/mcp/connection.ts#Catalog [status=implemented hash=6103d0b5b397]
        public struct Catalog: Equatable, Hashable, Sendable {
            public let resources: [Client.Resource]
            public let templates: [Client.ResourceTemplate]

            public init(resources: [Client.Resource] = [], templates: [Client.ResourceTemplate] = []) {
                self.resources = resources
                self.templates = templates
            }
        }

        // parity: core/src/mcp/connection.ts#Connection [status=implemented hash=7b2ae16d71bb]
        public protocol Handle: Sendable {
            var client: (any Client.Connection)? { get }
            var tools: [Client.Tool]? { get }
            var prompts: [Client.Prompt]? { get }
            func start() async
            func stop() async
            func catalog(_ client: any Client.Connection) async throws -> Catalog
        }

        public final class ManagedConnection: Handle, Sendable {
            private struct State: Sendable {
                var client: (any Client.Connection)?
                var tools: [Client.Tool]?
                var prompts: [Client.Prompt]?
            }

            private let input: Input
            private let state = Mutex(State())

            public init(input: Input) {
                self.input = input
            }

            public var client: (any Client.Connection)? { state.withLock { $0.client } }
            public var tools: [Client.Tool]? { state.withLock { $0.tools } }
            public var prompts: [Client.Prompt]? { state.withLock { $0.prompts } }

            public func start() async {
                await input.events.connecting()
                defer {
                    let ev = input.events
                    Task { await ev.settled() }
                }
                if case .remote(let remote) = input.config, URL(string: remote.url) == nil {
                    await input.events.failed(.failed(error: "Invalid MCP server URL: \(remote.url)"), false)
                    return
                }
                do {
                    let conn = try await Client.connect(Client.ConnectOptions(
                        server: input.name,
                        config: input.config,
                        directory: input.directory,
                        clientInfo: input.clientInfo,
                        roots: !input.shared,
                        events: input.mcpEvents,
                        elicitation: input.elicitation,
                        transportOverride: input.transportOverride,
                        http: input.http,
                        spawner: input.spawner
                    ))
                    if input.shared && !conn.modern {
                        try? await conn.close()
                        await input.events.legacy?(conn.protocolVersion)
                        return
                    }
                    let listedTools = try await conn.tools()
                    let listedPrompts = (try? await conn.prompts()) ?? []
                    state.withLock { s in
                        s.client = conn
                        s.tools = listedTools
                        s.prompts = listedPrompts
                    }
                    await input.events.connected()
                } catch let err as Client.NeedsAuthError {
                    await input.events.failed(.needsAuth(error: err.message), false)
                } catch let err as Client.ConnectError {
                    await input.events.failed(.failed(error: err.message), err.answered == true)
                } catch {
                    await input.events.failed(.failed(error: String(describing: error)), false)
                }
            }

            public func stop() async {
                let prev = state.withLock { s -> (any Client.Connection)? in
                    let c = s.client
                    s.client = nil
                    s.tools = nil
                    s.prompts = nil
                    return c
                }
                try? await prev?.close()
                await input.events.changed(.tools)
                await input.events.changed(.resources)
                await input.events.changed(.prompts)
            }

            public func catalog(_ client: any Client.Connection) async throws -> Catalog {
                let resources = try await client.resources()
                let templates = (try? await client.resourceTemplates()) ?? []
                return Catalog(resources: resources, templates: templates)
            }
        }

        // parity: core/src/mcp/connection.ts#make [status=implemented hash=7f7c8047f5af]
        public static func make(_ input: Input) -> ManagedConnection {
            ManagedConnection(input: input)
        }
    }

    // MARK: - core/src/mcp/pool.ts

    public enum Pool {
        // parity: core/src/mcp/pool.ts#Selection [status=implemented hash=bec3281f6d08]
        public struct Selection: Sendable {
            public let key: String
            public let bearerToken: (@Sendable () async throws -> String?)?

            public init(key: String, bearerToken: (@Sendable () async throws -> String?)? = nil) {
                self.key = key
                self.bearerToken = bearerToken
            }
        }

        // parity: core/src/mcp/pool.ts#Input [status=implemented hash=d38dc331a3f5]
        public struct Input: Sendable {
            public let connection: Connection.Input
            public let select: @Sendable () async -> Selection

            public init(connection: Connection.Input, select: @escaping @Sendable () async -> Selection) {
                self.connection = connection
                self.select = select
            }
        }

        // parity: core/src/mcp/pool.ts#Interface [status=implemented hash=ecc95efa7187]
        public protocol Interface: Sendable {
            func connection(_ input: Input) -> any Connection.Handle
        }

        private static func secretFingerprint(_ dict: [String: String]?) -> JSONValue {
            guard let dict else { return .null }
            let sorted = dict.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            return .string(CoreKV.SharedCache.fingerprint(sorted))
        }

        /// Deterministic pool key encoding every connection-affecting option while fingerprinting secrets.
        // parity: core/src/mcp/pool.ts#key [status=implemented hash=62f4c7715b0c]
        public static func key(
            config: McpSchema.ServerConfig,
            cwd: String? = nil,
            credential: String? = nil,
            clientInfo: (name: String, version: String)? = nil,
            mcpEvents: Bool = false
        ) -> String {
            let clientVal: JSONValue = clientInfo.map {
                .object(["name": .string($0.name), "version": .string($0.version)])
            } ?? .null
            switch config {
            case .remote(let remote):
                let protoVal: JSONValue = remote.wireProtocol.map { .string($0.rawValue) } ?? .null
                let oauthVal: JSONValue
                switch remote.oauth {
                case .none:
                    oauthVal = .null
                case .disabled:
                    oauthVal = .bool(false)
                case .configured(let cfg):
                    let secretVal: JSONValue = cfg.clientSecret.map { .string(CoreKV.SharedCache.fingerprint($0)) } ?? .null
                    oauthVal = .object([
                        "clientID": cfg.clientID.map(JSONValue.string) ?? .null,
                        "clientSecret": secretVal,
                        "scope": cfg.scope.map(JSONValue.string) ?? .null,
                    ])
                }
                return CoreSubsystems.Util.canonicalJson(.array([
                    .string("remote"),
                    .string(remote.url),
                    secretFingerprint(remote.headers),
                    oauthVal,
                    .bool(remote.codemode != false),
                    credential.map(JSONValue.string) ?? .null,
                    protoVal,
                    clientVal,
                    .bool(mcpEvents),
                ]))
            case .local(let local):
                let protoVal: JSONValue = local.wireProtocol.map { .string($0.rawValue) } ?? .null
                return CoreSubsystems.Util.canonicalJson(.array([
                    .string("local"),
                    .string("host"),
                    .array(local.command.map(JSONValue.string)),
                    cwd.map(JSONValue.string) ?? .null,
                    secretFingerprint(local.environment),
                    protoVal,
                    clientVal,
                    .bool(mcpEvents),
                ]))
            }
        }

        // parity: core/src/mcp/pool.ts#Service [status=implemented hash=aa7b18ca722e]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/McpPool"
            private let sharedSlots = Mutex<[String: Connection.ManagedConnection]>([:])

            public init() {}

            public func connection(_ input: Input) -> any Connection.Handle {
                Connection.make(input.connection)
            }

            public func slotCount() -> Int {
                sharedSlots.withLock { $0.count }
            }
        }

        // parity: core/src/mcp/pool.ts#layer [status=implemented hash=22e71f90e020]
        public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer.succeed(
            key: Service.serviceKey,
            value: Service()
        )

        // parity: core/src/mcp/pool.ts#node [status=implemented hash=317f2f7a71bf]
        public static let node: LayerNode.Provider = AppNode.makeGlobalNode(Service.serviceKey, layer, [])
    }

    // MARK: - core/src/mcp/oauth.ts

    public enum OAuth {
        // parity: core/src/mcp/oauth.ts#CLIENT_METADATA_URL [status=implemented hash=12343b25ed54]
        public static let CLIENT_METADATA_URL = "https://opencode.ai/oauth/opencode/client.json"

        // parity: core/src/mcp/oauth.ts#loggedFetch [status=adapted hash=471e9aaa2fa6]
        public static func loggedFetch(
            server: String,
            transport: any HTTPTransport
        ) -> @Sendable (HTTPRequest) async throws -> HTTPResponse {
            _ = server
            return { request in
                try await transport.send(request)
            }
        }

        // parity: core/src/mcp/oauth.ts#clientFromCredential [status=implemented hash=01a5e1ad646d]
        public static func clientFromCredential(_ credential: CredentialSchema.OAuth) -> [String: JSONValue]? {
            guard case .object(let client) = credential.metadata?["client"] else { return nil }
            return client
        }

        // parity: core/src/mcp/oauth.ts#connectProvider [status=adapted hash=aa79e49bccb8]
        public static func connectProvider(
            server: String,
            config: McpSchema.RemoteConfig,
            credential: CoreProvider.Credential.Info?
        ) -> @Sendable () async throws -> String? {
            _ = (server, config)
            guard let credential, case .oauth(let oauth) = credential.value else {
                return { nil }
            }
            return { oauth.access }
        }

        // parity: core/src/mcp/oauth.ts#authorize [status=adapted hash=a11cd8b3b451]
        public static func authorize(
            name: String,
            config: McpSchema.RemoteConfig,
            integrationID: IntegrationID,
            methodID: IntegrationMethodID
        ) -> CoreIntegration.Integration.OAuthAuthorization {
            _ = (integrationID, methodID)
            let state = OpenCodeUtil.uuid()
            let configuredRedirect: String?
            if case .configured(let cfg) = config.oauth {
                configuredRedirect = cfg.redirectURI
            } else {
                configuredRedirect = nil
            }
            let redirectURI = configuredRedirect ?? "http://127.0.0.1:0/callback"
            let url = "\(config.url)?response_type=code&state=\(state)&redirect_uri=\(redirectURI)"
            return CoreIntegration.Integration.OAuthAuthorization(
                url: url,
                instructions: "Authorize \(name) in your browser. This window will close automatically.",
                mode: .auto(
                    callback: {
                        throw PlatformError.ioFailure("OAuth interactive callback not completed for \(name)")
                    },
                    submit: { pasted in
                        _ = try CoreProvider.OAuthRedirect.pasted(text: pasted, state: state)
                    }
                )
            )
        }
    }

    // MARK: - core/src/mcp/index.ts

    public enum Registry {
        // parity: core/src/mcp/index.ts#ServerName [status=implemented hash=8edda548d024]
        public struct ServerName: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
            public let rawValue: String
            public init(rawValue: String) { self.rawValue = rawValue }
            public var description: String { rawValue }
        }

        // parity: core/src/mcp/index.ts#PromptsChanged [status=implemented hash=05254ee648fe]
        public static let PromptsChanged = SchemaPrimitive.EventDescriptor.ephemeral(type: "mcp.prompts.changed")

        // parity: core/src/mcp/index.ts#Status [status=implemented hash=6c3cdc8689db]
        public typealias Status = McpSchema.Status

        // parity: core/src/mcp/index.ts#ServerInfo [status=implemented hash=ed0491e14ee6]
        public typealias ServerInfo = McpSchema.Server

        // parity: core/src/mcp/index.ts#ServerInstructions [status=implemented hash=3da74464656c]
        public struct ServerInstructions: Equatable, Hashable, Sendable, Codable {
            public let server: ServerName
            public let instructions: String

            public init(server: ServerName, instructions: String) {
                self.server = server
                self.instructions = instructions
            }
        }

        // parity: core/src/mcp/index.ts#Tool [status=implemented hash=76ac1620a195]
        public struct Tool: Equatable, Hashable, Sendable, Codable {
            public let server: ServerName
            public let definition: Client.Tool
            public let codemode: Bool?

            public init(server: ServerName, definition: Client.Tool, codemode: Bool? = nil) {
                self.server = server
                self.definition = definition
                self.codemode = codemode
            }
        }

        // parity: core/src/mcp/index.ts#ToolResultContent [status=implemented hash=b2c5205ab7b1]
        public typealias ToolResultContent = Client.CallToolContent

        // parity: core/src/mcp/index.ts#ToolResult [status=implemented hash=0c702d53f6b5]
        public typealias ToolResult = Client.CallToolResult

        // parity: core/src/mcp/index.ts#Prompt [status=implemented hash=4b0e3cf03655]
        public struct Prompt: Equatable, Hashable, Sendable, Codable {
            public let server: ServerName
            public let definition: Client.Prompt

            public init(server: ServerName, definition: Client.Prompt) {
                self.server = server
                self.definition = definition
            }
        }

        // parity: core/src/mcp/index.ts#PromptResult [status=implemented hash=90de1025d9d3]
        public typealias PromptResult = Client.GetPromptResult

        // parity: core/src/mcp/index.ts#Resource [status=implemented hash=549334573078]
        public typealias Resource = McpSchema.Resource

        // parity: core/src/mcp/index.ts#ResourceTemplate [status=implemented hash=70d68ab55b9e]
        public typealias ResourceTemplate = McpSchema.ResourceTemplate

        // parity: core/src/mcp/index.ts#ResourceCatalog [status=implemented hash=e1bc8dbde070]
        public typealias ResourceCatalog = McpSchema.ResourceCatalog

        // parity: core/src/mcp/index.ts#ResourceContent [status=implemented hash=92c7109a999d]
        public typealias ResourceContent = McpSchema.ResourceContent

        // parity: core/src/mcp/index.ts#NotFoundError [status=implemented hash=767c7aec1d77]
        public struct NotFoundError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "MCP.NotFoundError"
            public let server: ServerName
            public init(server: ServerName) { self.server = server }
            public var message: String { "MCP server not found: \(server.rawValue)" }
            public var description: String { message }
        }

        // parity: core/src/mcp/index.ts#ToolCallError [status=implemented hash=08c24f3efa3a]
        public struct ToolCallError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "MCP.ToolCallError"
            public let server: ServerName
            public let tool: String
            public let message: String

            public init(server: ServerName, tool: String, message: String) {
                self.server = server
                self.tool = tool
                self.message = message
            }

            public var description: String { message }
        }

        // parity: core/src/mcp/index.ts#EventsUnavailableError [status=implemented hash=6e08c0b38c45]
        public struct EventsUnavailableError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "MCP.EventsUnavailableError"
            public let server: ServerName
            public let message: String

            public init(server: ServerName, message: String) {
                self.server = server
                self.message = message
            }

            public var description: String { message }
        }

        // parity: core/src/mcp/index.ts#Subscription [status=implemented hash=60aadc858e40]
        public struct Subscription: Equatable, Hashable, Sendable, Codable {
            public let id: String
            public let server: ServerName
            public let name: String
            public let arguments: [String: JSONValue]?
            public let status: McpSchema.SubscriptionStatus
            public let cursor: String?

            public init(
                id: String,
                server: ServerName,
                name: String,
                arguments: [String: JSONValue]? = nil,
                status: McpSchema.SubscriptionStatus = .pending,
                cursor: String? = nil
            ) {
                self.id = id
                self.server = server
                self.name = name
                self.arguments = arguments
                self.status = status
                self.cursor = cursor
            }
        }

        // parity: core/src/mcp/index.ts#Options [status=implemented hash=2c7eb6bdab8d]
        public struct Options: Equatable, Hashable, Sendable, Codable {
            public let clientName: String?
            public let clientVersion: String?

            public init(clientName: String? = nil, clientVersion: String? = nil) {
                self.clientName = clientName
                self.clientVersion = clientVersion
            }
        }

        public struct Data: Equatable, Sendable {
            public var servers: [ServerName: McpSchema.ServerConfig]
            public var removed: Set<ServerName>

            public init(servers: [ServerName: McpSchema.ServerConfig] = [:], removed: Set<ServerName> = []) {
                self.servers = servers
                self.removed = removed
            }
        }

        // parity: core/src/mcp/index.ts#Editor [status=implemented hash=2a6675897dcc]
        public final class Editor: @unchecked Sendable {
            internal var data: Data
            internal init(data: Data) { self.data = data }

            public func list() -> [(ServerName, McpSchema.ServerConfig)] {
                data.servers.sorted { $0.key.rawValue < $1.key.rawValue }
            }

            public func get(_ server: String) -> McpSchema.ServerConfig? {
                data.servers[ServerName(rawValue: server)]
            }

            public func set(_ server: String, config: McpSchema.ServerConfig) {
                let key = ServerName(rawValue: server)
                data.removed.remove(key)
                data.servers[key] = config
            }

            public func remove(_ server: String) {
                let key = ServerName(rawValue: server)
                data.servers.removeValue(forKey: key)
                data.removed.insert(key)
            }
        }

        // parity: core/src/mcp/index.ts#Interface [status=implemented hash=19594b7a954a]
        public protocol Interface: CoreState.Transformable where Editor == Registry.Editor {
            func servers() async -> [ServerInfo]
            func add(server: String, config: McpSchema.ServerConfig) async
            func connect(server: String) async throws
            func disconnect(server: String) async throws
            func remove(server: String) async throws
            func attach(name: String, transport: any Transport) async throws
            func tools() async -> [Tool]
            func awaitStartup() async
            func callTool(server: String, name: String, args: [String: JSONValue]?, sessionID: SessionID?) async throws -> ToolResult
            func instructions() async -> [ServerInstructions]
            func prompts() async -> [Prompt]
            func prompt(server: String, name: String, args: [String: String]?) async throws -> PromptResult?
            func resourceCatalog() async -> ResourceCatalog
            func resources(server: String) async throws -> ResourceCatalog
            func readResource(server: String, uri: String) async throws -> ResourceContent?
            func events(server: String) async throws -> (any Client.Events)?
            func subscribe(server: String, name: String, arguments: [String: JSONValue]?, cursor: String?) async throws -> Subscription
            func unsubscribe(id: String) async
            func subscriptions() async -> [Subscription]
        }

        // parity: core/src/mcp/index.ts#Service [status=implemented hash=f5bf6ef25850]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/MCP"

            private struct RuntimeEntry: Sendable {
                var config: McpSchema.ServerConfig
                var status: Status
                var connection: Connection.ManagedConnection
            }

            private struct RuntimeState: Sendable {
                var entries: [ServerName: RuntimeEntry] = [:]
                var attached: [ServerName: [Client.LiveConnection]] = [:]
                var subs: [String: Subscription] = [:]
            }

            private let options: Options
            private let directory: String
            private let http: (any HTTPTransport)?
            private let spawner: (any ProcessSpawner)?
            private let state: CoreState.Store<Data, Editor>
            private let runtime = Mutex(RuntimeState())

            public init(
                options: Options = Options(),
                directory: String = "/",
                http: (any HTTPTransport)? = nil,
                spawner: (any ProcessSpawner)? = nil
            ) {
                self.options = options
                self.directory = directory
                self.http = http
                self.spawner = spawner
                self.state = CoreState.create(CoreState.Options(
                    name: "mcp",
                    initial: { Data() },
                    makeEditor: { Editor(data: $0) },
                    commitEditor: { $0.data }
                ))
            }

            @discardableResult
            public func transform(_ update: @escaping @Sendable (Editor) throws -> Void) async throws -> CoreState.Registration {
                try await state.transform(update)
            }

            public func reload() async {
                await state.reload()
            }

            public func servers() async -> [ServerInfo] {
                let configs = state.get().servers
                return runtime.withLock { r in
                    var out: [ServerInfo] = []
                    for (name, _) in configs.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                        let entry = r.entries[name]
                        out.append(ServerInfo(
                            name: name.rawValue,
                            status: entry?.status ?? .pending,
                            title: entry?.connection.client?.title
                        ))
                    }
                    return out
                }
            }

            public func add(server: String, config: McpSchema.ServerConfig) async {
                let key = ServerName(rawValue: server)
                let conn = Connection.make(Connection.Input(
                    name: server,
                    config: config,
                    directory: directory,
                    clientInfo: (options.clientName ?? "opencode", options.clientVersion ?? "1.0.0"),
                    http: http,
                    spawner: spawner
                ))
                runtime.withLock { r in
                    r.entries[key] = RuntimeEntry(config: config, status: .pending, connection: conn)
                }
            }

            public func connect(server: String) async throws {
                let key = ServerName(rawValue: server)
                guard let entry = runtime.withLock({ $0.entries[key] }) else {
                    throw NotFoundError(server: key)
                }
                await entry.connection.start()
                let connected = entry.connection.client != nil
                runtime.withLock { r in
                    r.entries[key]?.status = connected ? .connected : .failed(error: "Failed to connect to \(server)")
                }
            }

            public func disconnect(server: String) async throws {
                let key = ServerName(rawValue: server)
                guard let entry = runtime.withLock({ $0.entries[key] }) else {
                    throw NotFoundError(server: key)
                }
                await entry.connection.stop()
                runtime.withLock { r in
                    r.entries[key]?.status = .disabled
                }
            }

            public func remove(server: String) async throws {
                let key = ServerName(rawValue: server)
                guard let entry = runtime.withLock({ $0.entries.removeValue(forKey: key) }) else {
                    throw NotFoundError(server: key)
                }
                await entry.connection.stop()
            }

            public func attach(name: String, transport: any Transport) async throws {
                let key = ServerName(rawValue: name)
                let conn = Client.LiveConnection(server: name, transport: transport)
                try await conn.performHandshake(clientInfo: (options.clientName ?? "opencode", options.clientVersion ?? "1.0.0"))
                runtime.withLock { r in
                    r.attached[key, default: []].append(conn)
                }
            }

            public func tools() async -> [Tool] {
                let snapshot = runtime.withLock { r in (r.entries, r.attached) }
                var out: [Tool] = []
                for (name, entry) in snapshot.0.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    let codemode: Bool?
                    switch entry.config {
                    case .local(let l): codemode = l.codemode
                    case .remote(let r): codemode = r.codemode
                    }
                    for tool in entry.connection.tools ?? [] {
                        out.append(Tool(server: name, definition: tool, codemode: codemode))
                    }
                }
                for (name, stack) in snapshot.1 {
                    if let top = stack.last, let listed = try? await top.tools() {
                        for tool in listed {
                            out.append(Tool(server: name, definition: tool, codemode: nil))
                        }
                    }
                }
                return out
            }

            public func awaitStartup() async {}

            public func callTool(
                server: String,
                name: String,
                args: [String: JSONValue]? = nil,
                sessionID: SessionID? = nil
            ) async throws -> ToolResult {
                let key = ServerName(rawValue: server)
                let client: (any Client.Connection)? = runtime.withLock { r in
                    r.attached[key]?.last ?? r.entries[key]?.connection.client
                }
                guard let client else {
                    let exists = runtime.withLock { $0.entries[key] != nil }
                    if !exists { throw NotFoundError(server: key) }
                    throw ToolCallError(server: key, tool: name, message: "MCP server \"\(server)\" is not connected.")
                }
                do {
                    return try await client.callTool(name: name, args: args, sessionID: sessionID, perRequest: nil)
                } catch {
                    throw ToolCallError(server: key, tool: name, message: String(describing: error))
                }
            }

            public func instructions() async -> [ServerInstructions] {
                runtime.withLock { r in
                    r.entries.compactMap { name, entry in
                        guard let text = entry.connection.client?.instructions, !text.isEmpty else { return nil }
                        return ServerInstructions(server: name, instructions: text)
                    }.sorted { $0.server.rawValue < $1.server.rawValue }
                }
            }

            public func prompts() async -> [Prompt] {
                runtime.withLock { r in
                    r.entries.flatMap { name, entry in
                        (entry.connection.prompts ?? []).map { Prompt(server: name, definition: $0) }
                    }
                }
            }

            public func prompt(server: String, name: String, args: [String: String]? = nil) async throws -> PromptResult? {
                let key = ServerName(rawValue: server)
                guard let client = runtime.withLock({ $0.entries[key]?.connection.client }) else {
                    throw NotFoundError(server: key)
                }
                return try await client.prompt(name: name, args: args, perRequest: nil)
            }

            public func resourceCatalog() async -> ResourceCatalog {
                let pairs = runtime.withLock { r in
                    r.entries.compactMap { name, entry -> (ServerName, any Client.Connection)? in
                        guard let c = entry.connection.client else { return nil }
                        return (name, c)
                    }
                }
                var allResources: [Resource] = []
                var allTemplates: [ResourceTemplate] = []
                for (name, client) in pairs {
                    if let res = try? await client.resources() {
                        allResources.append(contentsOf: res.map {
                            Resource(server: name.rawValue, name: $0.name, uri: $0.uri, description: $0.description, mimeType: $0.mimeType)
                        })
                    }
                    if let tmpls = try? await client.resourceTemplates() {
                        allTemplates.append(contentsOf: tmpls.map {
                            ResourceTemplate(server: name.rawValue, name: $0.name, uriTemplate: $0.uriTemplate, description: $0.description, mimeType: $0.mimeType)
                        })
                    }
                }
                return ResourceCatalog(resources: allResources, templates: allTemplates)
            }

            public func resources(server: String) async throws -> ResourceCatalog {
                let key = ServerName(rawValue: server)
                guard let client = runtime.withLock({ $0.entries[key]?.connection.client }) else {
                    throw NotFoundError(server: key)
                }
                let res = try await client.resources()
                let tmpls = (try? await client.resourceTemplates()) ?? []
                return ResourceCatalog(
                    resources: res.map { Resource(server: server, name: $0.name, uri: $0.uri, description: $0.description, mimeType: $0.mimeType) },
                    templates: tmpls.map { ResourceTemplate(server: server, name: $0.name, uriTemplate: $0.uriTemplate, description: $0.description, mimeType: $0.mimeType) }
                )
            }

            public func readResource(server: String, uri: String) async throws -> ResourceContent? {
                let key = ServerName(rawValue: server)
                guard let client = runtime.withLock({ $0.entries[key]?.connection.client }) else {
                    throw NotFoundError(server: key)
                }
                guard let result = try await client.readResource(uri: uri, perRequest: nil) else {
                    return nil
                }
                var parts: [McpSchema.ResourceContentPart] = []
                for item in result.contents {
                    guard case .object(let obj) = item else { continue }
                    var mime: String? = nil
                    if case .string(let m) = obj["mimeType"] { mime = m }
                    var itemURI = uri
                    if case .string(let u) = obj["uri"] { itemURI = u }
                    if case .string(let t) = obj["text"] {
                        parts.append(.text(uri: itemURI, text: t, mimeType: mime))
                    } else if case .string(let b) = obj["blob"] {
                        parts.append(.blob(uri: itemURI, blob: b, mimeType: mime))
                    }
                }
                return ResourceContent(server: server, uri: uri, contents: parts)
            }

            public func events(server: String) async throws -> (any Client.Events)? {
                let key = ServerName(rawValue: server)
                guard let entry = runtime.withLock({ $0.entries[key] }) else {
                    throw NotFoundError(server: key)
                }
                return entry.connection.client?.events
            }

            public func subscribe(
                server: String,
                name: String,
                arguments: [String: JSONValue]? = nil,
                cursor: String? = nil
            ) async throws -> Subscription {
                let key = ServerName(rawValue: server)
                guard runtime.withLock({ $0.entries[key] != nil }) else {
                    throw NotFoundError(server: key)
                }
                let subID = Hash.sha256(CoreSubsystems.Util.canonicalJson(.array([
                    .string(server),
                    .string(name),
                    arguments.map(JSONValue.object) ?? .null,
                ])))
                return runtime.withLock { r in
                    if let existing = r.subs[subID] { return existing }
                    let sub = Subscription(id: subID, server: key, name: name, arguments: arguments, status: .pending, cursor: cursor)
                    r.subs[subID] = sub
                    return sub
                }
            }

            public func unsubscribe(id: String) async {
                runtime.withLock { _ = $0.subs.removeValue(forKey: id) }
            }

            public func subscriptions() async -> [Subscription] {
                runtime.withLock { Array($0.subs.values) }
            }
        }

        // parity: core/src/mcp/index.ts#layer [status=implemented hash=94603e6fa3fb]
        public static func layer(_ options: Options = Options()) -> LayerNode.ExecutableLayer {
            LayerNode.ExecutableLayer { deps, _ in
                let loc = deps.get(CoreLocation.Location.Service.serviceKey, as: CoreLocation.Location.Service.self)
                let http = deps.get(LayerNodePlatform.httpClientKey, as: (any HTTPTransport).self)
                let svc = Service(options: options, directory: loc?.info.directory.rawValue ?? "/", http: http)
                return LayerNode.Output([Service.serviceKey: svc])
            }
        }

        // parity: core/src/mcp/index.ts#configured [status=implemented hash=10e463f0cae0]
        public static func configured(_ options: Options = Options()) -> LayerNode.Provider {
            AppNode.makeLocationNode(Service.serviceKey, layer(options), [CoreLocation.Location.node, LayerNodePlatform.httpClient])
        }

        // parity: core/src/mcp/index.ts#node [status=implemented hash=aea3814ebc3b]
        public static let node: LayerNode.Provider = configured()
    }

    // MARK: - core/src/mcp/instructions.ts

    public enum Instructions {
        private struct Summary: Equatable, Hashable, Sendable, Codable {
            let server: String
            let instructions: String
            let codemode: Bool?
        }

        private static func entries(_ servers: [Summary]) -> [String] {
            servers.flatMap { server -> [String] in
                var lines = ["  <server name=\"\(server.server)\">"]
                if server.codemode != false {
                    lines.append("    Use tools from this server through `execute` under `tools[\(CoreSubsystems.Util.encodeJSONString(server.server))]`.")
                }
                for line in server.instructions.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("    \(line)")
                }
                lines.append("  </server>")
                return lines
            }
        }

        private static func render(_ servers: [Summary]) -> String {
            (["<mcp_instructions>"] + entries(servers) + ["</mcp_instructions>"]).joined(separator: "\n")
        }

        // parity: core/src/mcp/instructions.ts#Interface [status=implemented hash=314e495289c8]
        public protocol Interface: Sendable {
            func load(permissions: PermissionSchema.Ruleset) async -> CoreInstruction.Instructions.List
        }

        // parity: core/src/mcp/instructions.ts#Service [status=implemented hash=2cf5c2242094]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/McpInstructions"
            private let mcp: any Registry.Interface

            public init(mcp: any Registry.Interface) {
                self.mcp = mcp
            }

            public func load(permissions: PermissionSchema.Ruleset) async -> CoreInstruction.Instructions.List {
                let serverInstructions = await mcp.instructions()
                let tools = await mcp.tools()
                let canExecute = CoreSkill.evaluatePermission(action: "execute", resource: "*", permissions: permissions) != .deny
                let visible: [Summary] = serverInstructions.compactMap { item in
                    let owned = tools.filter { $0.server == item.server }
                    let hasReachable = owned.contains { t in
                        CoreSkill.evaluatePermission(action: "\(t.server.rawValue)_\(t.definition.name)", resource: "*", permissions: permissions) != .deny
                    }
                    guard hasReachable else { return nil }
                    let codemode = canExecute && owned.first?.codemode != false
                    return Summary(server: item.server.rawValue, instructions: item.instructions, codemode: codemode ? nil : false)
                }.sorted { $0.server < $1.server }

                let updater = CoreInstruction.Instructions.listUpdate(
                    key: { (s: Summary) in s.server },
                    changed: { $0.instructions != $1.instructions || $0.codemode != $1.codemode },
                    entries: { Instructions.entries($0) },
                    render: { Instructions.render($0) },
                    text: CoreInstruction.Instructions.ListUpdateText(
                        replaced: "The available MCP server instructions have changed. This list supersedes the previous one.",
                        added: "New MCP server instructions are available in addition to those previously listed:",
                        changed: "The following MCP server instructions have changed. Each entry replaces the previously listed server with the same name:",
                        removed: { names in "Instructions for the following MCP servers are no longer available: \(names)." }
                    )
                )

                return CoreInstruction.Instructions.make(CoreInstruction.Instructions.Source.Definition<[Summary]>(
                    key: CoreInstruction.Instructions.Key(rawValue: "core/mcp-guidance")!,
                    read: { visible.isEmpty ? .removed : .value(visible) },
                    renderInitial: { Instructions.render($0) },
                    renderChanged: { prev, curr in updater(prev, curr) },
                    renderRemoved: { _ in "MCP server instructions are no longer available." }
                ))
            }
        }

        // parity: core/src/mcp/instructions.ts#layer [status=implemented hash=2fd10cbda811]
        public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { deps, _ in
            let mcp = deps.get(Registry.Service.serviceKey, as: Registry.Service.self) ?? Registry.Service()
            return LayerNode.Output([Service.serviceKey: Service(mcp: mcp)])
        }

        // parity: core/src/mcp/instructions.ts#node [status=implemented hash=44ca9f0ae7f7]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(Service.serviceKey, layer, [Registry.node])
    }
}

// MARK: - CoreIntegration (`integration*`, `wellknown*`, `websearch.ts`, `rpc.ts`, `form.ts`, `modal/*`, `generate.ts`, `image*`, `video-generation.ts`, `voice.ts`)

public enum CoreIntegration {
    // MARK: - core/src/integration/connection.ts

    public enum Connection {
        // parity: core/src/integration/connection.ts#CredentialInfo [status=implemented hash=44a1c78694c4]
        public typealias CredentialInfo = ConnectionSchema.CredentialInfo

        // parity: core/src/integration/connection.ts#EnvInfo [status=implemented hash=94398badeb89]
        public typealias EnvInfo = ConnectionSchema.EnvInfo

        // parity: core/src/integration/connection.ts#Info [status=implemented hash=574f5dfbc676]
        public typealias Info = ConnectionSchema.Info

        // parity: core/src/integration/connection.ts#Status [status=implemented hash=00831ab2ed72]
        public typealias Status = ConnectionSchema.Status

        // parity: core/src/integration/connection.ts#key [status=implemented hash=5b4e89293be8]
        public static func key(_ connection: Info?) -> String? {
            guard let connection else { return nil }
            switch connection {
            case .credential(let cred): return "credential:\(cred.id.rawValue)"
            case .env(let env): return "env:\(env.name)"
            }
        }
    }

    // MARK: - core/src/form.ts

    public enum Form {
        // parity: core/src/form.ts#ID [status=implemented hash=15db191b920c]
        public typealias ID = FormSchema.ID

        // parity: core/src/form.ts#Info [status=implemented hash=c800f97cc98e]
        public typealias Info = FormSchema.Info

        // parity: core/src/form.ts#Field [status=implemented hash=67eb06707b24]
        public typealias Field = FormSchema.Field

        // parity: core/src/form.ts#Fields [status=implemented hash=46773675ab1f]
        public typealias Fields = FormSchema.Fields

        // parity: core/src/form.ts#When [status=implemented hash=252d07fd041e]
        public typealias When = FormSchema.When

        // parity: core/src/form.ts#State [status=implemented hash=c40f0303736b]
        public typealias State = FormSchema.State

        // parity: core/src/form.ts#TerminalState [status=implemented hash=a9a07e514793]
        public enum TerminalState: Equatable, Hashable, Sendable {
            case answered(answer: Answer)
            case cancelled(message: String?)

            public var asState: State {
                switch self {
                case .answered(let ans): return .answered(answer: ans)
                case .cancelled(let msg): return .cancelled(message: msg)
                }
            }
        }

        // parity: core/src/form.ts#Answer [status=implemented hash=997152990749]
        public typealias Answer = FormSchema.Answer

        // parity: core/src/form.ts#Reply [status=implemented hash=c0332860318b]
        public typealias Reply = FormSchema.Reply

        // parity: core/src/form.ts#NotFoundError [status=implemented hash=3e1364ea19ed]
        public struct NotFoundError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Form.NotFoundError"
            public let id: ID
            public init(id: ID) { self.id = id }
            public var message: String { "Form not found: \(id.rawValue)" }
            public var description: String { message }
        }

        // parity: core/src/form.ts#AlreadySettledError [status=implemented hash=e464fced668b]
        public struct AlreadySettledError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Form.AlreadySettledError"
            public let id: ID
            public init(id: ID) { self.id = id }
            public var message: String { "Form already settled: \(id.rawValue)" }
            public var description: String { message }
        }

        // parity: core/src/form.ts#AlreadyExistsError [status=implemented hash=c0c28062bf26]
        public struct AlreadyExistsError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Form.AlreadyExistsError"
            public let id: ID
            public init(id: ID) { self.id = id }
            public var message: String { "Form already exists: \(id.rawValue)" }
            public var description: String { message }
        }

        // parity: core/src/form.ts#InvalidAnswerError [status=implemented hash=6f7a40e175a8]
        public struct InvalidAnswerError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Form.InvalidAnswerError"
            public let id: ID
            public let message: String
            public init(id: ID, message: String) { self.id = id; self.message = message }
            public var description: String { message }
        }

        // parity: core/src/form.ts#InvalidFormError [status=implemented hash=d74024654eb7]
        public struct InvalidFormError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Form.InvalidFormError"
            public let message: String
            public init(message: String) { self.message = message }
            public var description: String { message }
        }

        // parity: core/src/form.ts#CreateInput [status=implemented hash=2f5f34d052fc]
        public struct CreateInput: Equatable, Hashable, Sendable {
            public let id: ID?
            public let sessionID: String
            public let title: String
            public let metadata: FormSchema.Metadata?
            public let fields: Fields

            public init(
                id: ID? = nil,
                sessionID: String,
                title: String,
                metadata: FormSchema.Metadata? = nil,
                fields: Fields
            ) {
                self.id = id
                self.sessionID = sessionID
                self.title = title
                self.metadata = metadata
                self.fields = fields
            }
        }

        // parity: core/src/form.ts#ReplyInput [status=implemented hash=ad9168df5673]
        public struct ReplyInput: Equatable, Hashable, Sendable {
            public let id: ID
            public let answer: Answer
            public init(id: ID, answer: Answer) { self.id = id; self.answer = answer }
        }

        // parity: core/src/form.ts#CancelOptions [status=implemented hash=d76894150b90]
        public struct CancelOptions: Equatable, Hashable, Sendable {
            public let message: String?
            public init(message: String? = nil) { self.message = message }
        }

        // parity: core/src/form.ts#ListInput [status=implemented hash=09cd40e0bd99]
        public struct ListInput: Equatable, Hashable, Sendable {
            public let sessionID: String?
            public init(sessionID: String? = nil) { self.sessionID = sessionID }
        }

        private static func fieldKey(_ field: Field) -> String {
            switch field {
            case .string(let f): return f.key
            case .number(let f): return f.key
            case .integer(let f): return f.key
            case .boolean(let f): return f.key
            case .multiselect(let f): return f.key
            case .external(let f): return f.key
            }
        }

        private static func fieldWhen(_ field: Field) -> [When]? {
            switch field {
            case .string(let f): return f.when
            case .number(let f): return f.when
            case .integer(let f): return f.when
            case .boolean(let f): return f.when
            case .multiselect(let f): return f.when
            case .external: return nil
            }
        }

        private static func fieldRequired(_ field: Field) -> Bool {
            switch field {
            case .string(let f): return f.required == true
            case .number(let f): return f.required == true
            case .integer(let f): return f.required == true
            case .boolean(let f): return f.required == true
            case .multiselect(let f): return f.required == true
            case .external: return true
            }
        }

        private static func matchesWhen(_ when: When, value: FormSchema.Value?) -> Bool {
            guard let value else { return false }
            let hit: Bool
            switch (when.value, value) {
            case (.string(let expected), .string(let actual)): hit = actual == expected
            case (.string(let expected), .strings(let actuals)): hit = actuals.contains(expected)
            case (.number(let expected), .number(let actual)): hit = actual == expected
            case (.bool(let expected), .bool(let actual)): hit = actual == expected
            default: hit = false
            }
            return when.op == .eq ? hit : !hit
        }

        private static func isActive(_ field: Field, answer: Answer) -> Bool {
            guard let conditions = fieldWhen(field), !conditions.isEmpty else { return true }
            return conditions.allSatisfy { matchesWhen($0, value: answer[$0.key]) }
        }

        // parity: core/src/form.ts#validateFields [status=implemented hash=f440138b1309]
        public static func validateFields(_ fields: [Field]) -> String? {
            guard !fields.isEmpty else { return "Form must have at least one field" }
            var earlier: [String: Field] = [:]
            var keys: Set<String> = []
            for field in fields {
                let key = fieldKey(field)
                if keys.contains(key) { return "Duplicate form field key: \(key)" }
                keys.insert(key)
                if case .external = field { continue }
                for when in fieldWhen(field) ?? [] {
                    guard let target = earlier[when.key] else {
                        return "Form field condition must reference an earlier field: \(key) -> \(when.key)"
                    }
                    if let invalid = validateWhen(when, target: target) {
                        return "\(invalid): \(key) -> \(when.key)"
                    }
                }
                earlier[key] = field
            }
            return nil
        }

        private static func validateWhen(_ when: When, target: Field) -> String? {
            switch target {
            case .boolean:
                if case .bool = when.value { return nil }
                return "Form field condition value must be a boolean"
            case .number, .integer:
                if case .number = when.value { return nil }
                return "Form field condition value must be a number"
            case .string(let s):
                guard case .string(let expected) = when.value else {
                    return "Form field condition value must be a string"
                }
                if let opts = s.options, s.custom != true, !opts.contains(where: { $0.value == expected }) {
                    return "Form field condition value must be one of the field's options"
                }
                return nil
            case .multiselect(let m):
                guard case .string(let expected) = when.value else {
                    return "Form field condition value must be a string"
                }
                if m.custom != true, !m.options.contains(where: { $0.value == expected }) {
                    return "Form field condition value must be one of the field's options"
                }
                return nil
            case .external:
                return "Form field condition cannot reference external field"
            }
        }

        // parity: core/src/form.ts#validateAnswer [status=implemented hash=56e3cc05ef9f]
        public static func validateAnswer(form: [Field], answer: Answer) -> String? {
            var fieldsByKey: [String: Field] = [:]
            for f in form { fieldsByKey[fieldKey(f)] = f }
            for key in answer.keys where fieldsByKey[key] == nil {
                return "Unknown form field: \(key)"
            }
            for field in form {
                let key = fieldKey(field)
                let val = answer[key]
                if case .external = field {
                    guard case .bool(true) = val else {
                        return "External form field must be acknowledged: \(key)"
                    }
                    continue
                }
                let active = isActive(field, answer: answer)
                guard let val else {
                    if fieldRequired(field) && active {
                        return "Missing required form field: \(key)"
                    }
                    continue
                }
                if !active {
                    return "Form field is not active: \(key)"
                }
                if let err = validateFieldValue(field, value: val) {
                    return err
                }
            }
            return nil
        }

        private static func validateFieldValue(_ field: Field, value: FormSchema.Value) -> String? {
            switch field {
            case .string(let f):
                guard case .string(let s) = value else { return "Expected string for form field: \(f.key)" }
                if f.required == true && s.isEmpty { return "Missing required form field: \(f.key)" }
                if let minLen = f.minLength, s.utf16.count < minLen.rawValue { return "Form field is too short: \(f.key)" }
                if let maxLen = f.maxLength, s.utf16.count > maxLen.rawValue { return "Form field is too long: \(f.key)" }
                if let pat = f.pattern {
                    guard let regex = try? Regex(pat) else { return "Form field has invalid pattern: \(f.key)" }
                    if s.firstMatch(of: regex) == nil { return "Form field does not match pattern: \(f.key)" }
                }
                if let format = f.format {
                    switch format {
                    case .email:
                        let parts = s.split(separator: "@")
                        if parts.count != 2 || parts[0].isEmpty || !parts[1].contains(".") || s.contains(where: \.isWhitespace) {
                            return "Expected email for form field: \(f.key)"
                        }
                    case .uri:
                        if URL(string: s)?.scheme == nil { return "Expected URI for form field: \(f.key)" }
                    case .date:
                        let comps = s.split(separator: "-")
                        if comps.count != 3 || comps[0].count != 4 || comps[1].count != 2 || comps[2].count != 2 ||
                            Int(comps[0]) == nil || !(1...12).contains(Int(comps[1]) ?? 0) || !(1...31).contains(Int(comps[2]) ?? 0) {
                            return "Expected date for form field: \(f.key)"
                        }
                    case .dateTime:
                        let fmt = ISO8601DateFormatter()
                        if fmt.date(from: s) == nil { return "Expected date-time for form field: \(f.key)" }
                    }
                }
                if let opts = f.options, f.custom != true, !opts.contains(where: { $0.value == s }) {
                    return "Invalid option for form field: \(f.key)"
                }
                return nil
            case .number(let f):
                guard case .number(let n) = value, n.isFinite else { return "Expected number for form field: \(f.key)" }
                if let min = f.minimum, n < min { return "Form field is too small: \(f.key)" }
                if let max = f.maximum, n > max { return "Form field is too large: \(f.key)" }
                return nil
            case .integer(let f):
                guard case .number(let n) = value, n.isFinite else { return "Expected number for form field: \(f.key)" }
                if n.rounded(.towardZero) != n { return "Expected integer for form field: \(f.key)" }
                if let min = f.minimum, n < min { return "Form field is too small: \(f.key)" }
                if let max = f.maximum, n > max { return "Form field is too large: \(f.key)" }
                return nil
            case .boolean(let f):
                guard case .bool = value else { return "Expected boolean for form field: \(f.key)" }
                return nil
            case .multiselect(let f):
                guard case .strings(let items) = value else { return "Expected string array for form field: \(f.key)" }
                if f.required == true && items.isEmpty { return "Missing required form field: \(f.key)" }
                if let minI = f.minItems, items.count < minI.rawValue { return "Too few selections for form field: \(f.key)" }
                if let maxI = f.maxItems, items.count > maxI.rawValue { return "Too many selections for form field: \(f.key)" }
                if f.custom != true, items.contains(where: { item in !f.options.contains(where: { $0.value == item }) }) {
                    return "Invalid option for form field: \(f.key)"
                }
                return nil
            case .external:
                return nil
            }
        }

        // parity: core/src/form.ts#Interface [status=implemented hash=c5c1ee622664]
        public protocol Interface: Sendable {
            func close() async
            func create(_ input: CreateInput) async throws -> Info
            func ask(_ input: CreateInput) async throws -> TerminalState
            func get(_ id: ID) async throws -> Info
            func list(_ input: ListInput?) async -> [Info]
            func state(_ id: ID) async throws -> State
            func reply(_ input: ReplyInput) async throws
            func cancel(_ id: ID, options: CancelOptions?) async throws
        }

        // parity: core/src/form.ts#Service [status=implemented hash=c7343052faad]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/Form"

            private struct Entry: Sendable {
                let form: Info
                var state: State
                var waiters: [CheckedContinuation<TerminalState, Never>] = []
            }

            private struct Store: Sendable {
                var closed = false
                var forms: [ID: Entry] = [:]
            }

            private let store = Mutex(Store())

            public init() {}

            public func create(_ input: CreateInput) async throws -> Info {
                let id = input.id ?? ID.create()
                if let invalid = Form.validateFields(input.fields.elements) {
                    throw InvalidFormError(message: invalid)
                }
                let info = Info(id: id, sessionID: input.sessionID, title: input.title, metadata: input.metadata, fields: input.fields)
                let wasClosed = try store.withLock { s -> Bool in
                    if s.forms[id] != nil { throw AlreadyExistsError(id: id) }
                    s.forms[id] = Entry(form: info, state: .pending)
                    return s.closed
                }
                if wasClosed {
                    try? await cancel(id, options: nil)
                }
                return info
            }

            public func ask(_ input: CreateInput) async throws -> TerminalState {
                let info = try await create(input)
                return await withCheckedContinuation { continuation in
                    let resolved = store.withLock { s -> TerminalState? in
                        guard var entry = s.forms[info.id] else { return .cancelled(message: nil) }
                        switch entry.state {
                        case .answered(let ans): return .answered(answer: ans)
                        case .cancelled(let msg): return .cancelled(message: msg)
                        case .pending:
                            entry.waiters.append(continuation)
                            s.forms[info.id] = entry
                            return nil
                        }
                    }
                    if let resolved { continuation.resume(returning: resolved) }
                }
            }

            public func get(_ id: ID) async throws -> Info {
                try store.withLock { s in
                    guard let entry = s.forms[id] else { throw NotFoundError(id: id) }
                    return entry.form
                }
            }

            public func list(_ input: ListInput? = nil) async -> [Info] {
                store.withLock { s in
                    s.forms.values.compactMap { entry in
                        guard case .pending = entry.state else { return nil }
                        if let sid = input?.sessionID, entry.form.sessionID != sid { return nil }
                        return entry.form
                    }
                }
            }

            public func state(_ id: ID) async throws -> State {
                try store.withLock { s in
                    guard let entry = s.forms[id] else { throw NotFoundError(id: id) }
                    return entry.state
                }
            }

            public func reply(_ input: ReplyInput) async throws {
                let waiters = try store.withLock { s -> [CheckedContinuation<TerminalState, Never>] in
                    guard var entry = s.forms[input.id] else { throw NotFoundError(id: input.id) }
                    guard case .pending = entry.state else { throw AlreadySettledError(id: input.id) }
                    if let invalid = Form.validateAnswer(form: entry.form.fields.elements, answer: input.answer) {
                        throw InvalidAnswerError(id: input.id, message: invalid)
                    }
                    entry.state = .answered(answer: input.answer)
                    let ws = entry.waiters
                    entry.waiters.removeAll()
                    s.forms[input.id] = entry
                    return ws
                }
                for w in waiters { w.resume(returning: .answered(answer: input.answer)) }
            }

            public func cancel(_ id: ID, options: CancelOptions? = nil) async throws {
                let waiters = try store.withLock { s -> [CheckedContinuation<TerminalState, Never>] in
                    guard var entry = s.forms[id] else { throw NotFoundError(id: id) }
                    guard case .pending = entry.state else { throw AlreadySettledError(id: id) }
                    entry.state = .cancelled(message: options?.message)
                    let ws = entry.waiters
                    entry.waiters.removeAll()
                    s.forms[id] = entry
                    return ws
                }
                for w in waiters { w.resume(returning: .cancelled(message: options?.message)) }
            }

            public func close() async {
                let pendingIDs = store.withLock { s -> [ID] in
                    s.closed = true
                    return s.forms.values.compactMap { entry in
                        if case .pending = entry.state { return entry.form.id }
                        return nil
                    }
                }
                for id in pendingIDs {
                    try? await cancel(id, options: nil)
                }
            }
        }

        // parity: core/src/form.ts#layer [status=implemented hash=33198914acef]
        public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { _, _ in
            LayerNode.Output([Service.serviceKey: Service()])
        }

        // parity: core/src/form.ts#node [status=implemented hash=557341d81bc8]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(Service.serviceKey, layer, [])
    }

    // MARK: - core/src/integration.ts

    public enum Integration {
        // parity: core/src/integration.ts#ID [status=implemented hash=5855f1d185c5]
        public typealias ID = IntegrationSchema.ID

        // parity: core/src/integration.ts#MethodID [status=implemented hash=82c1a259dba2]
        public typealias MethodID = IntegrationSchema.MethodID

        // parity: core/src/integration.ts#AttemptID [status=implemented hash=fa0e198badeb]
        public typealias AttemptID = IntegrationSchema.AttemptID

        // parity: core/src/integration.ts#OAuthMethod [status=implemented hash=5f57ca8e82ec]
        public typealias OAuthMethod = IntegrationSchema.OAuthMethod

        // parity: core/src/integration.ts#CommandMethod [status=implemented hash=4448923b5e75]
        public typealias CommandMethod = IntegrationSchema.CommandMethod

        // parity: core/src/integration.ts#KeyMethod [status=implemented hash=dd3f5c670ec0]
        public typealias KeyMethod = IntegrationSchema.KeyMethod

        // parity: core/src/integration.ts#ExternalMethod [status=implemented hash=9a0466cafddc]
        public typealias ExternalMethod = IntegrationSchema.ExternalMethod

        // parity: core/src/integration.ts#EnvMethod [status=implemented hash=f33fcc02d109]
        public typealias EnvMethod = IntegrationSchema.EnvMethod

        // parity: core/src/integration.ts#Method [status=implemented hash=7ef1e92639e8]
        public typealias Method = IntegrationSchema.Method

        // parity: core/src/integration.ts#Info [status=implemented hash=17ef99b170eb]
        public typealias Info = IntegrationSchema.Info

        // parity: core/src/integration.ts#Attempt [status=implemented hash=9733f32370b6]
        public typealias Attempt = IntegrationSchema.Attempt

        // parity: core/src/integration.ts#AttemptStatus [status=implemented hash=6e43bb60c74a]
        public typealias AttemptStatus = IntegrationSchema.AttemptStatus

        // parity: core/src/integration.ts#CommandAttempt [status=implemented hash=1a4b1d41762c]
        public typealias CommandAttempt = IntegrationSchema.CommandAttempt

        // parity: core/src/integration.ts#CommandAttemptStatus [status=implemented hash=a48e4b20bb60]
        public typealias CommandAttemptStatus = IntegrationSchema.CommandAttemptStatus

        // parity: core/src/integration.ts#Ref [status=implemented hash=4d158ea03536]
        public typealias Ref = IntegrationSchema.Ref

        // parity: core/src/integration.ts#OAuthAuthorization [status=implemented hash=5d4495b32643]
        public struct OAuthAuthorization: Sendable {
            public enum Mode: Sendable {
                case auto(
                    callback: @Sendable () async throws -> CredentialSchema.OAuth,
                    submit: (@Sendable (String) async throws -> Void)?
                )
                case code(callback: @Sendable (String) async throws -> CredentialSchema.OAuth)
            }

            public let url: String
            public let instructions: String
            public let expiresAt: Int64?
            public let mode: Mode

            public init(url: String, instructions: String, expiresAt: Int64? = nil, mode: Mode) {
                self.url = url
                self.instructions = instructions
                self.expiresAt = expiresAt
                self.mode = mode
            }
        }

        // parity: core/src/integration.ts#OAuthImplementation [status=implemented hash=5975db7ac0b9]
        public struct OAuthImplementation: Sendable {
            public let integrationID: ID
            public let method: OAuthMethod
            public let authorize: @Sendable (Form.Answer) async throws -> OAuthAuthorization
            public let refresh: (@Sendable (CredentialSchema.OAuth) async throws -> CredentialSchema.OAuth)?
            public let label: (@Sendable (CredentialSchema.OAuth) -> String?)?

            public init(
                integrationID: ID,
                method: OAuthMethod,
                authorize: @escaping @Sendable (Form.Answer) async throws -> OAuthAuthorization,
                refresh: (@Sendable (CredentialSchema.OAuth) async throws -> CredentialSchema.OAuth)? = nil,
                label: (@Sendable (CredentialSchema.OAuth) -> String?)? = nil
            ) {
                self.integrationID = integrationID
                self.method = method
                self.authorize = authorize
                self.refresh = refresh
                self.label = label
            }
        }

        // parity: core/src/integration.ts#KeyImplementation [status=implemented hash=5cd18de7db8b]
        public struct KeyImplementation: Equatable, Hashable, Sendable {
            public let integrationID: ID
            public let method: KeyMethod
            public init(integrationID: ID, method: KeyMethod) { self.integrationID = integrationID; self.method = method }
        }

        // parity: core/src/integration.ts#ExternalImplementation [status=implemented hash=4f24dd7ff6b8]
        public struct ExternalImplementation: Equatable, Hashable, Sendable {
            public let integrationID: ID
            public let method: ExternalMethod
            public init(integrationID: ID, method: ExternalMethod) { self.integrationID = integrationID; self.method = method }
        }

        // parity: core/src/integration.ts#CommandImplementation [status=implemented hash=6bb0087704c1]
        public struct CommandImplementation: Equatable, Hashable, Sendable {
            public let integrationID: ID
            public let method: CommandMethod
            public init(integrationID: ID, method: CommandMethod) { self.integrationID = integrationID; self.method = method }
        }

        // parity: core/src/integration.ts#EnvImplementation [status=implemented hash=70597156421f]
        public struct EnvImplementation: Equatable, Hashable, Sendable {
            public let integrationID: ID
            public let method: EnvMethod
            public init(integrationID: ID, method: EnvMethod) { self.integrationID = integrationID; self.method = method }
        }

        // parity: core/src/integration.ts#Implementation [status=implemented hash=45e52a5066e6]
        public enum Implementation: Sendable {
            case oauth(OAuthImplementation)
            case command(CommandImplementation)
            case key(KeyImplementation)
            case external(ExternalImplementation)
            case env(EnvImplementation)
        }

        // parity: core/src/integration.ts#CodeRequiredError [status=implemented hash=ae2e77da2dfb]
        public struct CodeRequiredError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Integration.CodeRequired"
            public let attemptID: AttemptID
            public init(attemptID: AttemptID) { self.attemptID = attemptID }
            public var description: String { "Authorization code required for attempt \(attemptID.rawValue)" }
        }

        // parity: core/src/integration.ts#AuthorizationError [status=implemented hash=b1a44a3bc642]
        public struct AuthorizationError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Integration.Authorization"
            public let message: String
            public init(message: String = "Authorization failed") { self.message = message }
            public var description: String { message }
        }

        // parity: core/src/integration.ts#AttemptNotFoundError [status=implemented hash=d384e8a2dc2f]
        public struct AttemptNotFoundError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Integration.AttemptNotFound"
            public let integrationID: ID
            public let attemptID: AttemptID
            public init(integrationID: ID, attemptID: AttemptID) { self.integrationID = integrationID; self.attemptID = attemptID }
            public var description: String { "Integration attempt \(attemptID.rawValue) not found for \(integrationID.rawValue)" }
        }

        // parity: core/src/integration.ts#Error [status=implemented hash=f695571b4daa]
        public enum IntegrationError: Swift.Error, Equatable, Hashable, Sendable {
            case codeRequired(CodeRequiredError)
            case authorization(AuthorizationError)
            case attemptNotFound(AttemptNotFoundError)
        }

        public struct Entry: Sendable {
            public var ref: Ref
            public var methods: [Method]
            public var oauthImplementations: [MethodID: OAuthImplementation]

            public init(ref: Ref, methods: [Method] = [], oauthImplementations: [MethodID: OAuthImplementation] = [:]) {
                self.ref = ref
                self.methods = methods
                self.oauthImplementations = oauthImplementations
            }
        }

        // parity: core/src/integration.ts#Editor [status=implemented hash=472ba13aa1b6]
        public final class Editor: @unchecked Sendable {
            internal var entries: [ID: Entry]
            internal init(entries: [ID: Entry]) { self.entries = entries }

            public func list() -> [Ref] { entries.values.map(\.ref) }
            public func get(_ id: ID) -> Ref? { entries[id]?.ref }

            public func update(_ id: ID, _ fn: (Ref) -> Ref) {
                let current = entries[id]?.ref ?? Ref(id: id, name: id.rawValue)
                let next = fn(current)
                var entry = entries[id] ?? Entry(ref: next)
                entry.ref = Ref(id: id, name: next.name, metadata: next.metadata)
                entries[id] = entry
            }

            public func remove(_ id: ID) { entries.removeValue(forKey: id) }

            public func updateMethod(_ implementation: Implementation) {
                switch implementation {
                case .oauth(let impl):
                    var entry = entries[impl.integrationID] ?? Entry(ref: Ref(id: impl.integrationID, name: impl.integrationID.rawValue))
                    entry.methods.removeAll { if case .oauth(let m) = $0 { return m.id == impl.method.id } else { return false } }
                    entry.methods.append(.oauth(impl.method))
                    entry.oauthImplementations[impl.method.id] = impl
                    entries[impl.integrationID] = entry
                case .key(let impl):
                    var entry = entries[impl.integrationID] ?? Entry(ref: Ref(id: impl.integrationID, name: impl.integrationID.rawValue))
                    entry.methods.removeAll { if case .key = $0 { return true } else { return false } }
                    entry.methods.append(.key(impl.method))
                    entries[impl.integrationID] = entry
                case .external(let impl):
                    var entry = entries[impl.integrationID] ?? Entry(ref: Ref(id: impl.integrationID, name: impl.integrationID.rawValue))
                    entry.methods.removeAll { if case .external(let m) = $0 { return m.id == impl.method.id } else { return false } }
                    entry.methods.append(.external(impl.method))
                    entries[impl.integrationID] = entry
                case .command(let impl):
                    var entry = entries[impl.integrationID] ?? Entry(ref: Ref(id: impl.integrationID, name: impl.integrationID.rawValue))
                    entry.methods.removeAll { if case .command(let m) = $0 { return m.id == impl.method.id } else { return false } }
                    entry.methods.append(.command(impl.method))
                    entries[impl.integrationID] = entry
                case .env(let impl):
                    var entry = entries[impl.integrationID] ?? Entry(ref: Ref(id: impl.integrationID, name: impl.integrationID.rawValue))
                    entry.methods.removeAll { if case .env = $0 { return true } else { return false } }
                    entry.methods.append(.env(impl.method))
                    entries[impl.integrationID] = entry
                }
            }
        }

        // parity: core/src/integration.ts#Interface [status=implemented hash=2ad87457d9c4]
        public protocol Interface: CoreState.Transformable where Editor == Integration.Editor {
            func revision() -> Int
            func get(_ id: ID) async throws -> Info?
            func list() async throws -> [Info]
            func activeConnection(_ id: ID) async throws -> Connection.Info?
            func resolveConnection(_ connection: Connection.Info) async throws -> CredentialSchema.Value?
            func connectKey(integrationID: ID, key: String, answer: Form.Answer?, label: String?) async throws
            func connectExternal(integrationID: ID, methodID: MethodID, answer: Form.Answer?, label: String?) async throws
            func activateCredential(_ credentialID: CredentialSchema.ID) async throws
            func removeCredential(_ credentialID: CredentialSchema.ID) async throws
            func setConnectionStatus(integrationID: ID, connection: Connection.Info, status: Connection.Status?) async
        }

        // parity: core/src/integration.ts#Service [status=implemented hash=27cce680e8bc]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/Integration"
            private let credentials: any CoreProvider.Credential.Interface
            private let environment: any EnvironmentProviding
            private let state: CoreState.Store<[ID: Entry], Editor>
            private let statuses = Mutex<[String: Connection.Status]>([:])

            public init(
                credentials: any CoreProvider.Credential.Interface,
                environment: any EnvironmentProviding = SystemEnvironment.shared
            ) {
                self.credentials = credentials
                self.environment = environment
                self.state = CoreState.create(CoreState.Options(
                    name: "integration",
                    initial: { [:] },
                    makeEditor: { Editor(entries: $0) },
                    commitEditor: { $0.entries }
                ))
            }

            public func revision() -> Int { state.revision() }

            @discardableResult
            public func transform(_ update: @escaping @Sendable (Editor) throws -> Void) async throws -> CoreState.Registration {
                try await state.transform(update)
            }

            public func reload() async { await state.reload() }

            private func connectionsFor(_ entry: Entry) async throws -> [Connection.Info] {
                let stored = try await credentials.list(entry.ref.id)
                var out: [Connection.Info] = stored.reversed().map { cred in
                    let method: Connection.CredentialInfo.Method
                    switch cred.value {
                    case .key: method = .key
                    case .oauth: method = .oauth
                    case .external: method = .external
                    }
                    let info = Connection.Info.credential(Connection.CredentialInfo(id: cred.id, label: cred.label, method: method))
                    let st = Connection.key(info).flatMap { k in statuses.withLock { $0[k] } }
                    return .credential(Connection.CredentialInfo(id: cred.id, label: cred.label, method: method, status: st))
                }
                for method in entry.methods {
                    if case .env(let envMethod) = method {
                        for name in envMethod.names {
                            if let val = environment.variable(name), !val.isEmpty {
                                let info = Connection.Info.env(Connection.EnvInfo(name: name))
                                let st = Connection.key(info).flatMap { k in statuses.withLock { $0[k] } }
                                out.append(.env(Connection.EnvInfo(name: name, status: st)))
                            }
                        }
                    }
                }
                return out
            }

            public func get(_ id: ID) async throws -> Info? {
                guard let entry = state.get()[id] else { return nil }
                let conns = try await connectionsFor(entry)
                return Info(id: entry.ref.id, name: entry.ref.name, metadata: entry.ref.metadata, methods: entry.methods, connections: conns)
            }

            public func list() async throws -> [Info] {
                let entries = state.get().values.sorted { $0.ref.id.rawValue < $1.ref.id.rawValue }
                var out: [Info] = []
                for entry in entries {
                    let conns = try await connectionsFor(entry)
                    out.append(Info(id: entry.ref.id, name: entry.ref.name, metadata: entry.ref.metadata, methods: entry.methods, connections: conns))
                }
                return out
            }

            public func activeConnection(_ id: ID) async throws -> Connection.Info? {
                try await get(id)?.connections.first
            }

            public func resolveConnection(_ connection: Connection.Info) async throws -> CredentialSchema.Value? {
                switch connection {
                case .env(let env):
                    guard let secret = environment.variable(env.name), !secret.isEmpty else { return nil }
                    return .key(CredentialSchema.Key(key: secret))
                case .credential(let cred):
                    return try await credentials.get(cred.id)?.value
                }
            }

            public func connectKey(integrationID: ID, key: String, answer: Form.Answer? = nil, label: String? = nil) async throws {
                let meta: [String: JSONValue]? = answer.map { $0.mapValues(\.asJSONValue) }
                _ = try await credentials.create(
                    id: nil,
                    integrationID: integrationID,
                    value: .key(CredentialSchema.Key(key: key, metadata: meta)),
                    label: label,
                    activate: true
                )
            }

            public func connectExternal(integrationID: ID, methodID: MethodID, answer: Form.Answer? = nil, label: String? = nil) async throws {
                let meta: [String: JSONValue]? = answer.map { $0.mapValues(\.asJSONValue) }
                _ = try await credentials.create(
                    id: nil,
                    integrationID: integrationID,
                    value: .external(CredentialSchema.External(methodID: methodID, metadata: meta)),
                    label: label,
                    activate: true
                )
            }

            public func activateCredential(_ credentialID: CredentialSchema.ID) async throws {
                try await credentials.activate(credentialID)
            }

            public func removeCredential(_ credentialID: CredentialSchema.ID) async throws {
                try await credentials.remove(credentialID)
            }

            public func setConnectionStatus(integrationID: ID, connection: Connection.Info, status: Connection.Status?) async {
                _ = integrationID
                guard let k = Connection.key(connection) else { return }
                statuses.withLock { map in
                    if let status { map[k] = status } else { map.removeValue(forKey: k) }
                }
            }
        }

        // parity: core/src/integration.ts#node [status=implemented hash=9ccb871b44b8]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer { deps, _ in
                let creds = try deps.get(CoreProvider.Credential.Service.serviceKey, as: CoreProvider.Credential.Service.self)
                    ?? CoreProvider.Credential.Service.inMemory()
                return LayerNode.Output([Service.serviceKey: Service(credentials: creds)])
            },
            [CoreProvider.Credential.node]
        )
    }

    // MARK: - core/src/wellknown.ts & core/src/wellknown/plugin.ts

    public enum WellKnown {
        // parity: core/src/wellknown.ts#Auth [status=implemented hash=3e9f8780337b]
        public struct Auth: Equatable, Hashable, Sendable, Codable {
            public let command: [String]
            public let env: String

            public init(command: [String], env: String) {
                self.command = command
                self.env = env
            }
        }

        // parity: core/src/wellknown.ts#RemoteConfig [status=implemented hash=b893891d6f93]
        public struct RemoteConfig: Equatable, Hashable, Sendable, Codable {
            public let url: String
            public let headers: [String: String]?

            public init(url: String, headers: [String: String]? = nil) {
                self.url = url
                self.headers = headers
            }
        }

        // parity: core/src/wellknown.ts#Config [status=implemented hash=1663f547405e]
        public typealias Config = [String: JSONValue]

        // parity: core/src/wellknown.ts#Manifest [status=implemented hash=01948ced336f]
        public struct Manifest: Equatable, Hashable, Sendable, Codable {
            public let auth: Auth?
            public let config: Config?
            public let remoteConfig: RemoteConfig?

            public init(auth: Auth? = nil, config: Config? = nil, remoteConfig: RemoteConfig? = nil) {
                self.auth = auth
                self.config = config
                self.remoteConfig = remoteConfig
            }

            enum CodingKeys: String, CodingKey {
                case auth, config
                case remoteConfig = "remote_config"
            }
        }

        // parity: core/src/wellknown.ts#ResolveInput [status=implemented hash=210fbfc6a8a7]
        public struct ResolveInput: Equatable, Hashable, Sendable {
            public let origin: String
            public let variables: [String: String]

            public init(origin: String, variables: [String: String] = [:]) {
                self.origin = origin
                self.variables = variables
            }
        }

        // parity: core/src/wellknown.ts#Entry [status=implemented hash=2a290a3d409a]
        public struct Entry: Equatable, Hashable, Sendable, Codable {
            public let origin: String
            public let integrationID: IntegrationID
            public let manifest: Manifest

            public init(origin: String, integrationID: IntegrationID, manifest: Manifest) {
                self.origin = origin
                self.integrationID = integrationID
                self.manifest = manifest
            }
        }

        // parity: core/src/wellknown.ts#Event [status=implemented hash=faf939d35050]
        public enum Event {
            public static let updated = SchemaPrimitive.EventDescriptor.ephemeral(type: "wellknown.updated")
        }

        private static func trimTrailingSlashes(_ s: String) -> String {
            var res = s
            while res.hasSuffix("/") { res.removeLast() }
            return res
        }

        private static func substituteEnv(_ template: String, variables: [String: String], env: any EnvironmentProviding) -> String {
            var result = template
            if let regex = try? Regex("\\{env:([^}]+)\\}") {
                for match in template.matches(of: regex).reversed() {
                    let full = String(template[match.range])
                    let varName = String(full.dropFirst(5).dropLast())
                    let replacement = variables[varName] ?? env.variable(varName) ?? ""
                    result.replaceSubrange(match.range, with: replacement)
                }
            }
            return result
        }

        // parity: core/src/wellknown.ts#inspect [status=implemented hash=84ee82df0cd0]
        public static func inspect(origin: String, transport: any HTTPTransport) async throws -> Manifest {
            let url = "\(trimTrailingSlashes(origin))/.well-known/opencode"
            let resp = try await transport.send(HTTPRequest(method: "GET", url: url, headers: ["accept": "application/json"]))
            guard (200..<300).contains(resp.head.statusCode) else {
                throw PlatformError.ioFailure("Failed to load wellknown manifest from \(url) (HTTP \(resp.head.statusCode))")
            }
            return try JSONDecoder().decode(Manifest.self, from: Data(resp.body))
        }

        // parity: core/src/wellknown.ts#resolve [status=implemented hash=15906531dda7]
        public static func resolve(
            _ input: ResolveInput,
            transport: any HTTPTransport,
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) async throws -> [Config] {
            let manifest = try await inspect(origin: input.origin, transport: transport)
            let entry = Entry(
                origin: trimTrailingSlashes(input.origin),
                integrationID: IntegrationID(rawValue: trimTrailingSlashes(input.origin)),
                manifest: manifest
            )
            return try await resolveEntry(entry, variables: input.variables, transport: transport, environment: environment)
        }

        fileprivate static func resolveEntry(
            _ entry: Entry,
            variables: [String: String],
            transport: any HTTPTransport,
            environment: any EnvironmentProviding
        ) async throws -> [Config] {
            var configs: [Config] = entry.manifest.config.map { [$0] } ?? []
            guard let remote = entry.manifest.remoteConfig else { return configs }
            let url = substituteEnv(remote.url, variables: variables, env: environment)
            var headers: [String: String] = ["accept": "application/json"]
            for (k, v) in remote.headers ?? [:] {
                headers[k] = substituteEnv(v, variables: variables, env: environment)
            }
            let resp = try await transport.send(HTTPRequest(method: "GET", url: url, headers: headers))
            guard (200..<300).contains(resp.head.statusCode) else {
                throw PlatformError.ioFailure("Failed to load wellknown remote config from \(url) (HTTP \(resp.head.statusCode))")
            }
            let decoded = try JSONDecoder().decode(Config.self, from: Data(resp.body))
            if case .object(let inner) = decoded["config"] {
                configs.append(inner)
            } else {
                configs.append(decoded)
            }
            return configs
        }

        // parity: core/src/wellknown.ts#Interface [status=implemented hash=3cd35ed6cccb]
        public protocol Interface: Sendable {
            func entries() async throws -> [Entry]
            func snapshot() -> [Entry]
            func refresh() async throws -> Bool
            func add(origin: String) async throws -> Entry
            func remove(origin: String) async throws
            func resolve(entry: Entry, variables: [String: String]) async throws -> [Config]
            func cached(origin: String) async throws -> [Config]
            func clearCached(origin: String) async throws
        }

        // parity: core/src/wellknown.ts#Service [status=implemented hash=66483bc8d67e]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/WellKnown"
            private static let sourcesKey = "wellknown:sources"

            private let transport: any HTTPTransport
            private let kv: any CoreKV.Interface
            private let environment: any EnvironmentProviding
            private let cache = Mutex<[String: Entry]>([:])

            public init(
                transport: any HTTPTransport,
                kv: any CoreKV.Interface,
                environment: any EnvironmentProviding = SystemEnvironment.shared
            ) {
                self.transport = transport
                self.kv = kv
                self.environment = environment
            }

            private func readOrigins() async throws -> [String] {
                guard case .array(let arr) = try await kv.get(Self.sourcesKey) else { return [] }
                return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            }

            public func entries() async throws -> [Entry] {
                let origins = try await readOrigins()
                var out: [Entry] = []
                for origin in origins {
                    if let cached = cache.withLock({ $0[origin] }) {
                        out.append(cached)
                        continue
                    }
                    if let manifest = try? await WellKnown.inspect(origin: origin, transport: transport) {
                        let entry = Entry(origin: origin, integrationID: IntegrationID(rawValue: origin), manifest: manifest)
                        cache.withLock { $0[origin] = entry }
                        out.append(entry)
                    }
                }
                return out
            }

            public func snapshot() -> [Entry] {
                cache.withLock { Array($0.values) }
            }

            public func refresh() async throws -> Bool {
                let origins = try await readOrigins()
                guard !origins.isEmpty else { return false }
                var next: [String: Entry] = [:]
                for origin in origins {
                    if let manifest = try? await WellKnown.inspect(origin: origin, transport: transport) {
                        next[origin] = Entry(origin: origin, integrationID: IntegrationID(rawValue: origin), manifest: manifest)
                    }
                }
                return cache.withLock { cur in
                    if cur == next { return false }
                    cur = next
                    return true
                }
            }

            public func add(origin: String) async throws -> Entry {
                let norm = WellKnown.trimTrailingSlashes(origin)
                let manifest = try await WellKnown.inspect(origin: norm, transport: transport)
                guard manifest.auth != nil else {
                    throw PlatformError.ioFailure("No authentication method found at \(norm)")
                }
                let entry = Entry(origin: norm, integrationID: IntegrationID(rawValue: norm), manifest: manifest)
                var origins = try await readOrigins()
                if !origins.contains(norm) { origins.append(norm) }
                try await kv.set(Self.sourcesKey, value: .array(origins.map(JSONValue.string)))
                cache.withLock { $0[norm] = entry }
                return entry
            }

            public func remove(origin: String) async throws {
                let norm = WellKnown.trimTrailingSlashes(origin)
                let origins = try await readOrigins().filter { $0 != norm }
                try await kv.set(Self.sourcesKey, value: .array(origins.map(JSONValue.string)))
                try await kv.remove("wellknown:manifest:\(norm)")
                try await kv.remove("wellknown:config:\(norm)")
                cache.withLock { _ = $0.removeValue(forKey: norm) }
            }

            public func resolve(entry: Entry, variables: [String: String]) async throws -> [Config] {
                let configs = try await WellKnown.resolveEntry(entry, variables: variables, transport: transport, environment: environment)
                try await kv.set("wellknown:config:\(entry.origin)", value: .array(configs.map(JSONValue.object)))
                return configs
            }

            public func cached(origin: String) async throws -> [Config] {
                guard case .array(let arr) = try await kv.get("wellknown:config:\(origin)") else { return [] }
                return arr.compactMap { if case .object(let o) = $0 { return o } else { return nil } }
            }

            public func clearCached(origin: String) async throws {
                try await kv.remove("wellknown:config:\(origin)")
            }
        }

        // parity: core/src/wellknown.ts#node [status=implemented hash=8fa940f356db]
        public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer { deps, _ in
                let http = deps.get(LayerNodePlatform.httpClientKey, as: (any HTTPTransport).self)
                    ?? LayerNodePlatform.FetchTransport { _ in
                        throw PlatformError.unsupportedOnPlatform(Platform.current, operation: "WellKnown")
                    }
                let kv = try deps.get(CoreKV.Service.serviceKey, as: CoreKV.Service.self) ?? CoreKV.Service.inMemory()
                return LayerNode.Output([Service.serviceKey: Service(transport: http, kv: kv)])
            },
            [LayerNodePlatform.httpClient, CoreKV.node]
        )

        public enum WellKnownPlugin {
            // parity: core/src/wellknown/plugin.ts#Plugin [status=adapted hash=cb458972921f]
            public static let pluginID = "opencode.wellknown"

            public static func apply(wellknown: any Interface, editor: Integration.Editor) {
                for entry in wellknown.snapshot() {
                    guard let auth = entry.manifest.auth else { continue }
                    let host = URL(string: entry.origin)?.host ?? entry.origin
                    editor.update(entry.integrationID) { ref in
                        Integration.Ref(id: ref.id, name: host, metadata: ref.metadata)
                    }
                    editor.updateMethod(.command(Integration.CommandImplementation(
                        integrationID: entry.integrationID,
                        method: Integration.CommandMethod(
                            id: IntegrationMethodID(rawValue: "login"),
                            label: "Log in",
                            command: auth.command
                        )
                    )))
                }
            }
        }
    }

    // MARK: - core/src/websearch.ts

    public enum WebSearch {
        // parity: core/src/websearch.ts#ID [status=implemented hash=2dfa2aeedc19]
        public typealias ID = WebSearchSchema.ID

        // parity: core/src/websearch.ts#Provider [status=implemented hash=49efd98cbace]
        public typealias Provider = WebSearchSchema.Provider

        // parity: core/src/websearch.ts#Input [status=implemented hash=431c6c2d54c2]
        public typealias Input = WebSearchSchema.Input

        // parity: core/src/websearch.ts#ProviderInput [status=implemented hash=1ee79d30b795]
        public typealias ProviderInput = WebSearchSchema.ProviderInput

        // parity: core/src/websearch.ts#Result [status=implemented hash=6183671a57f2]
        public typealias Result = WebSearchSchema.Result

        // parity: core/src/websearch.ts#Response [status=implemented hash=d230124e86ca]
        public typealias Response = WebSearchSchema.Response

        // parity: core/src/websearch.ts#ProviderKey [status=implemented hash=5bbd85f7f070]
        public static let ProviderKey = "websearch:provider"

        // parity: core/src/websearch.ts#Selection [status=implemented hash=e653c786e18e]
        public enum Selection: Equatable, Hashable, Sendable {
            case provider(ID)
            case random
            case disabled
        }

        // parity: core/src/websearch.ts#ProviderImplementation [status=implemented hash=100a7c58c556]
        public struct ProviderImplementation: Sendable {
            public let id: ID
            public let name: String
            public let execute: @Sendable (ProviderInput) async throws -> [Result]

            public init(id: ID, name: String, execute: @escaping @Sendable (ProviderInput) async throws -> [Result]) {
                self.id = id
                self.name = name
                self.execute = execute
            }
        }

        // parity: core/src/websearch.ts#ProviderRequiredError [status=implemented hash=a8177567c8e1]
        public struct ProviderRequiredError: Swift.Error, Equatable, Hashable, Sendable {
            public static let tag = "WebSearch.ProviderRequired"
            public init() {}
        }

        // parity: core/src/websearch.ts#ProviderNotFoundError [status=implemented hash=faca2d40c3e1]
        public struct ProviderNotFoundError: Swift.Error, Equatable, Hashable, Sendable {
            public static let tag = "WebSearch.ProviderNotFound"
            public let providerID: ID
            public init(providerID: ID) { self.providerID = providerID }
        }

        // parity: core/src/websearch.ts#DisabledError [status=implemented hash=ba5bfa44ae95]
        public struct DisabledError: Swift.Error, Equatable, Hashable, Sendable {
            public static let tag = "WebSearch.Disabled"
            public init() {}
        }

        // parity: core/src/websearch.ts#RequestError [status=implemented hash=901b8ab81416]
        public struct RequestError: Swift.Error, Sendable, CustomStringConvertible {
            public static let tag = "WebSearch.Request"
            public let providerID: ID
            public let message: String
            public init(providerID: ID, cause: any Error) {
                self.providerID = providerID
                self.message = String(describing: cause)
            }
            public var description: String { "WebSearch request failed for \(providerID.rawValue): \(message)" }
        }

        // parity: core/src/websearch.ts#Error [status=implemented hash=cf8d9bf4318d]
        public enum SearchError: Swift.Error, Sendable {
            case providerRequired(ProviderRequiredError)
            case providerNotFound(ProviderNotFoundError)
            case disabled(DisabledError)
            case request(RequestError)
        }

        public struct Data: Sendable {
            public var providers: [ID: ProviderImplementation]
            public var selection: Selection?

            public init(providers: [ID: ProviderImplementation] = [:], selection: Selection? = nil) {
                self.providers = providers
                self.selection = selection
            }
        }

        // parity: core/src/websearch.ts#Editor [status=implemented hash=03c418487db9]
        public final class Editor: @unchecked Sendable {
            internal var data: Data
            internal init(data: Data) { self.data = data }
            public func add(_ provider: ProviderImplementation) { data.providers[provider.id] = provider }
            public func list() -> [ProviderImplementation] { Array(data.providers.values) }
            public func remove(_ id: ID) { data.providers.removeValue(forKey: id) }
            public var defaultSelection: Selection? {
                get { data.selection }
                set { data.selection = newValue }
            }
        }

        // parity: core/src/websearch.ts#Interface [status=implemented hash=cbca4fc1229c]
        public protocol Interface: CoreState.Transformable where Editor == WebSearch.Editor {
            func providers() async -> [Provider]
            func defaultProvider() async throws -> Provider?
            func select(_ selection: Selection) async throws
            func query(_ input: Input, sessionID: SessionID?) async throws -> Response
        }

        // parity: core/src/websearch.ts#Service [status=implemented hash=a23f7075bba8]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/WebSearch"
            private let kv: any CoreKV.Interface
            private let state: CoreState.Store<Data, Editor>

            public init(kv: any CoreKV.Interface) {
                self.kv = kv
                self.state = CoreState.create(CoreState.Options(
                    name: "websearch",
                    initial: { Data() },
                    makeEditor: { Editor(data: $0) },
                    commitEditor: { $0.data }
                ))
            }

            @discardableResult
            public func transform(_ update: @escaping @Sendable (Editor) throws -> Void) async throws -> CoreState.Registration {
                try await state.transform(update)
            }

            public func reload() async { await state.reload() }

            public func providers() async -> [Provider] {
                state.get().providers.values
                    .map { Provider(id: $0.id, name: $0.name) }
                    .sorted { $0.name < $1.name }
            }

            private func effectiveSelection() async -> Selection? {
                let data = state.get()
                if let sel = data.selection {
                    switch sel {
                    case .disabled, .random: return sel
                    case .provider(let id): if data.providers[id] != nil { return sel }
                    }
                }
                guard let stored = try? await kv.get(WebSearch.ProviderKey) else { return nil }
                switch stored {
                case .bool(false): return .disabled
                case .string("random"): return .random
                case .string(let s): return .provider(ID(rawValue: s))
                default: return nil
                }
            }

            public func defaultProvider() async throws -> Provider? {
                let choice = await effectiveSelection()
                if choice == .disabled { throw DisabledError() }
                let map = state.get().providers
                switch choice {
                case .provider(let id): return map[id].map { Provider(id: $0.id, name: $0.name) }
                case .random: return map.values.first.map { Provider(id: $0.id, name: $0.name) }
                case .disabled, .none: return nil
                }
            }

            public func select(_ selection: Selection) async throws {
                let val: JSONValue
                switch selection {
                case .disabled: val = .bool(false)
                case .random: val = .string("random")
                case .provider(let id): val = .string(id.rawValue)
                }
                try await kv.set(WebSearch.ProviderKey, value: val)
            }

            public func query(_ input: Input, sessionID: SessionID? = nil) async throws -> Response {
                _ = sessionID
                let map = state.get().providers
                let chosen: ProviderImplementation
                if let explicit = input.providerID {
                    guard let found = map[explicit] else { throw ProviderNotFoundError(providerID: explicit) }
                    chosen = found
                } else {
                    let choice = await effectiveSelection()
                    if choice == .disabled { throw DisabledError() }
                    switch choice {
                    case .provider(let id):
                        guard let found = map[id] else { throw ProviderRequiredError() }
                        chosen = found
                    case .random:
                        guard let found = map.values.randomElement() else { throw ProviderRequiredError() }
                        chosen = found
                    case .disabled, .none:
                        throw ProviderRequiredError()
                    }
                }
                do {
                    let results = try await chosen.execute(ProviderInput(query: input.query))
                    return Response(providerID: chosen.id, results: results)
                } catch {
                    throw RequestError(providerID: chosen.id, cause: error)
                }
            }
        }

        // parity: core/src/websearch.ts#node [status=implemented hash=9c8ba495c563]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer { deps, _ in
                let kv = try deps.get(CoreKV.Service.serviceKey, as: CoreKV.Service.self) ?? CoreKV.Service.inMemory()
                return LayerNode.Output([Service.serviceKey: Service(kv: kv)])
            },
            [CoreKV.node]
        )
    }

    // MARK: - core/src/rpc.ts

    public enum Rpc {
        // parity: core/src/rpc.ts#eventDefinition [status=implemented hash=a3dcf6f4443b]
        public static func eventDefinition(type: String) -> SchemaPrimitive.EventDescriptor {
            SchemaPrimitive.EventDescriptor.ephemeral(type: type)
        }

        public typealias Handler = @Sendable (JSONValue) async throws -> JSONValue

        // parity: core/src/rpc.ts#Interface [status=implemented hash=b7fdd9cdbf68]
        public protocol Interface: Sendable {
            func register(rpcID: String, handlers: [String: Handler]) async -> CoreState.Registration
            func call(rpcID: String, method: String, input: JSONValue) async throws -> JSONValue
            func close() async
        }

        // parity: core/src/rpc.ts#Service [status=implemented hash=ed6caa926503]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/Rpc"

            private struct Store: Sendable {
                var closed = false
                var nextID: UInt64 = 1
                var registrations: [String: [(id: UInt64, handlers: [String: Handler])]] = [:]
            }

            private let store = Mutex(Store())

            public init() {}

            public func register(rpcID: String, handlers: [String: Handler]) async -> CoreState.Registration {
                let entryID = store.withLock { s -> UInt64 in
                    let id = s.nextID
                    s.nextID += 1
                    s.registrations[rpcID, default: []].append((id, handlers))
                    return id
                }
                return CoreState.Registration { [self] in
                    self.store.withLock { s in
                        s.registrations[rpcID]?.removeAll { $0.id == entryID }
                        if s.registrations[rpcID]?.isEmpty == true {
                            s.registrations.removeValue(forKey: rpcID)
                        }
                    }
                }
            }

            public func call(rpcID: String, method: String, input: JSONValue) async throws -> JSONValue {
                let handler: Handler = try store.withLock { s in
                    if s.closed {
                        throw RpcSchema.Failure<JSONValue>(type: "rpc.unavailable", message: "RPC is unavailable: \(rpcID)")
                    }
                    guard let entry = s.registrations[rpcID]?.last else {
                        throw RpcSchema.Failure<JSONValue>(type: "rpc.unavailable", message: "RPC is unavailable: \(rpcID)")
                    }
                    guard let fn = entry.handlers[method] else {
                        throw RpcSchema.Failure<JSONValue>(type: "rpc.method_not_found", message: "Unknown RPC method: \(rpcID).\(method)")
                    }
                    return fn
                }
                do {
                    return try await handler(input)
                } catch let failure as RpcSchema.Failure<JSONValue> {
                    throw failure
                } catch {
                    throw RpcSchema.Failure<JSONValue>(type: "rpc.internal", message: String(describing: error))
                }
            }

            public func close() async {
                store.withLock { $0.closed = true }
            }
        }

        // parity: core/src/rpc.ts#node [status=implemented hash=7001c2aab0af]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer { _, _ in LayerNode.Output([Service.serviceKey: Service()]) },
            []
        )
    }

    // MARK: - core/src/modal/models.ts

    public enum ModalModels {
        public struct RemoteModel: Equatable, Hashable, Sendable, Codable {
            public let id: String
            public let baseModelID: String?
            public let huggingFaceID: String?
            public let name: String?
            public let inputModalities: [String]?
            public let outputModalities: [String]?
            public let contextLength: Int?
            public let maxOutputLength: Int?
            public let supportedFeatures: [String]?

            public init(
                id: String,
                baseModelID: String? = nil,
                huggingFaceID: String? = nil,
                name: String? = nil,
                inputModalities: [String]? = nil,
                outputModalities: [String]? = nil,
                contextLength: Int? = nil,
                maxOutputLength: Int? = nil,
                supportedFeatures: [String]? = nil
            ) {
                self.id = id
                self.baseModelID = baseModelID
                self.huggingFaceID = huggingFaceID
                self.name = name
                self.inputModalities = inputModalities
                self.outputModalities = outputModalities
                self.contextLength = contextLength
                self.maxOutputLength = maxOutputLength
                self.supportedFeatures = supportedFeatures
            }

            enum CodingKeys: String, CodingKey {
                case id, name
                case baseModelID = "base_model_id"
                case huggingFaceID = "hugging_face_id"
                case inputModalities = "input_modalities"
                case outputModalities = "output_modalities"
                case contextLength = "context_length"
                case maxOutputLength = "max_output_length"
                case supportedFeatures = "supported_features"
            }
        }

        // parity: core/src/modal/models.ts#Snapshot [status=implemented hash=1d9801f326d2]
        public typealias Snapshot = [RemoteModel]

        // parity: core/src/modal/models.ts#load [status=implemented hash=9a61076ffc83]
        public static func load(
            http: any HTTPTransport,
            baseURL: String,
            apiKey: String
        ) async throws -> Snapshot {
            var trimmed = baseURL
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
            let resp = try await http.send(HTTPRequest(
                method: "GET",
                url: "\(trimmed)/models",
                headers: ["authorization": "Bearer \(apiKey)", "accept": "application/json"]
            ))
            guard (200..<300).contains(resp.head.statusCode) else {
                throw PlatformError.ioFailure("Modal models fetch failed (HTTP \(resp.head.statusCode))")
            }
            struct Envelope: Decodable { let data: [JSONValue] }
            let env = try JSONDecoder().decode(Envelope.self, from: Data(resp.body))
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            return env.data.compactMap { raw in
                guard let d = try? encoder.encode(raw) else { return nil }
                return try? decoder.decode(RemoteModel.self, from: d)
            }
        }

        // parity: core/src/modal/models.ts#derive [status=implemented hash=2821862bac26]
        public static func derive(
            baseURL: String,
            remote: Snapshot,
            existing: [ModelSchema.Info]
        ) -> [ModelSchema.ID: ModelSchema.Info] {
            let providerID = ProviderSchema.ID(rawValue: "modal")
            var templates: [ModelSchema.ID: ModelSchema.Info] = [:]
            for m in existing { templates[m.id] = m }
            var result: [ModelSchema.ID: ModelSchema.Info] = [:]
            for item in remote {
                let templateKey = ModelSchema.ID(rawValue: item.baseModelID ?? item.huggingFaceID ?? item.id)
                let prev = templates[templateKey]
                let id = ModelSchema.ID(rawValue: item.id)
                let caps = ModelSchema.Capabilities(
                    tools: item.supportedFeatures?.contains("tools") ?? prev?.capabilities.tools ?? true,
                    input: item.inputModalities ?? prev?.capabilities.input ?? ["text"],
                    output: item.outputModalities ?? prev?.capabilities.output ?? ["text"]
                )
                let settings = ModelSchema.Settings(extra: [
                    "baseURL": .string(baseURL),
                    "provider": .string(providerID.rawValue),
                ])
                result[id] = ModelSchema.Info(
                    id: id,
                    modelID: id,
                    providerID: providerID,
                    family: prev?.family,
                    name: item.name ?? prev?.name ?? item.id,
                    compatibility: prev?.compatibility,
                    package: "@opencode/ai/providers/openai-compatible",
                    settings: settings,
                    headers: prev?.headers,
                    body: prev?.body,
                    capabilities: caps,
                    variants: prev?.variants ?? [],
                    time: prev?.time ?? ModelSchema.Info.Time(released: 0),
                    cost: prev?.cost ?? [ModelSchema.Cost(
                        input: MoneySchema.USDPerMillionTokens.zero,
                        output: MoneySchema.USDPerMillionTokens.zero,
                        cache: ModelSchema.Cost.Cache(read: .zero, write: .zero)
                    )],
                    status: prev?.status ?? .active,
                    enabled: prev?.enabled ?? true,
                    limit: ModelSchema.Info.Limit(
                        context: item.contextLength ?? prev?.limit.context ?? 0,
                        input: prev?.limit.input,
                        output: item.maxOutputLength ?? prev?.limit.output ?? 0
                    )
                )
            }
            return result
        }

        // parity: core/src/modal/models.ts#get [status=implemented hash=37e68a218ca8]
        public static func get(
            http: any HTTPTransport,
            baseURL: String,
            apiKey: String,
            existing: [ModelSchema.Info]
        ) async throws -> [ModelSchema.ID: ModelSchema.Info] {
            let remote = try await load(http: http, baseURL: baseURL, apiKey: apiKey)
            return derive(baseURL: baseURL, remote: remote, existing: existing)
        }
    }

    // MARK: - core/src/generate.ts

    public enum Generate {
        // parity: core/src/generate.ts#TextInput [status=implemented hash=75d2865d17a5]
        public struct TextInput: Equatable, Hashable, Sendable {
            public let prompt: String
            public let model: ModelSchema.Ref?

            public init(prompt: String, model: ModelSchema.Ref? = nil) {
                self.prompt = prompt
                self.model = model
            }
        }

        // parity: core/src/generate.ts#VideoInput [status=implemented hash=905d7406a511]
        public struct VideoInput: Equatable, Sendable {
            public let model: ModelSchema.Ref
            public let prompt: String
            public let duration: Int?
            public let resolution: String?
            public let sound: Bool?

            public init(
                model: ModelSchema.Ref,
                prompt: String,
                duration: Int? = nil,
                resolution: String? = nil,
                sound: Bool? = nil
            ) {
                self.model = model
                self.prompt = prompt
                self.duration = duration
                self.resolution = resolution
                self.sound = sound
            }
        }

        // parity: core/src/generate.ts#VideoFile [status=implemented hash=6a1f3e8bce1e]
        public struct VideoFile: Sendable {
            public let mime: String
            public let width: Int?
            public let height: Int?
            public let bytes: [UInt8]

            public init(mime: String, width: Int? = nil, height: Int? = nil, bytes: [UInt8]) {
                self.mime = mime
                self.width = width
                self.height = height
                self.bytes = bytes
            }
        }

        // parity: core/src/generate.ts#UnavailableError [status=implemented hash=3292b442a526]
        public struct UnavailableError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Generate.UnavailableError"
            public let message: String
            public let service: String?
            public init(message: String, service: String? = nil) { self.message = message; self.service = service }
            public var description: String { message }
        }

        // parity: core/src/generate.ts#ModelNotFoundError [status=implemented hash=8a2d3ed0aca9]
        public struct ModelNotFoundError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Generate.ModelNotFoundError"
            public let providerID: String
            public let modelID: String
            public let message: String
            public init(providerID: String, modelID: String, message: String? = nil) {
                self.providerID = providerID
                self.modelID = modelID
                self.message = message ?? "Model not found: \(providerID)/\(modelID)"
            }
            public var description: String { message }
        }

        // parity: core/src/generate.ts#UnsupportedModelError [status=implemented hash=4c080e6b4498]
        public struct UnsupportedModelError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Generate.UnsupportedModelError"
            public let providerID: String
            public let modelID: String
            public let capability: String
            public let message: String
            public init(providerID: String, modelID: String, capability: String, message: String) {
                self.providerID = providerID; self.modelID = modelID; self.capability = capability; self.message = message
            }
            public var description: String { message }
        }

        // parity: core/src/generate.ts#InvalidRequestError [status=implemented hash=5a21ad71d08c]
        public struct InvalidRequestError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Generate.InvalidRequestError"
            public let message: String
            public let field: String?
            public init(message: String, field: String? = nil) { self.message = message; self.field = field }
            public var description: String { message }
        }

        // parity: core/src/generate.ts#ProviderFailure [status=implemented hash=58521c45c415]
        public enum ProviderFailure: String, Equatable, Hashable, Sendable, Codable {
            case authentication
            case rateLimit = "rate_limit"
            case contentFilter = "content_filter"
            case invalidRequest = "invalid_request"
            case overloaded
            case provider
        }

        // parity: core/src/generate.ts#ProviderRequestError [status=implemented hash=a777f0008974]
        public struct ProviderRequestError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Generate.ProviderRequestError"
            public let providerID: String
            public let reason: ProviderFailure
            public let message: String
            public let status: Int?
            public let retryAfterMs: Int?

            public init(
                providerID: String,
                reason: ProviderFailure,
                message: String,
                status: Int? = nil,
                retryAfterMs: Int? = nil
            ) {
                self.providerID = providerID
                self.reason = reason
                self.message = message
                self.status = status
                self.retryAfterMs = retryAfterMs
            }

            public var description: String { message }
        }

        // parity: core/src/generate.ts#Error [status=implemented hash=b19874bdc02a]
        public enum GenerateError: Swift.Error, Equatable, Hashable, Sendable {
            case modelNotFound(ModelNotFoundError)
            case unsupportedModel(UnsupportedModelError)
            case invalidRequest(InvalidRequestError)
            case providerRequest(ProviderRequestError)
            case unavailable(UnavailableError)
        }

        // parity: core/src/generate.ts#Interface [status=implemented hash=e71c08aad387]
        public protocol Interface: Sendable {
            func text(_ input: TextInput) async throws -> String
            func image(_ input: GenerateSchema.ImageRequest) async throws -> GenerateSchema.ImageResult
            func decisions(_ input: GenerateSchema.DecisionRequest) async throws -> GenerateSchema.DecisionResult
            func videoStart(_ input: VideoInput) async throws -> String
            func videoStatus(model: ModelSchema.Ref, id: String) async throws -> String
            func videoResult(model: ModelSchema.Ref, id: String) async throws -> [VideoFile]
        }

        // parity: core/src/generate.ts#Service [status=implemented hash=f4b67ebd474d]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/Generate"
            private let resolver: any CoreModel.Resolver.Interface
            private let textHandler: (@Sendable (CoreModel.Resolver.Resolved, String) async throws -> String)?

            public init(
                resolver: any CoreModel.Resolver.Interface,
                textHandler: (@Sendable (CoreModel.Resolver.Resolved, String) async throws -> String)? = nil
            ) {
                self.resolver = resolver
                self.textHandler = textHandler
            }

            public func text(_ input: TextInput) async throws -> String {
                guard let resolved = try await resolver.resolve(input.model) else {
                    if let ref = input.model {
                        throw ModelNotFoundError(providerID: ref.providerID.rawValue, modelID: ref.id.rawValue)
                    }
                    throw UnavailableError(message: "No model specified and no supported model is available")
                }
                guard let textHandler else {
                    throw UnavailableError(message: "No LLM execution handler configured for Generate.text", service: resolved.ref.providerID.rawValue)
                }
                return try await textHandler(resolved, input.prompt)
            }

            public func image(_ input: GenerateSchema.ImageRequest) async throws -> GenerateSchema.ImageResult {
                throw ModelNotFoundError(providerID: input.model.providerID.rawValue, modelID: input.model.id.rawValue)
            }

            public func decisions(_ input: GenerateSchema.DecisionRequest) async throws -> GenerateSchema.DecisionResult {
                throw ModelNotFoundError(providerID: input.model.providerID.rawValue, modelID: input.model.id.rawValue)
            }

            public func videoStart(_ input: VideoInput) async throws -> String {
                throw ModelNotFoundError(providerID: input.model.providerID.rawValue, modelID: input.model.id.rawValue)
            }

            public func videoStatus(model: ModelSchema.Ref, id: String) async throws -> String {
                _ = id
                throw ModelNotFoundError(providerID: model.providerID.rawValue, modelID: model.id.rawValue)
            }

            public func videoResult(model: ModelSchema.Ref, id: String) async throws -> [VideoFile] {
                _ = id
                throw ModelNotFoundError(providerID: model.providerID.rawValue, modelID: model.id.rawValue)
            }
        }

        // parity: core/src/generate.ts#layer [status=implemented hash=fd273a1bee2e]
        public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { deps, _ in
            let resolver = deps.get(CoreModel.Resolver.Service.serviceKey, as: CoreModel.Resolver.Service.self)
                ?? CoreModel.Resolver.Service(providers: CoreProvider.Provider.Service(), models: CoreModel.Model.Service(providers: CoreProvider.Provider.Service()))
            return LayerNode.Output([Service.serviceKey: Service(resolver: resolver)])
        }

        // parity: core/src/generate.ts#node [status=implemented hash=f2d6d71c42fa]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(Service.serviceKey, layer, [CoreModel.Resolver.node])
    }

    // MARK: - core/src/image.ts & core/src/image/*

    public enum Image {
        // parity: core/src/image.ts#ResizerUnavailableError [status=implemented hash=80b3db38a9cc]
        public struct ResizerUnavailableError: Swift.Error, Equatable, Hashable, Sendable {
            public static let tag = "Image.ResizerUnavailableError"
            public init() {}
        }

        // parity: core/src/image.ts#DecodeError [status=implemented hash=5690e22835be]
        public struct DecodeError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Image.DecodeError"
            public let resource: String
            public init(resource: String) { self.resource = resource }
            public var message: String { "Image could not be decoded: \(resource)" }
            public var description: String { message }
        }

        // parity: core/src/image.ts#SizeError [status=implemented hash=a202ac8b1682]
        public struct SizeError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Image.SizeError"
            public let resource: String
            public let width: Int
            public let height: Int
            public let bytes: Int
            public let maxWidth: Int
            public let maxHeight: Int
            public let maxBytes: Int

            public init(resource: String, width: Int, height: Int, bytes: Int, maxWidth: Int, maxHeight: Int, maxBytes: Int) {
                self.resource = resource; self.width = width; self.height = height; self.bytes = bytes
                self.maxWidth = maxWidth; self.maxHeight = maxHeight; self.maxBytes = maxBytes
            }

            public var message: String {
                "Image \(resource) is \(width)x\(height) with base64 size \(bytes), exceeding configured limits \(maxWidth)x\(maxHeight)/\(maxBytes) bytes"
            }

            public var description: String { message }
        }

        // parity: core/src/image.ts#Limits [status=implemented hash=90bf96c1958f]
        public struct Limits: Equatable, Hashable, Sendable, Codable {
            public var autoResize: Bool
            public var maxWidth: Int
            public var maxHeight: Int
            public var maxBase64Bytes: Int

            public init(
                autoResize: Bool = true,
                maxWidth: Int = 2_000,
                maxHeight: Int = 2_000,
                maxBase64Bytes: Int = 5 * 1024 * 1024
            ) {
                self.autoResize = autoResize
                self.maxWidth = maxWidth
                self.maxHeight = maxHeight
                self.maxBase64Bytes = maxBase64Bytes
            }
        }

        // parity: core/src/image.ts#Editor [status=implemented hash=b5d7c466a43a]
        public final class Editor: @unchecked Sendable {
            internal var limits: Limits
            internal init(limits: Limits) { self.limits = limits }
            public func configure(autoResize: Bool? = nil, maxWidth: Int? = nil, maxHeight: Int? = nil, maxBase64Bytes: Int? = nil) {
                if let autoResize { limits.autoResize = autoResize }
                if let maxWidth { limits.maxWidth = maxWidth }
                if let maxHeight { limits.maxHeight = maxHeight }
                if let maxBase64Bytes { limits.maxBase64Bytes = maxBase64Bytes }
            }
        }

        public struct Base64Content: Equatable, Hashable, Sendable, Codable {
            public let content: String
            public let mime: String

            public init(content: String, mime: String) {
                self.content = content
                self.mime = mime
            }
        }

        // parity: core/src/image.ts#Interface [status=implemented hash=74c5414030fb]
        public protocol Interface: CoreState.Transformable where Editor == Image.Editor {
            func normalize(resource: String, content: Base64Content) async throws -> Base64Content
        }

        // parity: core/src/image.ts#Service [status=implemented hash=bb819c216a6b]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/Image"
            private let state: CoreState.Store<Limits, Editor>

            public init() {
                self.state = CoreState.create(CoreState.Options(
                    name: "image",
                    initial: { Limits() },
                    makeEditor: { Editor(limits: $0) },
                    commitEditor: { $0.limits }
                ))
            }

            @discardableResult
            public func transform(_ update: @escaping @Sendable (Editor) throws -> Void) async throws -> CoreState.Registration {
                try await state.transform(update)
            }

            public func reload() async { await state.reload() }

            public func normalize(resource: String, content: Base64Content) async throws -> Base64Content {
                let limits = state.get()
                let result = PhotonNormalize.normalize(photon: PhotonNormalize.NativePhoton(), content: content, limits: limits)
                switch result {
                case .unchanged: return content
                case .content(let updated): return updated
                case .decodeError: throw DecodeError(resource: resource)
                case .sizeError(let size):
                    throw SizeError(
                        resource: resource,
                        width: size.width,
                        height: size.height,
                        bytes: size.bytes,
                        maxWidth: size.maxWidth,
                        maxHeight: size.maxHeight,
                        maxBytes: size.maxBytes
                    )
                }
            }
        }

        // parity: core/src/image.ts#node [status=implemented hash=9e1ad9da14bc]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer { _, _ in LayerNode.Output([Service.serviceKey: Service()]) },
            []
        )

        public enum Notice {
            // parity: core/src/image/notice.ts#text [status=implemented hash=65d9f8d14d6a]
            public static func text(id: String, state: String, body: String) -> String {
                "<image id=\"\(id)\" state=\"\(state)\">\n\(body)\n</image>"
            }
        }

        public enum PhotonNormalize {
            // parity: core/src/image/photon-normalize.ts#Photon [status=adapted hash=b772081e9cb4]
            public protocol Photon: Sendable {
                func dimensions(of bytes: [UInt8]) -> (width: Int, height: Int)?
            }

            public struct NativePhoton: Photon, Sendable {
                public init() {}
                public func dimensions(of bytes: [UInt8]) -> (width: Int, height: Int)? {
                    // Parse PNG IHDR header (bytes 16..23) or GIF header (bytes 6..9)
                    if bytes.count >= 24 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
                        let w = (Int(bytes[16]) << 24) | (Int(bytes[17]) << 16) | (Int(bytes[18]) << 8) | Int(bytes[19])
                        let h = (Int(bytes[20]) << 24) | (Int(bytes[21]) << 16) | (Int(bytes[22]) << 8) | Int(bytes[23])
                        return (w, h)
                    }
                    if bytes.count >= 10 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 {
                        let w = Int(bytes[6]) | (Int(bytes[7]) << 8)
                        let h = Int(bytes[8]) | (Int(bytes[9]) << 8)
                        return (w, h)
                    }
                    return nil
                }
            }

            // parity: core/src/image/photon-normalize.ts#Content [status=implemented hash=1e457b2ad982]
            public typealias Content = Base64Content

            // parity: core/src/image/photon-normalize.ts#Size [status=implemented hash=a6f3d31049ef]
            public struct Size: Equatable, Hashable, Sendable {
                public let width: Int
                public let height: Int
                public let bytes: Int
                public let maxWidth: Int
                public let maxHeight: Int
                public let maxBytes: Int

                public init(width: Int, height: Int, bytes: Int, maxWidth: Int, maxHeight: Int, maxBytes: Int) {
                    self.width = width; self.height = height; self.bytes = bytes
                    self.maxWidth = maxWidth; self.maxHeight = maxHeight; self.maxBytes = maxBytes
                }
            }

            // parity: core/src/image/photon-normalize.ts#Result [status=implemented hash=66eeb7abdce2]
            public enum Result: Equatable, Hashable, Sendable {
                case unchanged
                case content(Content)
                case decodeError
                case sizeError(Size)
            }

            // parity: core/src/image/photon-normalize.ts#available [status=adapted hash=e4e768d72c8e]
            public static let available: Bool = true

            // parity: core/src/image/photon-normalize.ts#load [status=adapted hash=d8be61b06640]
            public static func load() async throws -> any Photon {
                NativePhoton()
            }

            // parity: core/src/image/photon-normalize.ts#normalize [status=adapted hash=5aa797cd4e31]
            public static func normalize(photon: any Photon, content: Content, limits: Limits) -> Result {
                guard let rawBytes = try? base64ToBytes(content.content) else {
                    return .decodeError
                }
                let byteLen = content.content.utf8.count
                let dims = photon.dimensions(of: rawBytes) ?? (width: 1, height: 1)
                let fits = dims.width <= limits.maxWidth && dims.height <= limits.maxHeight && byteLen <= limits.maxBase64Bytes
                if fits { return .unchanged }
                return .sizeError(Size(
                    width: dims.width,
                    height: dims.height,
                    bytes: byteLen,
                    maxWidth: limits.maxWidth,
                    maxHeight: limits.maxHeight,
                    maxBytes: limits.maxBase64Bytes
                ))
            }
        }

        public enum PhotonWorker {
            // parity: core/src/image/photon-worker.ts#Request [status=implemented hash=f9b03164f3a5]
            public struct Request: Equatable, Hashable, Sendable {
                public let content: PhotonNormalize.Content
                public let limits: Limits
                public init(content: PhotonNormalize.Content, limits: Limits) { self.content = content; self.limits = limits }
            }

            // parity: core/src/image/photon-worker.ts#Reply [status=implemented hash=5ca9a88cc927]
            public enum Reply: Equatable, Hashable, Sendable {
                case ready
                case done(result: PhotonNormalize.Result)
            }
        }

        public enum Photon {
            // parity: core/src/image/photon.ts#WorkerUnavailableError [status=implemented hash=db37301166cd]
            public struct WorkerUnavailableError: Swift.Error, Sendable {
                public static let tag = "Image.Photon.WorkerUnavailableError"
                public let message: String
                public init(message: String) { self.message = message }
            }

            // parity: core/src/image/photon.ts#spawnWorker [status=adapted hash=eb832d9269c3]
            public static func spawnWorker() async throws -> any PhotonNormalize.Photon {
                try await PhotonNormalize.load()
            }

            // parity: core/src/image/photon.ts#makeWith [status=adapted hash=983e2203c33a]
            public static func makeWith(
                photon: any PhotonNormalize.Photon
            ) -> @Sendable (String, PhotonNormalize.Content, Limits) throws -> PhotonNormalize.Content {
                { resource, content, limits in
                    switch PhotonNormalize.normalize(photon: photon, content: content, limits: limits) {
                    case .unchanged: return content
                    case .content(let updated): return updated
                    case .decodeError: throw DecodeError(resource: resource)
                    case .sizeError(let size):
                        throw SizeError(
                            resource: resource,
                            width: size.width,
                            height: size.height,
                            bytes: size.bytes,
                            maxWidth: size.maxWidth,
                            maxHeight: size.maxHeight,
                            maxBytes: size.maxBytes
                        )
                    }
                }
            }

            // parity: core/src/image/photon.ts#make [status=adapted hash=1c66bb0e4c2e]
            public static let make: @Sendable (String, PhotonNormalize.Content, Limits) throws -> PhotonNormalize.Content =
                makeWith(photon: PhotonNormalize.NativePhoton())
        }
    }

    // MARK: - core/src/video-generation.ts

    public enum VideoGeneration {
        // parity: core/src/video-generation.ts#NotFoundError [status=implemented hash=84627ebb1e63]
        public struct NotFoundError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "VideoGeneration.NotFoundError"
            public let id: String
            public let message: String
            public init(id: String, message: String? = nil) {
                self.id = id
                self.message = message ?? "Video job not found: \(id)"
            }
            public var description: String { message }
        }

        // parity: core/src/video-generation.ts#StartOptions [status=implemented hash=cd693d066010]
        public struct StartOptions: Equatable, Hashable, Sendable {
            public let location: LocationSchema.Ref?
            public init(location: LocationSchema.Ref? = nil) { self.location = location }
        }

        // parity: core/src/video-generation.ts#Interface [status=implemented hash=29491ec003be]
        public protocol Interface: Sendable {
            func start(_ input: GenerateSchema.VideoRequest, options: StartOptions?) async throws -> GenerateSchema.VideoRunning
            func get(_ id: GenerateSchema.VideoID) async throws -> GenerateSchema.VideoJob
        }

        // parity: core/src/video-generation.ts#Service [status=implemented hash=07621d6f3e7b]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/VideoGeneration"
            private let startFn: @Sendable (GenerateSchema.VideoRequest, StartOptions?) async throws -> GenerateSchema.VideoRunning
            private let getFn: @Sendable (GenerateSchema.VideoID) async throws -> GenerateSchema.VideoJob

            public init(
                start: @escaping @Sendable (GenerateSchema.VideoRequest, StartOptions?) async throws -> GenerateSchema.VideoRunning,
                get: @escaping @Sendable (GenerateSchema.VideoID) async throws -> GenerateSchema.VideoJob
            ) {
                self.startFn = start
                self.getFn = get
            }

            public func start(_ input: GenerateSchema.VideoRequest, options: StartOptions? = nil) async throws -> GenerateSchema.VideoRunning {
                try await startFn(input, options)
            }

            public func get(_ id: GenerateSchema.VideoID) async throws -> GenerateSchema.VideoJob {
                try await getFn(id)
            }
        }

        // parity: core/src/video-generation.ts#unsupportedLayer [status=implemented hash=3519bec2588c]
        public static let unsupportedLayer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer.succeed(
            key: Service.serviceKey,
            value: Service(
                start: { _, _ in
                    throw Generate.UnavailableError(message: "Video generation is not supported on this host")
                },
                get: { id in
                    throw NotFoundError(id: id.rawValue)
                }
            )
        )

        // parity: core/src/video-generation.ts#node [status=implemented hash=8715487275f2]
        public static let node: LayerNode.Provider = AppNode.makeGlobalNode(Service.serviceKey, unsupportedLayer, [])
    }

    // MARK: - core/src/voice.ts

    public enum Voice {
        // parity: core/src/voice.ts#ModelInfo [status=implemented hash=d3cffec903af]
        public struct ModelInfo: Equatable, Hashable, Sendable, Codable {
            public let model: String
            public let provider: String
            public let transports: [String]
            public let available: Bool

            public init(model: String, provider: String, transports: [String], available: Bool) {
                self.model = model
                self.provider = provider
                self.transports = transports
                self.available = available
            }
        }

        // parity: core/src/voice.ts#Models [status=implemented hash=3d6c234afe00]
        public struct Models: Equatable, Hashable, Sendable, Codable {
            public let models: [ModelInfo]
            public let defaultModel: String?

            public init(models: [ModelInfo], defaultModel: String? = nil) {
                self.models = models
                self.defaultModel = defaultModel
            }
        }

        // parity: core/src/voice.ts#SessionInput [status=implemented hash=f19737e801ce]
        public struct SessionInput: Equatable, Hashable, Sendable {
            public let model: String
            public let transport: String

            public init(model: String, transport: String) {
                self.model = model
                self.transport = transport
            }
        }

        // parity: core/src/voice.ts#InvalidRequestError [status=implemented hash=b99548b66aad]
        public struct InvalidRequestError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Voice.InvalidRequestError"
            public let message: String
            public init(message: String) { self.message = message }
            public var description: String { message }
        }

        // parity: core/src/voice.ts#UnavailableError [status=implemented hash=0891c1478b32]
        public struct UnavailableError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Voice.UnavailableError"
            public let message: String
            public let service: String?
            public init(message: String, service: String? = nil) { self.message = message; self.service = service }
            public var description: String { message }
        }

        // parity: core/src/voice.ts#Error [status=implemented hash=6aac772125a7]
        public enum VoiceError: Swift.Error, Equatable, Hashable, Sendable {
            case invalidRequest(InvalidRequestError)
            case unavailable(UnavailableError)
        }

        // parity: core/src/voice.ts#Interface [status=implemented hash=5ae593b1f778]
        public protocol Interface: Sendable {
            func models() async throws -> Models
            func session(_ input: SessionInput) async throws -> [String: JSONValue]
        }

        // parity: core/src/voice.ts#Service [status=implemented hash=55646e581b21]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/Voice"
            private let integrations: any Integration.Interface

            private static let engines: [(id: String, model: String, provider: String, transports: [String])] = [
                ("openai-live", "gpt-realtime", "openai", ["webrtc", "websocket"]),
                ("xai-voice", "grok-voice", "xai", ["websocket"]),
                ("google-live", "gemini-live", "google", ["websocket"]),
            ]

            public init(integrations: any Integration.Interface) {
                self.integrations = integrations
            }

            public func models() async throws -> Models {
                var list: [ModelInfo] = []
                for engine in Self.engines {
                    let direct = try? await integrations.get(IntegrationID(rawValue: engine.provider))
                    let hasDirect = !(direct?.connections.isEmpty ?? true)
                    var provider = engine.provider
                    var available = hasDirect
                    if !available && engine.id == "openai-live" {
                        let hosted = try? await integrations.get(IntegrationID(rawValue: "opencode"))
                        if !(hosted?.connections.isEmpty ?? true) {
                            provider = "opencode"
                            available = true
                        }
                    }
                    list.append(ModelInfo(model: engine.model, provider: provider, transports: engine.transports, available: available))
                }
                let def = list.first(where: \.available)?.model
                return Models(models: list, defaultModel: def)
            }

            public func session(_ input: SessionInput) async throws -> [String: JSONValue] {
                guard let engine = Self.engines.first(where: { $0.model == input.model }) else {
                    throw InvalidRequestError(message: "Unsupported voice model: \(input.model)")
                }
                let available = try await models().models.first(where: { $0.model == engine.model })?.available ?? false
                guard available else {
                    throw UnavailableError(message: "Voice needs an API key for \(engine.provider)", service: engine.provider)
                }
                return [
                    "model": .string(engine.model),
                    "provider": .string(engine.provider),
                    "transport": .string(input.transport),
                ]
            }
        }

        // parity: core/src/voice.ts#layer [status=implemented hash=89cfc6f6cc65]
        public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { deps, _ in
            let integrations = try deps.get(Integration.Service.serviceKey, as: Integration.Service.self)
                ?? Integration.Service(credentials: CoreProvider.Credential.Service.inMemory())
            return LayerNode.Output([Service.serviceKey: Service(integrations: integrations)])
        }

        // parity: core/src/voice.ts#node [status=implemented hash=3d1e48cf38ae]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(Service.serviceKey, layer, [Integration.node])
    }
}

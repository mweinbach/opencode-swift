#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeUtil

// MARK: - Logging (`observability/logging.ts`)

public enum OpenCodeLogLevel: String, Equatable, Hashable, Sendable, Codable, Comparable {
    case debug = "Debug"
    case info = "Info"
    case warn = "Warn"
    case error = "Error"

    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: OpenCodeLogLevel, rhs: OpenCodeLogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct StructuredLogRecord: Equatable, Sendable {
    public let timestamp: String
    public let level: OpenCodeLogLevel
    public let message: String
    public let fields: [(String, String)]
    public let cause: String?

    public init(
        timestamp: String,
        level: OpenCodeLogLevel,
        message: String,
        fields: [(String, String)] = [],
        cause: String? = nil
    ) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.fields = fields
        self.cause = cause
    }

    public static func == (lhs: StructuredLogRecord, rhs: StructuredLogRecord) -> Bool {
        lhs.timestamp == rhs.timestamp
            && lhs.level == rhs.level
            && lhs.message == rhs.message
            && lhs.cause == rhs.cause
            && lhs.fields.count == rhs.fields.count
            && zip(lhs.fields, rhs.fields).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

public protocol LogSink: Sendable {
    func log(_ record: StructuredLogRecord) async
}

public enum Logging {
    // parity: util/src/observability/logging.ts#LOG_MAX_BYTES [status=implemented hash=f3573128981c]
    public static let LOG_MAX_BYTES: Int = 50 * 1024 * 1024

    // parity: util/src/observability/logging.ts#LOG_KEEP_BYTES [status=implemented hash=737076a41292]
    public static let LOG_KEEP_BYTES: Int = 25 * 1024 * 1024

    // parity: util/src/observability/logging.ts#LOG_TRIM_INTERVAL [status=implemented hash=b074aed6964f]
    public static let LOG_TRIM_INTERVAL: String = "1 hour"

    // parity: util/src/observability/logging.ts#LOG_TRIM_LOCK_STALE_MS [status=implemented hash=5c36b4350f7a]
    public static let LOG_TRIM_LOCK_STALE_MS: Int = 5 * 60 * 1000

    /// Formats a log record in upstream's logfmt format (`timestamp=... level=... run=... message=...`).
    public static func formatRecord(_ record: StructuredLogRecord, runID: String = ObservabilityShared.runID()) -> String {
        var pairs: [(String, String)] = [
            ("timestamp", record.timestamp),
            ("level", record.level.rawValue),
            ("run", runID),
            ("message", record.message),
        ]
        if let cause = record.cause {
            pairs.append(("cause", cause))
        }
        pairs.append(contentsOf: record.fields)
        return pairs.map { key, value in
            "\(key)=\(formatValue(value))"
        }.joined(separator: " ")
    }

    private static func formatValue(_ value: String) -> String {
        if !value.isEmpty && value.allSatisfy({ ch in
            !ch.isWhitespace && ch != "=" && ch != "\"" && ch != "\\"
        }) {
            return value
        }
        return PureJSON.stringifyCompact(.string(value))
    }

    /// Computes the shared log file path for a given channel (`opencode.log` for releases, `opencode-<channel>.log` locally).
    // parity: util/src/observability/logging.ts#file [status=implemented hash=f6a3a0f9865c]
    public static func file(
        local: Bool = true,
        channel: String = "local",
        logDirectory: String? = nil
    ) -> String {
        let dir = logDirectory ?? Global.Path.log
        if !local {
            return "\(dir)/opencode.log"
        }
        let sanitized = String(channel.map { ch in
            (ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-")) ? ch : "-"
        })
        return "\(dir)/opencode-\(sanitized).log"
    }

    public final class FileLogSink: LogSink, Sendable {
        public let target: String
        public let runID: String
        private let fileSystem: any OpenCodeFileSystem

        public init(target: String, runID: String, fileSystem: any OpenCodeFileSystem) {
            self.target = target
            self.runID = runID
            self.fileSystem = fileSystem
        }

        public func log(_ record: StructuredLogRecord) async {
            let line = Logging.formatRecord(record, runID: runID) + "\n"
            let existing = (try? await fileSystem.readFile(at: target)) ?? []
            var next = existing
            next.append(contentsOf: line.utf8)
            try? await fileSystem.writeFile(next, to: target, createDirectories: true)
        }
    }

    // parity: util/src/observability/logging.ts#fileLogger [status=implemented hash=a2dc14035db4]
    public static func fileLogger(
        target: String = file(),
        id: String = ObservabilityShared.runID(),
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
    ) -> FileLogSink {
        FileLogSink(target: target, runID: id, fileSystem: fileSystem)
    }

    /// Compacts `target` in place when its size exceeds `max`, retaining approximately the trailing `keep` bytes
    /// aligned forward to the next newline boundary.
    // parity: util/src/observability/logging.ts#trim [status=implemented hash=4ad03e5456c5]
    public static func trim(
        target: String,
        max maxBytes: Int = LOG_MAX_BYTES,
        keep keepBytes: Int = LOG_KEEP_BYTES,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        nowMs: @Sendable () -> Int64 = { Flock.currentEpochMs() }
    ) async throws {
        let lock = "\(target).trim"
        let acquired: Bool
        do {
            try await fileSystem.makeDirectory(at: lock, recursive: false)
            acquired = true
        } catch PlatformError.alreadyExists {
            if let info = try? await fileSystem.stat(at: lock),
               nowMs() - info.modifiedAtMs >= Int64(LOG_TRIM_LOCK_STALE_MS) {
                try? await fileSystem.remove(at: lock)
            }
            acquired = false
        }
        guard acquired else { return }
        do {
            let info = try await fileSystem.stat(at: target)
            guard Int(info.size) > maxBytes else {
                try? await fileSystem.remove(at: lock)
                return
            }
            let data = try await fileSystem.readFile(at: target)
            guard data.count > maxBytes else {
                try? await fileSystem.remove(at: lock)
                return
            }

            let cut = max(0, data.count - keepBytes)
            var start = data.count
            for idx in cut..<data.count {
                if data[idx] == 0x0A {
                    start = idx + 1
                    break
                }
            }
            let retained = start < data.count ? Array(data[start...]) : []
            try await fileSystem.writeFile(retained, to: target, createDirectories: false)
            try? await fileSystem.remove(at: lock)
        } catch {
            try? await fileSystem.remove(at: lock)
            throw error
        }
    }

    // parity: util/src/observability/logging.ts#minimumLogLevel [status=implemented hash=ca840d0315fb]
    public static func minimumLogLevel(
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) -> OpenCodeLogLevel {
        switch environment.variable("OPENCODE_LOG_LEVEL")?.uppercased() {
        case "DEBUG": return .debug
        case "INFO": return .info
        case "WARN": return .warn
        case "ERROR": return .error
        default: return .info
        }
    }

    // parity: util/src/observability/logging.ts#loggers [status=implemented hash=325c1afd5402]
    public static func loggers(
        local: Bool = true,
        channel: String = "local",
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
    ) -> [any LogSink] {
        [fileLogger(target: file(local: local, channel: channel), fileSystem: fileSystem)]
    }
}

// MARK: - OTLP (`observability/otlp.ts`)

public enum Otlp {
    // parity: util/src/observability/otlp.ts#Options [status=implemented hash=43e10659d3ee]
    public struct Options: Equatable, Hashable, Sendable, Codable {
        public let endpoint: String?
        public let headers: String?

        public init(endpoint: String? = nil, headers: String? = nil) {
            self.endpoint = endpoint
            self.headers = headers
        }
    }

    // parity: util/src/observability/otlp.ts#App [status=implemented hash=8dbb344251d2]
    public struct App: Equatable, Hashable, Sendable, Codable {
        public let client: String
        public let version: String
        public let channel: String

        public init(client: String = "opencode", version: String = "unknown", channel: String = "local") {
            self.client = client
            self.version = version
            self.channel = channel
        }
    }

    public struct Resource: Equatable, Sendable, Codable {
        public let serviceName: String
        public let serviceVersion: String
        public let attributes: [String: String]

        public init(serviceName: String, serviceVersion: String, attributes: [String: String]) {
            self.serviceName = serviceName
            self.serviceVersion = serviceVersion
            self.attributes = attributes
        }
    }

    public final class OtlpLogSink: LogSink, Sendable {
        public let url: String
        public let resource: Resource
        public let headers: [String: String]
        private let transport: (any HTTPTransport)?

        public init(url: String, resource: Resource, headers: [String: String], transport: (any HTTPTransport)? = nil) {
            self.url = url
            self.resource = resource
            self.headers = headers
            self.transport = transport
        }

        public func log(_ record: StructuredLogRecord) async {
            guard let transport else { return }
            let body = Logging.formatRecord(record)
            var reqHeaders = headers
            reqHeaders["Content-Type"] = "application/json"
            _ = try? await transport.send(HTTPRequest(
                method: "POST",
                url: url,
                headers: reqHeaders,
                body: Array(body.utf8)
            ))
        }
    }

    public static func parseHeaders(_ value: String?) -> [String: String]? {
        guard let value, !value.isEmpty else { return nil }
        var result: [String: String] = [:]
        for entry in value.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if let first = parts.first {
                result[String(first)] = parts.count > 1 ? String(parts[1]) : ""
            }
        }
        return result
    }

    private static func resourceAttributes(environment: any EnvironmentProviding) -> [String: String] {
        guard let raw = environment.variable("OTEL_RESOURCE_ATTRIBUTES"), !raw.isEmpty else {
            return [:]
        }
        var attrs: [String: String] = [:]
        for entry in raw.split(separator: ",", omittingEmptySubsequences: false) {
            guard let eq = entry.firstIndex(of: "="), eq != entry.startIndex else {
                return [:]
            }
            let rawKey = String(entry[..<eq])
            let rawVal = String(entry[entry.index(after: eq)...])
            guard let key = rawKey.removingPercentEncoding,
                  let val = rawVal.removingPercentEncoding else {
                return [:]
            }
            attrs[key] = val
        }
        return attrs
    }

    // parity: util/src/observability/otlp.ts#resource [status=implemented hash=fda9351650d9]
    public static func resource(
        app: App = App(),
        environment: any EnvironmentProviding = SystemEnvironment.shared,
        runID: String = ObservabilityShared.runID()
    ) -> Resource {
        var attrs = resourceAttributes(environment: environment)
        attrs["deployment.environment.name"] = app.channel
        attrs["opencode.client"] = app.client
        attrs["opencode.run"] = runID
        attrs["service.instance.id"] = runID
        return Resource(serviceName: "opencode", serviceVersion: app.version, attributes: attrs)
    }

    // parity: util/src/observability/otlp.ts#loggers [status=implemented hash=371686b89cd8]
    public static func loggers(
        options: Options?,
        app: App,
        transport: (any HTTPTransport)? = nil
    ) -> [OtlpLogSink] {
        guard let endpoint = options?.endpoint, !endpoint.isEmpty else { return [] }
        return [
            OtlpLogSink(
                url: "\(endpoint)/v1/logs",
                resource: resource(app: app),
                headers: parseHeaders(options?.headers) ?? [:],
                transport: transport
            ),
        ]
    }

    // parity: util/src/observability/otlp.ts#tracingLayer [status=implemented hash=f691d9439716]
    public static func tracingLayer(options: Options?, app: App) -> LayerNode.ExecutableLayer {
        guard let endpoint = options?.endpoint, !endpoint.isEmpty else {
            return LayerNode.ExecutableLayer.empty
        }
        let res = resource(app: app)
        return LayerNode.ExecutableLayer.succeed(key: "@opencode/OtlpTracing", value: "\(endpoint)/v1/traces:\(res.serviceName)")
    }
}

// MARK: - Observability (`observability.ts`)

public enum Observability {
    // parity: util/src/observability.ts#Options [status=implemented hash=0a2aa998f1ba]
    public struct Options: Equatable, Hashable, Sendable, Codable {
        public let endpoint: String?
        public let headers: String?
        public let client: String?
        public let version: String?
        public let channel: String?

        public init(
            endpoint: String? = nil,
            headers: String? = nil,
            client: String? = nil,
            version: String? = nil,
            channel: String? = nil
        ) {
            self.endpoint = endpoint
            self.headers = headers
            self.client = client
            self.version = version
            self.channel = channel
        }
    }

    public struct Service: Sendable {
        public static let serviceKey = "@opencode/Observability"
        public let minimumLevel: OpenCodeLogLevel
        public let sinks: [any LogSink]

        public init(minimumLevel: OpenCodeLogLevel, sinks: [any LogSink]) {
            self.minimumLevel = minimumLevel
            self.sinks = sinks
        }
    }

    // parity: util/src/observability.ts#layer [status=implemented hash=5bdc4711a997]
    public static func layer(
        options: Options? = nil,
        environment: any EnvironmentProviding = SystemEnvironment.shared,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
    ) -> LayerNode.ExecutableLayer {
        LayerNode.ExecutableLayer { _, _ in
            let opts = options ?? Options(
                endpoint: environment.variable("OTEL_EXPORTER_OTLP_ENDPOINT"),
                headers: environment.variable("OTEL_EXPORTER_OTLP_HEADERS")
            )
            let app = Otlp.App(
                client: opts.client ?? "opencode",
                version: opts.version ?? "unknown",
                channel: opts.channel ?? "local"
            )
            let localSinks = Logging.loggers(
                local: app.channel == "local",
                channel: app.channel,
                fileSystem: fileSystem
            )
            let otlpSinks: [any LogSink] = Otlp.loggers(
                options: Otlp.Options(endpoint: opts.endpoint, headers: opts.headers),
                app: app
            )
            let svc = Service(
                minimumLevel: Logging.minimumLogLevel(environment: environment),
                sinks: localSinks + otlpSinks
            )
            return LayerNode.Output([Service.serviceKey: svc])
        }
    }

    // parity: util/src/observability.ts#node [status=implemented hash=3e6a40fdb0c8]
    public static let node: LayerNode.Provider = LayerNode.make(
        name: "observability",
        layer: layer(),
        deps: []
    )
}

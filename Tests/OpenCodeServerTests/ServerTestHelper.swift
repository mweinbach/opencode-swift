#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer
import OpenCodeUtil

/// Helper container holding a fully wired in-memory `ServerFetch.Handle` and `OpenCodeClient`
/// for deterministic cross-platform tests (no `import Testing` per macOS CLT cross-import rule).
struct TestServerHarness: Sendable {
    let handle: ServerFetch.Handle
    let client: OpenCodeClient
    let fileSystem: InMemoryFileSystem
    let rootDir: String
    let password: String?

    var runtime: ServerAppRuntime { handle.runtime }
    var router: ServerRouter { handle.router }
    var transport: ServerInProcessTransport { handle.transport }

    func close() async {
        await handle.close()
    }
}

enum ServerTestFixture {
    static func makeHarness(
        password: String? = nil,
        cors: [String]? = nil,
        configContent: String? = nil,
        initialFiles: [String: [UInt8]] = [:],
        rootDir: String = "/workspace",
        onLocationBoot: ServerAppRuntime.LocationCustomizer? = nil
    ) async throws -> TestServerHarness {
        var files = initialFiles
        if files["\(rootDir)/.keep"] == nil {
            files["\(rootDir)/.keep"] = Array("ok".utf8)
        }
        let fs = InMemoryFileSystem(initialFiles: files)
        try await fs.makeDirectory(at: rootDir, recursive: true)
        try await fs.makeDirectory(at: "/tmp/opencode-test/config", recursive: true)
        try await fs.makeDirectory(at: "/tmp/opencode-test/data", recursive: true)
        try await fs.makeDirectory(at: "/tmp/opencode-test/log", recursive: true)

        let globalOverrides = Global.Overrides(
            home: "/tmp/opencode-test/home",
            data: "/tmp/opencode-test/data",
            cache: "/tmp/opencode-test/cache",
            config: "/tmp/opencode-test/config",
            state: "/tmp/opencode-test/state",
            tmp: "/tmp/opencode-test/tmp",
            bin: "/tmp/opencode-test/bin",
            log: "/tmp/opencode-test/log",
            repos: "/tmp/opencode-test/repos"
        )

        let options = ServerOptions(
            app: ServerOptions.AppOptions(name: "opencode", version: "2.0.0-test", channel: "local"),
            password: password,
            cors: cors,
            events: ServerOptions.EventsOptions(persist: true),
            config: ServerOptions.ConfigOptions(
                directory: "/tmp/opencode-test/config",
                project: false,
                claude: false,
                content: configContent
            )
        )

        let handle = try await ServerFetch.make(
            options: options,
            boot: ServerFetch.BootOptions(
                fileSystem: fs,
                httpTransport: MockHTTPTransport(),
                environment: DictionaryEnvironment(variables: [:], homeDirectory: "/tmp/opencode-test/home", temporaryDirectory: "/tmp/opencode-test/tmp"),
                globalOverrides: globalOverrides,
                defaultDirectory: rootDir,
                onLocationBoot: onLocationBoot
            )
        )

        var headers: [String: String] = [:]
        if let password {
            headers["authorization"] = ClientHTTPHeaders.basicAuthorization(username: "opencode", password: password)
        }
        let client = OpenCodeClient(options: ClientOptions(
            baseUrl: "http://127.0.0.1:4096",
            transport: handle.transport,
            headers: headers
        ))
        return TestServerHarness(
            handle: handle,
            client: client,
            fileSystem: fs,
            rootDir: rootDir,
            password: password
        )
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
        try JSONDecoder().decode(type, from: Data(bytes))
    }

    static func decodeJSONObject(from bytes: [UInt8]) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(bytes))
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Array(try encoder.encode(value))
    }

    static func utf8String(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    static func insertReferencedMediaBlob(
        in db: any SQLiteDatabase,
        sessionID: SessionID,
        mime: String,
        data: [UInt8]
    ) throws -> String {
        let hash = Hash.sha256(data)
        let now = Flock.currentEpochMs()
        _ = try db.execute(
            """
            INSERT INTO `blob` (`hash`, `mime`, `bytes`, `width`, `height`, `data`, `time_created`)
            VALUES (?, ?, ?, NULL, NULL, ?, ?)
            ON CONFLICT (`hash`) DO NOTHING
            """,
            parameters: [.text(hash), .text(mime), .integer(Int64(data.count)), .blob(data), .integer(now)]
        )
        _ = try db.execute(
            """
            INSERT INTO `blob_ref` (`session_id`, `message_id`, `hash`, `seq`)
            VALUES (?, ?, ?, 1)
            ON CONFLICT DO NOTHING
            """,
            parameters: [.text(sessionID.rawValue), .text("msg_media_ref"), .text(hash)]
        )
        return hash
    }

    static func makeURLSessionTransport() -> URLSessionHTTPTransport {
        URLSessionHTTPTransport(configuration: URLSessionHTTPTransport.Configuration(
            timeoutIntervalForRequest: 15,
            timeoutIntervalForResource: 30
        ))
    }

    static func makeTCPClient(baseUrl: String, password: String, transport: URLSessionHTTPTransport) -> OpenCodeClient {
        OpenCodeClient(options: ClientOptions(
            baseUrl: baseUrl,
            transport: transport,
            headers: ["authorization": ClientHTTPHeaders.basicAuthorization(username: "opencode", password: password)]
        ))
    }

    static func makeTempWorkspaceDirectory() throws -> String {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-server-test-\(uuid().prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.path
    }

    static func removeTempDirectory(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Minimal in-memory `DurableObjectStorage` backed by SQLite `:memory:` for `ServerWorkerd` tests.
    final class MockDurableObjectStorage: CoreDatabaseWorkerdSQLite.DurableObjectStorage, Sendable {
        final class SqlAdapter: CoreDatabaseWorkerdSQLite.SqlStorage, Sendable {
            let db: any SQLiteDatabase
            init(db: any SQLiteDatabase) { self.db = db }
            func exec(_ query: String, bindings: [SQLiteValue]) throws -> [SQLiteRow] {
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if trimmed.hasPrefix("SELECT") || trimmed.contains("RETURNING") || trimmed.hasPrefix("PRAGMA") {
                    return try db.query(query, parameters: bindings)
                }
                if bindings.isEmpty && query.contains(";") {
                    try db.executeScript(query)
                    return []
                }
                _ = try db.execute(query, parameters: bindings)
                return []
            }
        }

        private let adapter: SqlAdapter
        let sql: any CoreDatabaseWorkerdSQLite.SqlStorage

        init() throws {
            let db = try SQLiteDatabaseFactory.open(path: ":memory:")
            let ad = SqlAdapter(db: db)
            self.adapter = ad
            self.sql = ad
        }

        func transactionSync<T>(_ closure: () throws -> T) throws -> T {
            try adapter.db.transaction(closure)
        }
    }

    /// Collects the first `count` events from an `AsyncThrowingStream` safely with a timeout.
    /// Optionally invokes `onFirstEvent` immediately after the first event (e.g. `server.connected`)
    /// is observed so callers can deterministically trigger follow-up actions without arbitrary sleeps.
    static func collectEvents<T: Sendable>(
        from stream: AsyncThrowingStream<T, any Error>,
        count: Int,
        timeoutMs: Int = 5_000,
        onFirstEvent: (@Sendable () -> Void)? = nil
    ) async throws -> [T] {
        try await withThrowingTaskGroup(of: [T]?.self) { group in
            group.addTask {
                var items: [T] = []
                for try await item in stream {
                    items.append(item)
                    if items.count == 1 {
                        onFirstEvent?()
                    }
                    if items.count >= count { break }
                }
                return items
            }
            group.addTask {
                try await Task.sleep(for: .milliseconds(timeoutMs))
                return nil
            }
            defer { group.cancelAll() }
            while let result = try await group.next() {
                if let collected = result {
                    return collected
                }
                throw HTTPTransportError.networkFailure("Timed out waiting for \(count) SSE events")
            }
            return []
        }
    }
}

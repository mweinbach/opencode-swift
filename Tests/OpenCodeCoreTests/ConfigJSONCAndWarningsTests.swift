import Synchronization
import Testing
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Swift Testing suite covering:
/// 1. Structured warning logs emitted by `CoreConfig.Service` on malformed JSONC/JSON,
///    normalization diagnostics, `plutil` conversion failure, WellKnown discovery/load/refresh
///    failures, and missing `{file:...}` variable references.
/// 2. Surgical CRLF & comment preservation in `CoreConfig.Service.update(_:)`.
@Suite("CoreConfig Structured Warnings and Surgical JSONC Updates")
struct ConfigJSONCAndWarningsTests {
    private final class CapturingLogSink: LogSink, Sendable {
        private let records = Mutex<[StructuredLogRecord]>([])

        func log(_ record: StructuredLogRecord) async {
            records.withLock { $0.append(record) }
        }

        var snapshot: [StructuredLogRecord] {
            records.withLock { $0 }
        }
    }

    private struct FakeProcessSpawner: ProcessSpawner, Sendable {
        let handler: @Sendable (ProcessSpec) async throws -> ProcessOutput

        func run(_ spec: ProcessSpec) async throws -> ProcessOutput {
            try await handler(spec)
        }
    }

    private struct FailingWellKnown: CoreIntegration.WellKnown.Interface, Sendable {
        enum Mode: Sendable {
            case entriesFail
            case resolveFails(entry: CoreIntegration.WellKnown.Entry, cachedConfigs: [CoreIntegration.WellKnown.Config])
            case refreshFails(entry: CoreIntegration.WellKnown.Entry)
        }

        struct FakeError: Error, CustomStringConvertible {
            let description: String
        }

        let mode: Mode

        func entries() async throws -> [CoreIntegration.WellKnown.Entry] {
            switch mode {
            case .entriesFail:
                throw FakeError(description: "wellknown discovery failed")
            case .resolveFails(let entry, _), .refreshFails(let entry):
                return [entry]
            }
        }

        func snapshot() -> [CoreIntegration.WellKnown.Entry] {
            switch mode {
            case .entriesFail: return []
            case .resolveFails(let entry, _), .refreshFails(let entry): return [entry]
            }
        }

        func refresh() async throws -> Bool {
            if case .refreshFails = mode {
                throw FakeError(description: "wellknown refresh boom")
            }
            return false
        }

        func add(origin: String) async throws -> CoreIntegration.WellKnown.Entry {
            throw FakeError(description: "unused")
        }

        func remove(origin: String) async throws {}

        func resolve(entry: CoreIntegration.WellKnown.Entry, variables: [String: String]) async throws -> [CoreIntegration.WellKnown.Config] {
            switch mode {
            case .resolveFails:
                throw FakeError(description: "wellknown resolve timeout")
            case .entriesFail, .refreshFails:
                return []
            }
        }

        func cached(origin: String) async throws -> [CoreIntegration.WellKnown.Config] {
            if case .resolveFails(_, let cachedConfigs) = mode {
                return cachedConfigs
            }
            return []
        }

        func clearCached(origin: String) async throws {}
    }

    private func makeGlobal(root: String) -> Global.Interface {
        Global.make(Global.Overrides(
            home: "\(root)/home",
            data: "\(root)/data",
            cache: "\(root)/cache",
            config: "\(root)/global",
            state: "\(root)/state",
            tmp: "\(root)/tmp",
            bin: "\(root)/bin",
            log: "\(root)/log",
            repos: "\(root)/repos"
        ))
    }

    @Test("logs redacted source-aware diagnostics for malformed, empty, null, and invalid config sources")
    func logsRedactedSourceAwareDiagnosticsForAllSources() async throws {
        let root = "/diag-test"
        let globalDir = "\(root)/global"
        let projectDir = "\(root)/project"
        let malformedPath = "\(root)/malformed.json"

        let fs = InMemoryFileSystem(initialFiles: [
            "\(globalDir)/opencode.json": Array("null".utf8),
            "\(projectDir)/opencode.json": Array("".utf8),
            malformedPath: Array("{ \"credential\": \"file-secret\"".utf8),
            "\(projectDir)/opencode.jsonc": Array("""
            {
              "logLevel": "debug",
              "username": "{file:./missing-secret.txt}"
            }
            """.utf8),
        ])
        try await fs.makeDirectory(at: globalDir, recursive: true)
        try await fs.makeDirectory(at: projectDir, recursive: true)

        let sink = CapturingLogSink()
        let config = await CoreConfig.Service(
            directory: projectDir,
            options: CoreConfig.Options(
                project: true,
                global: true,
                system: .disabled,
                claude: false,
                file: malformedPath,
                content: ""
            ),
            globalPaths: makeGlobal(root: root),
            fileSystem: fs,
            environment: DictionaryEnvironment(homeDirectory: "\(root)/home", temporaryDirectory: "\(root)/tmp"),
            platform: .linux,
            log: sink
        )
        defer { Task { await config.close() } }

        let records = sink.snapshot
        let normWarnings = records.filter {
            $0.level == .warn && $0.message == "configuration normalization diagnostic"
        }
        let summaries = normWarnings.map { rec -> String in
            let f = Dictionary(uniqueKeysWithValues: rec.fields)
            return "\(f["source"] ?? ""):\(f["path"] ?? ""):\(f["kind"] ?? "")"
        }.sorted()

        #expect(summaries == [
            "\(globalDir)/opencode.json:$:invalid",
            "\(malformedPath):$:invalid",
            "\(projectDir)/opencode.json:$:invalid",
            "OPENCODE_CONFIG_CONTENT:$:invalid",
        ].sorted())

        // Unsupported legacy field on an accepted document logs at `.debug`, not `.warn`.
        let debugDiagnostics = records.filter {
            $0.level == .debug && $0.message == "configuration normalization diagnostic"
        }
        #expect(debugDiagnostics.contains { rec in
            let f = Dictionary(uniqueKeysWithValues: rec.fields)
            return f["source"] == "\(projectDir)/opencode.jsonc"
                && f["path"] == "$.logLevel"
                && f["kind"] == "unsupported"
        })

        // Missing `{file:...}` reference logs upstream's warning.
        let fileRefWarnings = records.filter {
            $0.level == .warn && $0.message == "config file reference is missing or unreadable"
        }
        #expect(fileRefWarnings.count == 1)
        let refFields = Dictionary(uniqueKeysWithValues: fileRefWarnings[0].fields)
        #expect(refFields["source"] == "\(projectDir)/opencode.jsonc")
        #expect(refFields["reference"] == "{file:./missing-secret.txt}")
        #expect(refFields["path"] == "\(projectDir)/missing-secret.txt")

        // Secrets must never appear in any log record.
        for rec in records {
            #expect(!rec.message.contains("file-secret"))
            for (_, v) in rec.fields {
                #expect(!v.contains("file-secret"))
            }
        }
    }

    @Test("logs structured warnings on plutil failure and WellKnown discover/resolve failures")
    func logsWarningsOnPlutilAndWellKnownFailures() async throws {
        let root = "/warn-plutil-wk"
        let globalDir = "\(root)/global"
        let projectDir = "\(root)/project"
        let plistPath = "/Library/Managed Preferences/alice/ai.opencode.managed.plist"
        let origin = "https://remote.acme.test"
        let integrationID = IntegrationID(rawValue: origin)

        let fs = InMemoryFileSystem(initialFiles: [
            plistPath: Array("not-a-valid-plist".utf8),
            "\(globalDir)/opencode.json": Array("{\"username\":\"local\"}".utf8),
        ])
        try await fs.makeDirectory(at: globalDir, recursive: true)
        try await fs.makeDirectory(at: projectDir, recursive: true)

        let failingSpawner = FakeProcessSpawner { _ in
            ProcessOutput(exitCode: 1, stdout: [], stderr: Array("corrupt plist".utf8))
        }
        let credentials = try CoreProvider.Credential.Service.inMemory()
        _ = try await credentials.create(
            integrationID: integrationID,
            value: .key(CredentialSchema.Key(key: "tok-1")),
            label: "Primary"
        )
        let wkEntry = CoreIntegration.WellKnown.Entry(
            origin: origin,
            integrationID: integrationID,
            manifest: CoreIntegration.WellKnown.Manifest(
                auth: CoreIntegration.WellKnown.Auth(command: ["login"], env: "WK_TOKEN")
            )
        )

        // 1. plutil failure + WellKnown resolve failure (falls back to cached config)
        let sink1 = CapturingLogSink()
        let config1 = await CoreConfig.Service(
            directory: projectDir,
            options: CoreConfig.Options(project: false, global: true, system: .enabled, claude: false),
            globalPaths: makeGlobal(root: root),
            fileSystem: fs,
            environment: DictionaryEnvironment(variables: ["USER": "alice"], homeDirectory: "\(root)/home", temporaryDirectory: "\(root)/tmp"),
            platform: .macOS,
            credentials: credentials,
            wellKnown: FailingWellKnown(mode: .resolveFails(entry: wkEntry, cachedConfigs: [["timezone": .string("UTC")]])),
            processes: AppProcess.Service(spawner: failingSpawner),
            log: sink1
        )
        defer { Task { await config1.close() } }

        // Cached WellKnown config survives the resolve failure.
        #expect(CoreConfig.latest(await config1.entries(), \.timezone) == "UTC")

        let plutilWarnings = sink1.snapshot.filter {
            $0.level == .warn && $0.message == "failed to convert managed preferences"
        }
        #expect(plutilWarnings.count == 1)
        #expect(Dictionary(uniqueKeysWithValues: plutilWarnings[0].fields)["source"] == plistPath)

        let wkResolveWarnings = sink1.snapshot.filter {
            $0.level == .warn && $0.message == "failed to load wellknown config"
        }
        #expect(wkResolveWarnings.count == 1)
        let resolveFields = Dictionary(uniqueKeysWithValues: wkResolveWarnings[0].fields)
        #expect(resolveFields["source"] == origin)
        #expect(resolveFields["error"]?.contains("wellknown resolve timeout") == true)

        // 2. WellKnown entries() discovery failure
        let sink2 = CapturingLogSink()
        let config2 = await CoreConfig.Service(
            directory: projectDir,
            options: CoreConfig.Options(project: false, global: true, system: .disabled, claude: false),
            globalPaths: makeGlobal(root: root),
            fileSystem: fs,
            environment: DictionaryEnvironment(homeDirectory: "\(root)/home", temporaryDirectory: "\(root)/tmp"),
            platform: .linux,
            wellKnown: FailingWellKnown(mode: .entriesFail),
            log: sink2
        )
        defer { Task { await config2.close() } }

        let wkDiscoverWarnings = sink2.snapshot.filter {
            $0.level == .warn && $0.message == "failed to discover wellknown config"
        }
        #expect(wkDiscoverWarnings.count == 1)
        #expect(Dictionary(uniqueKeysWithValues: wkDiscoverWarnings[0].fields)["error"]?.contains("wellknown discovery failed") == true)
    }

    @Test("CoreConfig.Service.update preserves CRLF line endings, comments, and key order")
    func coreConfigUpdatePreservesCRLFAndComments() async throws {
        let root = "/crlf-update"
        let globalDir = "\(root)/global"
        let configPath = "\(globalDir)/opencode.jsonc"
        let original = "{\r\n  // keep CRLF comment\r\n  \"username\": \"win\",\r\n  \"shell\": \"pwsh\"\r\n}\r\n"
        let expected = "{\r\n  // keep CRLF comment\r\n  \"username\": \"win\",\r\n  \"shell\": \"powershell\"\r\n}\r\n"

        let fs = InMemoryFileSystem(initialFiles: [
            configPath: Array(original.utf8),
        ])
        try await fs.makeDirectory(at: "\(root)/repo", recursive: true)

        let config = await CoreConfig.Service(
            directory: "\(root)/repo",
            options: CoreConfig.Options(project: false, global: true, system: .disabled, claude: false),
            globalPaths: makeGlobal(root: root),
            fileSystem: fs,
            environment: DictionaryEnvironment(homeDirectory: "\(root)/home", temporaryDirectory: "\(root)/tmp"),
            platform: .linux
        )
        defer { Task { await config.close() } }

        try await config.update(ConfigSchema.Patch(shell: "powershell"))
        let actual = String(decoding: try await fs.readFile(at: configPath), as: UTF8.self)
        #expect(actual == expected)
    }
}

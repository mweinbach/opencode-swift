import Synchronization
import Testing
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer
import OpenCodeUtil

/// Server-level Swift Testing suite verifying:
/// 1. Updating settings via `PATCH /api/experimental/config` on a commented `opencode.jsonc`
///    performs surgical JSONC edits preserving every comment and formatting byte-for-byte
///    outside the changed span.
/// 2. Loading a config with a JSONC parse error through the server emits upstream's structured
///    warning log (`configuration normalization diagnostic`) without leaking config values.
@Suite("Server API Surgical JSONC Config Edits and Parse Warnings")
struct ServerConfigJSONCEditTests {
    private final class CapturingLogSink: LogSink, Sendable {
        private let records = Mutex<[StructuredLogRecord]>([])

        func log(_ record: StructuredLogRecord) async {
            records.withLock { $0.append(record) }
        }

        var snapshot: [StructuredLogRecord] {
            records.withLock { $0 }
        }
    }

    @Test("PATCH /api/experimental/config preserves every comment and formatting byte-for-byte except the changed span")
    func serverConfigUpdatePreservesCommentsAndFormattingByteForByte() async throws {
        let root = "/tmp/opencode-jsonc-server-test"
        let globalDir = "\(root)/config"
        let projectDir = "\(root)/repo"
        let configPath = "\(globalDir)/opencode.jsonc"

        let original = """
        // 🚀 User global OpenCode config — DO NOT STRIP
        {
          /* Keep custom key order (z before a) and trailing commas */
          "username": "alice", // inline username note
          // Preferred interactive shell
          "shell": "/bin/bash", // inline shell comment
          "snapshots": true,
        }
        // trailing footer comment
        """ + "\n"

        let expectedAfterReplace = """
        // 🚀 User global OpenCode config — DO NOT STRIP
        {
          /* Keep custom key order (z before a) and trailing commas */
          "username": "alice", // inline username note
          // Preferred interactive shell
          "shell": "/bin/zsh", // inline shell comment
          "snapshots": true,
        }
        // trailing footer comment
        """ + "\n"

        let fs = InMemoryFileSystem(initialFiles: [
            configPath: Array(original.utf8),
        ])
        try await fs.makeDirectory(at: projectDir, recursive: true)

        let globalOverrides = Global.Overrides(
            home: "\(root)/home",
            data: "\(root)/data",
            cache: "\(root)/cache",
            config: globalDir,
            state: "\(root)/state",
            tmp: "\(root)/tmp",
            bin: "\(root)/bin",
            log: "\(root)/log",
            repos: "\(root)/repos"
        )
        let router = try await createEmbeddedRoutes(
            options: ServerOptions(config: ServerOptions.ConfigOptions(project: false, claude: false)),
            fileSystem: fs,
            environment: DictionaryEnvironment(homeDirectory: "\(root)/home", temporaryDirectory: "\(root)/tmp"),
            globalOverrides: globalOverrides,
            defaultDirectory: projectDir
        )
        defer { Task { await router.runtime.close() } }

        let client = OpenCodeClient(
            options: ClientOptions(
                baseUrl: "http://127.0.0.1:4096",
                transport: ServerInProcessTransport(handler: { await router.handle($0) })
            )
        )
        let loc = LocationQuery.LocationField(directory: projectDir)

        // 1. Replace existing `shell` via server API: ONLY `"/bin/bash"` -> `"/bin/zsh"` may change.
        try await client.config.update(ConfigUpdateInput(shell: .value("/bin/zsh")))

        let afterReplaceBytes = try await fs.readFile(at: configPath)
        let afterReplace = String(decoding: afterReplaceBytes, as: UTF8.self)
        #expect(afterReplace == expectedAfterReplace)
        #expect(afterReplaceBytes == Array(expectedAfterReplace.utf8))

        // Verify live config view reflects the updated shell immediately.
        let entriesAfterReplace = try await client.config.get(ConfigGetInput(location: loc))
        let resolvedShell = entriesAfterReplace.reversed().compactMap { entry -> String? in
            if case .document(let doc) = entry { return doc.info.shell }
            return nil
        }.first
        #expect(resolvedShell == "/bin/zsh")

        // 2. Clear `shell` via server API (`{"shell": null}`): removes `shell` while preserving all comments and keys.
        try await client.config.update(ConfigUpdateInput(shell: .null))

        let afterRemove = String(decoding: try await fs.readFile(at: configPath), as: UTF8.self)
        #expect(afterRemove.contains("// 🚀 User global OpenCode config — DO NOT STRIP"))
        #expect(afterRemove.contains("/* Keep custom key order (z before a) and trailing commas */"))
        #expect(afterRemove.contains("\"username\": \"alice\""))
        #expect(afterRemove.contains("\"snapshots\": true"))
        #expect(afterRemove.contains("// trailing footer comment"))
        #expect(!afterRemove.contains("\"shell\""))

        // 3. Re-insert `shell` via server API into the commented file: preserves comments and inserts `shell`.
        try await client.config.update(ConfigUpdateInput(shell: .value("/bin/fish")))

        let afterInsert = String(decoding: try await fs.readFile(at: configPath), as: UTF8.self)
        #expect(afterInsert.contains("// 🚀 User global OpenCode config — DO NOT STRIP"))
        #expect(afterInsert.contains("/* Keep custom key order (z before a) and trailing commas */"))
        #expect(afterInsert.contains("\"username\": \"alice\""))
        #expect(afterInsert.contains("\"shell\": \"/bin/fish\""))
        #expect(afterInsert.contains("// trailing footer comment"))
        var parseErrors: [JSONC.ParseError] = []
        _ = JSONC.parse(afterInsert, errors: &parseErrors, options: JSONC.ParseOptions(allowTrailingComma: true))
        #expect(parseErrors.isEmpty)
    }

    @Test("server logs upstream structured warning when loading a config with a JSONC parse error")
    func serverLogsStructuredWarningOnMalformedJSONC() async throws {
        let root = "/tmp/opencode-jsonc-warn-test"
        let globalDir = "\(root)/config"
        let projectDir = "\(root)/repo"
        let brokenPath = "\(globalDir)/opencode.jsonc"

        let fs = InMemoryFileSystem(initialFiles: [
            brokenPath: Array("{ \"credential\": \"super-secret-value\"".utf8),
        ])
        try await fs.makeDirectory(at: projectDir, recursive: true)

        let sink = CapturingLogSink()
        let globalOverrides = Global.Overrides(
            home: "\(root)/home",
            data: "\(root)/data",
            cache: "\(root)/cache",
            config: globalDir,
            state: "\(root)/state",
            tmp: "\(root)/tmp",
            bin: "\(root)/bin",
            log: "\(root)/log",
            repos: "\(root)/repos"
        )
        let router = try await createEmbeddedRoutes(
            options: ServerOptions(config: ServerOptions.ConfigOptions(project: false, claude: false)),
            fileSystem: fs,
            environment: DictionaryEnvironment(homeDirectory: "\(root)/home", temporaryDirectory: "\(root)/tmp"),
            globalOverrides: globalOverrides,
            defaultDirectory: projectDir,
            logSink: sink
        )
        defer { Task { await router.runtime.close() } }

        let client = OpenCodeClient(
            options: ClientOptions(
                baseUrl: "http://127.0.0.1:4096",
                transport: ServerInProcessTransport(handler: { await router.handle($0) })
            )
        )
        _ = try await client.config.get(ConfigGetInput(location: LocationQuery.LocationField(directory: projectDir)))

        let warnings = sink.snapshot.filter {
            $0.level == .warn && $0.message == "configuration normalization diagnostic"
        }
        #expect(warnings.count == 1)
        let fields = Dictionary(uniqueKeysWithValues: warnings[0].fields)
        #expect(fields["source"] == brokenPath)
        #expect(fields["path"] == "$")
        #expect(fields["kind"] == "invalid")
        #expect(fields["action"] == "rejected malformed JSON or JSONC document")
        // Config secrets must never leak into log records.
        for record in sink.snapshot {
            #expect(!record.message.contains("super-secret-value"))
            for (_, v) in record.fields {
                #expect(!v.contains("super-secret-value"))
            }
        }
    }
}

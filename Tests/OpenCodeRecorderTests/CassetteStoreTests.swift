import Testing
import OpenCodePlatform
import OpenCodeRecorder
import OpenCodeUtil

@Suite("OpenCodeRecorder Cassette Model & Store")
struct CassetteStoreTests {
    @Test("encodes and decodes version-1 cassettes with HTTP and WebSocket interactions")
    func cassetteSchemaRoundTrip() throws {
        let http = HttpInteraction(
            request: RequestSnapshot(
                method: "POST",
                url: "https://api.example.test/v1/messages",
                headers: ["content-type": "application/json"],
                body: #"{"hello":"world"}"#
            ),
            response: ResponseSnapshot(
                status: 200,
                headers: ["content-type": "application/json"],
                body: #"{"ok":true}"#
            )
        )
        let ws = WebSocketInteraction(
            connection: WebSocketConnection(
                sequence: 0,
                url: "wss://api.example.test/ws",
                protocols: ["chat.v1"],
                close: WebSocketClose(code: 1000, reason: "done")
            ),
            events: [
                .text(direction: .client, body: #"{"type":"ping"}"#),
                .binary(direction: .server, bytes: [0x01, 0x02, 0xFE, 0xFF]),
            ]
        )
        let cassette = Cassette(
            version: 1,
            metadata: ["name": "mixed", "count": 2, "flag": true, "tags": ["a", "b"], "nil": nil],
            interactions: [.http(http), .websocket(ws)]
        )

        #expect(isHttpInteraction(.http(http)))
        #expect(!isHttpInteraction(.websocket(ws)))
        #expect(isWebSocketInteraction(.websocket(ws)))
        #expect(!isWebSocketInteraction(.http(http)))
        #expect(httpInteractions(cassette.interactions) == [http])
        #expect(webSocketInteractions(cassette.interactions) == [ws])

        let encoded = encodeCassette(cassette)
        let decoded = try decodeCassette(encoded)
        #expect(decoded == cassette)

        let jsonText = formatCassetteJSON(cassette)
        #expect(jsonText.hasSuffix("\n"))
        let fromText = try decodeCassette(fromJSON: jsonText)
        #expect(fromText == cassette)

        // Reject version != 1
        #expect(throws: RecorderSchemaError.self) {
            _ = try decodeCassette(fromJSON: #"{"version":2,"interactions":[]}"#)
        }
        // Reject unknown transport
        #expect(throws: RecorderSchemaError.self) {
            _ = try decodeCassette(fromJSON: #"{"version":1,"interactions":[{"transport":"grpc"}]}"#)
        }
    }

    @Test("error message formatting matches upstream")
    func errorMessages() {
        let notFound = CassetteNotFoundError(cassetteName: "foo/bar")
        #expect(notFound.message == #"Cassette "foo/bar" not found"#)

        let invalid = InvalidCassetteError(cassetteName: "foo", description: "bad json")
        #expect(invalid.message == #"Cassette "foo" is invalid: bad json"#)

        let unsafe = UnsafeCassetteError(
            cassetteName: "leak",
            findings: [SecretFinding(path: "response.body", reason: "bearer token")]
        )
        #expect(
            unsafe.message == #"Refusing to write cassette "leak" because it contains possible secrets: response.body (bearer token)"#
        )
    }

    @Test("failed memory appends leave cassette state unchanged")
    func transactionalMemoryAppend() async throws {
        let env = DictionaryEnvironment(variables: [:])
        let store = CassetteStoreService.memory([:], environment: env)
        let safeInteraction = Interaction.http(HttpInteraction(
            request: RequestSnapshot(method: "GET", url: "https://example.test", headers: [:], body: ""),
            response: ResponseSnapshot(status: 200, headers: [:], body: "safe")
        ))
        try await store.append("transactional", interaction: safeInteraction)

        let leakyInteraction = Interaction.http(HttpInteraction(
            request: RequestSnapshot(method: "GET", url: "https://example.test", headers: [:], body: ""),
            response: ResponseSnapshot(status: 200, headers: [:], body: "Bearer abcdefghijklmnopqrstuvwxyz1234")
        ))
        await #expect(throws: UnsafeCassetteError.self) {
            try await store.append("transactional", interaction: leakyInteraction)
        }

        let stored = try await store.read("transactional")
        #expect(stored == [safeInteraction])
        #expect(await store.exists("transactional"))
        #expect(try await store.list() == ["transactional"])
        await #expect(throws: CassetteNotFoundError.self) {
            _ = try await store.read("does-not-exist")
        }
    }

    @Test("concurrent filesystem appends preserve every interaction with zero leftover temp files")
    func concurrentFileSystemAppends() async throws {
        let tempDir = try TempRecorderDirectory(prefix: "recorder-concurrent-")
        defer { tempDir.cleanup() }
        let env = DictionaryEnvironment(variables: [:])
        let store = CassetteStoreService.fileSystem(
            directory: tempDir.path,
            fileSystem: LocalFileSystem.shared,
            environment: env
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try await store.append(
                        "concurrent",
                        interaction: .http(HttpInteraction(
                            request: RequestSnapshot(
                                method: "GET",
                                url: "https://example.test/\(index)",
                                headers: [:],
                                body: ""
                            ),
                            response: ResponseSnapshot(status: 200, headers: [:], body: "\(index)")
                        ))
                    )
                }
            }
            try await group.waitForAll()
        }

        let cassette = try tempDir.readCassette(relativePath: "concurrent.json")
        #expect(cassette.interactions.count == 20)
        let leftoverTmp = try tempDir.listDirectoryEntries().filter { $0.hasSuffix(".tmp") }
        #expect(leftoverTmp.isEmpty)
    }

    @Test("generated cassette metadata cannot be overridden by caller metadata")
    func generatedMetadataCannotBeOverridden() async throws {
        let fs = InMemoryFileSystem()
        let env = DictionaryEnvironment(variables: [:])
        let store = CassetteStoreService.fileSystem(
            directory: "/recordings",
            fileSystem: fs,
            environment: env
        )
        try await store.append(
            "metadata",
            interaction: .http(HttpInteraction(
                request: RequestSnapshot(method: "GET", url: "https://example.test", headers: [:], body: ""),
                response: ResponseSnapshot(status: 200, headers: [:], body: "safe")
            )),
            metadata: ["name": "wrong", "recordedAt": "wrong", "custom": "kept"]
        )

        let rawBytes = try await fs.readFile(at: "/recordings/metadata.json")
        let cassette = try decodeCassette(fromBytes: rawBytes)
        #expect(cassette.metadata?["name"] == .string("metadata"))
        #expect(cassette.metadata?["recordedAt"] != .string("wrong"))
        #expect(cassette.metadata?["custom"] == .string("kept"))
    }

    @Test("reports malformed cassette JSON as InvalidCassetteError")
    func malformedCassetteReportsInvalid() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/recordings/invalid.json": Array("{not-json".utf8),
        ])
        let store = CassetteStoreService.fileSystem(directory: "/recordings", fileSystem: fs)
        await #expect(throws: InvalidCassetteError.self) {
            _ = try await store.read("invalid")
        }
    }

    @Test("rejects path traversal and supports sync lifecycle helpers and recursive listing")
    func pathValidationSyncLifecycleAndList() async throws {
        let tempDir = try TempRecorderDirectory(prefix: "recorder-lifecycle-")
        defer { tempDir.cleanup() }

        #expect(throws: InvalidCassetteNameError.self) {
            _ = try HttpRecorder.hasCassetteSync("../outside", directory: tempDir.path)
        }
        #expect(throws: InvalidCassetteNameError.self) {
            _ = try HttpRecorder.hasCassetteSync("C:\\outside", directory: tempDir.path)
        }
        #expect(throws: InvalidCassetteNameError.self) {
            _ = try HttpRecorder.hasCassetteSync("/etc/passwd", directory: tempDir.path)
        }
        #expect(throws: InvalidCassetteNameError.self) {
            try HttpRecorder.removeCassetteSync("../outside", directory: tempDir.path)
        }

        #expect(try !HttpRecorder.hasCassetteSync("nested/example", directory: tempDir.path))

        let store = CassetteStoreService.fileSystem(
            directory: tempDir.path,
            fileSystem: LocalFileSystem.shared,
            environment: DictionaryEnvironment(variables: [:])
        )
        let sample = Interaction.http(HttpInteraction(
            request: RequestSnapshot(method: "GET", url: "https://x.test/a", headers: [:], body: ""),
            response: ResponseSnapshot(status: 200, headers: [:], body: "a")
        ))
        try await store.append("alpha/one", interaction: sample)
        try await store.append("beta", interaction: sample)
        try await store.append("nested/example", interaction: sample)

        #expect(try HttpRecorder.hasCassetteSync("nested/example", directory: tempDir.path))
        let names = try await store.list()
        #expect(names == ["alpha/one", "beta", "nested/example"])

        try HttpRecorder.removeCassetteSync("nested/example", directory: tempDir.path)
        #expect(try !HttpRecorder.hasCassetteSync("nested/example", directory: tempDir.path))
        // Removing a missing cassette is a no-op
        try HttpRecorder.removeCassetteSync("nested/example", directory: tempDir.path)
    }
}

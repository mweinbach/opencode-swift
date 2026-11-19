import Testing
import OpenCodePlatform
import OpenCodeRecorder
import OpenCodeUtil

@Suite("OpenCodeRecorder WebSocket Record & Replay")
struct WebSocketRecorderTests {
    @Test("records lower-level WebSocket frames in observed order with secret redaction")
    func recordsSocketFramesWithRedaction() async throws {
        let fs = InMemoryFileSystem()
        let env = DictionaryEnvironment(variables: [:])
        let upstream = ScriptedRecorderSocket(steps: [
            .frames([.text(#"{"type":"response.completed","token":"server-secret"}"#)]),
            .close(code: 1000, reason: "done"),
        ])

        let socket = WebSocketRecorder.layerSocketWithMode(
            "websocket/record",
            mode: .record,
            options: SocketRecorderOptions(directory: "/cassettes", metadata: ["provider": "test"]),
            upstream: upstream,
            fileSystem: fs,
            environment: env
        )

        do {
            try await socket.run { reader, writer in
                try await writer.write(.text(#"{"type":"response.create","token":"client-secret"}"#))
                while true {
                    _ = try await reader.pull()
                }
            }
        } catch let close as WebSocketCloseError where close.isNormalClose {
            // Expected normal close terminating read loop
        }

        let cassette = try decodeCassette(fromBytes: try await fs.readFile(at: "/cassettes/websocket/record.json"))
        let wsList = webSocketInteractions(cassette.interactions)
        #expect(wsList.count == 1)
        #expect(wsList[0].events == [
            .text(direction: .client, body: #"{"type":"response.create","token":"[REDACTED]"}"#),
            .text(direction: .server, body: #"{"type":"response.completed","token":"[REDACTED]"}"#),
        ])
    }

    @Test("does not record abnormal close, consumer errors, failed open, or write-after-close")
    func skipsRecordingFailedWebSocketSessions() async throws {
        let fs = InMemoryFileSystem()
        let env = DictionaryEnvironment(variables: [:])

        // 1. Abnormal close (1011) swallowed by consumer
        let abnormalUpstream = ScriptedRecorderSocket(steps: [
            .frames([.text("partial")]),
            .close(code: 1011, reason: "server error"),
        ])
        let abnormalSocket = WebSocketRecorder.layerSocketWithMode(
            "websocket/abnormal",
            mode: .record,
            options: SocketRecorderOptions(directory: "/cassettes"),
            upstream: abnormalUpstream,
            fileSystem: fs,
            environment: env
        )
        try await abnormalSocket.run { reader, _ in
            do {
                while true { _ = try await reader.pull() }
            } catch is WebSocketCloseError {
                return
            }
        }
        #expect(await !fs.exists(at: "/cassettes/websocket/abnormal.json"))

        // 2. Consumer error after normal close
        let normalUpstream = ScriptedRecorderSocket(steps: [
            .frames([.text("ok")]),
            .close(code: 1000, reason: ""),
        ])
        let consumerFailSocket = WebSocketRecorder.layerSocketWithMode(
            "websocket/consumer-fail",
            mode: .record,
            options: SocketRecorderOptions(directory: "/cassettes"),
            upstream: normalUpstream,
            fileSystem: fs,
            environment: env
        )
        await #expect(throws: WebSocketRecorderError.self) {
            try await consumerFailSocket.run { reader, _ in
                _ = try await reader.pull()
                throw WebSocketRecorderError("consumer defect")
            }
        }
        #expect(await !fs.exists(at: "/cassettes/websocket/consumer-fail.json"))

        // 3. Write after client close
        let holdUpstream = ScriptedRecorderSocket(steps: [.waitForever])
        let writeAfterCloseSocket = WebSocketRecorder.layerSocketWithMode(
            "websocket/write-after-close",
            mode: .record,
            options: SocketRecorderOptions(directory: "/cassettes"),
            upstream: holdUpstream,
            fileSystem: fs,
            environment: env
        )
        var afterCloseErr: WebSocketRecorderError?
        do {
            try await writeAfterCloseSocket.run { _, writer in
                try await writer.write(.text("before-close"))
                try await writer.write(.close(code: 1000, reason: ""))
                try await writer.write(.text("after-close"))
            }
        } catch let err as WebSocketRecorderError {
            afterCloseErr = err
        }
        #expect(afterCloseErr?.message.contains("after the client closed") == true)
        #expect(await !fs.exists(at: "/cassettes/websocket/write-after-close.json"))
    }

    @Test("replays causal multi-turn WebSocket conversation with canonical JSON client matching")
    func replaysCausalConversation() async throws {
        let env = DictionaryEnvironment(variables: [:])
        let store = CassetteStoreService.memory([
            "websocket/causal": [
                .websocket(WebSocketInteraction(events: [
                    .text(direction: .server, body: #"{"type":"session.created"}"#),
                    .text(direction: .client, body: #"{"type":"response.create","prompt":"first"}"#),
                    .text(direction: .server, body: #"{"type":"response.completed","id":"first"}"#),
                    .text(direction: .client, body: #"{"type":"response.create","prompt":"second"}"#),
                    .text(direction: .server, body: #"{"type":"response.completed","id":"second"}"#),
                ])),
            ],
        ], environment: env)

        let socket = HttpRecorder.layerSocket(
            "websocket/causal",
            upstream: UnavailableRecorderSocket(),
            cassette: store,
            environment: env
        )

        let received = try await socket.run { reader, writer -> [String] in
            var frames: [String] = []
            do {
                while true {
                    for frame in try await reader.pull() {
                        guard case .text(let msg) = frame else { continue }
                        frames.append(msg)
                        if msg.contains("session.created") {
                            // Intentionally reversed JSON key order
                            try await writer.write(.text(#"{"prompt":"first","type":"response.create"}"#))
                        } else if msg.contains(#""id":"first""#) {
                            try await writer.write(.text(#"{"prompt":"second","type":"response.create"}"#))
                        } else {
                            try await writer.write(.close(code: 1000, reason: "done"))
                        }
                    }
                }
            } catch let close as WebSocketCloseError where close.isNormalClose {
                return frames
            }
        }
        try await socket.finish()

        #expect(received == [
            #"{"type":"session.created"}"#,
            #"{"type":"response.completed","id":"first"}"#,
            #"{"type":"response.completed","id":"second"}"#,
        ])
    }

    @Test("rejects concurrent replay without consuming next interaction, rejects early close, and preserves binary frames")
    func concurrentReplayEarlyCloseAndBinary() async throws {
        let env = DictionaryEnvironment(variables: [:])

        // 1. Concurrent replay rejection does not consume second interaction
        let concurrentStore = CassetteStoreService.memory([
            "ws/concurrent": [
                .websocket(WebSocketInteraction(events: [.text(direction: .server, body: "first")])),
                .websocket(WebSocketInteraction(events: [.text(direction: .server, body: "second")])),
            ],
        ], environment: env)
        let concurrentSocket = WebSocketRecorder.layerSocketWithMode(
            "ws/concurrent",
            mode: .replay,
            upstream: UnavailableRecorderSocket(),
            cassette: concurrentStore,
            environment: env
        )
        let started = AsyncTestGate()
        let release = AsyncTestGate()
        let firstTask = Task {
            try await concurrentSocket.run { reader, _ -> String in
                let batch = try await reader.pull()
                await started.open()
                await release.wait()
                if case .text(let s) = batch.first { return s }
                return ""
            }
        }
        await started.wait()

        var concurrentErr: WebSocketRecorderError?
        do {
            _ = try await concurrentSocket.run { _, _ in () }
        } catch let e as WebSocketRecorderError {
            concurrentErr = e
        }
        #expect(concurrentErr?.message.contains("Concurrent runs") == true)

        await release.open()
        let firstMsg = try await firstTask.value
        let secondMsg = try await concurrentSocket.run { reader, _ -> String in
            let batch = try await reader.pull()
            if case .text(let s) = batch.first { return s }
            return ""
        }
        try await concurrentSocket.finish()
        #expect([firstMsg, secondMsg] == ["first", "second"])

        // 2. Early close with unconsumed events
        let earlyStore = CassetteStoreService.memory([
            "ws/early": [
                .websocket(WebSocketInteraction(events: [.text(direction: .client, body: "expected")])),
            ],
        ], environment: env)
        let earlySocket = WebSocketRecorder.layerSocketWithMode(
            "ws/early",
            mode: .replay,
            upstream: UnavailableRecorderSocket(),
            cassette: earlyStore,
            environment: env
        )
        var earlyErr: WebSocketRecorderError?
        do {
            try await earlySocket.run { _, writer in
                try await writer.write(.close(code: 1000, reason: ""))
            }
        } catch let e as WebSocketRecorderError {
            earlyErr = e
        }
        #expect(earlyErr?.message.contains("closed with unconsumed events") == true)

        // 3. Binary frames across reconnects
        let binaryInteraction = Interaction.websocket(WebSocketInteraction(events: [
            .binary(direction: .client, bytes: [1, 2]),
            .binary(direction: .server, bytes: [3, 4]),
        ]))
        let binaryStore = CassetteStoreService.memory([
            "ws/binary": [binaryInteraction, binaryInteraction],
        ], environment: env)
        let binarySocket = WebSocketRecorder.layerSocketWithMode(
            "ws/binary",
            mode: .replay,
            upstream: UnavailableRecorderSocket(),
            cassette: binaryStore,
            environment: env
        )
        var receivedBinary: [[UInt8]] = []
        for _ in 0..<2 {
            let bytes = try await binarySocket.run { reader, writer -> [UInt8] in
                try await writer.write(.binary([1, 2]))
                let batch = try await reader.pull()
                if case .binary(let data) = batch.first { return data }
                return []
            }
            receivedBinary.append(bytes)
        }
        try await binarySocket.finish()
        #expect(receivedBinary == [[3, 4], [3, 4]])
    }

    @Test("constructor layer records, reloads, validates dynamic URL/protocols, and replays terminal close")
    func constructorRecordAndReplayRoundTrip() async throws {
        let fs = InMemoryFileSystem()
        let env = DictionaryEnvironment(variables: [:])

        // 1. Record via constructor layer
        let recordCtor = HttpRecorder.layerWebSocketConstructor(
            "ws/constructor",
            options: SocketRecorderOptions(directory: "/cassettes"),
            upstream: { url, protocols in EchoWebSocketConnection(url: url, protocols: protocols) },
            fileSystem: fs,
            environment: env
        )

        try await recordCtor.withScope { ctor in
            let conn = try await ctor.connect(
                url: "wss://echo.example.test/one?api_key=live-key",
                protocols: ["echo.v1"]
            )
            try await conn.open()
            try await conn.send(.text(#"{"type":"hello","token":"secret-tok"}"#))
            let echoed = try await conn.receive()
            #expect(echoed == .text(#"{"type":"hello","token":"secret-tok"}"#))
            try await conn.close(code: 1000, reason: "complete")
        }

        // Verify saved cassette has redacted URL, redacted token, sequence 0, protocols, and close
        let saved = try decodeCassette(fromBytes: try await fs.readFile(at: "/cassettes/ws/constructor.json"))
        let recorded = try #require(webSocketInteractions(saved.interactions).first)
        #expect(recorded.connection == WebSocketConnection(
            sequence: 0,
            url: "wss://echo.example.test/one?api_key=%5BREDACTED%5D",
            protocols: ["echo.v1"],
            close: WebSocketClose(code: 1000, reason: "complete")
        ))
        #expect(recorded.events == [
            .text(direction: .client, body: #"{"type":"hello","token":"[REDACTED]"}"#),
            .text(direction: .server, body: #"{"type":"hello","token":"[REDACTED]"}"#),
        ])

        // 2. Replay offline — upstream constructor must NEVER be called!
        let replayCtor = HttpRecorder.layerWebSocketConstructor(
            "ws/constructor",
            options: SocketRecorderOptions(directory: "/cassettes"),
            upstream: { _, _ in throw WebSocketRecorderError("unexpected live WebSocket construction") },
            fileSystem: fs,
            environment: env
        )

        try await replayCtor.withScope { ctor in
            let conn = try await ctor.connect(
                url: "wss://echo.example.test/one?api_key=other-key",
                protocols: ["echo.v1"]
            )
            try await conn.open()
            // Reversed JSON key order still matches!
            try await conn.send(.text(#"{"token":"another-secret","type":"hello"}"#))
            let reply = try await conn.receive()
            #expect(reply == .text(#"{"type":"hello","token":"[REDACTED]"}"#))
            let eof = try await conn.receive()
            #expect(eof == nil)
            #expect(conn.terminalClose == WebSocketClose(code: 1000, reason: "complete"))
        }

        // 3. Rejects mismatched dynamic URL or protocols
        let mismatchCtor = HttpRecorder.layerWebSocketConstructor(
            "ws/constructor",
            options: SocketRecorderOptions(directory: "/cassettes"),
            upstream: { _, _ in throw WebSocketRecorderError("unexpected live WebSocket construction") },
            fileSystem: fs,
            environment: env
        )
        let badURLConn = try await mismatchCtor.connect(url: "wss://echo.example.test/wrong", protocols: ["echo.v1"])
        var urlErr: WebSocketRecorderError?
        do {
            try await badURLConn.open()
        } catch let e as WebSocketRecorderError {
            urlErr = e
        }
        #expect(urlErr?.message.contains("expected URL") == true)

        let badProtoConn = try await mismatchCtor.connect(
            url: "wss://echo.example.test/one?api_key=k",
            protocols: ["wrong.v2"]
        )
        var protoErr: WebSocketRecorderError?
        do {
            try await badProtoConn.open()
        } catch let e as WebSocketRecorderError {
            protoErr = e
        }
        #expect(protoErr?.message.contains("expected protocols") == true)
    }
}

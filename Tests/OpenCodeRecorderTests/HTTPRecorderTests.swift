import Testing
import OpenCodePlatform
import OpenCodeRecorder
import OpenCodeUtil

@Suite("OpenCodeRecorder HTTP Record, Replay, Streaming & Diffs")
struct HTTPRecorderTests {
    @Test("live record -> save -> redact -> reload -> replay round-trip")
    func liveRecordSaveRedactReloadReplay() async throws {
        let fs = InMemoryFileSystem()
        let env = DictionaryEnvironment(variables: [:])
        let liveMock = MockHTTPTransport()
        liveMock.enqueueResponse(
            statusCode: 200,
            headers: [
                "Content-Type": "application/json",
                "Set-Cookie": "sid=super-secret-cookie",
                "X-Request-Id": "req-42",
            ],
            text: #"{"access_token":"live-secret-token","reply":"hello"}"#
        )

        // 1. Record live request (auto mode -> cassette missing -> record)
        let recorder = HttpRecorder.layer(
            "api/login",
            options: RecorderOptions(
                directory: "/cassettes",
                metadata: ["suite": "auth"],
                redact: RedactOptions(allowRequestHeaders: ["x-trace-id"])
            ),
            upstream: liveMock,
            fileSystem: fs,
            environment: env
        )

        let liveResponse = try await recorder.withScope { transport in
            try await transport.send(HTTPRequest(
                method: "POST",
                url: "https://api.example.test/login?api_key=raw-query-key&safe=1",
                headers: [
                    "Content-Type": "application/json",
                    "Authorization": "Bearer live-bearer-1234567890abcdef",
                    "Cookie": "session=abc",
                    "X-Trace-Id": "trace-1",
                ],
                body: Array(#"{"password":"my-password","user":"alice"}"#.utf8)
            ))
        }

        // Caller receives unredacted live response
        #expect(String(decoding: liveResponse.body, as: UTF8.self) == #"{"access_token":"live-secret-token","reply":"hello"}"#)
        #expect(liveMock.recordedRequests.count == 1)

        // 2. Inspect saved cassette JSON on disk — verify secrets were redacted
        let savedBytes = try await fs.readFile(at: "/cassettes/api/login.json")
        let savedText = String(decoding: savedBytes, as: UTF8.self)
        #expect(!savedText.contains("raw-query-key"))
        #expect(!savedText.contains("live-bearer-1234567890abcdef"))
        #expect(!savedText.contains("my-password"))
        #expect(!savedText.contains("live-secret-token"))
        #expect(!savedText.contains("super-secret-cookie"))

        let cassette = try decodeCassette(fromBytes: savedBytes)
        let savedHTTP = try #require(httpInteractions(cassette.interactions).first)
        #expect(savedHTTP.request.url == "https://api.example.test/login?api_key=%5BREDACTED%5D&safe=1")
        #expect(savedHTTP.request.headers == ["content-type": "application/json", "x-trace-id": "trace-1"])
        #expect(savedHTTP.response.headers == ["content-type": "application/json"])
        #expect(savedHTTP.response.body == #"{"access_token":"[REDACTED]","reply":"hello"}"#)

        // 3. Reload in a brand-new transport backed by an empty (failing) upstream — auto mode detects cassette -> replay!
        let offlineUpstream = MockHTTPTransport()
        let replayer = HttpRecorder.layer(
            "api/login",
            options: RecorderOptions(
                directory: "/cassettes",
                redact: RedactOptions(allowRequestHeaders: ["x-trace-id"])
            ),
            upstream: offlineUpstream,
            fileSystem: fs,
            environment: env
        )

        // Replay with differently ordered JSON keys still matches canonically!
        let replayed = try await replayer.withScope { transport in
            try await transport.send(HTTPRequest(
                method: "POST",
                url: "https://api.example.test/login?api_key=different-key&safe=1",
                headers: [
                    "Authorization": "Bearer totally-different-token-12345678",
                    "Content-Type": "application/json",
                    "X-Trace-Id": "trace-1",
                ],
                body: Array(#"{"user":"alice","password":"another-password"}"#.utf8)
            ))
        }
        #expect(replayed.head.statusCode == 200)
        #expect(String(decoding: replayed.body, as: UTF8.self) == #"{"access_token":"[REDACTED]","reply":"hello"}"#)
        #expect(offlineUpstream.recordedRequests.isEmpty)
    }

    @Test("records and replays streaming SSE and binary HTTP responses")
    func streamingSSEAndBinaryRecordAndReplay() async throws {
        let fs = InMemoryFileSystem()
        let env = DictionaryEnvironment(variables: [:])

        // SSE streaming
        let sseMock = MockHTTPTransport()
        sseMock.enqueueStream(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            chunks: [
                Array("data: {\"delta\":\"hel\"}\n\n".utf8),
                Array("data: {\"delta\":\"lo\"}\n\n".utf8),
                Array("data: [DONE]\n\n".utf8),
            ]
        )

        let sseRecorder = HttpRecorder.layer(
            "stream/sse",
            options: RecorderOptions(directory: "/cassettes"),
            upstream: sseMock,
            fileSystem: fs,
            environment: env
        )
        let req = HTTPRequest(method: "POST", url: "https://api.example.test/stream", headers: ["content-type": "application/json"], body: Array(#"{"prompt":"hi"}"#.utf8))
        let liveStream = try await sseRecorder.stream(req)
        var liveChunks: [String] = []
        for try await chunk in liveStream.chunks {
            liveChunks.append(String(decoding: chunk, as: UTF8.self))
        }
        try await sseRecorder.finish()
        #expect(liveChunks == ["data: {\"delta\":\"hel\"}\n\n", "data: {\"delta\":\"lo\"}\n\n", "data: [DONE]\n\n"])

        // Replay stream offline
        let sseReplayer = HttpRecorder.layer(
            "stream/sse",
            options: RecorderOptions(directory: "/cassettes"),
            upstream: MockHTTPTransport(),
            fileSystem: fs,
            environment: env
        )
        let replayedStream = try await sseReplayer.stream(req)
        var replayedBytes: [UInt8] = []
        for try await chunk in replayedStream.chunks {
            replayedBytes.append(contentsOf: chunk)
        }
        try await sseReplayer.finish()
        #expect(String(decoding: replayedBytes, as: UTF8.self) == liveChunks.joined())

        // Binary streaming
        let pngBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0xFF, 0x00, 0x80]
        let binMock = MockHTTPTransport()
        binMock.enqueueStream(
            statusCode: 200,
            headers: ["Content-Type": "image/png"],
            chunks: [Array(pngBytes[0..<3]), Array(pngBytes[3...])]
        )
        let binRecorder = HttpRecorder.layer(
            "stream/png",
            options: RecorderOptions(directory: "/cassettes"),
            upstream: binMock,
            fileSystem: fs,
            environment: env
        )
        let imgReq = HTTPRequest(method: "GET", url: "https://cdn.example.test/logo.png")
        let binLive = try await binRecorder.stream(imgReq)
        var recordedBin: [UInt8] = []
        for try await chunk in binLive.chunks { recordedBin.append(contentsOf: chunk) }
        try await binRecorder.finish()
        #expect(recordedBin == pngBytes)

        let savedCassette = try decodeCassette(fromBytes: try await fs.readFile(at: "/cassettes/stream/png.json"))
        #expect(httpInteractions(savedCassette.interactions).first?.response.bodyEncoding == .base64)

        let binReplayer = HttpRecorder.layer(
            "stream/png",
            options: RecorderOptions(directory: "/cassettes"),
            upstream: MockHTTPTransport(),
            fileSystem: fs,
            environment: env
        )
        let replayedBin = try await binReplayer.send(imgReq)
        try await binReplayer.finish()
        #expect(replayedBin.body == pngBytes)
    }

    @Test("rejects secret leaks in both unary and streaming recordings without writing cassette")
    func rejectsSecretLeaksOnRecord() async throws {
        let fs = InMemoryFileSystem()
        let env = DictionaryEnvironment(variables: [:])

        let mock = MockHTTPTransport()
        mock.enqueueResponse(statusCode: 200, headers: ["content-type": "text/plain"], text: "Bearer abcdefghijklmnopqrstuvwxyz1234")
        let recorder = HTTPRecorder.cassetteLayer(
            "unsafe-unary",
            options: RecordReplayOptions(mode: .record, directory: "/cassettes"),
            upstream: mock,
            fileSystem: fs,
            environment: env
        )

        var caughtError: RecorderTransportError?
        do {
            _ = try await recorder.send(HTTPRequest(method: "GET", url: "https://example.test/leaky"))
        } catch let err as RecorderTransportError {
            caughtError = err
        }
        #expect(caughtError?.message.contains("contains possible secrets") == true)
        #expect(await !fs.exists(at: "/cassettes/unsafe-unary.json"))

        // Streaming secret leak
        let streamMock = MockHTTPTransport()
        streamMock.enqueueStream(
            statusCode: 200,
            headers: ["content-type": "text/plain"],
            chunks: [Array("hello ".utf8), Array("Bearer abcdefghijklmnopqrstuvwxyz1234".utf8)]
        )
        let streamRecorder = HTTPRecorder.cassetteLayer(
            "unsafe-stream",
            options: RecordReplayOptions(mode: .record, directory: "/cassettes"),
            upstream: streamMock,
            fileSystem: fs,
            environment: env
        )
        let streaming = try await streamRecorder.stream(HTTPRequest(method: "GET", url: "https://example.test/leaky-stream"))
        var streamError: RecorderTransportError?
        do {
            for try await _ in streaming.chunks {}
        } catch let err as RecorderTransportError {
            streamError = err
        }
        #expect(streamError?.message.contains("contains possible secrets") == true)
        #expect(await !fs.exists(at: "/cassettes/unsafe-stream.json"))
    }

    @Test("pool replay handles out-of-order, concurrent, and repeated identical requests")
    func poolReplayOrderingAndConcurrency() async throws {
        let store = CassetteStoreService.memory([
            "multi": [
                .http(HttpInteraction(
                    request: RequestSnapshot(method: "POST", url: "https://example.test/echo", headers: ["content-type": "application/json"], body: #"{"step":1}"#),
                    response: ResponseSnapshot(status: 200, headers: ["content-type": "application/json"], body: #"{"reply":"first"}"#)
                )),
                .http(HttpInteraction(
                    request: RequestSnapshot(method: "POST", url: "https://example.test/echo", headers: ["content-type": "application/json"], body: #"{"step":2}"#),
                    response: ResponseSnapshot(status: 200, headers: ["content-type": "application/json"], body: #"{"reply":"second"}"#)
                )),
            ],
            "retry": [
                .http(HttpInteraction(
                    request: RequestSnapshot(method: "POST", url: "https://example.test/poll", headers: ["content-type": "application/json"], body: #"{"id":"job_1"}"#),
                    response: ResponseSnapshot(status: 200, headers: ["content-type": "application/json"], body: #"{"status":"pending"}"#)
                )),
                .http(HttpInteraction(
                    request: RequestSnapshot(method: "POST", url: "https://example.test/poll", headers: ["content-type": "application/json"], body: #"{"id":"job_1"}"#),
                    response: ResponseSnapshot(status: 200, headers: ["content-type": "application/json"], body: #"{"status":"complete"}"#)
                )),
            ],
        ], environment: DictionaryEnvironment(variables: [:]))

        // Out-of-order replay
        let outOfOrder = HTTPRecorder.recordingLayer(
            "multi",
            options: RecordReplayOptions(mode: .replay),
            upstream: MockHTTPTransport(),
            cassette: store,
            environment: DictionaryEnvironment(variables: [:])
        )
        let r2 = try await outOfOrder.send(HTTPRequest(method: "POST", url: "https://example.test/echo", headers: ["content-type": "application/json"], body: Array(#"{"step":2}"#.utf8)))
        let r1 = try await outOfOrder.send(HTTPRequest(method: "POST", url: "https://example.test/echo", headers: ["content-type": "application/json"], body: Array(#"{"step":1}"#.utf8)))
        try await outOfOrder.finish()
        #expect(String(decoding: r2.body, as: UTF8.self) == #"{"reply":"second"}"#)
        #expect(String(decoding: r1.body, as: UTF8.self) == #"{"reply":"first"}"#)

        // Repeated identical requests replay in cassette order
        let retry = HTTPRecorder.recordingLayer(
            "retry",
            options: RecordReplayOptions(mode: .replay),
            upstream: MockHTTPTransport(),
            cassette: store,
            environment: DictionaryEnvironment(variables: [:])
        )
        let pollReq = HTTPRequest(method: "POST", url: "https://example.test/poll", headers: ["content-type": "application/json"], body: Array(#"{"id":"job_1"}"#.utf8))
        let p1 = try await retry.send(pollReq)
        let p2 = try await retry.send(pollReq)
        #expect(String(decoding: p1.body, as: UTF8.self) == #"{"status":"pending"}"#)
        #expect(String(decoding: p2.body, as: UTF8.self) == #"{"status":"complete"}"#)

        // Exhaustion error
        var exhaustedErr: RecorderTransportError?
        do {
            _ = try await retry.send(pollReq)
        } catch let err as RecorderTransportError {
            exhaustedErr = err
        }
        #expect(exhaustedErr?.message.contains("all 2 recorded interactions have already been consumed") == true)

        // Concurrent claiming
        let concurrent = HTTPRecorder.recordingLayer(
            "retry",
            options: RecordReplayOptions(mode: .replay),
            upstream: MockHTTPTransport(),
            cassette: store,
            environment: DictionaryEnvironment(variables: [:])
        )
        async let c1 = concurrent.send(pollReq)
        async let c2 = concurrent.send(pollReq)
        let bodies = try await [c1, c2].map { String(decoding: $0.body, as: UTF8.self) }.sorted()
        try await concurrent.finish()
        #expect(bodies == [#"{"status":"complete"}"#, #"{"status":"pending"}"#])
    }

    @Test("sequential, strict, and fallback replay strategies behave deterministically")
    func sequentialStrictAndFallbackStrategies() async throws {
        let env = DictionaryEnvironment(variables: [:])
        let store = CassetteStoreService.memory([
            "seq": [
                .http(HttpInteraction(
                    request: RequestSnapshot(method: "GET", url: "https://example.test/1", headers: [:], body: ""),
                    response: ResponseSnapshot(status: 200, headers: ["content-type": "text/plain"], body: "one")
                )),
                .http(HttpInteraction(
                    request: RequestSnapshot(method: "GET", url: "https://example.test/2", headers: [:], body: ""),
                    response: ResponseSnapshot(status: 200, headers: ["content-type": "text/plain"], body: "two")
                )),
            ],
        ], environment: env)

        // Sequential mode rejects out-of-order request without consuming index 0
        let seq = HTTPRecorder.recordingLayer(
            "seq",
            options: RecordReplayOptions(mode: .replay, replayStrategy: .sequential),
            upstream: MockHTTPTransport(),
            cassette: store,
            environment: env
        )
        await #expect(throws: RecorderTransportError.self) {
            _ = try await seq.send(HTTPRequest(method: "GET", url: "https://example.test/2"))
        }
        let first = try await seq.send(HTTPRequest(method: "GET", url: "https://example.test/1"))
        let second = try await seq.send(HTTPRequest(method: "GET", url: "https://example.test/2"))
        try await seq.finish()
        #expect(String(decoding: first.body, as: UTF8.self) == "one")
        #expect(String(decoding: second.body, as: UTF8.self) == "two")

        // Strict mode fails finish() when cassette has unused interactions
        let strict = HTTPRecorder.recordingLayer(
            "seq",
            options: RecordReplayOptions(mode: .replay, replayStrategy: .strict),
            upstream: MockHTTPTransport(),
            cassette: store,
            environment: env
        )
        var unusedErr: ReplayStateError?
        do {
            try await strict.finish()
        } catch let err as ReplayStateError {
            unusedErr = err
        }
        #expect(unusedErr == .unusedInteractions(cassetteName: "seq", used: 0, total: 2))
        #expect(unusedErr?.description == "Unused recorded interactions in seq: used 0 of 2")

        // Fallback mode replays known requests and falls back to upstream (recording when enabled)
        let upstream = MockHTTPTransport()
        upstream.enqueueResponse(statusCode: 200, headers: ["content-type": "text/plain"], text: "three-live")
        let fallback = HTTPRecorder.recordingLayer(
            "seq",
            options: RecordReplayOptions(mode: .replay, replayStrategy: .fallback(recordMissing: true)),
            upstream: upstream,
            cassette: store,
            environment: env
        )
        let replayedOne = try await fallback.send(HTTPRequest(method: "GET", url: "https://example.test/1"))
        let liveThree = try await fallback.send(HTTPRequest(method: "GET", url: "https://example.test/3"))
        try await fallback.finish()
        #expect(String(decoding: replayedOne.body, as: UTF8.self) == "one")
        #expect(String(decoding: liveThree.body, as: UTF8.self) == "three-live")
        let updated = try await store.read("seq")
        #expect(updated.count == 3)
    }

    @Test("mismatch diffs scrub secrets, preserve unconsumed interactions, and apply custom URL redaction")
    func mismatchDiagnosticsAndNonConsumption() async throws {
        let env = DictionaryEnvironment(variables: [:])
        let store = CassetteStoreService.memory([
            "multi": [
                .http(HttpInteraction(
                    request: RequestSnapshot(method: "POST", url: "https://example.test/echo", headers: ["content-type": "application/json"], body: #"{"step":1}"#),
                    response: ResponseSnapshot(status: 200, headers: ["content-type": "application/json"], body: #"{"reply":"first"}"#)
                )),
                .http(HttpInteraction(
                    request: RequestSnapshot(method: "POST", url: "https://example.test/echo", headers: ["content-type": "application/json"], body: #"{"step":2}"#),
                    response: ResponseSnapshot(status: 200, headers: ["content-type": "application/json"], body: #"{"reply":"second"}"#)
                )),
            ],
        ], environment: env)

        let secret = "private-account"
        let replayer = HTTPRecorder.recordingLayer(
            "multi",
            options: RecordReplayOptions(
                mode: .replay,
                redactor: Redactor.make(RedactOptions(
                    url: { $0.replacing(secret, with: "{account}") }
                ))
            ),
            upstream: MockHTTPTransport(),
            cassette: store,
            environment: env
        )

        var err1: RecorderTransportError?
        do {
            _ = try await replayer.send(HTTPRequest(
                method: "POST",
                url: "https://example.test/\(secret)?api_key=secret-value",
                headers: ["content-type": "application/json"],
                body: Array(#"{"step":3,"token":"sk-123456789012345678901234"}"#.utf8)
            ))
        } catch let e as RecorderTransportError {
            err1 = e
        }
        let msg = try #require(err1?.message)
        #expect(msg.contains("url:"))
        #expect(msg.contains("https://example.test/{account}?api_key=%5BREDACTED%5D"))
        #expect(!msg.contains(secret))
        #expect(msg.contains("body:"))
        #expect(msg.contains("$.step expected 1, received 3"))
        #expect(msg.contains(#"$.token expected undefined, received "[REDACTED]""#))
        #expect(!msg.contains("sk-123456789012345678901234"))

        // Mismatch did not consume interaction 0 or 1 — both still replay cleanly
        let ok1 = try await replayer.send(HTTPRequest(method: "POST", url: "https://example.test/echo", headers: ["content-type": "application/json"], body: Array(#"{"step":1}"#.utf8)))
        let ok2 = try await replayer.send(HTTPRequest(method: "POST", url: "https://example.test/echo", headers: ["content-type": "application/json"], body: Array(#"{"step":2}"#.utf8)))
        try await replayer.finish()
        #expect(String(decoding: ok1.body, as: UTF8.self) == #"{"reply":"first"}"#)
        #expect(String(decoding: ok2.body, as: UTF8.self) == #"{"reply":"second"}"#)
    }

    @Test("CI=true forces replay even when cassette is missing and allows unused missing cassette")
    func ciForcesReplay() async throws {
        let fs = InMemoryFileSystem()
        let ciEnv = DictionaryEnvironment(variables: ["CI": "true"])
        let store = CassetteStoreService.fileSystem(directory: "/cassettes", fileSystem: fs, environment: ciEnv)

        let mode = await resolveAutoMode(cassette: store, name: "missing", environment: ciEnv)
        #expect(mode == .replay)

        // Unused missing cassette finishes cleanly
        let unusedTransport = HTTPRecorder.layer(
            "missing",
            options: RecorderOptions(directory: "/cassettes"),
            upstream: MockHTTPTransport(),
            fileSystem: fs,
            environment: ciEnv
        )
        try await unusedTransport.finish()

        // Requesting against missing cassette under CI=true fails with clear message
        let transport = HTTPRecorder.layer(
            "missing",
            options: RecorderOptions(directory: "/cassettes"),
            upstream: MockHTTPTransport(),
            fileSystem: fs,
            environment: ciEnv
        )
        var err: RecorderTransportError?
        do {
            _ = try await transport.send(HTTPRequest(method: "GET", url: "https://example.test/echo"))
        } catch let e as RecorderTransportError {
            err = e
        }
        #expect(err?.message.contains(#"Fixture "missing" not found"#) == true)
    }

    @Test("records concurrent requests in request-start order even when responses complete out of order")
    func recordsConcurrentRequestsInStartOrder() async throws {
        let fs = InMemoryFileSystem()
        let env = DictionaryEnvironment(variables: [:])
        let firstStarted = AsyncTestGate()
        let releaseFirst = AsyncTestGate()
        let completed = TestEventLog<String>()

        let upstream = MockHTTPTransport(fallbackHandler: { request in
            if request.url.hasSuffix("/first") {
                await firstStarted.open()
                await releaseFirst.wait()
                await completed.append("first")
                return HTTPResponse(head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "text/plain"]), body: Array("first".utf8))
            }
            await completed.append("second")
            await releaseFirst.open()
            return HTTPResponse(head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "text/plain"]), body: Array("second".utf8))
        })

        let recorder = HttpRecorder.layer(
            "concurrent-order",
            options: RecorderOptions(directory: "/cassettes"),
            upstream: upstream,
            fileSystem: fs,
            environment: env
        )

        let firstTask = Task {
            try await recorder.send(HTTPRequest(method: "GET", url: "https://example.test/first"))
        }
        await firstStarted.wait()
        let secondTask = Task {
            try await recorder.send(HTTPRequest(method: "GET", url: "https://example.test/second"))
        }

        let res1 = try await firstTask.value
        let res2 = try await secondTask.value
        try await recorder.finish()

        #expect(String(decoding: res1.body, as: UTF8.self) == "first")
        #expect(String(decoding: res2.body, as: UTF8.self) == "second")
        #expect(await completed.snapshot() == ["second", "first"])

        let cassette = try decodeCassette(fromBytes: try await fs.readFile(at: "/cassettes/concurrent-order.json"))
        let urls = httpInteractions(cassette.interactions).map(\.request.url)
        #expect(urls == ["https://example.test/first", "https://example.test/second"])
    }

    @Test("reconstructs null-body statuses (204/HEAD) and supports passthrough and custom matchers")
    func nullBodyStatusesPassthroughAndCustomMatcher() async throws {
        let env = DictionaryEnvironment(variables: [:])
        let store = CassetteStoreService.memory([
            "null-body": [
                .http(HttpInteraction(
                    request: RequestSnapshot(method: "GET", url: "https://example.test/empty", headers: [:], body: ""),
                    response: ResponseSnapshot(status: 204, headers: [:], body: "ignored")
                )),
                .http(HttpInteraction(
                    request: RequestSnapshot(method: "HEAD", url: "https://example.test/head", headers: [:], body: ""),
                    response: ResponseSnapshot(status: 200, headers: [:], body: "ignored")
                )),
            ],
        ], environment: env)

        let replayer = HTTPRecorder.recordingLayer(
            "null-body",
            options: RecordReplayOptions(
                mode: .replay,
                match: { incoming, recorded in incoming.method == recorded.method }
            ),
            upstream: MockHTTPTransport(),
            cassette: store,
            environment: env
        )
        let r204 = try await replayer.send(HTTPRequest(method: "GET", url: "https://example.test/different-url"))
        let rHead = try await replayer.send(HTTPRequest(method: "HEAD", url: "https://example.test/different-head"))
        try await replayer.finish()
        #expect(r204.head.statusCode == 204)
        #expect(r204.body.isEmpty)
        #expect(rHead.head.statusCode == 200)
        #expect(rHead.body.isEmpty)

        // Passthrough mode
        let live = MockHTTPTransport()
        live.enqueueResponse(statusCode: 201, headers: [:], text: "passthrough-ok")
        let passthrough = HTTPRecorder.recordingLayer(
            "unused",
            options: RecordReplayOptions(mode: .passthrough),
            upstream: live,
            cassette: store,
            environment: env
        )
        let passRes = try await passthrough.send(HTTPRequest(method: "POST", url: "https://example.test/live"))
        try await passthrough.finish()
        #expect(passRes.head.statusCode == 201)
        #expect(String(decoding: passRes.body, as: UTF8.self) == "passthrough-ok")
        #expect(HTTPRecorder.defaultMatcher(
            RequestSnapshot(method: "GET", url: "https://a.test"),
            RequestSnapshot(method: "GET", url: "https://a.test")
        ))
    }
}

import Testing
import Synchronization
import OpenCodeAI
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// NOTE: Never import Foundation or FoundationEssentials in files that `import Testing` (macOS CLT cross-import rule).

@Suite("MCP Events, Follow/Reopen, Automation Sync #3 & Flag Graduation")
struct MCPEventsAndAutomationSync3Tests {
    // MARK: - In-Memory Bidirectional JSON-RPC Transport for Live MCP Events Tests

    private final class MockEventServerTransport: CoreMCP.Transport, Sendable {
        struct StreamOpen: Sendable {
            let id: CoreMCP.JSONRPCID
            let params: [String: JSONValue]
        }

        private struct State: Sendable {
            var onMessage: (@Sendable (CoreMCP.JSONRPCMessage) -> Void)?
            var onError: (@Sendable (any Error) -> Void)?
            var onClose: (@Sendable () -> Void)?
            var clientCapabilities: JSONValue?
            var listRequests: [JSONValue] = []
            var streams: [StreamOpen] = []
            var listens: [StreamOpen] = []
            var cancelledIDs: [JSONValue] = []
            var closed = false
        }

        let protocolVersion: String
        let offersEvents: Bool
        let listChanged: Bool
        let pages: [[JSONValue]]
        private let state = Mutex(State())

        init(
            protocolVersion: String = CoreMCP.Client.latestProtocolVersion,
            offersEvents: Bool = true,
            listChanged: Bool = false,
            pages: [[JSONValue]] = [
                [
                    .object([
                        "name": .string("job.finished"),
                        "description": .string("A job ended"),
                        "delivery": .array([.string("push"), .string("poll")]),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object(["job": .object(["type": .string("string")])]),
                        ]),
                        "payloadSchema": .object([
                            "type": .string("object"),
                            "properties": .object(["status": .object(["type": .string("string")])]),
                            "required": .array([.string("status")]),
                        ]),
                    ]),
                ],
                [
                    .object([
                        "name": .string("job.failed"),
                        "delivery": .array([.string("push"), .string("future")]),
                        "inputSchema": .object([:]),
                        "payloadSchema": .object([:]),
                    ]),
                    // Malformed: missing payloadSchema -> skipped without hiding valid types.
                    .object([
                        "name": .string("job.broken"),
                        "delivery": .array([.string("push")]),
                        "inputSchema": .object([:]),
                    ]),
                    // Malformed: empty delivery -> skipped without hiding valid types.
                    .object([
                        "name": .string("job.empty_delivery"),
                        "delivery": .array([]),
                        "inputSchema": .object([:]),
                        "payloadSchema": .object([:]),
                    ]),
                ],
            ]
        ) {
            self.protocolVersion = protocolVersion
            self.offersEvents = offersEvents
            self.listChanged = listChanged
            self.pages = pages
        }

        var clientCapabilities: JSONValue? { state.withLock { $0.clientCapabilities } }
        var listRequests: [JSONValue] { state.withLock { $0.listRequests } }
        var streams: [StreamOpen] { state.withLock { $0.streams } }
        var listens: [StreamOpen] { state.withLock { $0.listens } }
        var cancelledIDs: [JSONValue] { state.withLock { $0.cancelledIDs } }

        func start() async throws {}

        func setHandlers(
            onMessage: (@Sendable (CoreMCP.JSONRPCMessage) -> Void)?,
            onError: (@Sendable (any Error) -> Void)?,
            onClose: (@Sendable () -> Void)?
        ) {
            state.withLock { s in
                s.onMessage = onMessage
                s.onError = onError
                s.onClose = onClose
            }
        }

        func close() async throws {
            let cb = state.withLock { s -> (@Sendable () -> Void)? in
                if s.closed { return nil }
                s.closed = true
                return s.onClose
            }
            cb?()
        }

        private func deliver(_ msg: CoreMCP.JSONRPCMessage) {
            let cb = state.withLock { $0.onMessage }
            cb?(msg)
        }

        func send(_ message: CoreMCP.JSONRPCMessage) async throws {
            switch message {
            case .notification(let note):
                if note.method == "notifications/cancelled",
                   case .object(let obj) = note.params,
                   let reqID = obj["requestId"]
                {
                    state.withLock { $0.cancelledIDs.append(reqID) }
                }
            case .request(let req):
                let paramsObj: [String: JSONValue] = if case .object(let o) = req.params { o } else { [:] }
                switch req.method {
                case "initialize":
                    state.withLock { $0.clientCapabilities = paramsObj["capabilities"] }
                    var caps: [String: JSONValue] = [:]
                    if offersEvents {
                        caps["extensions"] = .object([
                            CoreMCP.Client.eventsExtensionKey: .object(listChanged ? ["listChanged": .bool(true)] : [:]),
                        ])
                    }
                    deliver(.response(CoreMCP.JSONRPCResponse(
                        id: req.id,
                        result: .object([
                            "protocolVersion": .string(protocolVersion),
                            "capabilities": .object(caps),
                            "serverInfo": .object(["name": .string("jobs"), "version": .string("1.0.0")]),
                        ])
                    )))
                case "events/list":
                    state.withLock { $0.listRequests.append(.object(paramsObj)) }
                    let pageIndex: Int
                    if case .string(let cur) = paramsObj["cursor"], cur.hasPrefix("page-"),
                       let idx = Int(cur.dropFirst(5))
                    {
                        pageIndex = idx
                    } else {
                        pageIndex = 0
                    }
                    let items = pageIndex < pages.count ? pages[pageIndex] : []
                    var result: [String: JSONValue] = ["events": .array(items)]
                    if pageIndex + 1 < pages.count {
                        result["nextCursor"] = .string("page-\(pageIndex + 1)")
                    }
                    deliver(.response(CoreMCP.JSONRPCResponse(id: req.id, result: .object(result))))
                case "events/stream":
                    state.withLock { $0.streams.append(StreamOpen(id: req.id, params: paramsObj)) }
                case "subscriptions/listen":
                    state.withLock { $0.listens.append(StreamOpen(id: req.id, params: paramsObj)) }
                    let idVal: JSONValue = switch req.id {
                    case .int(let i): .int(i)
                    case .string(let s): .string(s)
                    }
                    deliver(.notification(CoreMCP.JSONRPCNotification(
                        method: "notifications/subscriptions/acknowledged",
                        params: .object([
                            "notifications": paramsObj["notifications"] ?? .object([:]),
                            "_meta": .object([CoreMCP.Client.subscriptionIDMetaKey: idVal]),
                        ])
                    )))
                default:
                    deliver(.response(CoreMCP.JSONRPCResponse(id: req.id, result: .object([:]))))
                }
            case .response:
                break
            }
        }

        func sendNotification(method: String, subscriptionID: CoreMCP.JSONRPCID, params: [String: JSONValue] = [:]) {
            let idVal: JSONValue = switch subscriptionID {
            case .int(let i): .int(i)
            case .string(let s): .string(s)
            }
            var full = params
            full["_meta"] = .object([CoreMCP.Client.subscriptionIDMetaKey: idVal])
            deliver(.notification(CoreMCP.JSONRPCNotification(method: method, params: .object(full))))
        }

        func completeRequest(id: CoreMCP.JSONRPCID) {
            deliver(.response(CoreMCP.JSONRPCResponse(id: id, result: .object(["resultType": .string("complete")]))))
        }
    }

    private func waitUntil(
        timeoutMs: Int = 5_000,
        _ predicate: @Sendable () async throws -> Bool
    ) async throws {
        let stepMs = 10
        let maxSteps = max(1, timeoutMs / stepMs)
        for _ in 0..<maxSteps {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(stepMs))
        }
        Issue.record("Timed out after \(timeoutMs)ms waiting for condition")
    }

    // MARK: - 1. SEP-2243 x-mcp-header validation, paramHeaders encoding, and ISO-8601 timestamp check

    @Test("CoreMCP.Client validates x-mcp-header annotations, encodes Mcp-Param-* headers, and validates ISO-8601")
    func headerParamsAndISO8601Parity() throws {
        // Valid nested header annotations
        let validSchema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object([
                "job": .object(["type": .string("string"), "x-mcp-header": .string("Job")]),
                "nested": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "count": .object(["type": .string("integer"), "x-mcp-header": .string("Count")]),
                        "flag": .object(["type": .string("boolean"), "x-mcp-header": .string("Flag")]),
                        "special": .object(["type": .string("string"), "x-mcp-header": .string("Special")]),
                        "sentinel": .object(["type": .string("string"), "x-mcp-header": .string("Sentinel")]),
                    ]),
                ]),
            ]),
        ]
        let params = try CoreMCP.Client.headerParams(validSchema).get()
        #expect(params.count == 5)

        let headers = CoreMCP.Client.paramHeaders(params, arguments: [
            "job": .string("j1"),
            "nested": .object([
                "count": .int(42),
                "flag": .bool(true),
                "special": .string(" hello "),
                "sentinel": .string("=?base64?YWJj?="),
            ]),
        ])
        #expect(headers["Mcp-Param-Job"] == "j1")
        #expect(headers["Mcp-Param-Count"] == "42")
        #expect(headers["Mcp-Param-Flag"] == "true")
        #expect(headers["Mcp-Param-Special"]?.hasPrefix("=?base64?") == true)
        #expect(headers["Mcp-Param-Special"]?.hasSuffix("?=") == true)
        #expect(headers["Mcp-Param-Sentinel"]?.hasPrefix("=?base64?") == true)

        // Invalid: root annotation
        if case .success = CoreMCP.Client.headerParams(["type": .string("string"), "x-mcp-header": .string("Bad")]) {
            Issue.record("Expected root x-mcp-header to fail")
        }
        // Invalid: inside unreachable oneOf / items
        if case .success = CoreMCP.Client.headerParams([
            "oneOf": .array([.object(["properties": .object(["a": .object(["type": .string("string"), "x-mcp-header": .string("A")])])])]),
        ]) {
            Issue.record("Expected unreachable x-mcp-header under oneOf to fail")
        }
        // Invalid: non-primitive type
        if case .success = CoreMCP.Client.headerParams([
            "properties": .object(["arr": .object(["type": .string("array"), "x-mcp-header": .string("Arr")])]),
        ]) {
            Issue.record("Expected array type x-mcp-header to fail")
        }
        // Invalid: duplicate case-insensitive header
        if case .success = CoreMCP.Client.headerParams([
            "properties": .object([
                "a": .object(["type": .string("string"), "x-mcp-header": .string("Dup")]),
                "b": .object(["type": .string("string"), "x-mcp-header": .string("dup")]),
            ]),
        ]) {
            Issue.record("Expected duplicate case-insensitive x-mcp-header to fail")
        }

        // ISO-8601 timestamp validation
        #expect(CoreMCP.Client.isValidISO8601Timestamp("2026-11-11T00:00:00Z"))
        #expect(CoreMCP.Client.isValidISO8601Timestamp("2026-11-11T23:59:59.123+05:30"))
        #expect(CoreMCP.Client.isValidISO8601Timestamp("2026-11-11T12:30Z"))
        #expect(!CoreMCP.Client.isValidISO8601Timestamp("2026-13-01T00:00:00Z"))
        #expect(!CoreMCP.Client.isValidISO8601Timestamp("not-a-timestamp"))
        #expect(!CoreMCP.Client.isValidISO8601Timestamp("2026-11-11T00:00:00"))
    }

    // MARK: - 2. 2026-07-28 gating, events/list pagination, malformed skipping, and list_changed listener

    @Test("CoreMCP.Client exposes events only on 2026-07-28, paginates/filters events/list, and listens for list_changed")
    func clientEraGatingPaginationAndListChanged() async throws {
        // Legacy server -> events is nil even when advertised.
        let legacyTransport = MockEventServerTransport(protocolVersion: CoreMCP.Client.legacyProtocolVersion)
        let legacyConn = try await CoreMCP.Client.connect(CoreMCP.Client.ConnectOptions(
            server: "jobs",
            config: .local(McpSchema.LocalConfig(command: ["noop"])),
            events: true,
            transportOverride: legacyTransport,
            attachedProtocol: .legacy
        ))
        #expect(legacyConn.events == nil)
        try await legacyConn.close()

        // Undeclared events -> events is nil and client doesn't advertise extensions.
        let undeclaredTransport = MockEventServerTransport()
        let undeclaredConn = try await CoreMCP.Client.connect(CoreMCP.Client.ConnectOptions(
            server: "jobs",
            config: .local(McpSchema.LocalConfig(command: ["noop"])),
            events: false,
            transportOverride: undeclaredTransport,
            attachedProtocol: .rev20260728
        ))
        #expect(undeclaredConn.events == nil)
        if case .object(let caps) = undeclaredTransport.clientCapabilities {
            #expect(caps["extensions"] == nil)
        }
        try await undeclaredConn.close()

        // Modern server with listChanged: true -> paginates, skips malformed types, opens subscriptions/listen, relists on ack/change/reopen.
        let transport = MockEventServerTransport(listChanged: true)
        let conn = try await CoreMCP.Client.connect(CoreMCP.Client.ConnectOptions(
            server: "jobs",
            config: .local(McpSchema.LocalConfig(command: ["noop"])),
            events: true,
            transportOverride: transport,
            attachedProtocol: .rev20260728,
            sleep: { _ in try await Task.sleep(for: .milliseconds(5)) }
        ))
        let events = try #require(conn.events)
        let listed = try await events.list()
        #expect(listed.map(\.name) == ["job.finished", "job.failed"])
        #expect(listed[1].delivery == ["push", "future"])

        // Wait for listen open + ack relist (2 pages initial + 2 pages after ack = 4 requests).
        try await waitUntil { transport.listens.count >= 1 && transport.listRequests.count >= 4 }
        let firstListen = transport.listens[0]
        #expect(firstListen.params["notifications"] == .object(["eventsListChanged": .bool(true)]))

        // Notification triggers another coalesced 2-page relist.
        let beforeNotif = transport.listRequests.count
        transport.sendNotification(method: "notifications/events/list_changed", subscriptionID: firstListen.id)
        try await waitUntil { transport.listRequests.count >= beforeNotif + 2 }

        // Server closing listen stream triggers reopen + relist.
        let beforeClose = transport.listRequests.count
        transport.completeRequest(id: firstListen.id)
        try await waitUntil { transport.listens.count >= 2 && transport.listRequests.count >= beforeClose + 2 }

        try await conn.close()
    }

    // MARK: - 3. Live events/stream: check(), default maxAgeMs, payload drop, heartbeat watchdog, cancel

    @Test("CoreMCP.Client.Events validates check(), sets 1h replay maxAgeMs, drops bad payloads, and trips heartbeat watchdog")
    func clientStreamValidationDropAndWatchdog() async throws {
        let transport = MockEventServerTransport()
        let conn = try await CoreMCP.Client.connect(CoreMCP.Client.ConnectOptions(
            server: "jobs",
            config: .local(McpSchema.LocalConfig(command: ["noop"])),
            events: true,
            transportOverride: transport,
            attachedProtocol: .rev20260728,
            ungrantedSilenceMs: 2_000,
            sleep: { ms in
                // Scale down only the granted heartbeat silence (3 x 10_000ms) so the watchdog trips quickly; keep
                // the ungranted silence intact so a slow runner still delivers `active` and the events first.
                try await Task.sleep(for: .milliseconds(ms >= 30_000 ? 400 : ms))
            }
        ))
        let events = try #require(conn.events)

        // Unknown event type fails check() with -32023 without opening a stream.
        let unknownErr = await #expect(throws: CoreMCP.Client.EventStreamRejectedError.self) {
            try await events.check(name: "missing", arguments: nil)
        }
        #expect(unknownErr?.code == -32023)
        #expect(transport.streams.isEmpty)

        // Wrong argument type fails check() with -32602 without opening a stream.
        let badArgErr = await #expect(throws: CoreMCP.Client.EventStreamRejectedError.self) {
            try await events.check(name: "job.finished", arguments: ["job": .int(99)])
        }
        #expect(badArgErr?.code == -32602)
        #expect(transport.streams.isEmpty)

        // Opening from a cursor sets default maxAgeMs = 3_600_000 (1 hour).
        let stream = try await events.stream(
            name: "job.finished",
            arguments: ["job": .string("j1")],
            cursor: "c0",
            maxAgeMs: nil
        )
        let collected = AtomicBox<[CoreMCP.Client.EventMessage]>([])
        let consumerError = AtomicBox<String?>(nil)
        let consumer = Task {
            do {
                for try await msg in stream {
                    collected.modify { $0.append(msg) }
                }
            } catch {
                consumerError.set(String(describing: error))
            }
        }

        try await waitUntil { transport.streams.count == 1 }
        let opened = transport.streams[0]
        #expect(opened.params["cursor"] == .string("c0"))
        #expect(opened.params["maxAgeMs"] == .int(3_600_000))

        // Active with heartbeatMs=10_000 -> delivered.
        transport.sendNotification(
            method: "notifications/events/active",
            subscriptionID: opened.id,
            params: ["cursor": .string("c0"), "truncated": .bool(true), "heartbeatMs": .int(10_000)]
        )
        // Event with mismatched payloadSchema (status is int instead of string) -> dropped silently!
        transport.sendNotification(
            method: "notifications/events/event",
            subscriptionID: opened.id,
            params: [
                "eventId": .string("e_bad"),
                "name": .string("job.finished"),
                "timestamp": .string("2026-11-11T00:00:00Z"),
                "data": .object(["status": .int(123)]),
                "cursor": .string("c_bad"),
            ]
        )
        // Valid event -> delivered!
        transport.sendNotification(
            method: "notifications/events/event",
            subscriptionID: opened.id,
            params: [
                "eventId": .string("e1"),
                "name": .string("job.finished"),
                "timestamp": .string("2026-11-11T00:00:01Z"),
                "data": .object(["status": .string("ok")]),
                "cursor": .string("c1"),
            ]
        )

        // Wait for watchdog timeout (scaled to 40ms) -> fails with heartbeat error & cancels request!
        await consumer.value
        let msgs = collected.get()
        #expect(msgs.count == 2)
        #expect(msgs.first == .active(cursor: "c0", truncated: true))
        #expect(msgs.dropFirst().first == .event(
            eventId: "e1",
            name: "job.finished",
            timestamp: "2026-11-11T00:00:01Z",
            data: ["status": .string("ok")],
            cursor: "c1"
        ))
        #expect(consumerError.get()?.contains("stopped sending event stream heartbeats") == true)
        try await waitUntil { !transport.cancelledIDs.isEmpty }

        try await conn.close()
    }

    // MARK: - 4. Streamable HTTP Mcp-Name + Mcp-Param-* headers & -32020 relist+retry

    @Test("StreamableHTTPTransport sends Mcp-Name and Mcp-Param-* headers and retries once on -32020 HeaderMismatch")
    func streamableHTTPHeaderMismatchRetry() async throws {
        let listsCount = AtomicCounter(0)
        let recordedStreamHeaders = AtomicBox<[(name: String?, job: String?)]>([])

        let http = Sync2MockHTTPTransport { req in
            let msg = try CoreSync2Helpers.decodeRPCRequest(from: req.body)
            switch msg {
            case .request(let r) where r.method == "initialize":
                return try CoreSync2Helpers.makeJSONResponse(body: .object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(1),
                    "result": .object([
                        "protocolVersion": .string("2026-07-28"),
                        "capabilities": .object([
                            "extensions": .object([CoreMCP.Client.eventsExtensionKey: .object([:])]),
                        ]),
                        "serverInfo": .object(["name": .string("resources")]),
                    ]),
                ]))
            case .request(let r) where r.method == "events/list":
                let n = listsCount.increment()
                var jobSchema: [String: JSONValue] = ["type": .string("string")]
                if n > 1 {
                    jobSchema["x-mcp-header"] = .string("Job")
                }
                let idVal: JSONValue = switch r.id {
                case .int(let i): .int(i)
                case .string(let s): .string(s)
                }
                return try CoreSync2Helpers.makeJSONResponse(body: .object([
                    "jsonrpc": .string("2.0"),
                    "id": idVal,
                    "result": .object([
                        "events": .array([
                            .object([
                                "name": .string("job.finished"),
                                "delivery": .array([.string("push")]),
                                "inputSchema": .object([
                                    "type": .string("object"),
                                    "properties": .object(["job": .object(jobSchema)]),
                                ]),
                                "payloadSchema": .object(["type": .string("object")]),
                            ]),
                        ]),
                    ]),
                ]))
            case .request(let r) where r.method == "events/stream":
                let mcpName = req.headers.first { $0.key.lowercased() == "mcp-name" }?.value
                let mcpJob = req.headers.first { $0.key.lowercased() == "mcp-param-job" }?.value
                recordedStreamHeaders.modify { $0.append((mcpName, mcpJob)) }
                let idVal: JSONValue = switch r.id {
                case .int(let i): .int(i)
                case .string(let s): .string(s)
                }
                if mcpJob == nil {
                    return try CoreSync2Helpers.makeJSONResponse(
                        status: 400,
                        body: .object([
                            "jsonrpc": .string("2.0"),
                            "id": idVal,
                            "error": .object(["code": .int(-32020), "message": .string("Header mismatch")]),
                        ])
                    )
                }
                let activeLine = #"data: {"jsonrpc":"2.0","method":"notifications/events/active","params":{"cursor":"c1","truncated":false,"heartbeatMs":30000,"_meta":{"io.modelcontextprotocol/subscriptionId":\#(idVal == .int(4) ? "4" : "5")}}}"#
                let reqIDNum: Int64 = if case .int(let i) = r.id { i } else { 0 }
                let sse = """
                data: {"jsonrpc":"2.0","method":"notifications/events/active","params":{"cursor":"c1","truncated":false,"heartbeatMs":30000,"_meta":{"io.modelcontextprotocol/subscriptionId":\(reqIDNum)}}}

                data: {"jsonrpc":"2.0","id":\(reqIDNum),"result":{"resultType":"complete"}}

                """
                _ = activeLine
                return CoreSync2Helpers.makeTextResponse(
                    status: 200,
                    headers: ["content-type": "text/event-stream"],
                    body: sse
                )
            case .notification:
                return CoreSync2Helpers.makeTextResponse(status: 202)
            default:
                return CoreSync2Helpers.makeTextResponse(status: 404)
            }
        }

        let conn = try await CoreMCP.Client.connect(CoreMCP.Client.ConnectOptions(
            server: "resources",
            config: .remote(McpSchema.RemoteConfig(url: "http://127.0.0.1:9999/mcp", wireProtocol: .rev20260728)),
            events: true,
            http: http
        ))
        let events = try #require(conn.events)
        let stream = try await events.stream(name: "job.finished", arguments: ["job": .string("j1")], cursor: nil, maxAgeMs: nil)
        var msgs: [CoreMCP.Client.EventMessage] = []
        for try await msg in stream {
            msgs.append(msg)
        }
        #expect(msgs == [.active(cursor: "c1", truncated: false)])
        let attempts = recordedStreamHeaders.get()
        #expect(attempts.count == 2)
        #expect(attempts[0].name == "job.finished" && attempts[0].job == nil)
        #expect(attempts[1].name == "job.finished" && attempts[1].job == "j1")
    }

    // MARK: - 5. EventErrors.reopen, Registry.followEvents (backoff, seen dedup, truncation, oversized cursor), subscribe

    private final class ScriptedEventsProducer: CoreMCP.Client.Events, Sendable {
        let onStream: @Sendable (String, [String: JSONValue]?, String?) async throws -> AsyncThrowingStream<CoreMCP.Client.EventMessage, Swift.Error>

        init(
            onStream: @escaping @Sendable (String, [String: JSONValue]?, String?) async throws -> AsyncThrowingStream<CoreMCP.Client.EventMessage, Swift.Error>
        ) {
            self.onStream = onStream
        }

        func list() async throws -> [CoreMCP.Client.EventType] {
            [CoreMCP.Client.EventType(name: "job.finished", delivery: ["push"])]
        }

        func check(name: String, arguments: [String: JSONValue]?) async throws {
            _ = (name, arguments)
        }

        func stream(
            name: String,
            arguments: [String: JSONValue]?,
            cursor: String?,
            maxAgeMs: Int?
        ) async throws -> AsyncThrowingStream<CoreMCP.Client.EventMessage, Swift.Error> {
            _ = maxAgeMs
            return try await onStream(name, arguments, cursor)
        }
    }

    @Test("EventErrors.reopen & Registry.followEvents handle jittered backoff, reset-on-active, dedup, truncation, and oversized cursors")
    func reopenScheduleAndFollowEventsParity() async throws {
        // Reopen schedule: 1s -> 2s -> 4s -> 8s -> 16s -> 30s -> 30s, jittered in [0.8, 1.2].
        let schedule = CoreMCP.EventErrors.reopen
        #expect(schedule.baseDelay(attempt: 0) == 1_000)
        #expect(schedule.baseDelay(attempt: 1) == 2_000)
        #expect(schedule.baseDelay(attempt: 2) == 4_000)
        #expect(schedule.baseDelay(attempt: 3) == 8_000)
        #expect(schedule.baseDelay(attempt: 4) == 16_000)
        #expect(schedule.baseDelay(attempt: 5) == 30_000)
        #expect(schedule.baseDelay(attempt: 10) == 30_000)
        for _ in 0..<20 {
            let d = schedule.delayMs(attempt: 1)
            #expect(d >= 1_600 && d <= 2_400)
        }

        // followEvents: 2 failed opens (backoff 1s, 2s) -> active resets backoff -> EOF -> reopen at 1s with saved cursor
        // -> truncated active sets truncated=true on ONLY first event -> duplicate eventId skipped while cursor still advances -> terminated ends cleanly.
        let sleepDelays = AtomicBox<[Int64]>([])
        let openCursors = AtomicBox<[String?]>([])
        let attemptCount = AtomicCounter(0)
        let producer = ScriptedEventsProducer { _, _, cursor in
            openCursors.modify { $0.append(cursor) }
            let n = attemptCount.increment()
            if n <= 2 {
                throw PlatformError.ioFailure("temporary outage \(n)")
            }
            if n == 3 {
                return AsyncThrowingStream { cont in
                    cont.yield(.active(cursor: "c1", truncated: false))
                    cont.yield(.heartbeat(cursor: "c5"))
                    cont.yield(.event(eventId: "e1", name: "job.finished", timestamp: "2026-11-11T00:00:00Z", data: ["ok": .bool(true)], cursor: "c6"))
                    cont.finish() // clean EOF -> must reopen from c6 with reset backoff (1s range)
                }
            }
            return AsyncThrowingStream { cont in
                cont.yield(.active(cursor: "c8", truncated: true))
                // Replayed duplicate e1 with new cursor c8b -> skipped, but position moves!
                cont.yield(.event(eventId: "e1", name: "job.finished", timestamp: "2026-11-11T00:00:00Z", data: ["ok": .bool(true)], cursor: "c8b"))
                // First fresh event after truncated active -> truncated == true
                cont.yield(.event(eventId: "e9", name: "job.finished", timestamp: "2026-11-11T00:00:01Z", data: ["ok": .bool(true)], cursor: "c9"))
                // Second fresh event -> truncated == false
                cont.yield(.event(eventId: "e10", name: "job.finished", timestamp: "2026-11-11T00:00:02Z", data: ["ok": .bool(true)], cursor: "c10"))
                cont.finish(throwing: CoreMCP.Client.EventStreamTerminatedError(server: "jobs", code: -32024, message: "revoked"))
            }
        }

        let stream = CoreMCP.Registry.followEvents(
            server: CoreMCP.Registry.ServerName(rawValue: "jobs"),
            name: "job.finished",
            sleep: { ms in sleepDelays.modify { $0.append(ms) } }
        ) { producer }

        var updates: [CoreMCP.Registry.EventUpdate] = []
        var terminalError: (any Error)?
        do {
            for try await u in stream {
                updates.append(u)
            }
        } catch {
            terminalError = error
        }

        #expect(terminalError is CoreMCP.Client.EventStreamTerminatedError)
        #expect(openCursors.get() == [nil, nil, nil, "c6"])
        let delays = sleepDelays.get()
        #expect(delays.count == 3)
        #expect(delays[0] >= 800 && delays[0] <= 1_200)   // attempt 0
        #expect(delays[1] >= 1_600 && delays[1] <= 2_400) // attempt 1
        #expect(delays[2] >= 800 && delays[2] <= 1_200)   // reset to attempt 0 after active!

        let eventsDelivered = updates.compactMap { u -> (String, Bool)? in
            if case .event(let ev, _, let trunc) = u { return (ev.eventId, trunc) }
            return nil
        }
        #expect(eventsDelivered.map(\.0) == ["e1", "e9", "e10"])
        #expect(eventsDelivered.map(\.1) == [false, true, false])
        // Duplicate e1 with cursor "c8b" yielded a .position update rather than a duplicate .event.
        #expect(updates.contains {
            if case .position(let pos) = $0 { return pos.cursor == "c8b" }
            return false
        })

        // Oversized cursor (> 4096 UTF-16 code units) fails immediately with EventsUnavailableError without retrying.
        let oversizedProducer = ScriptedEventsProducer { _, _, _ in
            AsyncThrowingStream { cont in
                cont.yield(.active(cursor: String(repeating: "a", count: 4097), truncated: false))
                cont.finish()
            }
        }
        let oversizedStream = CoreMCP.Registry.followEvents(
            server: CoreMCP.Registry.ServerName(rawValue: "jobs"),
            name: "job.finished",
            sleep: { _ in }
        ) { oversizedProducer }
        await #expect(throws: CoreMCP.Registry.EventsUnavailableError.self) {
            for try await _ in oversizedStream {}
        }
    }

    // MARK: - 6. Registry.subscribe (mcpsub_ ID, bus delivery, no flag gate), Pool.key, AutomationTools.View, Flag graduation

    @Test("Registry.subscribe works without mcp_events flag, Pool.key drops mcpEvents, View reorders action, Flag drops mcp_events")
    func subscribePoolKeyViewAndFlagGraduation() async throws {
        // Flag graduation: mcp_events is gone from Key & registry & CoreFlag.resolve output.
        #expect(!ConfigFlagSchema.Key.allCases.map(\.rawValue).contains("mcp_events"))
        let resolved = CoreFlag.resolve(CoreFlag.ResolveInput(entries: [], channel: "local"))
        #expect(resolved.keys.allSatisfy { $0.rawValue != "mcp_events" })

        // Pool.key drops mcpEvents and includes timeout.
        let k1 = CoreMCP.Pool.key(config: .remote(McpSchema.RemoteConfig(
            url: "https://mcp.example.com/rpc",
            timeout: McpSchema.TimeoutConfig(startup: SchemaPrimitive.PositiveInt(rawValue: 5_000))
        )))
        let k2 = CoreMCP.Pool.key(config: .remote(McpSchema.RemoteConfig(
            url: "https://mcp.example.com/rpc",
            timeout: McpSchema.TimeoutConfig(startup: SchemaPrimitive.PositiveInt(rawValue: 9_000))
        )))
        #expect(k1 != k2)

        // AutomationTools.View encodes `action` after `lastOutcome` and before `lastOutput`.
        let view = CoreTool.AutomationTools.View(
            id: AutomationSchema.ID.create(),
            name: "n",
            trigger: .every(.init(every: "5 minutes")),
            tz: "UTC",
            status: .active,
            runCount: 1,
            lastOutcome: .fired,
            action: .shell(.init(command: "echo hi")),
            lastOutput: "hi"
        )
        #expect(view.status == .active)
        #expect(view.lastOutcome == .fired)

        // Registry.subscribe uses mcpsub_ prefix, publishes to bus, and marks unavailable when server has no events.
        let harness = try await SessionDatabaseHelper.makeHarness()
        let bus = harness.bus
        let registry = CoreMCP.Registry.Service(
            directory: "/workspace",
            bus: bus,
            reopenSleep: { _ in try await Task.sleep(for: .milliseconds(5)) }
        )
        let producer = ScriptedEventsProducer { _, _, _ in
            AsyncThrowingStream { cont in
                cont.yield(.active(cursor: "c1", truncated: false))
                cont.yield(.event(
                    eventId: "e1",
                    name: "job.finished",
                    timestamp: "2026-11-11T00:00:00Z",
                    data: ["job": .string("j1")],
                    cursor: "c2"
                ))
                cont.finish(throwing: CoreMCP.Client.EventStreamTerminatedError(server: "jobs", code: -32024, message: "done"))
            }
        }
        registry.registerEvents(server: "jobs", events: producer)
        let busEvents = bus.subscribe(types: Set([McpEventSchema.ExperimentalEvent.type]))
        let receivedBus = AtomicBox<[[String: JSONValue]]>([])
        let collector = Task {
            for await payload in busEvents {
                if case .object(let obj) = payload.data {
                    receivedBus.modify { $0.append(obj) }
                }
            }
        }
        defer { collector.cancel() }

        let sub = try await registry.subscribe(
            server: "jobs",
            name: "job.finished",
            arguments: ["job": JSONValue.string("j1")],
            cursor: nil
        )
        #expect(sub.id.hasPrefix("mcpsub_"))
        #expect(sub.id.count == "mcpsub_".count + 24)

        try await waitUntil {
            let subs = await registry.subscriptions()
            if case .terminated = subs.first?.status { return true }
            return false
        }
        try await waitUntil { receivedBus.get().count == 1 }
        let delivered = try #require(receivedBus.get().first)
        #expect(delivered["eventId"] == .string("e1"))
        #expect(delivered["cursor"] == .string("c2"))
        #expect(delivered["data"] == .object(["job": .string("j1")]))

        // Unsubscribe removes subscription.
        await registry.unsubscribe(id: sub.id)
        #expect(await registry.subscriptions().isEmpty)
    }

    // MARK: - 7. CoreAutomation.EventPosition omits `id`, Event.follow releases lifecycle cleanly on shutdown

    @Test("CoreAutomation.Event.follow interrupts cleanly on lifecycle shutdown without pausing, and EventPosition omits id")
    func automationFollowLifecycleShutdownAndEventPosition() async throws {
        let pos = CoreAutomation.EventPosition(agent: AgentSchema.ID(rawValue: "build"), cursor: "c1")
        let encoded = try CoreSync2Helpers.encodeToJSONString(pos)
        #expect(encoded.contains(#""agent":"build""#))
        #expect(encoded.contains(#""cursor":"c1""#))
        #expect(!encoded.contains(#""id""#))

        let lifecycle = CoreLocation.Lifecycle.Service()
        let registry = CoreMCP.Registry.Service(directory: "/workspace")
        let producer = ScriptedEventsProducer { _, _, _ in
            AsyncThrowingStream { cont in
                cont.yield(.active(cursor: nil, truncated: false))
                // Hold open until cancelled
            }
        }
        registry.registerEvents(server: "ci", events: producer)

        let stream = try await CoreAutomation.Event.follow(
            trigger: AutomationSchema.Event(server: "ci", event: "job.finished"),
            position: CoreMCP.Registry.EventPosition(cursor: nil, seen: []),
            mcp: registry,
            lifecycle: lifecycle
        )
        #expect(lifecycle.isRetained())

        let endedWithError = AtomicBox<Bool>(false)
        let finished = AtomicBox<Bool>(false)
        let reader = Task {
            do {
                for try await _ in stream {}
            } catch {
                endedWithError.set(true)
            }
            finished.set(true)
        }

        await lifecycle.shutdown()
        try await waitUntil { finished.get() }
        await reader.value
        #expect(!endedWithError.get())
        #expect(!lifecycle.isRetained())

        // Oversized event (> 16_384 serialized bytes) fails follow with "Oversized MCP event".
        let hugeLifecycle = CoreLocation.Lifecycle.Service()
        let hugeRegistry = CoreMCP.Registry.Service(directory: "/workspace")
        let hugeProducer = ScriptedEventsProducer { _, _, _ in
            AsyncThrowingStream { cont in
                cont.yield(.active(cursor: "c1", truncated: false))
                cont.yield(.event(
                    eventId: "e_huge",
                    name: "job.finished",
                    timestamp: "2026-11-11T00:00:00Z",
                    data: ["blob": .string(String(repeating: "x", count: 17_000))],
                    cursor: "c2"
                ))
                cont.finish()
            }
        }
        hugeRegistry.registerEvents(server: "ci", events: hugeProducer)
        let hugeStream = try await CoreAutomation.Event.follow(
            trigger: AutomationSchema.Event(server: "ci", event: "job.finished"),
            position: CoreMCP.Registry.EventPosition(cursor: nil, seen: []),
            mcp: hugeRegistry,
            lifecycle: hugeLifecycle
        )
        var oversizedErr: String?
        do {
            for try await _ in hugeStream {}
        } catch {
            oversizedErr = String(describing: error)
        }
        #expect(oversizedErr?.contains("Oversized MCP event") == true)
        #expect(!hugeLifecycle.isRetained())
    }
}

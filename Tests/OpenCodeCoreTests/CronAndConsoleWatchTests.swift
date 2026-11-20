import Testing
import Synchronization
@testable import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// NOTE: Never import Foundation or FoundationEssentials in files that `import Testing` (macOS CLT cross-import rule).

// MARK: - 1. Cron Triggers & Upstream Effect 4.1.0 Vector Parity

@Suite("Cron Triggers & Upstream Effect Vector Parity")
struct CronTriggersParityTests {
    @Test("All 54 upstream Effect 4.1.0 valid cron vectors match next1, next2, and CoreAutomation.Service create/tick")
    func upstreamValidCronVectorsMatchExactly() async throws {
        #expect(CronVectorsData.validVectors.count >= 40)

        for vector in CronVectorsData.validVectors {
            let zone = try #require(
                CoreAutomation.CronTimeZone.makeNamed(vector.tz),
                "Failed to resolve timezone '\(vector.tz)' for vector '\(vector.label)'"
            )
            let parsed: CoreAutomation.Cron
            do {
                parsed = try CoreAutomation.Cron.parse(vector.expression, timeZone: zone)
            } catch {
                Issue.record("Failed to parse valid vector '\(vector.label)' ('\(vector.expression)' @ \(vector.tz)): \(error)")
                continue
            }
            #expect(parsed.seconds.count == 1, "Vector '\(vector.label)' must fire once per minute")

            let next1 = parsed.nextSlot(after: vector.nowMs)
            #expect(
                next1 == vector.next1Ms,
                "Vector '\(vector.label)' (\(vector.expression) @ \(vector.tz), ref=\(vector.nowMs)): expected next1=\(vector.next1Ms), got \(String(describing: next1))"
            )
            if let next1 {
                let next2 = parsed.nextSlot(after: next1)
                #expect(
                    next2 == vector.next2Ms,
                    "Vector '\(vector.label)' (\(vector.expression) @ \(vector.tz), after next1=\(next1)): expected next2=\(vector.next2Ms), got \(String(describing: next2))"
                )
            }
        }

        // End-to-end verification through CoreAutomation.Service.create + tick on representative vectors
        // covering 5-field, 6-field, DST spring-forward, DST fall-back, and half-hour offsets.
        let sampleLabels: Set<String> = [
            "every minute UTC",
            "weekday 9am mon-fri",
            "6-field fixed second 30",
            "NY spring forward before gap 02:30 slot",
            "NY fall back 01:30 from 01:00 EDT (05:00Z)",
            "London spring forward 01:30 gap",
            "Asia/Kolkata +05:30 half-hour offset",
        ]
        var matchedSamples = 0
        for vector in CronVectorsData.validVectors where sampleLabels.contains(vector.label) {
            matchedSamples += 1
            let clock = CronAndConsoleWatchHelper.MutableClock(vector.nowMs)
            let autoHarness = try await CronAndConsoleWatchHelper.makeAutomationService(
                clock: clock,
                timezone: "UTC"
            )
            let created = try await autoHarness.service.create(
                AutomationSchema.CreateInput(
                    sessionID: autoHarness.owner.id,
                    name: vector.label,
                    trigger: .cron(.init(cron: vector.expression, tz: vector.tz)),
                    action: .prompt(.init(prompt: "ping"))
                ),
                projectID: autoHarness.owner.projectID,
                directory: autoHarness.directory,
                invocation: autoHarness.invocation
            )
            #expect(created.tz == vector.tz)
            #expect(created.nextDueAt.map { Int64($0.epochMillis) } == vector.next1Ms, "create() nextDueAt mismatch for \(vector.label)")

            // Advance clock to next1Ms and tick -> fires once and schedules next2Ms.
            clock.set(vector.next1Ms)
            try await autoHarness.service.tick()
            let updated = try await autoHarness.service.get(created.id)
            #expect(updated.runCount.rawValue == 1, "Expected 1 run for \(vector.label)")
            #expect(updated.nextDueAt.map { Int64($0.epochMillis) } == vector.next2Ms, "tick() nextDueAt mismatch for \(vector.label)")
        }
        #expect(matchedSamples == sampleLabels.count)
    }

    @Test("All 29 upstream Effect 4.1.0 + automation.ts invalid cron vectors produce exact upstream error text")
    func upstreamInvalidCronVectorsProduceExactErrors() async throws {
        #expect(CronVectorsData.invalidVectors.count >= 25)

        let clock = CronAndConsoleWatchHelper.MutableClock(1_773_547_200_000)
        let autoHarness = try await CronAndConsoleWatchHelper.makeAutomationService(clock: clock, timezone: "UTC")

        for vector in CronVectorsData.invalidVectors {
            clock.set(vector.nowMs)
            do {
                _ = try await autoHarness.service.create(
                    AutomationSchema.CreateInput(
                        sessionID: autoHarness.owner.id,
                        name: vector.label,
                        trigger: .cron(.init(cron: vector.expression, tz: vector.tz)),
                        action: .prompt(.init(prompt: "should-fail"))
                    ),
                    projectID: autoHarness.owner.projectID,
                    directory: autoHarness.directory,
                    invocation: autoHarness.invocation
                )
                Issue.record("Expected invalid vector '\(vector.label)' ('\(vector.expression)') to fail with '\(vector.expectedError)'")
            } catch let err as CoreAutomation.InvalidError {
                #expect(
                    err.reason == vector.expectedError,
                    "Vector '\(vector.label)' error mismatch: expected '\(vector.expectedError)', got '\(err.reason)'"
                )
            } catch {
                Issue.record("Vector '\(vector.label)' threw unexpected error type: \(error)")
            }
        }
    }

    @Test("Automation cron timezone inherits Location config timezone, supports trigger override, and parses zoned wall-clock timestamps")
    func timezoneInheritanceAndZonedWallClock() async throws {
        // 2026-06-15T06:30:00.000Z is 2026-06-15T08:30:00+02:00 in Europe/Paris (month0 = 5 for June).
        let refMs = CoreAutomation.CronCalendar.makeUTCMillis(year: 2026, month0: 5, day: 15, hour: 6, minute: 30, second: 0)
        let clock = CronAndConsoleWatchHelper.MutableClock(refMs)
        let autoHarness = try await CronAndConsoleWatchHelper.makeAutomationService(clock: clock, timezone: "Europe/Paris")

        // Inherits Europe/Paris from Location config when trigger.tz is omitted:
        // "0 9 * * *" -> 09:00 CEST = 07:00 UTC.
        let inherited = try await autoHarness.service.create(
            AutomationSchema.CreateInput(
                sessionID: autoHarness.owner.id,
                name: "inherit-paris",
                trigger: .cron(.init(cron: "0 9 * * *")),
                action: .prompt(.init(prompt: "bonjour"))
            ),
            projectID: autoHarness.owner.projectID,
            directory: autoHarness.directory,
            invocation: autoHarness.invocation
        )
        #expect(inherited.tz == "Europe/Paris")
        let expectedParis9am = CoreAutomation.CronCalendar.makeUTCMillis(year: 2026, month0: 5, day: 15, hour: 7, minute: 0, second: 0)
        #expect(inherited.nextDueAt.map { Int64($0.epochMillis) } == expectedParis9am)

        // Explicit trigger.tz overrides Location timezone:
        // "0 9 * * *" in America/New_York -> 09:00 EDT = 13:00 UTC.
        let overridden = try await autoHarness.service.create(
            AutomationSchema.CreateInput(
                sessionID: autoHarness.owner.id,
                name: "override-ny",
                trigger: .cron(.init(cron: "0 9 * * *", tz: "America/New_York")),
                action: .prompt(.init(prompt: "morning"))
            ),
            projectID: autoHarness.owner.projectID,
            directory: autoHarness.directory,
            invocation: autoHarness.invocation
        )
        #expect(overridden.tz == "America/New_York")
        let expectedNY9am = CoreAutomation.CronCalendar.makeUTCMillis(year: 2026, month0: 5, day: 15, hour: 13, minute: 0, second: 0)
        #expect(overridden.nextDueAt.map { Int64($0.epochMillis) } == expectedNY9am)

        // Zoned wall-clock `at` without explicit offset is interpreted in the resolved timezone (Europe/Paris CEST = UTC+2):
        let once = try await autoHarness.service.create(
            AutomationSchema.CreateInput(
                sessionID: autoHarness.owner.id,
                name: "zoned-once",
                trigger: .at(.init(at: "2026-06-15T11:15")),
                action: .prompt(.init(prompt: "lunch"))
            ),
            projectID: autoHarness.owner.projectID,
            directory: autoHarness.directory,
            invocation: autoHarness.invocation
        )
        #expect(once.tz == "Europe/Paris")
        let expectedParis1115 = CoreAutomation.CronCalendar.makeUTCMillis(year: 2026, month0: 5, day: 15, hour: 9, minute: 15, second: 0)
        #expect(once.nextDueAt.map { Int64($0.epochMillis) } == expectedParis1115)
    }
}

// MARK: - 2. Console Watches WebSocket Transport, Reconnect, Backoff, Replay & Fallback

@Suite("Console Watches WebSocket Transport & Fallback")
struct ConsoleWatchesWebSocketTests {
    private static func makeWatchEvent(
        id: String,
        watchID: String = "ew_1",
        sessionID: SessionID,
        kind: String = "comment",
        body: String = "Looks good!"
    ) -> CorePlugin.OpencodeWatches.WatchEvent {
        CorePlugin.OpencodeWatches.WatchEvent(
            id: id,
            watchID: watchID,
            sessionID: sessionID.rawValue,
            source: "github",
            kind: kind,
            actor: .init(login: "octocat", bot: false),
            title: "acme/app#42",
            body: body,
            url: "https://github.com/acme/app/pull/42",
            status: nil
        )
    }

    private final class SyntheticRecorder: Sendable {
        let requests = Mutex<[CoreSessionSynthetic.Request]>([])
        let seenIDs = Mutex<Set<SessionMessageSchema.ID>>([])
        let replayConflicts = Mutex(0)

        func handle(_ req: CoreSessionSynthetic.Request) async throws {
            if let id = req.id {
                let inserted = seenIDs.withLock { $0.insert(id).inserted }
                if !inserted {
                    replayConflicts.withLock { $0 += 1 }
                    throw CoreSessionErrors.SyntheticConflictError(sessionID: req.sessionID, inputID: id)
                }
            }
            requests.withLock { $0.append(req) }
        }
    }

    @Test("WebSocket connect, auth headers, snapshot + live events delivery, malformed frame tolerance, chunked acks (>1000), and replay dedup")
    func webSocketConnectDeliverChunkedAckAndReplayDedup() async throws {
        let session = CronAndConsoleWatchHelper.makeSessionInfo()
        let recorder = SyntheticRecorder()
        let host = CorePlugin.Host.Environment(
            location: CronAndConsoleWatchHelper.makeLocationInfo(),
            onSessionSynthetic: { req in try await recorder.handle(req) }
        )
        host.registerSession(session)

        let connectRecord = Mutex<(url: String, headers: [String: String])?>(nil)
        let (clientSocket, serverPeer) = InMemoryWebSocketConnection.makePair()
        let wsTransport = MockWebSocketTransport { attempt in
            connectRecord.withLock { $0 = (attempt.url, attempt.headers) }
            return clientSocket
        }

        let ctx = CorePlugin.Host.make(environment: host, pluginID: "opencode.provider.opencode")
        let clock = CronAndConsoleWatchHelper.MutableClock(1_770_000_000_000)
        let controller = await CorePlugin.OpencodeWatches.make(
            ctx: ctx,
            http: nil,
            webSocket: wsTransport,
            clock: { clock.now() },
            startPolling: true,
            options: .init(sleep: { _ in })
        )

        let conn = CorePlugin.OpencodeWatches.ConsoleConnection(
            key: "ws-unit-1",
            server: "https://console.example.test",
            headers: { ["authorization": "Bearer tok-initial", "x-org-id": "org_123"] }
        )
        await controller.sync(conn)

        let connected = await CronAndConsoleWatchHelper.waitUntil { connectRecord.withLock { $0 != nil } }
        #expect(connected)
        let recorded = try #require(connectRecord.withLock { $0 })
        #expect(recorded.url == "wss://console.example.test/api/event-watches/stream")
        #expect(recorded.headers["authorization"] == "Bearer tok-initial")
        #expect(recorded.headers["x-org-id"] == "org_123")

        // Collect acks received by the server peer concurrently.
        let ackChunks = Mutex<[[String]]>([])
        let serverReader = Task {
            for try await msg in serverPeer.messages {
                if case .text(let text) = msg,
                   let obj = try? CronAndConsoleWatchHelper.decodeJSON([String: JSONValue].self, from: text),
                   obj["type"] == .string("ack"),
                   case .array(let arr)? = obj["ids"]
                {
                    let ids = arr.compactMap { v -> String? in
                        if case .string(let s) = v { return s }
                        return nil
                    }
                    ackChunks.withLock { $0.append(ids) }
                }
            }
        }

        // 1. Malformed frame is ignored without closing the socket.
        try await serverPeer.send(text: "{not-valid-json")
        // 2. Unknown message type is ignored.
        try await serverPeer.send(text: #"{"type":"ping","events":[]}"#)

        // 3. Snapshot frame (text) with 1 event.
        let ev1 = Self.makeWatchEvent(id: "ev_snap_1", sessionID: session.id, body: "Initial snapshot")
        let snapFrame = try CronAndConsoleWatchHelper.encodeJSON(
            CorePlugin.OpencodeWatches.ServerMessage(type: .snapshot, events: [ev1])
        )
        try await serverPeer.send(text: snapFrame)

        #expect(await CronAndConsoleWatchHelper.waitUntil { ackChunks.withLock { $0.count } >= 1 })
        #expect(ackChunks.withLock { $0[0] } == ["ev_snap_1"])
        #expect(recorder.requests.withLock { $0.count } == 1)

        // 4. Replay of the exact same batch (binary UTF-8 frame) conflicts with existing synthetic ID:
        //    must still be acknowledged, and must NOT produce a second wake!
        try await serverPeer.send(binary: CronAndConsoleWatchHelper.encodeUTF8(snapFrame))
        #expect(await CronAndConsoleWatchHelper.waitUntil { ackChunks.withLock { $0.count } >= 2 })
        #expect(ackChunks.withLock { $0[1] } == ["ev_snap_1"])
        #expect(recorder.requests.withLock { $0.count } == 1)
        #expect(recorder.replayConflicts.withLock { $0 } == 1)

        // 5. Batch of 1,050 events must be acknowledged in 2 chunks (1000 + 50).
        let bulkEvents = (1...1050).map { i in
            Self.makeWatchEvent(id: "ev_bulk_\(i)", sessionID: session.id, body: "msg \(i)")
        }
        let bulkFrame = try CronAndConsoleWatchHelper.encodeJSON(
            CorePlugin.OpencodeWatches.ServerMessage(type: .events, events: bulkEvents)
        )
        try await serverPeer.send(text: bulkFrame)

        #expect(await CronAndConsoleWatchHelper.waitUntil { ackChunks.withLock { $0.count } >= 4 })
        let chunks = ackChunks.withLock { $0 }
        #expect(chunks[2].count == 1000)
        #expect(chunks[3].count == 50)
        #expect(chunks[2].first == "ev_bulk_1")
        #expect(chunks[3].last == "ev_bulk_1050")

        await controller.close()
        await serverPeer.close()
        serverReader.cancel()
    }

    @Test("WebSocket reconnect semantics: 4401 lease immediate reconnect with rotated token, 1009 backoff, exponential header backoff, and silence timeout")
    func webSocketReconnectBackoffLeaseAndSilence() async throws {
        let session = CronAndConsoleWatchHelper.makeSessionInfo()
        let recorder = SyntheticRecorder()
        let host = CorePlugin.Host.Environment(
            location: CronAndConsoleWatchHelper.makeLocationInfo(),
            onSessionSynthetic: { req in try await recorder.handle(req) }
        )
        host.registerSession(session)

        // Phase 1: 4401 (immediate, 0 backoff) -> 1009 (1s backoff) -> silence timeout (1s backoff).
        let sleeps = Mutex<[Int64]>([])
        let seenTokens = Mutex<[String]>([])
        let tokenNumber = Mutex(1)
        let attemptCounter = Mutex(0)
        let peers = Mutex<[InMemoryWebSocketConnection]>([])

        let wsTransport = MockWebSocketTransport { attempt in
            let n = attemptCounter.withLock { v -> Int in v += 1; return v }
            seenTokens.withLock { $0.append(attempt.headers["authorization"] ?? "") }
            let (client, server) = InMemoryWebSocketConnection.makePair()
            peers.withLock { $0.append(server) }
            if n == 1 {
                // Deliver event, then end lease with 4401 after rotating token.
                Task {
                    let ev = Self.makeWatchEvent(id: "ev_before_lease", sessionID: session.id)
                    let msg = try CronAndConsoleWatchHelper.encodeJSON(
                        CorePlugin.OpencodeWatches.ServerMessage(type: .events, events: [ev])
                    )
                    try? await server.send(text: msg)
                    tokenNumber.withLock { $0 = 2 }
                    await server.close(code: CorePlugin.OpencodeWatches.LEASE_CLOSE_CODE, reason: "lease ended")
                }
            } else if n == 2 {
                // Close with 1009 oversized -> resets failures to 0, then 1s backoff.
                Task {
                    await server.close(code: CorePlugin.OpencodeWatches.OVERSIZED_CLOSE_CODE, reason: "too big")
                }
            }
            // Attempt 3 stays silent -> triggers silence timeout (60ms) -> 1s backoff -> Attempt 4 connects.
            return client
        }

        let ctx = CorePlugin.Host.make(environment: host, pluginID: "opencode.provider.opencode")
        let controller = await CorePlugin.OpencodeWatches.make(
            ctx: ctx,
            http: nil,
            webSocket: wsTransport,
            startPolling: true,
            options: .init(
                silenceTimeoutMs: 60,
                sleep: { ms in
                    sleeps.withLock { $0.append(ms) }
                }
            )
        )
        await controller.sync(CorePlugin.OpencodeWatches.ConsoleConnection(
            key: "ws-reconnect-1",
            server: "https://console.example.test",
            headers: {
                let n = tokenNumber.withLock { $0 }
                return ["authorization": "Bearer tok-\(n)"]
            }
        ))

        let reachedAttempt4 = await CronAndConsoleWatchHelper.waitUntil(timeoutMs: 4_000) {
            attemptCounter.withLock { $0 >= 4 }
        }
        #expect(reachedAttempt4)

        let tokens = seenTokens.withLock { $0 }
        #expect(tokens.count >= 4)
        #expect(tokens[0] == "Bearer tok-1")
        #expect(tokens[1] == "Bearer tok-2")
        // 4401 did NOT sleep; 1009 slept 1000ms; silence timeout slept 1000ms!
        let recordedSleeps = sleeps.withLock { $0 }
        #expect(Array(recordedSleeps.prefix(2)) == [1_000, 1_000])

        await controller.close()
        for p in peers.withLock({ $0 }) { await p.close() }

        // Phase 2: Repeated header-resolution errors back off exponentially 1s, 2s, 4s, 8s, 16s, 32s, 60s, 60s
        // without falling back to HTTP poll.
        let expSleeps = Mutex<[Int64]>([])
        let httpCalls = Mutex(0)
        let httpTransport = LayerNodePlatform.FetchTransport { _ in
            httpCalls.withLock { $0 += 1 }
            return CronAndConsoleWatchHelper.textResponse(status: 200, text: #"{"cursor":"c","events":[]}"#)
        }
        let wsUnused = MockWebSocketTransport { _ in
            throw WebSocketTransportError.upgradeFailed(statusCode: 500, detail: "unexpected")
        }
        let expController = await CorePlugin.OpencodeWatches.make(
            ctx: ctx,
            http: httpTransport,
            webSocket: wsUnused,
            startPolling: true,
            options: .init(sleep: { ms in
                let count = expSleeps.withLock { arr -> Int in
                    arr.append(ms)
                    return arr.count
                }
                if count >= 8 {
                    throw CancellationError()
                }
            })
        )
        await expController.sync(CorePlugin.OpencodeWatches.ConsoleConnection(
            key: "ws-backoff-cap",
            server: "https://console.example.test",
            headers: { throw ToolSchema.ToolError(message: "token refresh failed") }
        ))
        #expect(await CronAndConsoleWatchHelper.waitUntil { expSleeps.withLock { $0.count >= 8 } })
        #expect(expSleeps.withLock { Array($0.prefix(8)) } == [1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000, 60_000])
        #expect(httpCalls.withLock { $0 } == 0)
        await expController.close()
    }

    @Test("WebSocket upgrade refusal falls back to HTTP long-poll with encoded cursor & chunked acks and retries WebSocket after 10 minutes")
    func webSocketUpgradeRefusalFallsBackToHTTPPollAndRetriesWS() async throws {
        let session = CronAndConsoleWatchHelper.makeSessionInfo()
        let recorder = SyntheticRecorder()
        let host = CorePlugin.Host.Environment(
            location: CronAndConsoleWatchHelper.makeLocationInfo(),
            onSessionSynthetic: { req in try await recorder.handle(req) }
        )
        host.registerSession(session)

        let clock = CronAndConsoleWatchHelper.MutableClock(1_000_000)
        let wsAttempts = Mutex(0)
        let pollURLs = Mutex<[String]>([])
        let ackedBatches = Mutex<[[String]]>([])
        let sleeps = Mutex<[Int64]>([])
        let (wsClient, wsServer) = InMemoryWebSocketConnection.makePair()

        let wsTransport = MockWebSocketTransport { _ in
            let n = wsAttempts.withLock { v -> Int in v += 1; return v }
            if n == 1 {
                throw WebSocketTransportError.upgradeFailed(statusCode: 426, detail: "Upgrade Required")
            }
            return wsClient
        }

        let pollCount = Mutex(0)
        let httpTransport = LayerNodePlatform.FetchTransport { req in
            if req.method == "GET", req.url.contains("/api/event-watches/events") {
                pollURLs.withLock { $0.append(req.url) }
                let idx = pollCount.withLock { n -> Int in n += 1; return n }
                if idx == 1 {
                    let ev = Self.makeWatchEvent(id: "ev_poll_1", sessionID: session.id, body: "via http poll")
                    let page = CorePlugin.OpencodeWatches.PollResponse(cursor: "cur+1&a=b", events: [ev])
                    let json = try CronAndConsoleWatchHelper.encodeJSON(page)
                    return CronAndConsoleWatchHelper.textResponse(status: 200, text: json)
                }
                // Second poll advances clock past POLL_RETRY_WEBSOCKET (10 minutes) so loop retries WS immediately.
                clock.advance(by: CorePlugin.OpencodeWatches.POLL_RETRY_WEBSOCKET_MS)
                let page = CorePlugin.OpencodeWatches.PollResponse(cursor: "cur_2", events: [])
                let json = try CronAndConsoleWatchHelper.encodeJSON(page)
                return CronAndConsoleWatchHelper.textResponse(status: 200, text: json)
            }
            if req.method == "POST", req.url.hasSuffix("/api/event-watches/ack") {
                if let body = req.body,
                   let obj = try? CronAndConsoleWatchHelper.decodeJSON([String: JSONValue].self, from: body),
                   case .array(let ids)? = obj["ids"]
                {
                    ackedBatches.withLock { $0.append(ids.compactMap { if case .string(let s) = $0 { s } else { nil } }) }
                }
                return CronAndConsoleWatchHelper.textResponse(status: 204, text: "")
            }
            return CronAndConsoleWatchHelper.textResponse(status: 404, text: "")
        }

        let ctx = CorePlugin.Host.make(environment: host, pluginID: "opencode.provider.opencode")
        let controller = await CorePlugin.OpencodeWatches.make(
            ctx: ctx,
            http: httpTransport,
            webSocket: wsTransport,
            clock: { clock.now() },
            startPolling: true,
            options: .init(sleep: { ms in sleeps.withLock { $0.append(ms) } })
        )
        await controller.sync(CorePlugin.OpencodeWatches.Console(baseURL: "https://console.example.test", token: "tok"))

        let retriedWS = await CronAndConsoleWatchHelper.waitUntil(timeoutMs: 4_000) {
            wsAttempts.withLock { $0 >= 2 }
        }
        #expect(retriedWS)
        #expect(sleeps.withLock { $0 }.isEmpty, "poll -> websocket retry must happen without backoff sleep")
        let urls = pollURLs.withLock { $0 }
        #expect(urls.count == 2)
        #expect(urls[0].hasSuffix("/api/event-watches/events?wait=25"))
        #expect(urls[1].hasSuffix("/api/event-watches/events?wait=25&cursor=cur%2B1%26a%3Db"))
        #expect(ackedBatches.withLock { $0 } == [["ev_poll_1"]])
        #expect(recorder.requests.withLock { $0.count } == 1)

        await controller.close()
        await wsServer.close()
    }

    @Test("Live loopback RFC 6455 WebSocket end-to-end with URLSessionWebSocketTransport: connect, deliver, ack, 4401 lease reconnect, and 426 HTTP fallback")
    func liveLoopbackRFC6455EndToEnd() async throws {
        let session = CronAndConsoleWatchHelper.makeSessionInfo()
        let recorder = SyntheticRecorder()
        let host = CorePlugin.Host.Environment(
            location: CronAndConsoleWatchHelper.makeLocationInfo(),
            onSessionSynthetic: { req in try await recorder.handle(req) }
        )
        host.registerSession(session)

        let wsAttempt = Mutex(0)
        let receivedWSAuth = Mutex<[String]>([])
        let receivedWSAcks = Mutex<[String]>([])
        let receivedHTTPPolls = Mutex(0)
        let receivedHTTPAcks = Mutex<[String]>([])
        let sleeps = Mutex<[Int64]>([])
        let tokenSlot = Mutex("tok-wire-1")

        let ev1 = Self.makeWatchEvent(id: "ev_wire_1", sessionID: session.id, body: "first socket")
        let ev2 = Self.makeWatchEvent(id: "ev_wire_2", sessionID: session.id, body: "after 4401 lease")
        let ev3 = Self.makeWatchEvent(id: "ev_wire_poll", sessionID: session.id, body: "via 426 fallback")
        let frame1 = try CronAndConsoleWatchHelper.encodeJSON(CorePlugin.OpencodeWatches.ServerMessage(type: .snapshot, events: [ev1]))
        let frame2 = try CronAndConsoleWatchHelper.encodeJSON(CorePlugin.OpencodeWatches.ServerMessage(type: .events, events: [ev2]))
        let pollJSON = try CronAndConsoleWatchHelper.encodeJSON(CorePlugin.OpencodeWatches.PollResponse(cursor: "c1", events: [ev3]))

        let server = try CronAndConsoleWatchHelper.LoopbackConsoleServer(
            onUpgrade: { path, headers in
                guard path == "/api/event-watches/stream" else {
                    return .reject(status: 404, body: "not found")
                }
                let n = wsAttempt.withLock { v -> Int in v += 1; return v }
                receivedWSAuth.withLock { $0.append(headers["authorization"] ?? "") }
                if n == 1 {
                    return .accept { ws in
                        ws.sendText(frame1)
                        if let ack = ws.readClientText(timeoutSeconds: 5) {
                            receivedWSAcks.withLock { $0.append(ack) }
                        }
                        tokenSlot.withLock { $0 = "tok-wire-2" }
                        ws.sendClose(code: CorePlugin.OpencodeWatches.LEASE_CLOSE_CODE, reason: "lease")
                    }
                }
                if n == 2 {
                    return .accept { ws in
                        ws.sendText(frame2)
                        if let ack = ws.readClientText(timeoutSeconds: 5) {
                            receivedWSAcks.withLock { $0.append(ack) }
                        }
                        ws.sendClose(code: 1011, reason: "restart")
                    }
                }
                // Attempt 3 refuses WebSocket upgrade -> client falls back to HTTP long-poll.
                return .reject(status: 426, body: "Use HTTP long-poll")
            },
            onHTTP: { req in
                if req.method == "GET", req.path.hasPrefix("/api/event-watches/events") {
                    let count = receivedHTTPPolls.withLock { v -> Int in v += 1; return v }
                    if count == 1 {
                        return (200, ["Content-Type": "application/json"], pollJSON)
                    }
                    // Subsequent poll returns 503 to let test finish cleanly.
                    return (503, ["Content-Type": "text/plain"], "done")
                }
                if req.method == "POST", req.path == "/api/event-watches/ack" {
                    receivedHTTPAcks.withLock { $0.append(req.body) }
                    return (204, [:], "")
                }
                return (404, [:], "")
            }
        )
        defer { server.stop() }

        let ctx = CorePlugin.Host.make(environment: host, pluginID: "opencode.provider.opencode")
        let controller = await CorePlugin.OpencodeWatches.make(
            ctx: ctx,
            http: URLSessionHTTPTransport.shared,
            webSocket: URLSessionWebSocketTransport(),
            startPolling: true,
            options: .init(sleep: { ms in
                sleeps.withLock { $0.append(ms) }
                // Keep real loopback test fast while still recording exact backoff ms.
                try await Task.sleep(for: .milliseconds(10))
            })
        )

        await controller.sync(CorePlugin.OpencodeWatches.ConsoleConnection(
            key: "ws-loopback-e2e",
            server: server.baseURL,
            headers: { ["authorization": "Bearer \(tokenSlot.withLock { $0 })"] }
        ))

        let completed = await CronAndConsoleWatchHelper.waitUntil(timeoutMs: 8_000) {
            receivedHTTPAcks.withLock { !$0.isEmpty }
        }
        #expect(completed)

        await controller.close()

        let authHeaders = receivedWSAuth.withLock { $0 }
        #expect(authHeaders.count >= 3)
        #expect(authHeaders[0] == "Bearer tok-wire-1")
        #expect(authHeaders[1] == "Bearer tok-wire-2")
        let wsAcks = receivedWSAcks.withLock { $0 }
        #expect(wsAcks.count == 2)
        #expect(wsAcks[0].contains("ev_wire_1"))
        #expect(wsAcks[1].contains("ev_wire_2"))
        // 4401 on attempt 1 had 0 sleep; 1011 on attempt 2 slept 1000ms before attempt 3!
        #expect(sleeps.withLock { $0.first } == 1_000)
        #expect(receivedHTTPAcks.withLock { $0.first?.contains("ev_wire_poll") } == true)
        #expect(recorder.requests.withLock { $0.count } == 3)
    }
}

// MARK: - 3. OpencodePlugin Activation Lifecycle & Flag Gating

@Suite("OpencodePlugin Auth Sync & Console Watches Activation")
struct OpencodePluginActivationTests {
    private struct PluginHarness: Sendable {
        let db: any SQLiteDatabase
        let bus: CoreBus.Service
        let credentials: CoreProvider.Credential.Service
        let integrations: CoreIntegration.Integration.Service
        let env: CorePlugin.Host.Environment
        let pluginService: CorePlugin.Service
    }

    private static func makeHarness(
        consoleWatchesFlag: Bool,
        http: any HTTPTransport,
        webSocket: any WebSocketTransport,
        config: (any CoreConfig.Interface)? = nil,
        pollIntervalMs: Int64 = 60_000,
        sharedCache: (any CoreKV.SharedCache.Interface)? = nil,
        onSessionSynthetic: (@Sendable (CoreSessionSynthetic.Request) async throws -> Void)? = nil
    ) throws -> PluginHarness {
        let db = try CronAndConsoleWatchHelper.openInMemoryDatabase()
        let bus = CoreBus.Service(db: db)
        let credentials = try CoreProvider.Credential.Service(database: db, bus: bus)
        let staticEnv = DictionaryEnvironment()
        let integrations = CoreIntegration.Integration.Service(credentials: credentials, environment: staticEnv)
        let flags = CronAndConsoleWatchHelper.makeFlagService(consoleWatches: consoleWatchesFlag)
        let hostEnv = CorePlugin.Host.Environment(
            app: PluginContract.App(name: "opencode", version: "2.5.0", channel: "test"),
            location: CronAndConsoleWatchHelper.makeLocationInfo(),
            http: http,
            webSocket: webSocket,
            environment: staticEnv,
            flags: flags,
            bus: bus,
            config: config,
            sharedCache: sharedCache ?? CoreKV.SharedCache.Service(),
            opencodeWatchesOptions: .init(sleep: { _ in }),
            opencodePollIntervalMs: pollIntervalMs,
            integrationService: integrations,
            onSessionSynthetic: onSessionSynthetic
        )
        let pluginService = CorePlugin.Service(environment: hostEnv)
        return PluginHarness(
            db: db,
            bus: bus,
            credentials: credentials,
            integrations: integrations,
            env: hostEnv,
            pluginService: pluginService
        )
    }

    @Test("console_watches flag OFF stays dormant even when signed in with x-opencode-event-watches header; ON connects and registers all 4 console_watch tools")
    func flagGatesConsoleWatchesActivation() async throws {
        let configRequests = Mutex<[HTTPRequest]>([])
        let http = LayerNodePlatform.FetchTransport { req in
            configRequests.withLock { $0.append(req) }
            return try CronAndConsoleWatchHelper.jsonResponse(
                status: 200,
                headers: [CorePlugin.OpencodeWatches.header: "1"],
                body: .object([:])
            )
        }

        // Case A: console_watches = false -> no WebSocket connection, no console_watch tools.
        let wsOffConnects = Mutex(0)
        let wsOff = MockWebSocketTransport { _ in
            wsOffConnects.withLock { $0 += 1 }
            return InMemoryWebSocketConnection.makePair().client
        }
        let harnessOff = try Self.makeHarness(consoleWatchesFlag: false, http: http, webSocket: wsOff)
        _ = try await harnessOff.credentials.create(
            id: nil,
            integrationID: IntegrationID(rawValue: "opencode"),
            value: .key(CredentialSchema.Key(
                key: "console-key-off",
                metadata: ["server": .string("https://console.flag-off.test")]
            )),
            label: "Flag Off Workspace",
            activate: true
        )
        try await harnessOff.pluginService.activate([
            CorePlugin.Generation(plugin: CorePlugin.OpencodePlugin, revision: "v1", source: .builtin),
        ])
        // Give any accidental async task a brief window, then verify zero WS connects & zero tools.
        try? await Task.sleep(for: .milliseconds(30))
        #expect(wsOffConnects.withLock { $0 } == 0)
        #expect(harnessOff.env.registeredTools().filter { $0.id.hasPrefix("console_watch_") }.isEmpty)
        let firstReq = try #require(configRequests.withLock { $0.first })
        #expect(firstReq.headers["User-Agent"] == "opencode/test/2.5.0/opencode")
        await harnessOff.pluginService.close()

        // Case B: console_watches = true -> connects WebSocket and registers all 4 console_watch tools!
        let wsOnURL = Mutex<String?>(nil)
        let (wsClient, wsServer) = InMemoryWebSocketConnection.makePair()
        let wsOn = MockWebSocketTransport { attempt in
            wsOnURL.withLock { $0 = attempt.url }
            return wsClient
        }
        let harnessOn = try Self.makeHarness(consoleWatchesFlag: true, http: http, webSocket: wsOn)
        _ = try await harnessOn.credentials.create(
            id: nil,
            integrationID: IntegrationID(rawValue: "opencode"),
            value: .key(CredentialSchema.Key(
                key: "console-key-on",
                metadata: ["server": .string("https://console.flag-on.test")]
            )),
            label: "Flag On Workspace",
            activate: true
        )
        try await harnessOn.pluginService.activate([
            CorePlugin.Generation(plugin: CorePlugin.OpencodePlugin, revision: "v1", source: .builtin),
        ])
        #expect(await CronAndConsoleWatchHelper.waitUntil { wsOnURL.withLock { $0 != nil } })
        #expect(wsOnURL.withLock { $0 } == "wss://console.flag-on.test/api/event-watches/stream")
        let toolIDs = Set(harnessOn.env.registeredTools().map(\.id))
        #expect(toolIDs.isSuperset(of: [
            "console_watch_watch",
            "console_watch_unwatch",
            "console_watch_watches",
            "console_watch_events",
        ]))
        await harnessOn.pluginService.close()
        await wsServer.close()
    }

    @Test("Sign-in starts OpencodeWatches and delivers events; sign-out closes WebSocket and removes tools")
    func signInStartsAndSignOutStopsWatches() async throws {
        let session = CronAndConsoleWatchHelper.makeSessionInfo()
        let syntheticEvents = Mutex<[CoreSessionSynthetic.Request]>([])
        let configCalls = Mutex(0)
        let http = LayerNodePlatform.FetchTransport { req in
            if req.url.hasSuffix("/api/v2/config") {
                configCalls.withLock { $0 += 1 }
                return try CronAndConsoleWatchHelper.jsonResponse(
                    status: 200,
                    headers: [CorePlugin.OpencodeWatches.header: "1"],
                    body: .object([:])
                )
            }
            return CronAndConsoleWatchHelper.textResponse(status: 204, text: "")
        }

        let wsConnected = Mutex(0)
        let wsPeerClosed = Mutex(false)
        let serverPeerBox = Mutex<InMemoryWebSocketConnection?>(nil)
        let ws = MockWebSocketTransport { _ in
            wsConnected.withLock { $0 += 1 }
            let (client, server) = InMemoryWebSocketConnection.makePair()
            serverPeerBox.withLock { $0 = server }
            Task {
                do {
                    for try await _ in server.messages {}
                } catch {}
                wsPeerClosed.withLock { $0 = true }
            }
            return client
        }

        let harness = try Self.makeHarness(
            consoleWatchesFlag: true,
            http: http,
            webSocket: ws,
            onSessionSynthetic: { req in syntheticEvents.withLock { $0.append(req) } }
        )
        harness.env.registerSession(session)

        // Activate OpencodePlugin while signed OUT -> zero HTTP requests, zero WS connects, zero tools.
        try await harness.pluginService.activate([
            CorePlugin.Generation(plugin: CorePlugin.OpencodePlugin, revision: "v1", source: .builtin),
        ])
        #expect(configCalls.withLock { $0 } == 0)
        #expect(wsConnected.withLock { $0 } == 0)
        #expect(harness.env.registeredTools().filter { $0.id.hasPrefix("console_watch_") }.isEmpty)

        // Sign in via Credential.Service.create -> emits credential.switched -> OpencodePlugin activates watches!
        let cred = try await harness.credentials.create(
            id: nil,
            integrationID: IntegrationID(rawValue: "opencode"),
            value: .key(CredentialSchema.Key(
                key: "live-signin-key",
                metadata: ["server": .string("https://console.signin.test"), "orgID": .string("org_live")]
            )),
            label: "Acme Org",
            activate: true
        )

        #expect(await CronAndConsoleWatchHelper.waitUntil { wsConnected.withLock { $0 == 1 } })
        #expect(configCalls.withLock { $0 } >= 1)
        let activeTools = Set(harness.env.registeredTools().map(\.id))
        #expect(activeTools.contains("console_watch_watch"))
        #expect(activeTools.contains("console_watch_unwatch"))
        #expect(activeTools.contains("console_watch_watches"))
        #expect(activeTools.contains("console_watch_events"))

        // Deliver a live event over the connected Console WebSocket -> wakes the session!
        let serverPeer = try #require(serverPeerBox.withLock { $0 })
        let watchEvent = CorePlugin.OpencodeWatches.WatchEvent(
            id: "ev_signin_1",
            watchID: "ew_signin",
            sessionID: session.id.rawValue,
            source: "slack",
            kind: "message",
            actor: .init(login: "alice", bot: false, isSelf: true),
            title: "#eng thread",
            body: "Ship it!",
            url: "https://slack.example/archives/C1/p1",
            status: nil
        )
        try await serverPeer.send(text: try CronAndConsoleWatchHelper.encodeJSON(
            CorePlugin.OpencodeWatches.ServerMessage(type: .events, events: [watchEvent])
        ))
        #expect(await CronAndConsoleWatchHelper.waitUntil { syntheticEvents.withLock { $0.count == 1 } })
        #expect(syntheticEvents.withLock { $0[0].sessionID } == session.id)

        // Sign out via Credential.Service.remove -> emits credential.switched(nil) -> stops watches & removes tools!
        try await harness.credentials.remove(cred.id)

        #expect(await CronAndConsoleWatchHelper.waitUntil {
            wsPeerClosed.withLock { $0 }
                && harness.env.registeredTools().filter { $0.id.hasPrefix("console_watch_") }.isEmpty
        })
        #expect(wsPeerClosed.withLock { $0 })
        #expect(harness.env.registeredTools().filter { $0.id.hasPrefix("console_watch_") }.isEmpty)

        await harness.pluginService.close()
    }

    @Test("Periodic Console config sync toggles watches on x-opencode-event-watches changes and managed policy denial withholds watches")
    func periodicConfigToggleAndManagedPolicyDenial() async throws {
        // Part 1: Periodic poll toggles watches on and off as Console header changes.
        let watchesHeaderEnabled = Mutex(false)
        let http = LayerNodePlatform.FetchTransport { _ in
            let headers: [String: String] = watchesHeaderEnabled.withLock { $0 }
                ? [CorePlugin.OpencodeWatches.header: "1"]
                : [:]
            return try CronAndConsoleWatchHelper.jsonResponse(status: 200, headers: headers, body: .object([:]))
        }
        let wsConnects = Mutex(0)
        let wsClosed = Mutex(false)
        let ws = MockWebSocketTransport { _ in
            wsConnects.withLock { $0 += 1 }
            let (client, server) = InMemoryWebSocketConnection.makePair()
            Task {
                do { for try await _ in server.messages {} } catch {}
                wsClosed.withLock { $0 = true }
            }
            return client
        }

        let harness = try Self.makeHarness(
            consoleWatchesFlag: true,
            http: http,
            webSocket: ws,
            pollIntervalMs: 25
        )
        _ = try await harness.credentials.create(
            id: nil,
            integrationID: IntegrationID(rawValue: "opencode"),
            value: .key(CredentialSchema.Key(
                key: "periodic-key",
                metadata: ["server": .string("https://console.periodic.test")]
            )),
            label: "Periodic Workspace",
            activate: true
        )
        try await harness.pluginService.activate([
            CorePlugin.Generation(plugin: CorePlugin.OpencodePlugin, revision: "v1", source: .builtin),
        ])

        // Initially header is absent -> dormant.
        try? await Task.sleep(for: .milliseconds(40))
        #expect(wsConnects.withLock { $0 } == 0)
        #expect(harness.env.registeredTools().filter { $0.id.hasPrefix("console_watch_") }.isEmpty)

        // Console turns on x-opencode-event-watches -> next periodic poll starts watches!
        watchesHeaderEnabled.withLock { $0 = true }
        #expect(await CronAndConsoleWatchHelper.waitUntil(timeoutMs: 3_000) {
            wsConnects.withLock { $0 == 1 }
                && harness.env.registeredTools().contains(where: { $0.id == "console_watch_watch" })
        })

        // Console turns off x-opencode-event-watches -> next periodic poll stops watches!
        watchesHeaderEnabled.withLock { $0 = false }
        #expect(await CronAndConsoleWatchHelper.waitUntil(timeoutMs: 3_000) {
            wsClosed.withLock { $0 }
                && harness.env.registeredTools().filter { $0.id.hasPrefix("console_watch_") }.isEmpty
        })
        await harness.pluginService.close()

        // Part 2: Managed policy `integration.use: deny` layers a policies-only document -> withholds watches.
        let policyConfig = CronAndConsoleWatchHelper.PolicyFilteringConfig(denyIntegrationUse: true)
        let deniedHTTP = LayerNodePlatform.FetchTransport { _ in
            try CronAndConsoleWatchHelper.jsonResponse(
                status: 200,
                headers: [CorePlugin.OpencodeWatches.header: "1"],
                body: .object([
                    "providers": .object([
                        "custom": .object(["name": .string("Custom Console Provider")]),
                    ]),
                ])
            )
        }
        let deniedWSConnects = Mutex(0)
        let deniedWS = MockWebSocketTransport { _ in
            deniedWSConnects.withLock { $0 += 1 }
            return InMemoryWebSocketConnection.makePair().client
        }
        let deniedHarness = try Self.makeHarness(
            consoleWatchesFlag: true,
            http: deniedHTTP,
            webSocket: deniedWS,
            config: policyConfig
        )
        _ = try await deniedHarness.credentials.create(
            id: nil,
            integrationID: IntegrationID(rawValue: "opencode"),
            value: .key(CredentialSchema.Key(
                key: "denied-key",
                metadata: ["server": .string("https://console.denied.test")]
            )),
            label: "Policy Denied",
            activate: true
        )
        try await deniedHarness.pluginService.activate([
            CorePlugin.Generation(plugin: CorePlugin.OpencodePlugin, revision: "v1", source: .builtin),
        ])
        try? await Task.sleep(for: .milliseconds(40))
        #expect(deniedWSConnects.withLock { $0 } == 0)
        #expect(deniedHarness.env.registeredTools().filter { $0.id.hasPrefix("console_watch_") }.isEmpty)
        await deniedHarness.pluginService.close()
    }
}

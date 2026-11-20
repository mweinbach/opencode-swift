import Synchronization
import Testing
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer

@Suite("End-to-End Video Generation, Polling, Leader Election, Restart Recovery & Tool Gating")
struct ServerVideoGenerationTests {

    // MARK: - 1. Full End-to-End Flow via Tool + xAI Provider + Blob Store + Session Notice

    @Test("xAI end-to-end: tool start -> poll -> complete -> blob stored -> file written -> <background-result kind=\"video\"> notice")
    func xaiEndToEndToolAndBlobStore() async throws {
        let mp4 = ServerVideoFixture.sampleMP4Bytes(tag: 0x42)
        let statusCalls = Mutex(0)
        let config = try ServerVideoFixture.makeConfigJSON(videoGenerateFlag: true, includeXAI: true, includeMiniMax: false)

        let harness = try await ServerVideoFixture.makeHarness(configContent: config) { req, _ in
            if req.method == "POST" && req.url == "https://api.x.ai/v1/videos/generations" {
                return try ServerVideoFixture.jsonResponse(.object(["request_id": .string("xai_e2e_1")]))
            }
            if req.method == "GET" && req.url == "https://api.x.ai/v1/videos/xai_e2e_1" {
                let count = statusCalls.withLock { c -> Int in
                    c += 1
                    return c
                }
                if count == 1 {
                    return try ServerVideoFixture.jsonResponse(.object([
                        "status": .string("pending"),
                        "progress": .int(25),
                    ]))
                }
                return try ServerVideoFixture.jsonResponse(.object([
                    "status": .string("done"),
                    "progress": .int(100),
                    "video": .object([
                        "url": .string("https://cdn.xai.test/e2e.mp4"),
                        "duration": .int(5),
                        "respect_moderation": .bool(true),
                    ]),
                ]))
            }
            if req.method == "GET" && req.url == "https://cdn.xai.test/e2e.mp4" {
                return ServerVideoFixture.bytesResponse(mp4)
            }
            return try ServerVideoFixture.jsonResponse(.object(["error": .string("unexpected \(req.method) \(req.url)")]), statusCode: 500)
        }
        defer { Task { await harness.close() } }

        let loc = try await harness.runtime.resolveLocation(
            LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: harness.rootDir))
        )
        let tools = await loc.tool.list()
        #expect(tools.contains(where: { $0.name == CoreTool.VideoGenerateTool.name }))

        let session = try await harness.runtime.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: harness.rootDir),
            title: "Video test session"
        ))

        let targetFile = "\(harness.rootDir)/out/cat.mp4"
        let toolResult = try await ServerVideoFixture.executeTool(
            loc: loc,
            name: CoreTool.VideoGenerateTool.name,
            input: .object([
                "prompt": .string("a cat riding a skateboard"),
                "path": .string("out/cat.mp4"),
                "duration": .int(5),
            ]),
            sessionID: session.id
        )

        guard case .string(let videoIDRaw) = toolResult.metadata?["jobID"] else {
            Issue.record("Expected jobID in tool metadata, got \(String(describing: toolResult.metadata))")
            return
        }
        let videoID = try #require(GenerateSchema.VideoID(rawValue: videoIDRaw))

        // Wait for the background video job to complete, copy the MP4 to the workspace, and deliver the notice.
        let completed = try await ServerVideoFixture.waitUntil {
            let exists = await harness.fileSystem.exists(at: targetFile)
            let hasNotice = ServerVideoFixture.sessionHasNotice(
                runtime: harness.runtime,
                sessionID: session.id,
                containing: "<background-result kind=\"video\" id=\"\(videoIDRaw)\" state=\"completed\">"
            )
            return exists && hasNotice
        }
        #expect(completed)

        // Saved workspace file matches downloaded MP4 bytes
        let savedBytes = try await harness.fileSystem.readFile(at: targetFile)
        #expect(savedBytes == mp4)

        // GET /api/experimental/generate/video/:id returns completed with blob metadata
        let getResp = await ServerVideoFixture.request(harness.handle, method: .get, path: "/api/experimental/generate/video/\(videoIDRaw)")
        #expect(getResp.statusCode == 200)
        let getBytes = try await ServerVideoFixture.responseBytes(getResp)
        let jobWrapper = try ServerVideoFixture.decodeJSON(ServerVideoFixture.DataEnvelope<GenerateSchema.VideoJob>.self, from: getBytes)
        guard case .completed(let done) = jobWrapper.data else {
            Issue.record("Expected completed video job, got \(jobWrapper.data)")
            return
        }
        #expect(done.id == videoID)
        let blob = try #require(done.blobs.first)
        #expect(blob.mime == "video/mp4")
        #expect(blob.bytes == Double(mp4.count))

        // GET /api/experimental/blob/:id serves the stored MP4 bytes
        let blobResp = await ServerVideoFixture.request(harness.handle, method: .get, path: "/api/experimental/blob/\(blob.id.rawValue)")
        #expect(blobResp.statusCode == 200)
        let blobBytes = try await ServerVideoFixture.responseBytes(blobResp)
        #expect(blobBytes == mp4)

        // Verify job outbox was cleaned up after synthetic notice delivery
        let cleaned = try await ServerVideoFixture.waitUntil {
            let pending = (try? await harness.runtime.job.pendingBackground()) ?? []
            return !pending.contains { $0.id == videoIDRaw }
        }
        #expect(cleaned)
    }

    // MARK: - 2. Second Provider (MiniMax H3) HTTP API + Cancel + Job Kind Filter

    @Test("MiniMax H3 HTTP API start -> complete and cancel (provider DELETE called + job kind=video filter)")
    func minimaxHttpApiAndCancel() async throws {
        let mp4 = ServerVideoFixture.sampleMP4Bytes(tag: 0x99)
        let config = try ServerVideoFixture.makeConfigJSON(videoGenerateFlag: "minimax/MiniMax-H3", includeXAI: false, includeMiniMax: true)

        let harness = try await ServerVideoFixture.makeHarness(configContent: config) { req, _ in
            if req.method == "POST" && req.url == "https://api.minimax.io/v2/video_generation" {
                let body = try ServerVideoFixture.decodeObject(req.body ?? [])
                let prompt: String = {
                    if case .array(let arr) = body["content"],
                       case .object(let first) = arr.first,
                       case .string(let t) = first["text"]
                    {
                        return t
                    }
                    return ""
                }()
                let taskID = prompt.contains("cancel-me") ? "mm_cancel_1" : "mm_done_1"
                return try ServerVideoFixture.jsonResponse(.object(["task_id": .string(taskID)]))
            }
            if req.method == "GET" && req.url == "https://api.minimax.io/v2/query/video_generation/mm_done_1" {
                return try ServerVideoFixture.jsonResponse(.object([
                    "task": .object([
                        "status": .string("succeeded"),
                        "duration": .int(5),
                        "content": .object(["url": .string("https://cdn.minimax.test/done.mp4")]),
                    ]),
                ]))
            }
            if req.method == "GET" && req.url == "https://api.minimax.io/v2/query/video_generation/mm_cancel_1" {
                return try ServerVideoFixture.jsonResponse(.object([
                    "task": .object(["status": .string("queued")]),
                ]))
            }
            if req.method == "DELETE" && req.url == "https://api.minimax.io/v2/video_generation/mm_cancel_1" {
                return try ServerVideoFixture.jsonResponse(.object(["ok": .bool(true)]))
            }
            if req.method == "GET" && req.url == "https://cdn.minimax.test/done.mp4" {
                return ServerVideoFixture.bytesResponse(mp4)
            }
            return try ServerVideoFixture.jsonResponse(.object([:]), statusCode: 500)
        }
        defer { Task { await harness.close() } }

        // Start via HTTP POST /api/experimental/generate/video with inline base64 PNG start frame
        let createBody = try ServerVideoFixture.encodeJSON(GenerateSchema.VideoRequest(
            model: ModelSchema.Ref(
                id: ModelSchema.ID(rawValue: "MiniMax-H3"),
                providerID: ProviderSchema.ID(rawValue: "minimax")
            ),
            prompt: "ocean waves",
            start: GenerateSchema.ImageFile(
                data: ServerVideoFixture.base64(ServerVideoFixture.samplePNGBytes()),
                mime: "image/png"
            ),
            duration: SchemaPrimitive.PositiveInt(rawValue: 5),
            aspect: .auto,
            resolution: .p720
        ))
        let createResp = await ServerVideoFixture.request(
            harness.handle,
            method: .post,
            path: "/api/experimental/generate/video",
            body: createBody
        )
        #expect(createResp.statusCode == 200)
        let createRespBytes = try await ServerVideoFixture.responseBytes(createResp)
        let started = try ServerVideoFixture.decodeJSON(
            ServerVideoFixture.DataEnvelope<GenerateSchema.VideoRunning>.self,
            from: createRespBytes
        ).data

        let doneJob = try await harness.runtime.videoGeneration.wait(started.id)
        guard case .completed(let completed) = doneJob else {
            Issue.record("Expected completed MiniMax job, got \(doneJob)")
            return
        }
        #expect(completed.blobs.count == 1)

        // Now start a video via the tool that stays queued, verify GET /api/experimental/job?kind=video, then cancel it.
        let loc = try await harness.runtime.resolveLocation(
            LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: harness.rootDir))
        )
        let session = try await harness.runtime.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: harness.rootDir),
            title: "Cancel video session"
        ))
        let toolOut = try await ServerVideoFixture.executeTool(
            loc: loc,
            name: CoreTool.VideoGenerateTool.name,
            input: .object(["prompt": .string("cancel-me slow video"), "path": .string("slow.mp4")]),
            sessionID: session.id
        )
        guard case .string(let cancelJobIDRaw) = toolOut.metadata?["jobID"],
              let cancelVideoID = GenerateSchema.VideoID(rawValue: cancelJobIDRaw)
        else {
            Issue.record("Missing jobID in cancel tool output")
            return
        }

        // Verify GET /api/experimental/job?kind=video lists it and kind=shell excludes it
        let videoJobsResp = await ServerVideoFixture.request(harness.handle, method: .get, path: "/api/experimental/job?kind=video")
        #expect(videoJobsResp.statusCode == 200)
        let videoJobsBytes = try await ServerVideoFixture.responseBytes(videoJobsResp)
        let videoJobs = try ServerVideoFixture.decodeJSON(
            ServerVideoFixture.DataEnvelope<[JobSchema.Info]>.self,
            from: videoJobsBytes
        ).data
        let hasVideoJob = videoJobs.contains { item in
            if case .video(let v) = item { return v.id == cancelJobIDRaw }
            return false
        }
        #expect(hasVideoJob)

        let shellJobsResp = await ServerVideoFixture.request(harness.handle, method: .get, path: "/api/experimental/job?kind=shell")
        let shellJobsBytes = try await ServerVideoFixture.responseBytes(shellJobsResp)
        let shellJobs = try ServerVideoFixture.decodeJSON(
            ServerVideoFixture.DataEnvelope<[JobSchema.Info]>.self,
            from: shellJobsBytes
        ).data
        let hasShellJob = shellJobs.contains { item in
            if case .video(let v) = item { return v.id == cancelJobIDRaw }
            return false
        }
        #expect(!hasShellJob)

        // Cancel via HTTP POST /api/experimental/job/:id/cancel -> invokes videoGeneration.cancel -> provider DELETE
        let cancelResp = await ServerVideoFixture.request(harness.handle, method: .post, path: "/api/experimental/job/\(cancelJobIDRaw)/cancel")
        #expect(cancelResp.statusCode == 204)

        let cancelledJob = try await harness.runtime.videoGeneration.get(cancelVideoID)
        guard case .error(let errJob) = cancelledJob else {
            Issue.record("Expected cancelled error state, got \(cancelledJob)")
            return
        }
        #expect(errJob.reason == .cancelled)
        #expect(harness.transport.count(method: "DELETE", matching: "/v2/video_generation/mm_cancel_1") == 1)
    }

    // MARK: - 3. Failure Classification, Empty Video & Deadline Timeout

    @Test("Failure classification (auth, rate limit, content filter, invalid input), empty video cleanup, and 2h deadline")
    func failureClassificationAndDeadlines() async throws {
        let config = try ServerVideoFixture.makeConfigJSON(videoGenerateFlag: true, includeXAI: true, includeMiniMax: true)

        let harness = try await ServerVideoFixture.makeHarness(configContent: config) { req, _ in
            if req.method == "POST" && req.url.hasSuffix("/videos/generations") {
                let body = try ServerVideoFixture.decodeObject(req.body ?? [])
                let prompt = (body["prompt"] == .string("auth-fail")) ? "auth-fail"
                    : (body["prompt"] == .string("rate-fail")) ? "rate-fail"
                    : (body["prompt"] == .string("empty-vid")) ? "empty-vid"
                    : "policy-vid"
                if prompt == "auth-fail" {
                    return try ServerVideoFixture.jsonResponse(.object(["error": .string("bad key")]), statusCode: 401)
                }
                if prompt == "rate-fail" {
                    return try ServerVideoFixture.jsonResponse(
                        .object(["error": .string("too many requests")]),
                        statusCode: 429,
                        headers: ["retry-after": "12"]
                    )
                }
                return try ServerVideoFixture.jsonResponse(.object(["request_id": .string(prompt)]))
            }
            if req.method == "GET" && req.url.hasSuffix("/videos/policy-vid") {
                return try ServerVideoFixture.jsonResponse(.object([
                    "status": .string("done"),
                    "video": .object(["respect_moderation": .bool(false)]),
                ]))
            }
            if req.method == "GET" && req.url.hasSuffix("/videos/empty-vid") {
                return try ServerVideoFixture.jsonResponse(.object([
                    "status": .string("done"),
                    "video": .object(["url": .string("https://cdn.xai.test/empty.mp4")]),
                ]))
            }
            if req.method == "GET" && req.url == "https://cdn.xai.test/empty.mp4" {
                return ServerVideoFixture.bytesResponse([])
            }
            return try ServerVideoFixture.jsonResponse(.object([:]), statusCode: 500)
        }
        defer { Task { await harness.close() } }

        let loc = try await harness.runtime.resolveLocation(
            LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: harness.rootDir))
        )
        let xaiRef = ModelSchema.Ref(id: ModelSchema.ID(rawValue: "grok-imagine-video"), providerID: ProviderSchema.ID(rawValue: "xai"))
        let hailuoRef = ModelSchema.Ref(id: ModelSchema.ID(rawValue: "MiniMax-Hailuo-02"), providerID: ProviderSchema.ID(rawValue: "minimax"))

        // Auth failure -> ProviderRequestError(.authentication, status: 401)
        do {
            _ = try await loc.generate.videoStart(CoreIntegration.Generate.VideoInput(model: xaiRef, prompt: "auth-fail"))
            Issue.record("Expected authentication error")
        } catch let err as CoreIntegration.Generate.ProviderRequestError {
            #expect(err.reason == .authentication)
            #expect(err.status == 401)
        }

        // Rate limit -> ProviderRequestError(.rateLimit, status: 429, retryAfterMs: 12_000)
        do {
            _ = try await loc.generate.videoStart(CoreIntegration.Generate.VideoInput(model: xaiRef, prompt: "rate-fail"))
            Issue.record("Expected rate limit error")
        } catch let err as CoreIntegration.Generate.ProviderRequestError {
            #expect(err.reason == .rateLimit)
            #expect(err.status == 429)
            #expect(err.retryAfterMs == 12_000)
        }

        // Content filter on result -> ProviderRequestError(.contentFilter)
        do {
            _ = try await loc.generate.videoResult(model: xaiRef, id: "policy-vid")
            Issue.record("Expected contentFilter error")
        } catch let err as CoreIntegration.Generate.ProviderRequestError {
            #expect(err.reason == .contentFilter)
        }

        // Unsupported operation (Hailuo concrete aspect) -> InvalidRequestError
        let aspect16x9 = try #require(GenerateSchema.ImageAspect(rawValue: "16:9"))
        do {
            _ = try await loc.generate.videoStart(CoreIntegration.Generate.VideoInput(
                model: hailuoRef,
                prompt: "bad aspect",
                aspect: .ratio(aspect16x9)
            ))
            Issue.record("Expected invalidRequest error for Hailuo aspect")
        } catch is CoreIntegration.Generate.InvalidRequestError {
            // Expected
        }

        // Invalid wire start media (non-image MIME) -> HTTP 400 InvalidRequestError
        let badWire = try ServerVideoFixture.encodeJSON(GenerateSchema.VideoRequest(
            model: xaiRef,
            prompt: "bad frame",
            start: GenerateSchema.ImageFile(data: "AAAA", mime: "video/mp4")
        ))
        let badResp = await ServerVideoFixture.request(harness.handle, method: .post, path: "/api/experimental/generate/video", body: badWire)
        #expect(badResp.statusCode == 400)

        // Empty 0-byte video fails with "The provider returned an empty video"
        let emptyStarted = try await harness.runtime.videoGeneration.start(
            CoreIntegration.Generate.VideoInput(model: xaiRef, prompt: "empty-vid"),
            options: nil
        )
        let emptySettled = try await harness.runtime.videoGeneration.wait(emptyStarted.id)
        guard case .error(let emptyErr) = emptySettled else {
            Issue.record("Expected error for empty video, got \(emptySettled)")
            return
        }
        #expect(emptyErr.reason == .failed)
        #expect(emptyErr.error.contains("empty video"))

        // 2h deadline timeout via injectable clock on standalone VideoGeneration.Service
        let db = try SQLiteDatabaseFactory.open(path: ":memory:")
        let kv = try CoreKV.Service(database: db)
        let clockBox = Mutex<Double>(1_000_000)
        let deadlineSvc = CoreIntegration.VideoGeneration.Service(
            database: db,
            kv: kv,
            blobs: CoreBlobStore.Service(globalPaths: Global.make(), fileSystem: InMemoryFileSystem()),
            defaultLocation: { LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: "/w")) },
            resolveGenerate: { _ in loc.generate },
            intervalMs: 10,
            deadlineMs: 2 * 3_600_000,
            retryBaseDelayMs: 1,
            nowMs: { clockBox.withLock { $0 } },
            startPolling: false
        )
        defer { Task { await deadlineSvc.close() } }
        let dlJob = try await deadlineSvc.start(
            CoreIntegration.Generate.VideoInput(model: xaiRef, prompt: "policy-vid"),
            options: nil
        )
        clockBox.withLock { $0 += 2 * 3_600_000 + 1 }
        await deadlineSvc.pollOnce()
        let dlResult = try await deadlineSvc.get(dlJob.id)
        guard case .error(let dlErr) = dlResult else {
            Issue.record("Expected deadline error, got \(dlResult)")
            return
        }
        #expect(dlErr.reason == .unknown)
        #expect(dlErr.error == "The provider had no result 2h after submission")
    }

    // MARK: - 4. Leader Election When Two VideoGeneration Services Share a SQLite DB

    @Test("Leader election: only one of two services sharing a SQLite DB polls; follower takes over on close or TTL expiry")
    func leaderElectionSharedDatabase() async throws {
        let tempDB = ServerVideoFixture.makeTempSQLitePath()
        defer { tempDB.cleanup() }

        let db1 = try SQLiteDatabaseFactory.open(path: tempDB.path)
        let kv1 = try CoreKV.Service(database: db1)
        let db2 = try SQLiteDatabaseFactory.open(path: tempDB.path)
        let kv2 = try CoreKV.Service(database: db2)

        let fs = InMemoryFileSystem()
        let blobs = CoreBlobStore.Service(globalPaths: Global.make(Global.Overrides(data: "/data")), fileSystem: fs)
        let clockBox = Mutex<Double>(10_000)
        let sharedState = LeaderElectionSharedState()

        @Sendable func makeStubGen(label: String) -> any CoreIntegration.Generate.Interface {
            LeaderElectionStubGenerate(label: label, shared: sharedState)
        }

        let svcA = CoreIntegration.VideoGeneration.Service(
            database: db1,
            kv: kv1,
            blobs: blobs,
            defaultLocation: { LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: "/w")) },
            resolveGenerate: { _ in makeStubGen(label: "A") },
            intervalMs: 10,
            ttlMs: 60_000,
            retryBaseDelayMs: 1,
            nowMs: { clockBox.withLock { $0 } },
            startPolling: false
        )
        let svcB = CoreIntegration.VideoGeneration.Service(
            database: db2,
            kv: kv2,
            blobs: blobs,
            defaultLocation: { LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: "/w")) },
            resolveGenerate: { _ in makeStubGen(label: "B") },
            intervalMs: 10,
            ttlMs: 60_000,
            retryBaseDelayMs: 1,
            nowMs: { clockBox.withLock { $0 } },
            startPolling: false
        )
        defer {
            Task {
                await svcA.close()
                await svcB.close()
            }
        }

        let modelRef = ModelSchema.Ref(id: ModelSchema.ID(rawValue: "grok-imagine-video"), providerID: ProviderSchema.ID(rawValue: "xai"))
        let job = try await svcA.start(CoreIntegration.Generate.VideoInput(model: modelRef, prompt: "shared db"), options: nil)

        // A claims the lease and polls; B must NOT poll while A's lease is fresh.
        await svcA.pollOnce()
        await svcB.pollOnce()
        #expect(sharedState.snapshotLog() == ["A"])

        // Halfway through TTL: B still cannot steal the lease.
        clockBox.withLock { $0 += 30_000 }
        await svcB.pollOnce()
        #expect(sharedState.snapshotLog() == ["A"])

        // When A closes, it releases the DB lease so B takes over immediately.
        await svcA.close()
        sharedState.setPhase("completed")
        await svcB.pollOnce()
        #expect(sharedState.snapshotLog() == ["A", "B"])

        let completed = try await svcB.get(job.id)
        guard case .completed(let info) = completed else {
            Issue.record("Expected B to complete the job after taking over leadership, got \(completed)")
            return
        }
        #expect(info.blobs.count == 1)

        // Test TTL expiry failover without explicit close (using a new job and svcC)
        let db3 = try SQLiteDatabaseFactory.open(path: tempDB.path)
        let kv3 = try CoreKV.Service(database: db3)
        let svcC = CoreIntegration.VideoGeneration.Service(
            database: db3,
            kv: kv3,
            blobs: blobs,
            defaultLocation: { LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: "/w")) },
            resolveGenerate: { _ in makeStubGen(label: "C") },
            intervalMs: 10,
            ttlMs: 60_000,
            retryBaseDelayMs: 1,
            nowMs: { clockBox.withLock { $0 } },
            startPolling: false
        )
        defer { Task { await svcC.close() } }

        sharedState.setPhase("running")
        let job2 = try await svcB.start(CoreIntegration.Generate.VideoInput(model: modelRef, prompt: "ttl failover"), options: nil)
        await svcB.pollOnce() // B holds lease until now + 60_000
        await svcC.pollOnce() // C blocked
        #expect(sharedState.snapshotLog() == ["A", "B", "B"])

        // Advance clock past TTL so C steals the expired lease without B closing.
        clockBox.withLock { $0 += 61_000 }
        sharedState.setPhase("completed")
        await svcC.pollOnce()
        #expect(sharedState.snapshotLog() == ["A", "B", "B", "C"])
        let completed2 = try await svcC.get(job2.id)
        if case .completed = completed2 {} else {
            Issue.record("Expected C to complete job2 after lease expiry, got \(completed2)")
        }
    }

    // MARK: - 5. Restart Recovery (Resume Tracking + Missing Folder Fallback)

    @Test("Restart recovery resumes tracking running video jobs across server restart and handles missing project folder")
    func restartRecoveryResumesAndFallsBack() async throws {
        let tempDB = ServerVideoFixture.makeTempSQLitePath()
        defer { tempDB.cleanup() }
        let mp4 = ServerVideoFixture.sampleMP4Bytes(tag: 0x77)
        let sharedFS = InMemoryFileSystem(initialFiles: [
            "/workspace/.keep": Array("ok".utf8),
            "/vanishing/.keep": Array("ok".utf8),
        ])
        let config = try ServerVideoFixture.makeConfigJSON(videoGenerateFlag: true, includeXAI: true, includeMiniMax: false)

        // Server 1: starts two video jobs (both stay pending while Server 1 runs), then shuts down.
        let db1 = try SQLiteDatabaseFactory.open(path: tempDB.path)
        let server1 = try await ServerVideoFixture.makeHarness(
            configContent: config,
            fileSystem: sharedFS,
            databaseClient: db1,
            pollIntervalMs: 60_000 // keep running across restart
        ) { req, _ in
            if req.method == "POST" && req.url.hasSuffix("/videos/generations") {
                let body = try ServerVideoFixture.decodeObject(req.body ?? [])
                let id = body["prompt"] == .string("vanish") ? "remote_vanish" : "remote_resume"
                return try ServerVideoFixture.jsonResponse(.object(["request_id": .string(id)]))
            }
            if req.method == "GET" && req.url.contains("/videos/") {
                return try ServerVideoFixture.jsonResponse(.object(["status": .string("pending")]))
            }
            return try ServerVideoFixture.jsonResponse(.object([:]), statusCode: 500)
        }

        let loc1 = try await server1.runtime.resolveLocation(
            LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: "/workspace"))
        )
        let sessionKeep = try await server1.runtime.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: "/workspace"),
            title: "Resume video session"
        ))
        let outKeep = try await ServerVideoFixture.executeTool(
            loc: loc1,
            name: CoreTool.VideoGenerateTool.name,
            input: .object(["prompt": .string("resume"), "path": .string("resumed.mp4")]),
            sessionID: sessionKeep.id
        )
        guard case .string(let keepJobID) = outKeep.metadata?["jobID"] else {
            Issue.record("Missing keepJobID")
            return
        }

        let locVanish = try await server1.runtime.resolveLocation(
            LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: "/vanishing"))
        )
        let sessionVanish = try await server1.runtime.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: "/vanishing"),
            title: "Vanishing folder session"
        ))
        let outVanish = try await ServerVideoFixture.executeTool(
            loc: locVanish,
            name: CoreTool.VideoGenerateTool.name,
            input: .object(["prompt": .string("vanish"), "path": .string("lost.mp4")]),
            sessionID: sessionVanish.id
        )
        guard case .string(let vanishJobID) = outVanish.metadata?["jobID"] else {
            Issue.record("Missing vanishJobID")
            return
        }

        // Verify both running jobs were persisted to SQLite `job` table before shutdown.
        let persistedBefore = try await server1.runtime.job.pendingBackground()
        #expect(persistedBefore.contains { $0.id == keepJobID && $0.status == .running })
        #expect(persistedBefore.contains { $0.id == vanishJobID && $0.status == .running })

        await server1.close()

        // Remove the vanishing project folder before Server 2 starts.
        try await sharedFS.remove(at: "/vanishing/.keep")
        try await sharedFS.remove(at: "/vanishing")

        // Server 2: opens the same SQLite DB & filesystem; provider now reports completion for remote_resume.
        let db2 = try SQLiteDatabaseFactory.open(path: tempDB.path)
        let server2 = try await ServerVideoFixture.makeHarness(
            configContent: config,
            fileSystem: sharedFS,
            databaseClient: db2,
            pollIntervalMs: 15
        ) { req, _ in
            if req.method == "GET" && req.url.hasSuffix("/videos/remote_resume") {
                return try ServerVideoFixture.jsonResponse(.object([
                    "status": .string("done"),
                    "video": .object(["url": .string("https://cdn.xai.test/resumed.mp4")]),
                ]))
            }
            if req.method == "GET" && req.url == "https://cdn.xai.test/resumed.mp4" {
                return ServerVideoFixture.bytesResponse(mp4)
            }
            if req.method == "GET" && req.url.hasSuffix("/videos/remote_vanish") {
                return try ServerVideoFixture.jsonResponse(.object(["status": .string("pending")]))
            }
            return try ServerVideoFixture.jsonResponse(.object([:]), statusCode: 500)
        }
        defer { Task { await server2.close() } }

        // ServerFetch.make runs resumeSuspendedSessions() on boot — wait for both outcomes!
        let recovered = try await ServerVideoFixture.waitUntil(timeoutMs: 6_000) {
            let fileReady = await sharedFS.exists(at: "/workspace/resumed.mp4")
            let keepNotified = ServerVideoFixture.sessionHasNotice(
                runtime: server2.runtime,
                sessionID: sessionKeep.id,
                containing: "<background-result kind=\"video\" id=\"\(keepJobID)\" state=\"completed\">"
            )
            let vanishNotified = ServerVideoFixture.sessionHasNotice(
                runtime: server2.runtime,
                sessionID: sessionVanish.id,
                containing: "<background-result kind=\"video\" id=\"\(vanishJobID)\" state=\"cancelled\">"
            ) && ServerVideoFixture.sessionHasNotice(
                runtime: server2.runtime,
                sessionID: sessionVanish.id,
                containing: "project folder no longer exists"
            )
            return fileReady && keepNotified && vanishNotified
        }
        #expect(recovered)
        #expect(try await sharedFS.readFile(at: "/workspace/resumed.mp4") == mp4)
    }

    // MARK: - 6. Tool Registration Gating (Flag, Model Availability, Dynamic model.updated, Config Default & Workerd)

    @Test("Tool registration is gated by video_generate flag, video model availability, model.updated, config model, and workerd stub")
    func toolRegistrationGatingAndWorkerd() async throws {
        // (a) Flag OFF + video model present -> tool NOT registered, video route 403 Forbidden
        let flagOffConfig = try ServerVideoFixture.makeConfigJSON(videoGenerateFlag: false, includeXAI: true, includeMiniMax: false)
        let hOff = try await ServerVideoFixture.makeHarness(configContent: flagOffConfig) { _, _ in
            try ServerVideoFixture.jsonResponse(.object([:]), statusCode: 500)
        }
        defer { Task { await hOff.close() } }
        let locOff = try await hOff.runtime.resolveLocation(
            LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: hOff.rootDir))
        )
        #expect(!(await locOff.tool.list().contains { $0.name == CoreTool.VideoGenerateTool.name }))
        let forbiddenReq = try ServerVideoFixture.encodeJSON(GenerateSchema.VideoRequest(
            model: ModelSchema.Ref(id: ModelSchema.ID(rawValue: "grok-imagine-video"), providerID: ProviderSchema.ID(rawValue: "xai")),
            prompt: "blocked"
        ))
        let forbiddenResp = await ServerVideoFixture.request(hOff.handle, method: .post, path: "/api/experimental/generate/video", body: forbiddenReq)
        #expect(forbiddenResp.statusCode == 403)

        // (b) Flag ON + NO video model initially -> NOT registered; registering video model + emitting model.updated registers it!
        let noModelsConfig = try ServerVideoFixture.makeConfigJSON(videoGenerateFlag: true, includeXAI: false, includeMiniMax: false)
        let hDyn = try await ServerVideoFixture.makeHarness(configContent: noModelsConfig) { _, _ in
            try ServerVideoFixture.jsonResponse(.object([:]), statusCode: 500)
        }
        defer { Task { await hDyn.close() } }
        let locDyn = try await hDyn.runtime.resolveLocation(
            LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: hDyn.rootDir))
        )
        #expect(!(await locDyn.tool.list().contains { $0.name == CoreTool.VideoGenerateTool.name }))

        // Register a video provider + video model and emit model.updated
        _ = try await locDyn.provider.transform { editor in
            editor.add(
                info: ProviderSchema.Info(
                    id: ProviderSchema.ID(rawValue: "xai"),
                    name: "xAI",
                    activation: .enabled,
                    package: "@opencode/ai/providers/xai/videos"
                ),
                models: [
                    ServerVideoFixture.makeVideoModelInfo(
                        providerID: "xai",
                        modelID: "grok-imagine-video",
                        package: "@opencode/ai/providers/xai/videos"
                    ),
                ]
            )
        }
        await locDyn.model.reload()
        await hDyn.runtime.bus.emit(
            EventSchema.EphemeralDefinition<JSONValue>(type: ModelSchema.Event.updated.type),
            data: .object([:])
        )
        let appeared = try await ServerVideoFixture.waitUntil {
            await locDyn.tool.list().contains { $0.name == CoreTool.VideoGenerateTool.name }
        }
        #expect(appeared)

        // (c) Configured default video model (`experimental.video_generate: { model: "minimax/MiniMax-H3" }`)
        let configuredJSON = try ServerVideoFixture.makeConfigJSON(
            videoGenerateFlag: "minimax/MiniMax-H3",
            includeXAI: true,
            includeMiniMax: true
        )
        let hCfg = try await ServerVideoFixture.makeHarness(configContent: configuredJSON) { req, _ in
            if req.method == "POST" && req.url == "https://api.minimax.io/v2/video_generation" {
                return try ServerVideoFixture.jsonResponse(.object(["task_id": .string("cfg_mm_1")]))
            }
            if req.method == "GET" && req.url.contains("/v2/query/video_generation/cfg_mm_1") {
                return try ServerVideoFixture.jsonResponse(.object(["task": .object(["status": .string("queued")])]))
            }
            return try ServerVideoFixture.jsonResponse(.object([:]), statusCode: 500)
        }
        defer { Task { await hCfg.close() } }
        let locCfg = try await hCfg.runtime.resolveLocation(
            LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: hCfg.rootDir))
        )
        let cfgSession = try await hCfg.runtime.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: hCfg.rootDir),
            title: "Config model session"
        ))
        let cfgOut = try await ServerVideoFixture.executeTool(
            loc: locCfg,
            name: CoreTool.VideoGenerateTool.name,
            input: .object(["prompt": .string("pick configured model"), "path": .string("cfg.mp4")]),
            sessionID: cfgSession.id
        )
        #expect(cfgOut.metadata?["model"] == .string("minimax/MiniMax-H3"))

        // (d) Workerd profile keeps unsupported video stub (503 on POST, 404 on GET)
        let hWorkerd = try await ServerVideoFixture.makeHarness(
            configContent: try ServerVideoFixture.makeConfigJSON(videoGenerateFlag: true, includeXAI: true, includeMiniMax: false),
            workerdProfile: true
        ) { _, _ in
            try ServerVideoFixture.jsonResponse(.object([:]), statusCode: 500)
        }
        defer { Task { await hWorkerd.close() } }
        let workerdCreate = await ServerVideoFixture.request(hWorkerd.handle, method: .post, path: "/api/experimental/generate/video", body: forbiddenReq)
        #expect(workerdCreate.statusCode == 503)
        let workerdGet = await ServerVideoFixture.request(
            hWorkerd.handle,
            method: .get,
            path: "/api/experimental/generate/video/\(GenerateSchema.VideoID.create().rawValue)"
        )
        #expect(workerdGet.statusCode == 404)
    }
}

private final class LeaderElectionSharedState: Sendable {
    private struct Inner: Sendable {
        var log: [String] = []
        var phase: String = "running"
    }
    private let inner = Mutex(Inner())

    func recordPoll(_ label: String) -> String {
        inner.withLock { s in
            s.log.append(label)
            return s.phase
        }
    }

    func setPhase(_ phase: String) {
        inner.withLock { $0.phase = phase }
    }

    func snapshotLog() -> [String] {
        inner.withLock { $0.log }
    }
}

private final class LeaderElectionStubGenerate: CoreIntegration.Generate.Interface, Sendable {
    let label: String
    let shared: LeaderElectionSharedState

    init(label: String, shared: LeaderElectionSharedState) {
        self.label = label
        self.shared = shared
    }

    func text(_ input: CoreIntegration.Generate.TextInput) async throws -> String { "" }
    func image(_ input: GenerateSchema.ImageRequest) async throws -> GenerateSchema.ImageResult { .init(images: []) }
    func decisions(_ input: GenerateSchema.DecisionRequest) async throws -> GenerateSchema.DecisionResult { .init(answers: []) }

    func videoStart(_ input: CoreIntegration.Generate.VideoInput) async throws -> String {
        "remote_\(label)_\(input.prompt)"
    }

    func videoStatus(model: ModelSchema.Ref, id: String) async throws -> CoreIntegration.Generate.VideoStatus {
        let current = shared.recordPoll(label)
        if current == "completed" {
            return CoreIntegration.Generate.VideoStatus(status: .completed)
        }
        return CoreIntegration.Generate.VideoStatus(status: .running)
    }

    func videoResult(model: ModelSchema.Ref, id: String) async throws -> [CoreIntegration.Generate.VideoFile] {
        [CoreIntegration.Generate.VideoFile(mime: "video/mp4", bytes: ServerVideoFixture.sampleMP4Bytes())]
    }

    func videoCancel(model: ModelSchema.Ref, id: String) async throws {}
}

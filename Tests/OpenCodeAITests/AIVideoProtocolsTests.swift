import Testing
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema

@Suite("OpenCodeAI Live Video Protocols")
struct AIVideoProtocolsTests {

    // MARK: - xAI Video

    @Test("xAI video: start, edit/extend paths, status progress, result, moderation, failure classification, cancel unsupported")
    func xaiVideoLifecycle() async throws {
        let mp4 = VideoProtocolFixture.sampleMP4Bytes()
        let transport = VideoProtocolMockTransport { req, _ in
            if req.method == "POST" && req.url.hasSuffix("/videos/generations") {
                return try VideoProtocolFixture.jsonResponse(.object(["request_id": .string("xai_req_1")]))
            }
            if req.method == "POST" && req.url.hasSuffix("/videos/edits") {
                return try VideoProtocolFixture.jsonResponse(.object(["request_id": .string("xai_edit_1")]))
            }
            if req.method == "POST" && req.url.hasSuffix("/videos/extensions") {
                return try VideoProtocolFixture.jsonResponse(.object(["request_id": .string("xai_ext_1")]))
            }
            if req.method == "GET" && req.url.hasSuffix("/videos/xai_req_1") {
                return try VideoProtocolFixture.jsonResponse(.object([
                    "status": .string("done"),
                    "progress": .int(100),
                    "model": .string("grok-imagine-video"),
                    "video": .object([
                        "url": .string("https://cdn.xai.test/out.mp4"),
                        "duration": .int(6),
                        "respect_moderation": .bool(true),
                    ]),
                ]))
            }
            if req.method == "GET" && req.url.hasSuffix("/videos/xai_pending") {
                return try VideoProtocolFixture.jsonResponse(.object([
                    "status": .string("pending"),
                    "progress": .int(37),
                ]))
            }
            if req.method == "GET" && req.url.hasSuffix("/videos/xai_moderated") {
                return try VideoProtocolFixture.jsonResponse(.object([
                    "status": .string("done"),
                    "video": .object(["respect_moderation": .bool(false)]),
                ]))
            }
            if req.method == "GET" && req.url.hasSuffix("/videos/xai_failed_perm") {
                return try VideoProtocolFixture.jsonResponse(.object([
                    "status": .string("failed"),
                    "error": .object(["code": .string("permission_denied"), "message": .string("denied")]),
                ]))
            }
            if req.method == "GET" && req.url == "https://cdn.xai.test/out.mp4" {
                return VideoProtocolFixture.bytesResponse(mp4)
            }
            return try VideoProtocolFixture.jsonResponse(.object(["error": .string("unexpected")]), statusCode: 500)
        }

        let env = DictionaryEnvironment(variables: ["XAI_API_KEY": "xai-secret"])
        let model = try AIProviders.makeVideoModel(
            package: "@opencode/ai/providers/xai/videos",
            modelID: "grok-imagine-video",
            environment: env
        )
        let executor = AIRequestExecutor.layer(transport: transport)
        let client = AIVideo.VideoClient.layer(executor: executor)

        let png = AIMedia.bytes(VideoProtocolFixture.samplePNGBytes(), mediaType: "image/png")
        let startJob = try await client.start(AIVideo.VideoRequest(
            model: model,
            prompt: "a cat skating",
            start: try AIMedia.ImageAsset(validating: png),
            end: try AIMedia.ImageAsset(validating: AIMedia.ref(provider: "xai", id: "file_99", mediaType: "image/png")),
            references: [AIMedia.url("https://example.com/voice.mp3", mediaType: "audio/mpeg")],
            duration: AIVideo.VideoDuration(rawValue: "6 seconds"),
            aspect: .auto,
            resolution: .res720p,
            sound: true
        ))
        #expect(startJob.id == "xai_req_1")

        let firstReq = try #require(transport.requests.first)
        #expect(VideoProtocolFixture.headerValue(firstReq, "authorization") == "Bearer xai-secret")
        let body = try VideoProtocolFixture.decodeBody(firstReq)
        #expect(body["model"] == .string("grok-imagine-video"))
        #expect(body["duration"] == .int(6))
        #expect(body["aspect_ratio"] == nil) // auto omitted when start frame is present
        #expect(body["resolution"] == .string("720p"))
        #expect(body["generate_audio"] == .bool(true))
        #expect(body["last_frame"] == .object(["file_id": .string("file_99")]))
        #expect(body["reference_audios"] == .array([.object(["url": .string("https://example.com/voice.mp3")])]))

        // Edit & extend paths strip `mode` from body.
        let editJob = try await client.start(AIVideo.VideoRequest(
            model: model,
            prompt: "recolor",
            aspect: .auto,
            providerOptions: ["mode": .string("edit"), "video": .object(["url": .string("https://example.com/in.mp4")])]
        ))
        #expect(editJob.id == "xai_edit_1")
        let editBody = try VideoProtocolFixture.decodeBody(transport.requests[1])
        #expect(editBody["mode"] == nil)
        #expect(editBody["aspect_ratio"] == .string("auto")) // auto kept when start is absent

        let extJob = try await client.start(AIVideo.VideoRequest(
            model: model,
            prompt: "continue",
            providerOptions: ["mode": .string("extend")]
        ))
        #expect(extJob.id == "xai_ext_1")

        // Pending progress fraction (37 -> 0.37)
        let pending = try await client.status(model: model, id: "xai_pending")
        #expect(pending.status == .running)
        #expect(pending.progress == 0.37)

        // Completed result + asset download
        let result = try await client.result(model: model, id: "xai_req_1")
        let video = try #require(result.video)
        #expect(video.info?.durationSeconds == 6)
        #expect(try await video.bytes(executor: executor) == mp4)

        // Moderation rejection
        do {
            _ = try await client.result(model: model, id: "xai_moderated")
            Issue.record("Expected contentPolicy error")
        } catch let err as AISchema.AIError {
            guard case .contentPolicy = err.reason else {
                Issue.record("Expected contentPolicy, got \(err.reason)")
                return
            }
        }

        // Failure code classification
        do {
            _ = try await client.result(model: model, id: "xai_failed_perm")
            Issue.record("Expected authentication error")
        } catch let err as AISchema.AIError {
            guard case .authentication = err.reason else {
                Issue.record("Expected authentication, got \(err.reason)")
                return
            }
        }

        // Video reference unsupported
        do {
            _ = try await client.start(AIVideo.VideoRequest(
                model: model,
                prompt: "bad ref",
                references: [AIMedia.url("https://example.com/ref.mp4", mediaType: "video/mp4")]
            ))
            Issue.record("Expected unsupportedOperation error")
        } catch let err as AISchema.AIError {
            guard case .unsupportedOperation(let u) = err.reason else {
                Issue.record("Expected unsupportedOperation, got \(err.reason)")
                return
            }
            #expect(u.operation == "video.references")
        }

        // Cancel unsupported on xAI
        do {
            try await client.cancel(model: model, id: "xai_req_1")
            Issue.record("Expected unsupportedOperation on xAI cancel")
        } catch let err as AISchema.AIError {
            guard case .unsupportedOperation(let u) = err.reason else {
                Issue.record("Expected unsupportedOperation, got \(err.reason)")
                return
            }
            #expect(u.operation == "video.cancel")
        }
    }

    // MARK: - MiniMax H3 (v2) & Hailuo (v1)

    @Test("MiniMax H3 v2 & Hailuo v1: URL version stripping, payloads, base_resp errors, file retrieve, cancel")
    func minimaxVideoH3AndHailuo() async throws {
        let transport = VideoProtocolMockTransport { req, _ in
            if req.method == "POST" && req.url == "https://proxy.minimax.test/v2/video_generation" {
                return try VideoProtocolFixture.jsonResponse(.object(["task_id": .string("h3_task_1")]))
            }
            if req.method == "GET" && req.url == "https://proxy.minimax.test/v2/query/video_generation/h3_task_1" {
                return try VideoProtocolFixture.jsonResponse(.object([
                    "task": .object([
                        "id": .string("h3_task_1"),
                        "model": .string("MiniMax-H3"),
                        "status": .string("succeeded"),
                        "duration": .int(5),
                        "content": .object(["url": .string("https://cdn.minimax.test/h3.mp4")]),
                        "usage": .object(["total_seconds": .int(5)]),
                    ]),
                ]))
            }
            if req.method == "GET" && req.url == "https://proxy.minimax.test/v2/query/video_generation/h3_quota" {
                return try VideoProtocolFixture.jsonResponse(.object([
                    "status": .string("failed"),
                    "error": .object(["code": .int(1008), "message": .string("insufficient balance")]),
                ]))
            }
            if req.method == "GET" && req.url == "https://proxy.minimax.test/v2/query/video_generation/h3_policy" {
                return try VideoProtocolFixture.jsonResponse(.object([
                    "status": .string("failed"),
                    "error": .object(["code": .string("1026"), "message": .string("blocked")]),
                ]))
            }
            if req.method == "DELETE" && req.url == "https://proxy.minimax.test/v2/video_generation/h3_task_1" {
                return try VideoProtocolFixture.jsonResponse(.object(["ok": .bool(true)]))
            }
            if req.method == "POST" && req.url == "https://proxy.minimax.test/v1/video_generation" {
                return try VideoProtocolFixture.jsonResponse(.object([
                    "task_id": .string("hailuo_1"),
                    "base_resp": .object(["status_code": .int(0), "status_msg": .string("success")]),
                ]))
            }
            if req.method == "GET" && req.url == "https://proxy.minimax.test/v1/query/video_generation?task_id=hailuo_1" {
                return try VideoProtocolFixture.jsonResponse(.object([
                    "status": .string("Success"),
                    "file_id": .string("file_77"),
                    "video_width": .int(1280),
                    "video_height": .int(720),
                    "base_resp": .object(["status_code": .int(0)]),
                ]))
            }
            if req.method == "GET" && req.url == "https://proxy.minimax.test/v1/files/retrieve?file_id=file_77" {
                return try VideoProtocolFixture.jsonResponse(.object([
                    "file": .object(["download_url": .string("https://cdn.minimax.test/hailuo.mp4")]),
                    "base_resp": .object(["status_code": .int(0)]),
                ]))
            }
            return try VideoProtocolFixture.jsonResponse(.object(["error": .string("unexpected \(req.method) \(req.url)")]), statusCode: 500)
        }

        let settings: [String: JSONValue] = [
            "apiKey": .string("mm-key"),
            "baseURL": .string("https://proxy.minimax.test/v1/"),
        ]
        let h3Model = try AIProviders.makeVideoModel(
            package: "@opencode/ai/providers/minimax/videos",
            modelID: "MiniMax-H3",
            settings: settings
        )
        let hailuoModel = try AIProviders.makeVideoModel(
            package: "@opencode/ai/providers/minimax/videos",
            modelID: "MiniMax-Hailuo-02",
            settings: settings
        )
        let client = AIVideo.VideoClient.layer(executor: AIRequestExecutor.layer(transport: transport))

        // H3 text-only defaults ratio to "16:9", uppercase resolution
        let h3Job = try await client.start(AIVideo.VideoRequest(
            model: h3Model,
            prompt: "waves on shore",
            duration: AIVideo.VideoDuration(rawValue: "5 seconds"),
            aspect: .auto,
            resolution: AIVideo.VideoResolution(rawValue: "768p")
        ))
        #expect(h3Job.id == "h3_task_1")
        let h3Body = try VideoProtocolFixture.decodeBody(transport.requests[0])
        #expect(h3Body["ratio"] == .string("16:9"))
        #expect(h3Body["resolution"] == .string("768P"))

        let h3Result = try await client.result(model: h3Model, id: "h3_task_1")
        #expect(h3Result.usage == .seconds(5))
        #expect(h3Result.video?.info?.durationSeconds == 5)
        try await client.cancel(model: h3Model, id: "h3_task_1")

        // Quota exceeded (1008) & content policy (1026)
        do {
            _ = try await client.result(model: h3Model, id: "h3_quota")
            Issue.record("Expected quotaExceeded")
        } catch let err as AISchema.AIError {
            guard case .quotaExceeded = err.reason else { Issue.record("Got \(err.reason)"); return }
        }
        do {
            _ = try await client.result(model: h3Model, id: "h3_policy")
            Issue.record("Expected contentPolicy")
        } catch let err as AISchema.AIError {
            guard case .contentPolicy = err.reason else { Issue.record("Got \(err.reason)"); return }
        }

        // Hailuo rejects concrete aspect ratio
        do {
            _ = try await client.start(AIVideo.VideoRequest(
                model: hailuoModel,
                prompt: "bad aspect",
                aspect: .ratio(try #require(AIMedia.AspectRatio(rawValue: "16:9")))
            ))
            Issue.record("Expected unsupportedOperation")
        } catch let err as AISchema.AIError {
            guard case .unsupportedOperation(let u) = err.reason else { Issue.record("Got \(err.reason)"); return }
            #expect(u.operation == "video.aspect")
        }

        // Hailuo two-step result retrieval
        let hailuoJob = try await client.start(AIVideo.VideoRequest(
            model: hailuoModel,
            prompt: "sunset"
        ))
        #expect(hailuoJob.id == "hailuo_1")
        let hailuoRes = try await client.result(model: hailuoModel, id: "hailuo_1")
        let hailuoVideo = try #require(hailuoRes.video)
        #expect(hailuoVideo.info?.width == 1280)
        #expect(hailuoVideo.info?.height == 720)
        #expect(hailuoVideo.expiresAt != nil)
        #expect(hailuoRes.providerMetadata?["minimax"]?["fileId"] == .string("file_77"))
    }

    // MARK: - OpenRouter, Seedance & Google Interactions

    @Test("OpenRouter: same-origin download credentials only, 4k resolution casing, inline video ref rejection")
    func openRouterVideoCredentialsAndShape() async throws {
        let mp4 = VideoProtocolFixture.sampleMP4Bytes()
        let transport = VideoProtocolMockTransport { req, _ in
            if req.method == "POST" && req.url == "https://openrouter.ai/api/v1/videos" {
                return try VideoProtocolFixture.jsonResponse(.object(["id": .string("or_1"), "status": .string("pending")]))
            }
            if req.method == "GET" && req.url == "https://openrouter.ai/api/v1/videos/or_1" {
                return try VideoProtocolFixture.jsonResponse(.object([
                    "id": .string("or_1"),
                    "status": .string("completed"),
                    "expires_at": .int(1_700_000_000),
                    "unsigned_urls": .array([
                        .string("https://openrouter.ai/api/v1/videos/or_1/content/0"),
                        .string("https://external-cdn.example/video.mp4"),
                    ]),
                ]))
            }
            if req.method == "GET" && (req.url.contains("/content/0") || req.url.contains("external-cdn")) {
                return VideoProtocolFixture.bytesResponse(mp4)
            }
            return try VideoProtocolFixture.jsonResponse(.object([:]), statusCode: 500)
        }

        let model = try AIProviders.makeVideoModel(
            package: "@opencode/ai/providers/openrouter/videos",
            modelID: "veo-3",
            settings: ["apiKey": .string("or-secret")]
        )
        let executor = AIRequestExecutor.layer(transport: transport)
        let client = AIVideo.VideoClient.layer(executor: executor)

        // Inline audio/video reference rejected
        do {
            _ = try await client.start(AIVideo.VideoRequest(
                model: model,
                prompt: "inline audio",
                references: [AIMedia.bytes([1, 2, 3], mediaType: "audio/mpeg")]
            ))
            Issue.record("Expected unsupportedOperation for inline audio reference")
        } catch let err as AISchema.AIError {
            guard case .unsupportedOperation(let u) = err.reason else { Issue.record("Got \(err.reason)"); return }
            #expect(u.operation == "video.references")
        }

        let job = try await client.start(AIVideo.VideoRequest(
            model: model,
            prompt: "city skyline",
            aspect: .auto,
            resolution: .res4k
        ))
        #expect(job.id == "or_1")
        let startBody = try VideoProtocolFixture.decodeBody(transport.requests[0])
        #expect(startBody["resolution"] == .string("4K"))
        #expect(startBody["aspect_ratio"] == nil)

        let res = try await client.result(model: model, id: "or_1")
        #expect(res.videos.count == 2)
        #expect(res.videos[0].expiresAt == 1_700_000_000_000)

        // Same-origin download carries Bearer token; cross-origin download MUST NOT leak it.
        _ = try await res.videos[0].bytes(executor: executor)
        _ = try await res.videos[1].bytes(executor: executor)
        let sameOriginReq = try #require(transport.requests.first { $0.url.contains("/content/0") })
        let crossOriginReq = try #require(transport.requests.first { $0.url.contains("external-cdn") })
        #expect(VideoProtocolFixture.headerValue(sameOriginReq, "authorization") == "Bearer or-secret")
        #expect(VideoProtocolFixture.headerValue(crossOriginReq, "authorization") == nil)
    }

    @Test("Seedance (volcengine & byteplus) and Google Interactions protocols match upstream wire contracts")
    func seedanceAndGoogleVideoProtocols() async throws {
        let mp4 = VideoProtocolFixture.sampleMP4Bytes()
        let transport = VideoProtocolMockTransport { req, _ in
            if req.method == "POST" && req.url == "https://ark.ap-southeast.bytepluses.com/api/v3/contents/generations/tasks" {
                return try VideoProtocolFixture.jsonResponse(.object(["id": .string("seed_1")]))
            }
            if req.method == "GET" && req.url == "https://ark.ap-southeast.bytepluses.com/api/v3/contents/generations/tasks/seed_1" {
                return try VideoProtocolFixture.jsonResponse(.object([
                    "id": .string("seed_1"),
                    "status": .string("succeeded"),
                    "output_format": .string("mov"),
                    "frames": .int(120),
                    "framespersecond": .int(24),
                    "updated_at": .int(1_700_000_000),
                    "content": .object(["video_url": .string("https://cdn.seedance.test/out.mov")]),
                    "usage": .object(["completion_tokens": .int(500), "total_tokens": .int(600)]),
                ]))
            }
            if req.method == "GET" && req.url == "https://ark.ap-southeast.bytepluses.com/api/v3/contents/generations/tasks/seed_mod" {
                return try VideoProtocolFixture.jsonResponse(.object([
                    "status": .string("failed"),
                    "error": .object(["code": .string("OutputVideoSensitiveContentDetected"), "message": .string("sensitive")]),
                ]))
            }
            if req.method == "DELETE" && req.url == "https://ark.ap-southeast.bytepluses.com/api/v3/contents/generations/tasks/seed_1" {
                return try VideoProtocolFixture.jsonResponse(.object(["ok": .bool(true)]))
            }
            if req.method == "POST" && req.url == "https://generativelanguage.googleapis.com/v1beta/interactions" {
                return try VideoProtocolFixture.jsonResponse(.object(["id": .string("int_1"), "status": .string("in_progress")]))
            }
            if req.method == "GET" && req.url == "https://generativelanguage.googleapis.com/v1beta/interactions/int_1" {
                return try VideoProtocolFixture.jsonResponse(.object([
                    "id": .string("int_1"),
                    "status": .string("completed"),
                    "steps": .array([
                        .object([
                            "type": .string("model_output"),
                            "content": .array([
                                .object([
                                    "type": .string("video"),
                                    "data": .string(VideoProtocolFixture.base64(mp4)),
                                    "mime_type": .string("video/mp4"),
                                ]),
                            ]),
                        ]),
                    ]),
                ]))
            }
            if req.method == "POST" && req.url == "https://generativelanguage.googleapis.com/v1beta/interactions/int_1/cancel" {
                return try VideoProtocolFixture.jsonResponse(.object(["id": .string("int_1"), "status": .string("cancelled")]))
            }
            return try VideoProtocolFixture.jsonResponse(.object([:]), statusCode: 500)
        }

        let executor = AIRequestExecutor.layer(transport: transport)
        let client = AIVideo.VideoClient.layer(executor: executor)

        // Seedance BytePlus
        let seedModel = try AIProviders.makeVideoModel(
            package: "@opencode/ai/providers/byteplus/videos",
            modelID: "seedance-1-5-pro",
            settings: ["apiKey": .string("bp-key")]
        )
        let seedJob = try await client.start(AIVideo.VideoRequest(
            model: seedModel,
            prompt: "",
            references: [AIMedia.ref(provider: "byteplus", id: "char_42", mediaType: "image/png")],
            aspect: .auto,
            providerOptions: ["draft_task": .object(["id": .string("draft_1")])]
        ))
        #expect(seedJob.id == "seed_1")
        let seedBody = try VideoProtocolFixture.decodeBody(transport.requests[0])
        #expect(seedBody["ratio"] == .string("adaptive"))
        #expect(seedBody["draft_task"] == nil) // moved into content array
        if case .array(let items) = seedBody["content"] {
            #expect(items.count == 2) // empty prompt omitted; ref + draft_task included
        } else {
            Issue.record("Expected content array")
        }

        let seedRes = try await client.result(model: seedModel, id: "seed_1")
        let seedVideo = try #require(seedRes.video)
        #expect(seedVideo.mediaType == "video/quicktime")
        #expect(seedVideo.info?.durationSeconds == 5.0)
        try await client.cancel(model: seedModel, id: "seed_1")

        do {
            _ = try await client.result(model: seedModel, id: "seed_mod")
            Issue.record("Expected contentPolicy for SensitiveContentDetected")
        } catch let err as AISchema.AIError {
            guard case .contentPolicy = err.reason else { Issue.record("Got \(err.reason)"); return }
        }

        // Google Interactions Video
        let googleModel = try AIProviders.makeVideoModel(
            package: "@opencode/ai/providers/google/videos",
            modelID: "veo-3.1",
            settings: ["apiKey": .string("g-key")]
        )
        // Rejects lone end frame without start
        do {
            _ = try await client.start(AIVideo.VideoRequest(
                model: googleModel,
                prompt: "bad end",
                end: try AIMedia.ImageAsset(validating: AIMedia.bytes(VideoProtocolFixture.samplePNGBytes(), mediaType: "image/png"))
            ))
            Issue.record("Expected unsupportedOperation for lone end frame")
        } catch let err as AISchema.AIError {
            guard case .unsupportedOperation(let u) = err.reason else { Issue.record("Got \(err.reason)"); return }
            #expect(u.operation == "video.end")
        }

        let gJob = try await client.start(AIVideo.VideoRequest(
            model: googleModel,
            prompt: "ocean breeze",
            start: try AIMedia.ImageAsset(validating: AIMedia.bytes(VideoProtocolFixture.samplePNGBytes(), mediaType: "image/png")),
            duration: AIVideo.VideoDuration(rawValue: "6 seconds"),
            resolution: .res720p
        ))
        #expect(gJob.id == "int_1")
        let gStartReq = try #require(transport.requests.first { $0.url.hasSuffix("/interactions") })
        #expect(VideoProtocolFixture.headerValue(gStartReq, "x-goog-api-key") == "g-key")
        let gBody = try VideoProtocolFixture.decodeBody(gStartReq)
        #expect(gBody["background"] == .bool(true))
        #expect(gBody["generation_config"] == .object(["video_config": .object(["task": .string("image_to_video")])]))

        let gRes = try await client.result(model: googleModel, id: "int_1")
        #expect(try await gRes.video?.bytes(executor: executor) == mp4)
        try await client.cancel(model: googleModel, id: "int_1")
    }

    // MARK: - Queued Media Read Retry

    @Test("MediaRoute.queued retries transient 503/429 on status GET but never retries 400")
    func queuedReadRetryBehavior() async throws {
        let transport = VideoProtocolMockTransport { req, idx in
            if req.url.hasSuffix("/videos/retry_me") {
                if idx == 0 {
                    return try VideoProtocolFixture.jsonResponse(.object(["error": .string("busy")]), statusCode: 503)
                }
                if idx == 1 {
                    return try VideoProtocolFixture.jsonResponse(
                        .object(["error": .string("slow down")]),
                        statusCode: 429,
                        headers: ["retry-after": "0"]
                    )
                }
                return try VideoProtocolFixture.jsonResponse(.object(["status": .string("done")]))
            }
            return try VideoProtocolFixture.jsonResponse(.object(["error": .string("bad")]), statusCode: 400)
        }

        let model = try AIProviders.makeVideoModel(
            package: "@opencode/ai/providers/xai/videos",
            modelID: "grok-imagine-video",
            settings: ["apiKey": .string("k")]
        )
        let client = AIVideo.VideoClient.layer(executor: AIRequestExecutor.layer(transport: transport))

        let status = try await VideoProtocolFixture.fastRetry {
            try await client.status(model: model, id: "retry_me")
        }
        #expect(status.status == .completed)
        #expect(transport.requests.count == 3)

        // 400 fails immediately without retrying
        let beforeBad = transport.requests.count
        do {
            _ = try await VideoProtocolFixture.fastRetry {
                try await client.status(model: model, id: "bad_req")
            }
            Issue.record("Expected 400 error")
        } catch let err as AISchema.AIError {
            guard case .invalidRequest = err.reason else { Issue.record("Got \(err.reason)"); return }
        }
        #expect(transport.requests.count == beforeBad + 1)
    }
}

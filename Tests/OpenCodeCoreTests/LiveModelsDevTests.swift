import Synchronization
import Testing
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

@Suite("Live ModelsDev Catalog, SQLite KV Cache, SWR, Fallback & Credentials")
struct LiveModelsDevTests {
    // MARK: - 1. Real Upstream 9MB Snapshot Decoding & Filtering

    @Test(
        "Decodes real upstream 9MB v2 snapshot.txt preserving API order, costs, limits, modes, and variants",
        .enabled(if: LiveModelsDevHelper.hasRealUpstreamSnapshot())
    )
    func decodesRealUpstreamSnapshotCatalog() throws {
        let text = try LiveModelsDevHelper.loadRealUpstreamSnapshotText()
        #expect(text.utf8.count > 1_000_000)

        let snapshots = try CoreModel.ModelsDev.decodeSnapshot(text)
        #expect(snapshots.count > 250)

        let totalModels = snapshots.reduce(0) { $0 + $1.models.count }
        #expect(totalModels > 5_000)

        let byProvider = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.info.id.rawValue, $0) })

        // Verify `opencode` provider & heterogeneous per-model packages/baseURLs
        let opencode = try #require(byProvider["opencode"])
        #expect(opencode.environment == ["OPENCODE_API_KEY"])
        #expect(opencode.info.package == "@opencode/ai/providers/openai-compatible")
        #expect(opencode.info.settings?.extra["baseURL"] == .string("https://opencode.ai/inference/openai/v1"))
        #expect(opencode.models.count >= 100)

        let bigPickle = try #require(opencode.models.first { $0.id.rawValue == "big-pickle" })
        #expect(bigPickle.package == nil) // inherits provider default package
        #expect(bigPickle.settings?.extra["provider"] == .string("opencode"))
        #expect(bigPickle.cost.first?.input == .zero)

        let opencodeSonnet = try #require(opencode.models.first { $0.id.rawValue == "claude-sonnet-4-6" })
        #expect(opencodeSonnet.package == "@opencode/ai/providers/anthropic")
        #expect(opencodeSonnet.settings?.extra["baseURL"] == .string("https://opencode.ai/inference/anthropic/v1"))
        #expect(opencodeSonnet.limit.context > 0)
        #expect(opencodeSonnet.limit.output > 0)
        #expect((opencodeSonnet.cost.first?.input.rawValue ?? 0) > 0)
        #expect(!opencodeSonnet.variants.isEmpty)

        // Verify `anthropic` picks `messages` over alphabetical `chat-completions`
        let anthropic = try #require(byProvider["anthropic"])
        #expect(anthropic.info.package == "@opencode/ai/providers/anthropic")
        #expect(anthropic.info.settings?.extra["baseURL"] == .string("https://api.anthropic.com/v1"))
        #expect(anthropic.environment.contains("ANTHROPIC_API_KEY"))

        let anthropicSonnet = try #require(anthropic.models.first { $0.id.rawValue == "claude-sonnet-4-6" })
        #expect(anthropicSonnet.package == nil)
        #expect(anthropicSonnet.settings == nil) // inherits provider baseURL
        #expect(anthropicSonnet.capabilities.tools)
        #expect(anthropicSonnet.capabilities.input.contains("pdf"))
        #expect((anthropicSonnet.cost.first?.input.rawValue ?? 0) > 0)
        #expect((anthropicSonnet.cost.first?.output.rawValue ?? 0) > 0)
        #expect((anthropicSonnet.cost.first?.cache.write.rawValue ?? 0) > 0)
        #expect(!anthropicSonnet.variants.isEmpty)

        // Verify `openai` picks `responses` over `chat-completions`, decodes TTL-map cache write order,
        // context tiers, freeform tools, variants, and experimental mode multiplier scaling
        let openai = try #require(byProvider["openai"])
        #expect(openai.info.package == "@opencode/ai/providers/openai/responses")
        #expect(openai.info.settings?.extra["baseURL"] == .string("https://api.openai.com/v1"))

        let gpt6Luna = try #require(openai.models.first { $0.id.rawValue == "gpt-6-luna" })
        #expect(gpt6Luna.package == nil)
        #expect(gpt6Luna.limit.context == 1_050_000)
        #expect(gpt6Luna.limit.input == 922_000)
        #expect(gpt6Luna.limit.output == 128_000)
        #expect(gpt6Luna.capabilities.freeform == [.text, .lark, .regex])
        #expect(gpt6Luna.capabilities.input == ["text", "image", "pdf"])
        #expect(gpt6Luna.variants.map(\.id.rawValue) == ["none", "low", "medium", "high", "xhigh", "max"])
        #expect(gpt6Luna.cost.count == 2)
        #expect(gpt6Luna.cost[0].input.rawValue == 0.1)
        #expect(gpt6Luna.cost[0].output.rawValue == 0.5)
        #expect(gpt6Luna.cost[0].cache.read.rawValue == 0.01)
        // Must pick first TTL key (`30m`: 0.125) rather than alphabetical (`12h`: 0.25)
        #expect(gpt6Luna.cost[0].cache.write.rawValue == 0.125)
        #expect(gpt6Luna.cost[1].tier?.size == 272_000)
        #expect(gpt6Luna.cost[1].input.rawValue == 0.2)
        #expect(gpt6Luna.cost[1].output.rawValue == 0.75)

        let gpt6LunaFast = try #require(openai.models.first { $0.id.rawValue == "gpt-6-luna-fast" })
        #expect(gpt6LunaFast.modelID.rawValue == "gpt-6-luna")
        #expect(gpt6LunaFast.name == "GPT-6 Luna Fast")
        #expect(gpt6LunaFast.body?["service_tier"] == .string("priority"))
        // Priority multiplier = 2x base prices, unscaled context tier preserved
        #expect(gpt6LunaFast.cost.count == 2)
        #expect(gpt6LunaFast.cost[0].input.rawValue == 0.2)
        #expect(gpt6LunaFast.cost[0].output.rawValue == 1.0)
        #expect(gpt6LunaFast.cost[0].cache.read.rawValue == 0.02)
        #expect(gpt6LunaFast.cost[0].cache.write.rawValue == 0.25)
        #expect(gpt6LunaFast.cost[1].tier?.size == 272_000)
        #expect(gpt6LunaFast.cost[1].input.rawValue == 0.2)

        // Verify `google` picks `generate-content` over `chat-completions`
        let google = try #require(byProvider["google"])
        #expect(google.info.package == "@opencode/ai/providers/google")
        let gemini25Pro = try #require(google.models.first { $0.id.rawValue == "gemini-2.5-pro" })
        #expect(gemini25Pro.package == nil)
        #expect(gemini25Pro.limit.context > 0)
        #expect((gemini25Pro.cost.first?.input.rawValue ?? 0) > 0)
        #expect(!gemini25Pro.variants.isEmpty)

        // Verify `openrouter` picks `chat-completions` first over `responses`/`messages`
        let openrouter = try #require(byProvider["openrouter"])
        #expect(openrouter.info.package == "@opencode/ai/providers/openrouter")
        #expect(openrouter.models.count >= 100)

        // Verify `amazon-bedrock` respects buildsOwnURL (no provider baseURL)
        let bedrock = try #require(byProvider["amazon-bedrock"])
        #expect(bedrock.info.package == "@opencode/ai/providers/amazon-bedrock")
        #expect(bedrock.info.settings == nil)

        // Verify filterSnapshots strips deprecated models and Bedrock profile-only IDs
        let hadDeprecatedBefore = snapshots.contains { snap in snap.models.contains { $0.status == .deprecated } }
        let hadBedrockProfileOnlyBefore = bedrock.models.contains {
            CoreModel.ModelsDev.bedrockProfileOnlyIDs.contains($0.modelID.rawValue)
        }
        #expect(hadDeprecatedBefore)
        #expect(hadBedrockProfileOnlyBefore)

        let filtered = CoreModel.ModelsDev.filterSnapshots(snapshots)
        #expect(filtered.count > 250)
        for snap in filtered {
            #expect(snap.info.id.rawValue != "azure-cognitive-services")
            #expect(snap.info.id.rawValue != "google-vertex-anthropic")
            #expect(!snap.models.isEmpty)
            for model in snap.models {
                #expect(model.status != .deprecated)
                if snap.info.id == .amazonBedrock {
                    #expect(!CoreModel.ModelsDev.bedrockProfileOnlyIDs.contains(model.modelID.rawValue))
                }
            }
        }
    }

    @Test("Decodes array-shaped API entries, filters retired aliases/profile-only/deprecated models, and rejects malformed JSON")
    func decodesArrayAPIAndFiltersAliases() throws {
        let catalogJSON = """
        {
          "custom-array": {
            "id": "custom-array",
            "name": "Custom Array API",
            "env": ["CUSTOM_KEY"],
            "models": {
              "m-active": {
                "id": "m-active",
                "type": "chat",
                "name": "Model Active",
                "release_date": "2026-04-01",
                "modalities": { "input": ["text"], "output": ["text"] },
                "capabilities": { "tools": { "supported": true }, "reasoning": { "supported": false } },
                "limit": { "context": 64000, "output": 8192 },
                "api": [
                  {
                    "protocol": "responses",
                    "base_url": "https://api.custom.example/v1",
                    "sdk": { "opencodeai": "@opencode/ai/providers/openai/responses" },
                    "compatibility": { "max_tokens_field": "max_tokens", "media_input": "root" },
                    "capabilities": { "tools": { "freeform": ["text", "lark"] } }
                  }
                ]
              },
              "m-old": {
                "id": "m-old",
                "type": "chat",
                "name": "Model Deprecated",
                "status": "deprecated",
                "release_date": "2024-01-01",
                "modalities": { "input": ["text"], "output": ["text"] },
                "capabilities": { "tools": { "supported": false }, "reasoning": { "supported": false } },
                "api": {
                  "responses": {
                    "base_url": "https://api.custom.example/v1",
                    "sdk": { "opencodeai": "@opencode/ai/providers/openai/responses" }
                  }
                }
              }
            }
          },
          "azure-cognitive-services": {
            "id": "azure-cognitive-services",
            "name": "Azure Legacy",
            "env": ["AZURE_KEY"],
            "models": {
              "legacy-gpt": {
                "id": "legacy-gpt",
                "type": "chat",
                "name": "Legacy GPT",
                "release_date": "2025-01-01",
                "modalities": { "input": ["text"], "output": ["text"] },
                "capabilities": { "tools": { "supported": true }, "reasoning": { "supported": false } },
                "api": { "chat-completions": { "base_url": "", "sdk": { "opencodeai": "@opencode/ai/providers/azure/chat" } } }
              }
            }
          },
          "google-vertex-anthropic": {
            "id": "google-vertex-anthropic",
            "name": "Vertex Anthropic Alias",
            "env": ["GOOGLE_VERTEX_PROJECT"],
            "models": {
              "claude": {
                "id": "claude",
                "type": "chat",
                "name": "Claude",
                "release_date": "2025-01-01",
                "modalities": { "input": ["text"], "output": ["text"] },
                "capabilities": { "tools": { "supported": true }, "reasoning": { "supported": false } },
                "api": { "messages": { "base_url": "", "sdk": { "opencodeai": "@opencode/ai/providers/google-vertex/messages" } } }
              }
            }
          },
          "amazon-bedrock": {
            "id": "amazon-bedrock",
            "name": "Amazon Bedrock",
            "env": ["AWS_REGION"],
            "models": {
              "anthropic.claude-opus-4-7": {
                "id": "anthropic.claude-opus-4-7",
                "type": "chat",
                "name": "Profile Only Opus",
                "release_date": "2026-01-01",
                "modalities": { "input": ["text"], "output": ["text"] },
                "capabilities": { "tools": { "supported": true }, "reasoning": { "supported": false } },
                "api": { "converse": { "base_url": "https://bedrock-runtime.us-east-1.amazonaws.com", "sdk": { "opencodeai": "@opencode/ai/providers/amazon-bedrock" } } }
              },
              "us.anthropic.claude-opus-4-7": {
                "id": "us.anthropic.claude-opus-4-7",
                "type": "chat",
                "name": "US Inference Profile Opus",
                "release_date": "2026-01-01",
                "modalities": { "input": ["text"], "output": ["text"] },
                "capabilities": { "tools": { "supported": true }, "reasoning": { "supported": false } },
                "api": { "converse": { "base_url": "https://bedrock-runtime.us-east-1.amazonaws.com", "sdk": { "opencodeai": "@opencode/ai/providers/amazon-bedrock" } } }
              }
            }
          }
        }
        """

        let decoded = try CoreModel.ModelsDev.decodeSnapshot(catalogJSON)
        #expect(decoded.count == 4)

        let filtered = CoreModel.ModelsDev.filterSnapshots(decoded)
        #expect(filtered.map(\.info.id.rawValue) == ["custom-array", "amazon-bedrock"])

        let custom = try #require(filtered.first { $0.info.id.rawValue == "custom-array" })
        #expect(custom.models.count == 1)
        let active = try #require(custom.models.first)
        #expect(active.id.rawValue == "m-active")
        #expect(active.capabilities.freeform == [.text, .lark])
        #expect(active.compatibility?.maxTokensField == .maxTokens)
        #expect(active.compatibility?.mediaInput == .root)

        let bedrock = try #require(filtered.first { $0.info.id == .amazonBedrock })
        #expect(bedrock.models.map(\.id.rawValue) == ["us.anthropic.claude-opus-4-7"])

        #expect(throws: CoreModel.ModelsDev.DecodeError.self) {
            _ = try CoreModel.ModelsDev.decodeSnapshot("<html>502 Bad Gateway</html>")
        }
        #expect(throws: CoreModel.ModelsDev.DecodeError.expectedObject) {
            _ = try CoreModel.ModelsDev.decodeSnapshot("[1, 2, 3]")
        }
    }

    // MARK: - 2. SQLite KV Cache Parity (String Body & Object Body)

    @Test("Reads upstream SQLite kv 'models-dev:v3:catalog' in both string-body and object-body formats without network calls")
    func readsSQLiteKVCacheBothFormats() async throws {
        let clock = LiveModelsDevHelper.MutableClock(initialMs: 1_770_000_000_000)

        // Format A: `{ updatedAt, digest, body: <rawJSONString> }`
        let kvStringBody = try CoreKV.Service.inMemory()
        try await kvStringBody.set("models-dev:v3:catalog", value: .object([
            "updatedAt": .int(clock.nowMs() - 1_000),
            "digest": .string(CoreModel.ModelsDev.bodyDigest(LiveModelsDevHelper.sampleV2CatalogA)),
            "body": .string(LiveModelsDevHelper.sampleV2CatalogA),
        ]))
        let transportA = LiveModelsDevHelper.RecordingTransport { _ in
            HTTPResponse(head: HTTPResponseHead(statusCode: 500), body: [])
        }
        let serviceA = CoreModel.ModelsDev.Service(
            http: transportA,
            kv: kvStringBody,
            nowMs: { clock.nowMs() }
        )
        let snapsA = try await serviceA.get()
        #expect(transportA.requests.isEmpty)
        #expect(snapsA.count == 2)
        #expect(snapsA.first { $0.info.id == .anthropic }?.info.package == "@opencode/ai/providers/anthropic")
        #expect(snapsA.first { $0.info.id == .openai }?.info.package == "@opencode/ai/providers/openai/responses")

        // Format B: `{ updatedAt, digest, body: <JSONObject> }`
        let kvObjectBody = try CoreKV.Service.inMemory()
        let parsedObj = try LiveModelsDevHelper.decodeJSONObject(LiveModelsDevHelper.sampleV2CatalogA)
        try await kvObjectBody.set("models-dev:v3:catalog", value: .object([
            "updatedAt": .double(Double(clock.nowMs() - 2_000)),
            "digest": .string("precomputed-digest"),
            "body": .object(parsedObj),
        ]))
        let transportB = LiveModelsDevHelper.RecordingTransport { _ in
            HTTPResponse(head: HTTPResponseHead(statusCode: 500), body: [])
        }
        let serviceB = CoreModel.ModelsDev.Service(
            http: transportB,
            kv: kvObjectBody,
            nowMs: { clock.nowMs() }
        )
        let snapsB = try await serviceB.get()
        #expect(transportB.requests.isEmpty)
        #expect(snapsB.count == 2)
        #expect(snapsB.first { $0.info.id == .anthropic }?.info.package == "@opencode/ai/providers/anthropic")
        #expect(snapsB.first { $0.info.id == .openai }?.info.package == "@opencode/ai/providers/openai/responses")
    }

    // MARK: - 3. Live HTTP Fetch, ETag 304, Disk Cache, Bus Refreshed Event

    @Test("Live HTTP fetch persists to SQLite kv + disk cache, sends User-Agent/Accept/If-None-Match, handles 304, and emits Bus Refreshed on digest changes")
    func liveFetchETag304DiskCacheAndBusEvent() async throws {
        let clock = LiveModelsDevHelper.MutableClock(initialMs: 1_770_000_000_000)
        let kv = try CoreKV.Service.inMemory()
        let bus = try await LiveModelsDevHelper.makeBus()
        let cachePath = LiveModelsDevHelper.makeTempCacheFilePath(prefix: "models-dev-live")
        defer { LiveModelsDevHelper.removeTempParent(of: cachePath) }

        let refreshedEvents = Mutex<Int>(0)
        let unsub = bus.listen { event in
            if event.type == CoreModel.ModelsDev.Event.Refreshed.type {
                refreshedEvents.withLock { $0 += 1 }
            }
        }
        defer { unsub() }

        struct ServerState: Sendable {
            var status: Int
            var body: String
            var etag: String?
        }
        let serverState = Mutex(ServerState(status: 200, body: LiveModelsDevHelper.sampleV2CatalogA, etag: "\"v1\""))

        let transport = LiveModelsDevHelper.RecordingTransport { _ in
            let s = serverState.withLock { $0 }
            var headers: [String: String] = ["content-type": "application/json"]
            if let etag = s.etag { headers["ETag"] = etag }
            return HTTPResponse(
                head: HTTPResponseHead(statusCode: s.status, headers: headers),
                body: s.status == 304 ? [] : LiveModelsDevHelper.utf8(s.body)
            )
        }

        let service = CoreModel.ModelsDev.Service(
            http: transport,
            fileSystem: LocalFileSystem.shared,
            kv: kv,
            bus: bus,
            cacheFilePath: cachePath,
            userAgent: "opencode/2.3.2",
            nowMs: { clock.nowMs() }
        )

        // 1. Cold start fetches primary URL, persists KV + disk cache, emits Refreshed
        let first = try await service.get()
        #expect(first.count == 2)
        #expect(transport.requests.count == 1)
        let req1 = try #require(transport.requests.first)
        #expect(req1.url == "https://models.opencode.ai/experimental/v2.0/api.json?type=chat,decision,image,video,realtime")
        #expect(LiveModelsDevHelper.headerValue(req1.headers, named: "user-agent") == "opencode/2.3.2")
        #expect(LiveModelsDevHelper.headerValue(req1.headers, named: "accept") == "application/json")
        #expect(LiveModelsDevHelper.headerValue(req1.headers, named: "if-none-match") == nil)
        #expect(refreshedEvents.withLock { $0 } == 1)

        // Verify SQLite KV catalog + meta rows
        let storedCat = try #require(try await kv.get("models-dev:v3:catalog"))
        if case .object(let catObj) = storedCat {
            #expect(catObj["updatedAt"] == .int(clock.nowMs()))
            #expect(catObj["digest"] == .string(CoreModel.ModelsDev.bodyDigest(LiveModelsDevHelper.sampleV2CatalogA)))
            #expect(catObj["body"] == .string(LiveModelsDevHelper.sampleV2CatalogA))
        } else {
            Issue.record("Expected KV catalog object")
        }
        let storedMeta = try #require(try await kv.get("models-dev:v3:catalog:meta"))
        if case .object(let metaObj) = storedMeta {
            #expect(metaObj["etag"] == .string("\"v1\""))
            #expect(metaObj["digest"] == .string(CoreModel.ModelsDev.bodyDigest(LiveModelsDevHelper.sampleV2CatalogA)))
        } else {
            Issue.record("Expected KV meta object")
        }

        // Verify disk cache written
        let diskBytes = try await LocalFileSystem.shared.readFile(at: cachePath)
        #expect(LiveModelsDevHelper.string(from: diskBytes) == LiveModelsDevHelper.sampleV2CatalogA)

        // 2. Within 5-minute TTL, refresh(force: false) skips HTTP completely
        clock.advance(byMs: 60_000)
        await service.refresh(force: false)
        #expect(transport.requests.count == 1)

        // 3. Past 5-minute TTL, sends If-None-Match and treats 304 as unchanged (no Refreshed event)
        clock.advance(byMs: 5 * 60_000)
        serverState.withLock { $0.status = 304 }
        await service.refresh(force: false)
        #expect(transport.requests.count == 2)
        let req2 = transport.requests[1]
        #expect(LiveModelsDevHelper.headerValue(req2.headers, named: "if-none-match") == "\"v1\"")
        #expect(refreshedEvents.withLock { $0 } == 1)
        #expect((try await service.get()).count == 2)

        // 4. Past another 5-minute TTL with byte-identical 200 OK stays quiet (no Refreshed event)
        clock.advance(byMs: 6 * 60_000)
        serverState.withLock { $0.status = 200 }
        await service.refresh(force: false)
        #expect(transport.requests.count == 3)
        #expect(refreshedEvents.withLock { $0 } == 1)

        // 5. Past another 5-minute TTL with new catalog body updates memory + KV + disk + emits Refreshed
        clock.advance(byMs: 6 * 60_000)
        serverState.withLock {
            $0.status = 200
            $0.body = LiveModelsDevHelper.sampleV2CatalogB
            $0.etag = "\"v2\""
        }
        await service.refresh(force: false)
        #expect(transport.requests.count == 4)
        #expect(refreshedEvents.withLock { $0 } == 2)
        let updated = try await service.get()
        #expect(updated.map(\.info.id.rawValue) == ["google"])

        let updatedDiskBytes = try await LocalFileSystem.shared.readFile(at: cachePath)
        #expect(LiveModelsDevHelper.string(from: updatedDiskBytes) == LiveModelsDevHelper.sampleV2CatalogB)

        // 6. Fresh service with empty KV loads immediately from persisted disk cache
        let coldKV = try CoreKV.Service.inMemory()
        let offlineTransport = LiveModelsDevHelper.RecordingTransport { _ in
            HTTPResponse(head: HTTPResponseHead(statusCode: 500), body: [])
        }
        let diskBacked = CoreModel.ModelsDev.Service(
            options: CoreModel.ModelsDev.Options(fetch: false),
            http: offlineTransport,
            fileSystem: LocalFileSystem.shared,
            kv: coldKV,
            cacheFilePath: cachePath,
            nowMs: { clock.nowMs() }
        )
        let fromDisk = try await diskBacked.get()
        #expect(offlineTransport.requests.isEmpty)
        #expect(fromDisk.map(\.info.id.rawValue) == ["google"])
    }

    // MARK: - 4. Automatic Fallback to models.dev v1 API

    @Test("Automatically falls back to https://models.dev/api.json v1 on primary HTTP error, invalid JSON, or timeout")
    func fallsBackToModelsDevV1() async throws {
        // Case A: Primary returns 503 -> falls back to https://models.dev/api.json (v1)
        do {
            let kv = try CoreKV.Service.inMemory()
            let memFS = LiveModelsDevHelper.InMemoryFileSystem()
            let transport = LiveModelsDevHelper.RecordingTransport { req in
                if req.url.hasPrefix("https://models.opencode.ai") {
                    return HTTPResponse(head: HTTPResponseHead(statusCode: 503), body: LiveModelsDevHelper.utf8("Service Unavailable"))
                }
                if req.url == "https://models.dev/api.json" {
                    return HTTPResponse(
                        head: HTTPResponseHead(statusCode: 200, headers: ["etag": "\"v1-fallback\""]),
                        body: LiveModelsDevHelper.utf8(LiveModelsDevHelper.sampleV1Catalog)
                    )
                }
                return HTTPResponse(head: HTTPResponseHead(statusCode: 404), body: [])
            }
            let service = CoreModel.ModelsDev.Service(
                http: transport,
                fileSystem: memFS,
                kv: kv,
                cacheFilePath: "/cache/models.json"
            )
            let snaps = try await service.get()
            #expect(transport.requests.count == 2)
            #expect(transport.requests[0].url == "https://models.opencode.ai/experimental/v2.0/api.json?type=chat,decision,image,video,realtime")
            #expect(transport.requests[1].url == "https://models.dev/api.json")
            #expect(snaps.count == 2)

            let openai = try #require(snaps.first { $0.info.id == .openai })
            #expect(openai.info.package == "@opencode/ai/providers/openai")
            let gpt5Mini = try #require(openai.models.first { $0.id.rawValue == "gpt-5-mini" })
            #expect(gpt5Mini.limit.context == 400_000)
            #expect(gpt5Mini.cost.count == 2)
            #expect(gpt5Mini.cost[0].input.rawValue == 0.25)
            #expect(gpt5Mini.cost[1].tier?.size == 200_000)
            #expect(gpt5Mini.cost[1].input.rawValue == 0.5)
            #expect(gpt5Mini.variants.map(\.id.rawValue) == ["low", "medium", "high"])

            let deepseek = try #require(snaps.first { $0.info.id.rawValue == "deepseek" })
            #expect(deepseek.info.package == "@opencode/ai/providers/deepseek")
            #expect(deepseek.models.first?.compatibility?.reasoningField?.rawValue == "reasoning_content")
            #expect(await memFS.exists(at: "/cache/models.json"))
        }

        // Case B: Primary returns 200 with invalid JSON -> falls back to https://models.dev/api.json
        do {
            let kv = try CoreKV.Service.inMemory()
            let transport = LiveModelsDevHelper.RecordingTransport { req in
                if req.url.hasPrefix("https://models.opencode.ai") {
                    return HTTPResponse(head: HTTPResponseHead(statusCode: 200), body: LiveModelsDevHelper.utf8("<html>not json</html>"))
                }
                return HTTPResponse(head: HTTPResponseHead(statusCode: 200), body: LiveModelsDevHelper.utf8(LiveModelsDevHelper.sampleV1Catalog))
            }
            let service = CoreModel.ModelsDev.Service(http: transport, kv: kv)
            let snaps = try await service.get()
            #expect(transport.requests.count == 2)
            #expect(snaps.count == 2)
        }

        // Case C: Primary times out -> falls back to https://models.dev/api.json cleanly
        do {
            let kv = try CoreKV.Service.inMemory()
            let transport = LiveModelsDevHelper.RecordingTransport { req in
                if req.url.hasPrefix("https://models.opencode.ai") {
                    try await Task.sleep(for: .milliseconds(500))
                    return HTTPResponse(head: HTTPResponseHead(statusCode: 200), body: LiveModelsDevHelper.utf8(LiveModelsDevHelper.sampleV2CatalogA))
                }
                return HTTPResponse(head: HTTPResponseHead(statusCode: 200), body: LiveModelsDevHelper.utf8(LiveModelsDevHelper.sampleV1Catalog))
            }
            let service = CoreModel.ModelsDev.Service(
                http: transport,
                kv: kv,
                requestTimeoutMs: 40
            )
            let snaps = try await service.get()
            #expect(transport.requests.count == 2)
            #expect(snaps.count == 2)
        }
    }

    // MARK: - 5. Non-Blocking Stale-While-Revalidate

    @Test("Returns stale cached snapshots immediately and revalidates in the background without blocking get()")
    func staleWhileRevalidateReturnsImmediately() async throws {
        let clock = LiveModelsDevHelper.MutableClock(initialMs: 1_770_000_000_000)
        let kv = try CoreKV.Service.inMemory()
        let bus = try await LiveModelsDevHelper.makeBus()
        let memFS = LiveModelsDevHelper.InMemoryFileSystem(clock: { clock.nowMs() })

        // Pre-seed stale KV cache (10 minutes old)
        try await kv.set("models-dev:v3:catalog", value: .object([
            "updatedAt": .int(clock.nowMs() - 10 * 60_000),
            "digest": .string(CoreModel.ModelsDev.bodyDigest(LiveModelsDevHelper.sampleV2CatalogA)),
            "body": .string(LiveModelsDevHelper.sampleV2CatalogA),
        ]))

        let refreshedCount = Mutex<Int>(0)
        let unsub = bus.listen { event in
            if event.type == CoreModel.ModelsDev.Event.Refreshed.type {
                refreshedCount.withLock { $0 += 1 }
            }
        }
        defer { unsub() }

        let transport = LiveModelsDevHelper.RecordingTransport { _ in
            // Deliberately slow network response to prove get() did NOT block on it
            try await Task.sleep(for: .milliseconds(120))
            return HTTPResponse(
                head: HTTPResponseHead(statusCode: 200, headers: ["etag": "\"swr-v2\""]),
                body: LiveModelsDevHelper.utf8(LiveModelsDevHelper.sampleV2CatalogB)
            )
        }

        let service = CoreModel.ModelsDev.Service(
            http: transport,
            fileSystem: memFS,
            kv: kv,
            bus: bus,
            cacheFilePath: "/cache/swr-models.json",
            nowMs: { clock.nowMs() }
        )

        var immediateSnapshots: [CoreModel.ModelsDev.Snapshot] = []
        let elapsedMs = try await LiveModelsDevHelper.measureElapsedMs {
            immediateSnapshots = try await service.get()
        }
        // Must return cached snapshots immediately (< 100ms, well below the 120ms HTTP delay)
        #expect(elapsedMs < 100)
        #expect(immediateSnapshots.count == 2)
        #expect(immediateSnapshots.contains { $0.info.id == .anthropic })

        // Background refresh should complete, update cache/disk, and emit Refreshed
        let refreshed = await LiveModelsDevHelper.waitUntil(timeoutMs: 15_000) {
            refreshedCount.withLock { $0 } >= 1
        }
        #expect(refreshed)

        let freshSnapshots = try await service.get()
        #expect(freshSnapshots.map(\.info.id.rawValue) == ["google"])
        #expect(await memFS.exists(at: "/cache/swr-models.json"))
    }

    @Test("Self-heals corrupt KV entry via disk cache SWR and supports custom mirror /api.json fallback")
    func corruptKVSelfHealAndCustomMirrorFallback() async throws {
        let clock = LiveModelsDevHelper.MutableClock(initialMs: 1_770_000_000_000)
        let kv = try CoreKV.Service.inMemory()
        let memFS = LiveModelsDevHelper.InMemoryFileSystem(clock: { clock.nowMs() })

        // Seed corrupt KV entry and stale disk cache
        try await kv.set("models-dev:v3:catalog", value: .object([
            "updatedAt": .int(clock.nowMs()),
            "body": .string("{not-valid-json"),
        ]))
        memFS.seedFile(
            LiveModelsDevHelper.sampleV2CatalogA,
            at: "/cache/models.json",
            modifiedAtMs: clock.nowMs() - 10 * 60_000
        )

        let transport = LiveModelsDevHelper.RecordingTransport { _ in
            HTTPResponse(
                head: HTTPResponseHead(statusCode: 200, headers: ["etag": "\"healed-v2\""]),
                body: LiveModelsDevHelper.utf8(LiveModelsDevHelper.sampleV2CatalogB)
            )
        }
        let service = CoreModel.ModelsDev.Service(
            http: transport,
            fileSystem: memFS,
            kv: kv,
            cacheFilePath: "/cache/models.json",
            nowMs: { clock.nowMs() }
        )

        // Immediately returns disk cache snapshots and removes corrupt KV entry
        let initial = try await service.get()
        #expect(initial.count == 2)

        // Background SWR replaces KV + disk with fresh catalog
        let updated = await LiveModelsDevHelper.waitUntil(timeoutMs: 15_000) {
            (try? await service.get().map(\.info.id.rawValue)) == ["google"]
        }
        #expect(updated)
        #expect(try await kv.get("models-dev:v3:catalog") != nil)

        // Custom mirror URL uses hashed KV key and falls back to `<mirror>/api.json`
        let mirrorKV = try CoreKV.Service.inMemory()
        let mirrorURL = "https://mirror.internal.example"
        let mirrorTransport = LiveModelsDevHelper.RecordingTransport { req in
            if req.url.contains("/experimental/v2.0/api.json") {
                return HTTPResponse(head: HTTPResponseHead(statusCode: 404), body: [])
            }
            if req.url == "\(mirrorURL)/api.json" {
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 200),
                    body: LiveModelsDevHelper.utf8(LiveModelsDevHelper.sampleV1Catalog)
                )
            }
            return HTTPResponse(head: HTTPResponseHead(statusCode: 500), body: [])
        }
        let mirrorService = CoreModel.ModelsDev.Service(
            options: CoreModel.ModelsDev.Options(url: mirrorURL),
            http: mirrorTransport,
            kv: mirrorKV,
            nowMs: { clock.nowMs() }
        )
        let mirrorSnaps = try await mirrorService.get()
        #expect(mirrorSnaps.count == 2)
        #expect(mirrorTransport.requests.map(\.url) == [
            "\(mirrorURL)\(CoreModel.ModelsDev.catalogPath)",
            "\(mirrorURL)/api.json",
        ])
        let hashedKey = "models-dev:v3:catalog:\(Hash.fast(mirrorURL))"
        #expect(try await mirrorKV.get(hashedKey) != nil)
        #expect(try await mirrorKV.get("models-dev:v3:catalog") == nil)
    }

    @Test("Keeps realtime models that answer in speech and call tools as voice models, not chat models")
    func decodesRealtimeVoiceModelsOnlyWhenSpeechAndToolsSupported() throws {
        let catalog = """
        {
          "acme": {
            "id": "acme",
            "name": "Acme",
            "env": ["ACME_API_KEY"],
            "models": {
              "chat": {
                "id": "chat",
                "type": "chat",
                "name": "Acme Chat",
                "release_date": "2026-09-01",
                "modalities": { "input": ["text"], "output": ["text"] },
                "capabilities": { "tools": { "supported": true }, "reasoning": { "supported": false } },
                "limit": { "context": 64000, "output": 8192 },
                "api": { "chat-completions": { "base_url": "https://api.acme.test/v1", "sdk": { "opencodeai": "@opencode/ai/providers/openai-compatible" } } }
              },
              "voice": {
                "id": "voice",
                "type": "realtime",
                "name": "Voice 1",
                "release_date": "2026-09-10",
                "modalities": { "input": ["audio/pcm"], "output": ["text", "audio/pcm"] },
                "capabilities": { "tools": { "supported": true }, "reasoning": { "supported": false } },
                "api": { "live": { "base_url": "https://api.acme.test/v1", "sdk": { "opencodeai": "none" } } }
              },
              "translate": {
                "id": "translate",
                "type": "realtime",
                "name": "Translate",
                "release_date": "2026-09-10",
                "modalities": { "input": ["audio/pcm"], "output": ["text", "audio/pcm"] },
                "capabilities": { "tools": { "supported": false }, "reasoning": { "supported": false } },
                "api": { "live": { "base_url": "https://api.acme.test/v1", "sdk": { "opencodeai": "none" } } }
              },
              "streaming": {
                "id": "streaming",
                "type": "realtime",
                "name": "Streaming",
                "release_date": "2026-09-10",
                "modalities": { "input": ["audio/pcm"], "output": ["text"] },
                "capabilities": { "tools": { "supported": true }, "reasoning": { "supported": false } },
                "api": { "live": { "base_url": "https://api.acme.test/v1", "sdk": { "opencodeai": "none" } } }
              },
              "retired": {
                "id": "retired",
                "type": "realtime",
                "name": "Retired",
                "status": "deprecated",
                "release_date": "2025-09-10",
                "modalities": { "input": ["audio/pcm"], "output": ["text", "audio/pcm"] },
                "capabilities": { "tools": { "supported": true }, "reasoning": { "supported": false } },
                "api": { "live": { "base_url": "https://api.acme.test/v1", "sdk": { "opencodeai": "none" } } }
              }
            }
          }
        }
        """

        let decoded = try CoreModel.ModelsDev.decodeSnapshot(catalog)
        let acme = try #require(decoded.first { $0.info.id.rawValue == "acme" })
        #expect(acme.models.map(\.id.rawValue) == ["chat"])
        #expect(acme.voices == [
            CoreModel.ModelsDev.VoiceModel(id: "voice", name: "Voice 1", api: "live", releaseDate: "2026-09-10"),
        ])
        let filtered = CoreModel.ModelsDev.filterSnapshots(decoded)
        #expect(filtered.first?.voices == acme.voices)
    }

    @Test("Frees and ignores catalogs cached under earlier v1 and v2 KV keys")
    func evictsLegacyV1AndV2KVCacheKeys() async throws {
        let kv = try CoreKV.Service.inMemory()
        for old in ["models-dev:catalog", "models-dev:v2:catalog"] {
            try await kv.set(old, value: .object([
                "updatedAt": .int(1_770_000_000_000),
                "digest": .string("old"),
                "body": .string("{}"),
            ]))
            try await kv.set("\(old):meta", value: .object([
                "updatedAt": .int(1_770_000_000_000),
                "digest": .string("old"),
            ]))
        }
        let scope = LayerNode.ResourceScope()
        let out = try await CoreModel.ModelsDev.layer(CoreModel.ModelsDev.Options(fetch: false)).build(
            LayerNode.Output([CoreKV.Service.serviceKey: kv]),
            scope
        )
        let service = try #require(out.get(CoreModel.ModelsDev.Service.serviceKey, as: CoreModel.ModelsDev.Service.self))
        let snaps = try await service.get()
        #expect(!snaps.isEmpty)
        for old in ["models-dev:catalog", "models-dev:catalog:meta", "models-dev:v2:catalog", "models-dev:v2:catalog:meta"] {
            #expect(try await kv.get(old) == nil)
        }
    }

    // MARK: - 6. Credential SQLite Row Decoding Robustness

    @Test("CoreProvider.Credential.Service decodes upstream SQLite credential rows including float expires and legacy configuration")
    func decodesUpstreamSQLiteCredentialRows() async throws {
        let db = try SQLiteDatabaseFactory.open(path: ":memory:")
        let service = try CoreProvider.Credential.Service(database: db)

        // 1. OAuth with integer expires + metadata
        let oauthIntJSON = """
        {"type":"oauth","methodID":"oauth-pkce","refresh":"rt_int_1","access":"at_int_1","expires":1776543210000,"metadata":{"accountId":"acct_1","email":"dev@example.com"}}
        """
        // 2. OAuth with floating-point expires (fractional ms from JS math) + null metadata
        let oauthFloatJSON = """
        {"type":"oauth","methodID":"oauth-device","refresh":"rt_flt_2","access":"at_flt_2","expires":1776543210123.75,"metadata":null}
        """
        // 3. OAuth with zero expires and methodID stored in SQLite `method_id` column
        let oauthColMethodJSON = """
        {"type":"oauth","refresh":"rt_zero_3","access":"at_zero_3","expires":0.0}
        """
        // 4. Key credential with metadata
        let keyJSON = """
        {"type":"key","key":"sk-live-secret-42","metadata":{"orgID":"org_99","server":"https://opencode.ai/console"}}
        """
        // 5. Legacy pre-v2.1 key credential with `configuration` overriding `metadata`
        let legacyKeyJSON = """
        {"type":"key","key":"sk-legacy-key","metadata":{"region":"us-west-2","tier":"free"},"configuration":{"region":"eu-west-1","project":"proj_1"}}
        """
        // 6. External credential
        let externalJSON = """
        {"type":"external","methodID":"aws-sso","metadata":{"profile":"prod"}}
        """

        let rows: [(String, String, String, String, String?, Int64)] = [
            ("cred_oauth_int", "anthropic", "Anthropic OAuth Int", oauthIntJSON, "oauth-pkce", 1),
            ("cred_oauth_flt", "openai", "OpenAI OAuth Float", oauthFloatJSON, "oauth-device", 1),
            ("cred_oauth_col", "github-copilot", "Copilot OAuth", oauthColMethodJSON, "device-flow", 1),
            ("cred_key_std", "opencode", "OpenCode Key", keyJSON, nil, 1),
            ("cred_key_legacy", "google-vertex", "Vertex Legacy Key", legacyKeyJSON, nil, 1),
            ("cred_external", "amazon-bedrock", "Bedrock SSO", externalJSON, "aws-sso", 1),
        ]

        for (id, intID, label, val, methodCol, active) in rows {
            _ = try db.execute(
                """
                INSERT INTO credential (id, integration_id, label, value, method_id, active, time_created, time_updated)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                parameters: [
                    .text(id),
                    .text(intID),
                    .text(label),
                    .text(val),
                    methodCol.map(SQLiteValue.text) ?? .null,
                    .integer(active),
                    .integer(1_770_000_000_000),
                    .integer(1_770_000_000_000),
                ]
            )
        }

        let all = try await service.all()
        #expect(all.count == 6)

        let c1 = try #require(try await service.get(CoreProvider.Credential.ID(rawValue: "cred_oauth_int")))
        if case .oauth(let oauth) = c1.value {
            #expect(oauth.methodID.rawValue == "oauth-pkce")
            #expect(oauth.refresh == "rt_int_1")
            #expect(oauth.access == "at_int_1")
            #expect(oauth.expires.rawValue == 1_776_543_210_000)
            #expect(oauth.metadata?["accountId"] == .string("acct_1"))
        } else {
            Issue.record("Expected oauth credential for cred_oauth_int")
        }

        let c2 = try #require(try await service.get(CoreProvider.Credential.ID(rawValue: "cred_oauth_flt")))
        if case .oauth(let oauth) = c2.value {
            #expect(oauth.methodID.rawValue == "oauth-device")
            #expect(oauth.refresh == "rt_flt_2")
            #expect(oauth.access == "at_flt_2")
            #expect(oauth.expires.rawValue == 1_776_543_210_123)
            #expect(oauth.metadata == nil)
        } else {
            Issue.record("Expected oauth credential for cred_oauth_flt")
        }

        let c3 = try #require(try await service.get(CoreProvider.Credential.ID(rawValue: "cred_oauth_col")))
        if case .oauth(let oauth) = c3.value {
            #expect(oauth.methodID.rawValue == "device-flow")
            #expect(oauth.expires.rawValue == 0)
            #expect(!CoreProvider.Credential.expiring(oauth, now: 1_900_000_000_000))
        } else {
            Issue.record("Expected oauth credential for cred_oauth_col")
        }

        let c4 = try #require(try await service.get(CoreProvider.Credential.ID(rawValue: "cred_key_std")))
        if case .key(let key) = c4.value {
            #expect(key.key == "sk-live-secret-42")
            #expect(key.metadata?["orgID"] == .string("org_99"))
        } else {
            Issue.record("Expected key credential for cred_key_std")
        }

        let c5 = try #require(try await service.get(CoreProvider.Credential.ID(rawValue: "cred_key_legacy")))
        if case .key(let key) = c5.value {
            #expect(key.key == "sk-legacy-key")
            #expect(key.metadata?["region"] == .string("eu-west-1"))
            #expect(key.metadata?["project"] == .string("proj_1"))
            #expect(key.metadata?["tier"] == .string("free"))
        } else {
            Issue.record("Expected legacy key credential for cred_key_legacy")
        }

        let c6 = try #require(try await service.get(CoreProvider.Credential.ID(rawValue: "cred_external")))
        if case .external(let ext) = c6.value {
            #expect(ext.methodID.rawValue == "aws-sso")
            #expect(ext.metadata?["profile"] == .string("prod"))
        } else {
            Issue.record("Expected external credential for cred_external")
        }
    }
}

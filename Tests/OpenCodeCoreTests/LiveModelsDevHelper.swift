#if os(macOS) || os(Linux) || os(Windows)
import Foundation
#elseif canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Foundation-backed helpers and test fixtures for `LiveModelsDevTests`.
/// Intentionally does NOT `import Testing` (macOS CLT cross-import overlay rule).
enum LiveModelsDevHelper {
    final class MutableClock: Sendable {
        private let value: Mutex<Int64>

        init(initialMs: Int64) {
            self.value = Mutex(initialMs)
        }

        func nowMs() -> Int64 {
            value.withLock { $0 }
        }

        func advance(byMs delta: Int64) {
            value.withLock { $0 += delta }
        }
    }

    final class RecordingTransport: HTTPTransport, Sendable {
        private let recorded = Mutex<[HTTPRequest]>([])
        private let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse

        init(handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
            self.handler = handler
        }

        var requests: [HTTPRequest] {
            recorded.withLock { $0 }
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            recorded.withLock { $0.append(request) }
            return try await handler(request)
        }

        func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
            let resp = try await send(request)
            let body = resp.body
            let chunks = AsyncThrowingStream<[UInt8], any Error> { continuation in
                if !body.isEmpty { continuation.yield(body) }
                continuation.finish()
            }
            return HTTPStreamingResponse(head: resp.head, chunks: chunks)
        }
    }

    final class InMemoryFileSystem: OpenCodeFileSystem, Sendable {
        private struct Entry: Sendable {
            var bytes: [UInt8]
            var modifiedAtMs: Int64
        }

        private let files = Mutex<[String: Entry]>([:])
        private let clock: @Sendable () -> Int64

        init(clock: @escaping @Sendable () -> Int64 = { Flock.currentEpochMs() }) {
            self.clock = clock
        }

        func readFile(at path: String) async throws -> [UInt8] {
            guard let entry = files.withLock({ $0[path] }) else {
                throw PlatformError.notFound(path)
            }
            return entry.bytes
        }

        func writeFile(_ bytes: [UInt8], to path: String, createDirectories: Bool) async throws {
            _ = createDirectories
            let ts = clock()
            files.withLock { $0[path] = Entry(bytes: bytes, modifiedAtMs: ts) }
        }

        func seedFile(_ text: String, at path: String, modifiedAtMs: Int64) {
            files.withLock { $0[path] = Entry(bytes: Array(text.utf8), modifiedAtMs: modifiedAtMs) }
        }

        func exists(at path: String) async -> Bool {
            files.withLock { $0[path] != nil }
        }

        func stat(at path: String) async throws -> FileStat {
            guard let entry = files.withLock({ $0[path] }) else {
                throw PlatformError.notFound(path)
            }
            return FileStat(type: .file, size: Int64(entry.bytes.count), modifiedAtMs: entry.modifiedAtMs)
        }

        func makeDirectory(at path: String, recursive: Bool) async throws {
            _ = (path, recursive)
        }

        func readDirectory(at path: String) async throws -> [String] {
            _ = path
            return []
        }

        func remove(at path: String) async throws {
            files.withLock { _ = $0.removeValue(forKey: path) }
        }

        func rename(from source: String, to destination: String) async throws {
            files.withLock { map in
                if let entry = map.removeValue(forKey: source) {
                    map[destination] = entry
                }
            }
        }

        func realPath(at path: String) async throws -> String { path }

        func setModificationTime(at path: String, epochMs: Int64) async throws {
            files.withLock { map in
                if var entry = map[path] {
                    entry.modifiedAtMs = epochMs
                    map[path] = entry
                }
            }
        }

        func chmod(at path: String, mode: UInt16) async throws {
            _ = (path, mode)
        }
    }

    static func utf8(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    static func string(from bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    static func decodeJSONObject(_ text: String) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8))
    }

    static func headerValue(_ headers: [String: String], named name: String) -> String? {
        let lower = name.lowercased()
        return headers.first(where: { $0.key.lowercased() == lower })?.value
    }

    static func hasRealUpstreamSnapshot() -> Bool {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("upstream/opencode/packages/core/src/models-dev/snapshot.txt")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return true
            }
            dir.deleteLastPathComponent()
        }
        return false
    }

    static func loadRealUpstreamSnapshotText() throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("upstream/opencode/packages/core/src/models-dev/snapshot.txt")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir.deleteLastPathComponent()
        }
        throw PlatformError.notFound("upstream/opencode/packages/core/src/models-dev/snapshot.txt")
    }

    static func makeBus() async throws -> CoreBus.Service {
        let db = try await CoreDatabaseStore.open().db
        return CoreBus.Service(db: db)
    }

    static func makeTempCacheFilePath(prefix: String = "models-dev-test") -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        return dir.appendingPathComponent("models.json").path
    }

    static func removeTempParent(of filePath: String) {
        let parent = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: parent)
    }

    static func waitUntil(
        timeoutMs: Int = 2_000,
        pollIntervalMs: Int = 10,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Flock.currentEpochMs() + Int64(timeoutMs)
        while Flock.currentEpochMs() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(pollIntervalMs))
        }
        return await condition()
    }

    static func measureElapsedMs(_ block: () async throws -> Void) async rethrows -> Int64 {
        let start = Flock.currentEpochMs()
        try await block()
        return Flock.currentEpochMs() - start
    }

    static let sampleV2CatalogA = """
    {
      "anthropic": {
        "id": "anthropic",
        "name": "Anthropic",
        "env": ["ANTHROPIC_API_KEY"],
        "models": {
          "claude-sonnet-4-6": {
            "id": "claude-sonnet-4-6",
            "type": "chat",
            "name": "Claude Sonnet 4.6",
            "family": "claude-sonnet",
            "release_date": "2026-02-17",
            "modalities": { "input": ["text", "image/png", "application/pdf"], "output": ["text"] },
            "capabilities": {
              "tools": { "supported": true },
              "reasoning": { "supported": true, "effort": ["low", "medium", "high", "max"] },
              "temperature": true
            },
            "limit": { "context": 200000, "output": 64000 },
            "cost": {
              "text": {
                "input": { "price": 3, "cache": { "read": 0.3, "write": { "5m": 3.75, "1h": 6 } } },
                "output": { "price": 15 }
              }
            },
            "api": {
              "messages": {
                "base_url": "https://api.anthropic.com/v1",
                "sdk": { "aisdk": "@ai-sdk/anthropic", "opencodeai": "@opencode/ai/providers/anthropic" }
              },
              "chat-completions": {
                "base_url": "https://api.anthropic.com/v1",
                "sdk": { "aisdk": "@ai-sdk/openai-compatible", "opencodeai": "@opencode/ai/providers/openai-compatible" }
              }
            }
          }
        }
      },
      "openai": {
        "id": "openai",
        "name": "OpenAI",
        "env": ["OPENAI_API_KEY"],
        "models": {
          "gpt-5.2": {
            "id": "gpt-5.2",
            "type": "chat",
            "name": "GPT-5.2",
            "family": "gpt",
            "release_date": "2026-01-15",
            "modalities": { "input": ["text", "image/jpeg"], "output": ["text"] },
            "capabilities": {
              "tools": { "supported": true },
              "reasoning": { "supported": true, "effort": ["low", "medium", "high"] },
              "temperature": false
            },
            "limit": { "context": 400000, "output": 128000 },
            "cost": {
              "text": {
                "input": { "price": 1.75, "cache": { "read": 0.175 } },
                "output": { "price": 14 }
              }
            },
            "api": {
              "responses": {
                "base_url": "https://api.openai.com/v1",
                "sdk": { "aisdk": "@ai-sdk/openai", "opencodeai": "@opencode/ai/providers/openai/responses" },
                "capabilities": { "tools": { "freeform": ["text", "lark", "regex"] } }
              },
              "chat-completions": {
                "base_url": "https://api.openai.com/v1",
                "sdk": { "aisdk": "@ai-sdk/openai", "opencodeai": "@opencode/ai/providers/openai/chat" }
              }
            }
          }
        }
      }
    }
    """

    static let sampleV2CatalogB = """
    {
      "google": {
        "id": "google",
        "name": "Google",
        "env": ["GEMINI_API_KEY"],
        "models": {
          "gemini-2.5-pro": {
            "id": "gemini-2.5-pro",
            "type": "chat",
            "name": "Gemini 2.5 Pro",
            "family": "gemini-pro",
            "release_date": "2025-06-17",
            "modalities": { "input": ["text", "image/png", "audio/mp3", "application/pdf"], "output": ["text"] },
            "capabilities": {
              "tools": { "supported": true },
              "reasoning": { "supported": true, "toggle": true, "budget": { "min": 1024, "max": 32768 } }
            },
            "limit": { "context": 1048576, "output": 65536 },
            "cost": {
              "text": {
                "input": { "price": 1.25, "cache": { "read": 0.31 } },
                "output": { "price": 10 }
              }
            },
            "api": {
              "generate-content": {
                "base_url": "https://generativelanguage.googleapis.com/v1beta",
                "sdk": { "aisdk": "@ai-sdk/google", "opencodeai": "@opencode/ai/providers/google" }
              },
              "chat-completions": {
                "base_url": "https://generativelanguage.googleapis.com/v1beta/openai",
                "sdk": { "aisdk": "@ai-sdk/openai-compatible", "opencodeai": "@opencode/ai/providers/openai-compatible" }
              }
            }
          }
        }
      }
    }
    """

    static let sampleV1Catalog = """
    {
      "openai": {
        "id": "openai",
        "name": "OpenAI",
        "env": ["OPENAI_API_KEY"],
        "npm": "@ai-sdk/openai",
        "api": "https://api.openai.com/v1",
        "models": {
          "gpt-5-mini": {
            "id": "gpt-5-mini",
            "name": "GPT-5 Mini",
            "family": "gpt-mini",
            "release_date": "2026-03-01",
            "tool_call": true,
            "reasoning": true,
            "reasoning_options": [
              { "type": "effort", "values": ["low", "medium", "high", null] }
            ],
            "temperature": false,
            "modalities": { "input": ["text", "image"], "output": ["text"] },
            "limit": { "context": 400000, "output": 128000 },
            "cost": {
              "input": 0.25,
              "output": 2.0,
              "cache_read": 0.025,
              "tiers": [
                { "tier": { "size": 200000 }, "input": 0.5, "output": 4.0, "cache_read": 0.05 }
              ]
            }
          }
        }
      },
      "deepseek": {
        "id": "deepseek",
        "name": "DeepSeek",
        "env": ["DEEPSEEK_API_KEY"],
        "npm": "@ai-sdk/openai-compatible",
        "api": "https://api.deepseek.com/v1",
        "models": {
          "deepseek-reasoner": {
            "id": "deepseek-reasoner",
            "name": "DeepSeek Reasoner",
            "release_date": "2025-12-01",
            "tool_call": true,
            "reasoning": true,
            "interleaved": { "field": "reasoning_content" },
            "limit": { "context": 128000, "output": 16384 },
            "cost": { "input": 0.55, "output": 2.19, "cache_read": 0.14 }
          }
        }
      }
    }
    """
}

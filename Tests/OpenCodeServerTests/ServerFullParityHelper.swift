#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer
import OpenCodeUtil

/// Full-parity test harness and fixture builders (no `import Testing` per macOS CLT cross-import rule).
struct FullParityHarness: Sendable {
    let handle: ServerFetch.Handle
    let client: OpenCodeClient
    let fileSystem: InMemoryFileSystem
    let mockTransport: LiveExecutionMockTransport
    let rootDir: String
    let globalHome: String
    let globalConfig: String
    let globalCache: String

    var runtime: ServerAppRuntime { handle.runtime }

    func resolveBundle(directory: String? = nil) async throws -> ServerLocationBundle {
        let dir = directory ?? rootDir
        return try await runtime.resolveLocation(
            LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: dir))
        )
    }

    func close() async {
        await handle.close()
    }
}

enum FullParityFixture {
    static func makeHarness(
        env: [String: String] = [:],
        configContent: String? = nil,
        initialFiles: [String: [UInt8]] = [:],
        responses: [LiveExecutionMockTransport.ScriptedResponse] = [],
        rootDir: String = "/workspace",
        workerdProfile: Bool = false
    ) async throws -> FullParityHarness {
        let stateBase = "/tmp/opencode-parity-\(OpenCodeUtil.uuid().prefix(8))"
        let homeDir = "\(stateBase)/home"
        let configDir = "\(stateBase)/config"
        let cacheDir = "\(stateBase)/cache"
        let dataDir = "\(stateBase)/data"
        let logDir = "\(stateBase)/log"
        let tmpDir = "\(stateBase)/tmp"

        var files = initialFiles
        if files["\(rootDir)/.keep"] == nil {
            files["\(rootDir)/.keep"] = Array("ok".utf8)
        }
        let fs = InMemoryFileSystem(initialFiles: files)
        try await fs.makeDirectory(at: rootDir, recursive: true)
        try await fs.makeDirectory(at: homeDir, recursive: true)
        try await fs.makeDirectory(at: configDir, recursive: true)
        try await fs.makeDirectory(at: cacheDir, recursive: true)
        try await fs.makeDirectory(at: dataDir, recursive: true)
        try await fs.makeDirectory(at: logDir, recursive: true)
        try await fs.makeDirectory(at: tmpDir, recursive: true)

        let globalOverrides = Global.Overrides(
            home: homeDir,
            data: dataDir,
            cache: cacheDir,
            config: configDir,
            state: "\(stateBase)/state",
            tmp: tmpDir,
            bin: "\(stateBase)/bin",
            log: logDir,
            repos: "\(stateBase)/repos"
        )

        let options = ServerOptions(
            app: ServerOptions.AppOptions(name: "opencode", version: "2.3.2-parity", channel: "local"),
            events: ServerOptions.EventsOptions(persist: true),
            config: ServerOptions.ConfigOptions(
                directory: configDir,
                project: true,
                claude: true,
                content: configContent
            )
        )

        let mockTransport = LiveExecutionMockTransport(responses: responses)
        let handle = try await ServerFetch.make(
            options: options,
            boot: ServerFetch.BootOptions(
                fileSystem: fs,
                httpTransport: mockTransport,
                environment: DictionaryEnvironment(
                    variables: env,
                    homeDirectory: homeDir,
                    temporaryDirectory: tmpDir
                ),
                globalOverrides: globalOverrides,
                defaultDirectory: rootDir,
                workerdProfile: workerdProfile
            )
        )
        let client = OpenCodeClient(options: ClientOptions(
            baseUrl: "http://127.0.0.1:4096",
            transport: handle.transport
        ))
        return FullParityHarness(
            handle: handle,
            client: client,
            fileSystem: fs,
            mockTransport: mockTransport,
            rootDir: rootDir,
            globalHome: homeDir,
            globalConfig: configDir,
            globalCache: cacheDir
        )
    }

    static func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    static func utf8(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    static func decodeJSON(_ bytes: [UInt8]) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(bytes))
    }

    /// Sample models.dev v2 catalog JSON with:
    /// - a net-new provider (`cohere`) with model `command-a`
    /// - an extra non-conflicting model under built-in `anthropic` (`claude-3-7-sonnet-cached`)
    /// - a deliberately stale duplicate of built-in `anthropic/claude-sonnet-4-6` to verify
    ///   higher-priority built-in definitions are never overwritten by the cache
    static let sampleModelsDevV2JSON = """
    {
      "cohere": {
        "id": "cohere",
        "name": "Cohere",
        "env": ["COHERE_API_KEY"],
        "models": {
          "command-a": {
            "id": "command-a",
            "name": "Command A",
            "family": "command",
            "type": "chat",
            "release_date": "2025-03-13",
            "status": "active",
            "limit": { "context": 256000, "output": 8192 },
            "modalities": { "input": ["text"], "output": ["text"] },
            "capabilities": {
              "tools": { "supported": true },
              "temperature": true
            },
            "cost": {
              "text": {
                "input": { "price": 2.5 },
                "output": { "price": 10.0 }
              }
            },
            "api": {
              "chat-completions": {
                "base_url": "https://api.cohere.com/compatibility/v1",
                "sdk": {
                  "opencodeai": "@opencode/ai/providers/openai-compatible"
                }
              }
            }
          }
        }
      },
      "anthropic": {
        "id": "anthropic",
        "name": "Stale Cached Anthropic",
        "env": ["ANTHROPIC_API_KEY"],
        "models": {
          "claude-sonnet-4-6": {
            "id": "claude-sonnet-4-6",
            "name": "Stale Cached Sonnet",
            "family": "claude-sonnet",
            "type": "chat",
            "release_date": "2024-01-01",
            "status": "active",
            "limit": { "context": 1234, "output": 567 },
            "modalities": { "input": ["text"], "output": ["text"] },
            "capabilities": {
              "tools": { "supported": true },
              "temperature": true
            },
            "api": {
              "messages": {
                "sdk": {
                  "opencodeai": "@opencode/ai/providers/anthropic"
                }
              }
            }
          },
          "claude-3-7-sonnet-cached": {
            "id": "claude-3-7-sonnet-cached",
            "name": "Claude 3.7 Sonnet (Cached)",
            "family": "claude-sonnet",
            "type": "chat",
            "release_date": "2025-02-24",
            "status": "active",
            "limit": { "context": 200000, "output": 64000 },
            "modalities": { "input": ["text", "image"], "output": ["text"] },
            "capabilities": {
              "tools": { "supported": true },
              "temperature": true
            },
            "api": {
              "messages": {
                "sdk": {
                  "opencodeai": "@opencode/ai/providers/anthropic"
                }
              }
            }
          }
        }
      }
    }
    """
}

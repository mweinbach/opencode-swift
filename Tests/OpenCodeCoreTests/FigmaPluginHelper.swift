#if canImport(Foundation)
import Foundation
#elseif canImport(FoundationEssentials)
import FoundationEssentials
#endif
import Synchronization
import OpenCodeCore
import OpenCodeSchema
import OpenCodeUtil

/// Foundation-backed helpers for `FigmaPluginTests`.
/// Intentionally does NOT `import Testing` (macOS CLT cross-import overlay rule).
enum FigmaPluginHelper {
    static func bundledSkillsRootPath() -> String? {
        FigmaPlugin.bundledSkillsRootURL()?.path
    }

    static func bundledSkillDirectoryNames() -> [String] {
        FigmaPlugin.bundledSkillDirectories().map(\.lastPathComponent)
    }

    static func bundledSkillDirectoryPaths() -> [String] {
        FigmaPlugin.bundledSkillDirectories().map(\.path)
    }

    static func encodeAndDecode<T: Codable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func inspectMCPServer(
        named name: String,
        in environment: CorePlugin.Host.Environment
    ) async -> McpSchema.ServerConfig? {
        let box = Mutex<McpSchema.ServerConfig?>(nil)
        let ctx = CorePlugin.Host.make(environment: environment, pluginID: "test.figma.inspector")
        _ = await ctx.mcp.transform { editor in
            box.withLock { $0 = editor.get(name) }
        }
        return box.withLock { $0 }
    }

    static func presetMCPServer(
        named name: String,
        config: McpSchema.ServerConfig,
        in environment: CorePlugin.Host.Environment
    ) async {
        let ctx = CorePlugin.Host.make(environment: environment, pluginID: "test.figma.preset")
        _ = await ctx.mcp.transform { editor in
            editor.set(name, config)
        }
    }

    static func presetSkill(
        _ skill: SkillSchema.Info,
        in environment: CorePlugin.Host.Environment
    ) async {
        let ctx = CorePlugin.Host.make(environment: environment, pluginID: "test.figma.preset")
        _ = await ctx.skill.transform { editor in
            editor.add(skill)
        }
    }

    static func inspectMCPConfig(
        named name: String,
        in service: CoreMCP.Registry.Service
    ) async throws -> McpSchema.ServerConfig? {
        let box = Mutex<McpSchema.ServerConfig?>(nil)
        let reg = try await service.transform { editor in
            box.withLock { $0 = editor.get(name) }
        }
        await reg.dispose()
        return box.withLock { $0 }
    }

    static func makeTemporarySkillFixture(
        skillID: String,
        skillMarkdown: String,
        references: [String: String] = [:]
    ) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-figma-test-\(UUID().uuidString)", isDirectory: true)
        let skillDir = root.appendingPathComponent(skillID, isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try skillMarkdown.write(
            to: skillDir.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        for (relPath, content) in references {
            let fileURL = skillDir.appendingPathComponent(relPath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return root.path
    }

    static func removeTemporaryDirectory(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

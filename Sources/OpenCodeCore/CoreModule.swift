import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Entry module for `OpenCodeCore` (port of `packages/core`: durable event-sourced Session runtime,
/// SQLite store & projections, tools, permissions, config, MCP, VCS, snapshots, and plugin host).
public enum OpenCodeCoreModule {
    public static let upstreamPackage = "core"
}

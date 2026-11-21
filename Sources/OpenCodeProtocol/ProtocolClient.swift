import OpenCodeSchema

private let clientLocationMiddleware = MiddlewareDescriptor(
    id: "@opencode/client/LocationMiddleware",
    errors: [ProtocolErrorRef(LocationNotFoundError.self)]
)

private let clientSessionLocationMiddleware = MiddlewareDescriptor(
    id: "@opencode/client/SessionLocationMiddleware",
    errors: [
        ProtocolErrorRef(InvalidRequestError.self),
        ProtocolErrorRef(SessionNotFoundError.self),
        ProtocolErrorRef(LocationNotFoundError.self),
    ]
)

/// Client-side composed HTTP API surface matching `packages/protocol/src/client.ts#ClientApi`.
/// Uses client-side middleware identities for API typing and OpenAPI generation.
// parity: protocol/src/client.ts#ClientApi [status=implemented hash=b6c287dc8f53]
public let ClientApi: ProtocolApi = makeDefaultApi(
    locationMiddleware: clientLocationMiddleware,
    formLocationMiddleware: clientSessionLocationMiddleware,
    sessionLocationMiddleware: clientSessionLocationMiddleware
)

/// Mapping from `HttpApiGroup` identifier (`server.<group>`) to generated SDK client property name.
// parity: protocol/src/client.ts#groupNames [status=implemented hash=a95362fbaf8a]
public let groupNames: [String: String] = [
    "server.server": "server",
    "server.debug": "debug",
    "server.migration": "migration",
    "server.location": "location",
    "server.agent": "agent",
    "server.plugin": "plugin",
    "server.session": "session",
    "server.message": "message",
    "server.model": "model",
    "server.generate": "generate",
    "server.voice": "voice",
    "server.provider": "provider",
    "server.integration": "integration",
    "server.websearch": "websearch",
    "server.usage": "usage",
    "server.credential": "credential",
    "server.form": "form",
    "server.permission": "permission",
    "server.fs": "file",
    "server.command": "command",
    "server.skill": "skill",
    "server.rpc": "rpc",
    "server.event": "event",
    "server.pty": "pty",
    "server.experimental": "experimental",
    "server.shell": "shell",
    "server.mcp": "mcp",
    "server.reference": "reference",
    "server.project": "project",
    "server.worktree": "worktree",
    "server.vcs": "vcs",
    "server.config": "config",
]

/// Experimental routes carry no compatibility promise, so generated clients nest them under
/// `client.experimental` instead of beside stable methods. The URL decides rather than the OpenAPI id.
// parity: protocol/src/client.ts#clientNamespace [status=implemented hash=0a210be22aad]
public func clientNamespace(path: String) -> String? {
    (path == "/api/experimental" || path.hasPrefix("/api/experimental/")) ? "experimental" : nil
}

/// Overload determining the generated client namespace directly from an `EndpointDescriptor`.
public func clientNamespace(_ endpoint: EndpointDescriptor) -> String? {
    clientNamespace(path: endpoint.path)
}

/// Client paths that shipped before experimental methods moved under `client.experimental`.
/// Frozen: endpoints added since never had another path.
// parity: protocol/src/client.ts#deprecatedClientPaths [status=implemented hash=1bdf2175ea67]
public let deprecatedClientPaths: Set<String> = [
    "config.update",
    "file.unwatch",
    "file.watch",
    "file.write",
    "generate.decisions",
    "generate.image",
    "generate.text",
    "integration.wellknown.add",
    "mcp.add",
    "mcp.client.token",
    "mcp.connect",
    "mcp.disconnect",
    "mcp.remove",
    "migration.v1.status",
    "session.export",
    "session.import",
    "session.instructions.entry.list",
    "session.instructions.entry.put",
    "session.instructions.entry.remove",
    "session.log",
    "session.skill",
    "session.stats",
    "session.wait",
    "usage.limits",
    "voice.models",
    "voice.session",
]

/// Endpoints omitted from generated Promise-based clients (WebSocket upgrades and legacy aliases).
// parity: protocol/src/client.ts#promiseOmitEndpoints [status=implemented hash=1ed613cf97bf]
public let promiseOmitEndpoints: Set<String> = [
    "pty.connect",
    "persistentPty.connect",
    "mcp.client",
    "machine.link",
    "generate.textLegacy",
]

/// Endpoints omitted from generated Effect-based clients (raw byte streams, WebSockets, and legacy aliases).
// parity: protocol/src/client.ts#effectOmitEndpoints [status=implemented hash=e15573ca0970]
public let effectOmitEndpoints: Set<String> = [
    "fs.read",
    "fs.write",
    "media.get",
    "blob.get",
    "artifacts.view",
    "pty.connect",
    "persistentPty.connect",
    "mcp.client",
    "machine.link",
    "generate.textLegacy",
]

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Server Route Context & Group Representation

public struct ServerRouteContext: Sendable {
    public let runtime: ServerAppRuntime
    public let request: ServerHTTPRequest
    public let params: [String: String]
    public let wildcard: String?
    public let endpoint: EndpointDescriptor?
    public let location: LocationServices?

    public init(
        runtime: ServerAppRuntime,
        request: ServerHTTPRequest,
        params: [String: String] = [:],
        wildcard: String? = nil,
        endpoint: EndpointDescriptor? = nil,
        location: LocationServices? = nil
    ) {
        self.runtime = runtime
        self.request = request
        self.params = params
        self.wildcard = wildcard
        self.endpoint = endpoint
        self.location = location
    }

    public func requireLocation() throws -> LocationServices {
        guard let location else {
            throw LocationNotFoundError(
                location: OpenCodeLocation(directory: runtime.defaultDirectory),
                message: "Location services unavailable"
            )
        }
        return location
    }

    public func requireParam(_ name: String) throws -> String {
        guard let value = params[name], !value.isEmpty else {
            throw InvalidRequestError(message: "Missing required path parameter: \(name)", kind: "Params", field: name)
        }
        return value
    }

    public func decodeJSONBody<T: Decodable>(_ type: T.Type) throws -> T {
        guard !request.body.isEmpty else {
            throw InvalidRequestError(message: "Missing required JSON request body", kind: "Payload")
        }
        do {
            return try ServerCodec.decode(type, from: request.body)
        } catch {
            throw InvalidRequestError(message: String(describing: error), kind: "Payload")
        }
    }

    public func decodeOptionalJSONBody<T: Decodable>(_ type: T.Type) throws -> T? {
        guard !request.body.isEmpty else { return nil }
        do {
            return try ServerCodec.decode(type, from: request.body)
        } catch {
            throw InvalidRequestError(message: String(describing: error), kind: "Payload")
        }
    }
}

public struct ServerRoute: Sendable {
    public let method: HTTPMethod
    public let pathTemplate: String
    public let endpointName: String
    public let groupIdentifier: String
    public let openAPIIdentifier: String
    public let requiresLocation: Bool
    public let requiresSessionLocation: Bool
    public let requiresFormLocation: Bool
    public let handler: @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse

    public init(
        method: HTTPMethod,
        pathTemplate: String,
        endpointName: String,
        groupIdentifier: String,
        openAPIIdentifier: String? = nil,
        requiresLocation: Bool = false,
        requiresSessionLocation: Bool = false,
        requiresFormLocation: Bool = false,
        handler: @escaping @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse
    ) {
        self.method = method
        self.pathTemplate = pathTemplate
        self.endpointName = endpointName
        self.groupIdentifier = groupIdentifier
        self.openAPIIdentifier = openAPIIdentifier ?? endpointName
        self.requiresLocation = requiresLocation
        self.requiresSessionLocation = requiresSessionLocation
        self.requiresFormLocation = requiresFormLocation
        self.handler = handler
    }
}

public struct ServerHandlerGroup: Sendable {
    public let groupIdentifier: String
    public let routes: [ServerRoute]

    public init(groupIdentifier: String, routes: [ServerRoute]) {
        self.groupIdentifier = groupIdentifier
        self.routes = routes
    }
}

public struct ServerDataWrapper<T: Encodable & Sendable>: Encodable, Sendable {
    public let data: T

    public init(data: T) {
        self.data = data
    }
}

internal func parseBoolQuery(_ value: String?) throws -> Bool? {
    guard let value else { return nil }
    switch value.lowercased() {
    case "true", "1": return true
    case "false", "0": return false
    default: throw InvalidRequestError(message: "Invalid boolean query value: \(value)", kind: "Query")
    }
}

internal func parseIntQuery(_ value: String?, field: String) throws -> Int? {
    guard let value else { return nil }
    guard let parsed = Int(value) else {
        throw InvalidRequestError(message: "Invalid integer query value for \(field): \(value)", kind: "Query", field: field)
    }
    return parsed
}

internal func parseInt64Query(_ value: String?, field: String) throws -> Int64? {
    guard let value else { return nil }
    guard let parsed = Int64(value) else {
        throw InvalidRequestError(message: "Invalid numeric query value for \(field): \(value)", kind: "Query", field: field)
    }
    return parsed
}

internal func parseDoubleQuery(_ value: String?, field: String) throws -> Double? {
    guard let value else { return nil }
    guard let parsed = Double(value), parsed.isFinite else {
        throw InvalidRequestError(message: "Invalid number query value for \(field): \(value)", kind: "Query", field: field)
    }
    return parsed
}

// MARK: - 1. Session Error Helpers (server/src/handlers/session-error.ts)

/// Maps `CoreSessionErrors.NotFoundError` into `SessionNotFoundError` (404).
// parity: server/src/handlers/session-error.ts#missingSession [status=implemented hash=d1bb180b3c1b]
public func missingSession(_ error: CoreSessionErrors.NotFoundError) -> SessionNotFoundError {
    SessionNotFoundError(
        sessionID: error.sessionID.rawValue,
        message: "Session not found: \(error.sessionID.rawValue)"
    )
}

/// Maps `CoreSessionErrors.MessageNotFoundError` into `MessageNotFoundError` (404).
// parity: server/src/handlers/session-error.ts#missingMessage [status=implemented hash=d9906b614e1e]
public func missingMessage(_ error: CoreSessionErrors.MessageNotFoundError) -> MessageNotFoundError {
    MessageNotFoundError(
        sessionID: error.sessionID.rawValue,
        messageID: error.messageID.rawValue,
        message: "Message not found: \(error.messageID.rawValue)"
    )
}

/// Maps `CoreSessionErrors.MessageDecodeError` into `UnknownError` (500) with a log reference.
// parity: server/src/handlers/session-error.ts#failedMessageDecode [status=implemented hash=6ce3ab398a8b]
public func failedMessageDecode(_ error: CoreSessionErrors.MessageDecodeError) -> UnknownError {
    _ = error
    let ref = "err_\(uuid().prefix(8))"
    return UnknownError(
        message: "Unexpected server error. Check server logs for details.",
        ref: ref
    )
}

/// Maps host snapshot repository failures into `UnknownError` (500) carrying only a log reference.
// parity: server/src/handlers/session-error.ts#failedSnapshot [status=implemented hash=7880d5afb2ea]
public func failedSnapshot(
    operation: String,
    sessionID: SessionID
) -> @Sendable (any Error) -> UnknownError {
    _ = (operation, sessionID)
    return { _ in
        let ref = "err_\(uuid().prefix(8))"
        return UnknownError(
            message: "Unexpected server error. Check server logs for details.",
            ref: ref
        )
    }
}

// MARK: - 2. Agent Handler (server/src/handlers/agent.ts)

/// Handlers for `server.agent` (`GET /api/agent`, `GET /api/agent/:agentID`).
/// Never waits for async plugin loading; returns currently registered agents immediately.
// parity: server/src/handlers/agent.ts#AgentHandler [status=implemented hash=28fc7390c06a]
public let AgentHandler = ServerHandlerGroup(
    groupIdentifier: "server.agent",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/agent",
            endpointName: "agent.list",
            groupIdentifier: "server.agent",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let agents = await loc.agent.list()
            return ServerHTTPResponse.json(response(location: loc, data: agents))
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/agent/:agentID",
            endpointName: "agent.get",
            groupIdentifier: "server.agent",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let agentID = try ctx.requireParam("agentID")
            guard let agent = await loc.agent.get(AgentSchema.ID(rawValue: agentID)) else {
                throw AgentNotFoundError(agentID: agentID, message: "Agent not found: \(agentID)")
            }
            return ServerHTTPResponse.json(response(location: loc, data: agent))
        },
    ]
)

// MARK: - 3. Artifact Handler Helpers (server/src/handlers/artifact.ts)

public struct ServerArtifactHandlers: Sendable {
    public let providers: @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse
    public let list: @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse
    public let create: @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse
    public let get: @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse
    public let update: @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse
    public let remove: @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse
    public let view: @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse
}

/// Builds `artifacts.*` route handlers for the `server.experimental` group.
// parity: server/src/handlers/artifact.ts#makeArtifact [status=implemented hash=fada42393a1e]
public let makeArtifact: @Sendable () -> ServerArtifactHandlers = {
    @Sendable func explicitDirectory(request: ServerHTTPRequest) -> String? {
        if let q = request.query("location[directory]"), !q.isEmpty { return q }
        if let h = request.header("x-opencode-directory"), !h.isEmpty {
            return ServerParsedURL.decodeURIComponentStrict(h) ?? h
        }
        return nil
    }

    @Sendable func resolveArtifactLocation(
        ctx: ServerRouteContext,
        sessionID: SessionID? = nil,
        artifactID: ArtifactSchema.ID? = nil
    ) async throws -> LocationServices {
        if let dir = explicitDirectory(request: ctx.request) {
            return try await ctx.runtime.resolveLocation(
                LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: dir))
            )
        }
        if let sessionID {
            do {
                let info = try ctx.runtime.session.get(sessionID)
                return try await ctx.runtime.resolveLocation(
                    LocationSchema.Ref(
                        directory: SchemaPrimitive.AbsolutePath(rawValue: info.location.directory),
                        workspaceID: info.location.workspaceID
                    )
                )
            } catch let err as CoreSessionErrors.NotFoundError {
                throw missingSession(err)
            }
        }
        if let artifactID {
            if let value = try? await ctx.runtime.kv.get("artifact:dir:\(artifactID.rawValue)"),
               case .string(let dir) = value {
                return try await ctx.runtime.resolveLocation(
                    LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: dir))
                )
            }
        }
        let ref = requestRef(ctx.request, defaultDirectory: ctx.runtime.defaultDirectory)
        return try await ctx.runtime.resolveLocation(ref)
    }

    @Sendable func mapArtifactError<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let e as CoreArtifact.DisabledError {
            throw ForbiddenError(message: e.description)
        } catch let e as CoreArtifact.NotFoundError {
            throw ArtifactNotFoundError(artifactID: e.artifactID.rawValue, message: e.description)
        } catch let e as CoreArtifact.ProviderNotFoundError {
            throw ProviderNotFoundError(providerID: e.providerID.rawValue, message: e.description)
        } catch let e as CoreArtifact.InvalidError {
            throw InvalidRequestError(message: e.description, kind: "artifact_invalid", field: e.field)
        } catch let e as CoreArtifact.ProviderError {
            throw ServiceUnavailableError(message: e.description, service: e.providerID.rawValue)
        } catch let e as CoreArtifact.FileMissingError {
            throw FileNotFoundError(path: e.path, message: e.description)
        } catch let e as CoreArtifact.ArtifactError {
            switch e {
            case .disabled(let d): throw ForbiddenError(message: d.description)
            case .notFound(let nf): throw ArtifactNotFoundError(artifactID: nf.artifactID.rawValue, message: nf.description)
            case .fileMissing(let fm): throw FileNotFoundError(path: fm.path, message: fm.description)
            case .providerNotFound(let pnf): throw ProviderNotFoundError(providerID: pnf.providerID.rawValue, message: pnf.description)
            case .invalid(let inv): throw InvalidRequestError(message: inv.description, kind: "artifact_invalid", field: inv.field)
            case .provider(let pe): throw ServiceUnavailableError(message: pe.description, service: pe.providerID.rawValue)
            }
        } catch let e as CoreSessionErrors.NotFoundError {
            throw missingSession(e)
        }
    }

    @Sendable func extractViewSubpath(pathname: String, artifactID: String) -> String? {
        let prefix = "/api/experimental/artifacts/\(ServerParsedURL.encodeURIComponent(artifactID))/view/"
        let rawPrefix = "/api/experimental/artifacts/\(artifactID)/view/"
        let raw: String
        if pathname.hasPrefix(prefix) {
            raw = String(pathname.dropFirst(prefix.count))
        } else if pathname.hasPrefix(rawPrefix) {
            raw = String(pathname.dropFirst(rawPrefix.count))
        } else {
            return nil
        }
        guard !raw.isEmpty else { return nil }
        return ServerParsedURL.decodeURIComponentStrict(raw) ?? raw
    }

    return ServerArtifactHandlers(
        providers: { ctx in
            try await mapArtifactError {
                let loc = try await resolveArtifactLocation(ctx: ctx)
                let list = try await loc.artifact.providers()
                return ServerHTTPResponse.json(response(location: loc, data: list))
            }
        },
        list: { ctx in
            try await mapArtifactError {
                let sessionID: SessionID? = try ctx.request.query("sessionID").map { raw in
                    do { return try SessionID(validating: raw) } catch {
                        throw InvalidRequestError(message: "Invalid session ID", field: "sessionID")
                    }
                }
                let provider = ctx.request.query("provider").flatMap { ArtifactSchema.ProviderID(rawValue: $0) }
                let loc = try await resolveArtifactLocation(ctx: ctx, sessionID: sessionID)
                let items = try await loc.artifact.list(CoreArtifact.ListFilter(sessionID: sessionID, provider: provider))
                return ServerHTTPResponse.json(response(location: loc, data: items))
            }
        },
        create: { ctx in
            try await mapArtifactError {
                let payload = try ctx.decodeJSONBody(ArtifactSchema.CreateInput.self)
                let loc = try await resolveArtifactLocation(ctx: ctx, sessionID: payload.sessionID)
                let created = try await loc.artifact.create(payload)
                try? await ctx.runtime.kv.set("artifact:dir:\(created.id.rawValue)", value: .string(loc.ref.directory.rawValue))
                return ServerHTTPResponse.json(response(location: loc, data: created))
            }
        },
        get: { ctx in
            try await mapArtifactError {
                let rawID = try ctx.requireParam("artifactID")
                guard let artifactID = ArtifactSchema.ID(rawValue: rawID) else {
                    throw InvalidRequestError(message: "Invalid artifact ID: \(rawID)", field: "artifactID")
                }
                let loc = try await resolveArtifactLocation(ctx: ctx, artifactID: artifactID)
                let content = try await loc.artifact.get(artifactID)
                return ServerHTTPResponse.json(response(location: loc, data: content))
            }
        },
        update: { ctx in
            try await mapArtifactError {
                let rawID = try ctx.requireParam("artifactID")
                guard let artifactID = ArtifactSchema.ID(rawValue: rawID) else {
                    throw InvalidRequestError(message: "Invalid artifact ID: \(rawID)", field: "artifactID")
                }
                let payload = try ctx.decodeJSONBody(ArtifactSchema.UpdateInput.self)
                let loc = try await resolveArtifactLocation(ctx: ctx, sessionID: payload.sessionID, artifactID: artifactID)
                let updated = try await loc.artifact.update(artifactID, input: payload)
                return ServerHTTPResponse.json(response(location: loc, data: updated))
            }
        },
        remove: { ctx in
            try await mapArtifactError {
                let rawID = try ctx.requireParam("artifactID")
                guard let artifactID = ArtifactSchema.ID(rawValue: rawID) else {
                    throw InvalidRequestError(message: "Invalid artifact ID: \(rawID)", field: "artifactID")
                }
                let loc = try await resolveArtifactLocation(ctx: ctx, artifactID: artifactID)
                try await loc.artifact.remove(artifactID)
                try? await ctx.runtime.kv.remove("artifact:dir:\(artifactID.rawValue)")
                return ServerHTTPResponse.empty(statusCode: 204)
            }
        },
        view: { ctx in
            try await mapArtifactError {
                let rawID = try ctx.requireParam("artifactID")
                guard let artifactID = ArtifactSchema.ID(rawValue: rawID) else {
                    throw InvalidRequestError(message: "Invalid artifact ID: \(rawID)", field: "artifactID")
                }
                let loc = try await resolveArtifactLocation(ctx: ctx, artifactID: artifactID)
                let encodedPrefix = "/api/experimental/artifacts/\(ServerParsedURL.encodeURIComponent(rawID))/view"
                let plainPrefix = "/api/experimental/artifacts/\(rawID)/view"
                if ctx.request.pathname == encodedPrefix || ctx.request.pathname == plainPrefix {
                    _ = try await loc.artifact.info(artifactID)
                    return ServerHTTPResponse.empty(
                        statusCode: 308,
                        headers: ["location": "\(encodedPrefix)/\(ctx.request.parsedURL.search)"]
                    )
                }
                let subpath = extractViewSubpath(pathname: ctx.request.pathname, artifactID: rawID)
                let file = try await loc.artifact.readLocalFile(artifactID, subpath: subpath)
                return ServerHTTPResponse.bytes(
                    file.bytes,
                    statusCode: 200,
                    contentType: file.mime,
                    headers: [
                        "access-control-allow-origin": "*",
                        "cache-control": "private, no-cache",
                        "content-security-policy": "sandbox allow-scripts",
                        "x-content-type-options": "nosniff",
                    ]
                )
            }
        }
    )
}

// MARK: - 4. Automation Handler Helpers (server/src/handlers/automation.ts)

public struct ServerAutomationHandlers: Sendable {
    public let create: @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse
    public let list: @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse
    public let get: @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse
    public let pause: @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse
    public let resume: @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse
    public let remove: @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse
}

private func isAbsoluteAutomationDirectory(_ dir: String) -> Bool {
    if dir.hasPrefix("/") { return true }
    let chars = Array(dir)
    if chars.count >= 3, chars[0].isLetter, chars[1] == ":", (chars[2] == "\\" || chars[2] == "/") {
        return true
    }
    return false
}

private func checkAutomationEnabled(runtime: ServerAppRuntime, directory: String) async -> Bool {
    let ref = LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: directory))
    do {
        let loc = try await runtime.resolveLocation(ref)
        return await loc.flag.enabled(.automations)
    } catch is LocationNotFoundError {
        return true
    } catch {
        return await runtime.automation.enabled(directory: directory)
    }
}

private func requireAutomationAllowed(runtime: ServerAppRuntime, directory: String) async throws {
    guard await checkAutomationEnabled(runtime: runtime, directory: directory) else {
        throw ForbiddenError(message: CoreAutomation.DisabledError().description)
    }
}

private func findServerAutomation(runtime: ServerAppRuntime, rawID: String) async throws -> AutomationSchema.Info {
    guard let id = AutomationSchema.ID(rawValue: rawID) else {
        throw InvalidRequestError(message: "Invalid automation ID: \(rawID)", field: "automationID")
    }
    let info: AutomationSchema.Info
    do {
        info = try await runtime.automation.get(id)
    } catch let e as CoreAutomation.NotFoundError {
        throw AutomationNotFoundError(automationID: e.automationID.rawValue, message: "Automation not found: \(e.automationID.rawValue)")
    }
    try await requireAutomationAllowed(runtime: runtime, directory: info.directory)
    return info
}

/// Builds `automation.*` route handlers for the `server.experimental` group.
// parity: server/src/handlers/automation.ts#makeAutomation [status=implemented hash=b98bb495269a]
public let makeAutomation: @Sendable () -> ServerAutomationHandlers = {
    ServerAutomationHandlers(
        create: { ctx in
            let payload = try ctx.decodeJSONBody(AutomationSchema.CreateInput.self)
            let directory: String
            let projectID: ProjectID
            if let sessionID = payload.sessionID {
                do {
                    let info = try ctx.runtime.session.get(sessionID)
                    directory = payload.directory ?? info.location.directory
                    projectID = info.projectID
                } catch let e as CoreSessionErrors.NotFoundError {
                    throw missingSession(e)
                }
            } else if let dir = payload.directory {
                guard isAbsoluteAutomationDirectory(dir) else {
                    throw InvalidRequestError(message: "Directory must be an absolute path: \(dir)", kind: "automation")
                }
                directory = dir
                let resolved = try await ctx.runtime.project.resolve(
                    SchemaPrimitive.AbsolutePath(rawValue: dir),
                    options: CoreProject.Project.ResolveOptions(persist: false)
                )
                projectID = resolved.id
            } else {
                directory = ctx.runtime.defaultDirectory
                let resolved = try await ctx.runtime.project.resolve(
                    SchemaPrimitive.AbsolutePath(rawValue: directory),
                    options: CoreProject.Project.ResolveOptions(persist: false)
                )
                projectID = resolved.id
            }
            try await requireAutomationAllowed(runtime: ctx.runtime, directory: directory)
            do {
                let created = try await ctx.runtime.automation.create(
                    payload,
                    projectID: projectID,
                    directory: directory,
                    invocation: nil
                )
                return ServerHTTPResponse.json(ServerDataWrapper(data: created))
            } catch let e as CoreAutomation.InvalidError {
                throw InvalidRequestError(message: e.description, kind: "automation")
            } catch is CoreAutomation.DisabledError {
                throw ForbiddenError(message: CoreAutomation.DisabledError().description)
            } catch let e as CorePermission.BlockedError {
                throw ForbiddenError(message: e.description)
            } catch let e as CorePermission.CorrectedError {
                throw ForbiddenError(message: e.feedback)
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            }
        },
        list: { ctx in
            let sessionID: SessionID? = try ctx.request.query("sessionID").map { raw in
                do { return try SessionID(validating: raw) } catch {
                    throw InvalidRequestError(message: "Invalid session ID", field: "sessionID")
                }
            }
            if let sessionID {
                do {
                    let s = try ctx.runtime.session.get(sessionID)
                    try await requireAutomationAllowed(runtime: ctx.runtime, directory: s.location.directory)
                } catch let e as CoreSessionErrors.NotFoundError {
                    throw missingSession(e)
                }
            }
            let directory = ctx.request.query("directory")
            if let directory {
                guard isAbsoluteAutomationDirectory(directory) else {
                    throw InvalidRequestError(message: "Directory must be an absolute path: \(directory)", kind: "automation")
                }
                try await requireAutomationAllowed(runtime: ctx.runtime, directory: directory)
            }
            let projectID: ProjectID?
            if let directory {
                projectID = try await ctx.runtime.project.resolve(
                    SchemaPrimitive.AbsolutePath(rawValue: directory),
                    options: CoreProject.Project.ResolveOptions(persist: false)
                ).id
            } else {
                projectID = nil
            }
            let rows = try await ctx.runtime.automation.list(CoreAutomation.ListInput(sessionID: sessionID))
            let matching = rows.filter { row in
                directory == nil || row.projectID == projectID || row.directory == directory
            }
            var visibleDirs: Set<String> = []
            for dir in Set(matching.map(\.directory)) {
                if await checkAutomationEnabled(runtime: ctx.runtime, directory: dir) {
                    visibleDirs.insert(dir)
                }
            }
            let filtered = matching.filter { visibleDirs.contains($0.directory) }
            return ServerHTTPResponse.json(ServerDataWrapper(data: filtered))
        },
        get: { ctx in
            let info = try await findServerAutomation(runtime: ctx.runtime, rawID: try ctx.requireParam("automationID"))
            return ServerHTTPResponse.json(ServerDataWrapper(data: info))
        },
        pause: { ctx in
            let info = try await findServerAutomation(runtime: ctx.runtime, rawID: try ctx.requireParam("automationID"))
            do {
                let updated = try await ctx.runtime.automation.pause(info.id)
                return ServerHTTPResponse.json(ServerDataWrapper(data: updated))
            } catch let e as CoreAutomation.NotFoundError {
                throw AutomationNotFoundError(automationID: e.automationID.rawValue, message: "Automation not found: \(e.automationID.rawValue)")
            }
        },
        resume: { ctx in
            let info = try await findServerAutomation(runtime: ctx.runtime, rawID: try ctx.requireParam("automationID"))
            do {
                let updated = try await ctx.runtime.automation.resume(info.id)
                return ServerHTTPResponse.json(ServerDataWrapper(data: updated))
            } catch let e as CoreAutomation.NotFoundError {
                throw AutomationNotFoundError(automationID: e.automationID.rawValue, message: "Automation not found: \(e.automationID.rawValue)")
            }
        },
        remove: { ctx in
            let info = try await findServerAutomation(runtime: ctx.runtime, rawID: try ctx.requireParam("automationID"))
            do {
                try await ctx.runtime.automation.remove(info.id)
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreAutomation.NotFoundError {
                throw AutomationNotFoundError(automationID: e.automationID.rawValue, message: "Automation not found: \(e.automationID.rawValue)")
            }
        }
    )
}

// MARK: - 5. Blob Get Handler (server/src/handlers/blob.ts)

/// Builds `blob.get` raw streaming handler supporting immutable ETag, 304 Not Modified, If-Range, and HTTP Byte Ranges (206/416).
// parity: server/src/handlers/blob.ts#makeBlobGet [status=implemented hash=04451e9b0536]
public let makeBlobGet: @Sendable () -> @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse = {
    { ctx in
        let rawID = try ctx.requireParam("id")
        guard let blobID = BlobStoreSchema.ID(rawValue: rawID) else {
            throw InvalidRequestError(message: "Invalid blob ID: \(rawID)", field: "id")
        }
        let blob: CoreBlobStore.Content
        do {
            blob = try await ctx.runtime.blobStore.read(blobID)
        } catch let e as CoreBlobStore.NotFoundError {
            throw BlobNotFoundError(blobID: e.id, message: e.description)
        } catch let e as CoreBlobStore.UnavailableError {
            throw BlobNotFoundError(blobID: rawID, message: e.description)
        }

        let etag = "\"\(rawID)\""
        var headers = ContentHeaders.download(mime: blob.mime)
        headers["cache-control"] = "private, max-age=31536000, immutable"
        headers["etag"] = etag
        headers["accept-ranges"] = "bytes"

        if matchesIfNoneMatch(ctx.request.header("if-none-match"), etag: etag) {
            return ServerHTTPResponse.empty(statusCode: 304, headers: headers)
        }

        let totalSize = Int(blob.bytes)
        let ifRange = ctx.request.header("if-range")
        let rangeResult: ByteRange.ParseResult? = (ifRange == nil || ifRange?.trimmingCharacters(in: .whitespaces) == etag)
            ? ByteRange.parse(ctx.request.header("range"), size: totalSize)
            : nil

        if case .unsatisfiable = rangeResult {
            var errHeaders = headers
            errHeaders["content-range"] = "bytes */\(totalSize)"
            return ServerHTTPResponse.empty(statusCode: 416, headers: errHeaders)
        }

        let allBytes = try await ctx.runtime.fileSystem.readFile(at: blob.path)
        let sliceBytes: [UInt8]
        let statusCode: Int
        if case .range(let slice) = rangeResult {
            let safeStart = min(slice.start, allBytes.count)
            let safeEnd = min(slice.end + 1, allBytes.count)
            sliceBytes = safeStart < safeEnd ? Array(allBytes[safeStart..<safeEnd]) : []
            headers["content-range"] = "bytes \(slice.start)-\(slice.end)/\(totalSize)"
            statusCode = 206
        } else {
            sliceBytes = allBytes
            statusCode = 200
        }
        return ServerHTTPResponse.bytes(
            sliceBytes,
            statusCode: statusCode,
            contentType: headers["content-type"] ?? blob.mime,
            headers: headers
        )
    }
}

private func matchesIfNoneMatch(_ header: String?, etag: String) -> Bool {
    guard let header else { return false }
    let strippedTarget = stripWeakETag(etag)
    return header.split(separator: ",").contains { rawTag in
        let trimmed = rawTag.trimmingCharacters(in: .whitespaces)
        return trimmed == "*" || stripWeakETag(trimmed) == strippedTarget
    }
}

private func stripWeakETag(_ tag: String) -> String {
    let trimmed = tag.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("W/") || trimmed.hasPrefix("w/") {
        return String(trimmed.dropFirst(2))
    }
    return trimmed
}

// MARK: - 6. Command Handler (server/src/handlers/command.ts)

/// Handlers for `server.command` (`GET /api/command`).
// parity: server/src/handlers/command.ts#CommandHandler [status=implemented hash=e3711193a9b6]
public let CommandHandler = ServerHandlerGroup(
    groupIdentifier: "server.command",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/command",
            endpointName: "command.list",
            groupIdentifier: "server.command",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let commands = await loc.command.list()
            return ServerHTTPResponse.json(response(location: loc, data: commands))
        },
    ]
)

// MARK: - 7. Config Handler (server/src/handlers/config.ts)

/// Handlers for `server.config` (`GET /api/config`, `GET /api/config/shell`, `PATCH /api/experimental/config`).
// parity: server/src/handlers/config.ts#ConfigHandler [status=implemented hash=af6ef459d786]
public let ConfigHandler = ServerHandlerGroup(
    groupIdentifier: "server.config",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/config",
            endpointName: "config.get",
            groupIdentifier: "server.config",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let entries = await loc.config.entries().map(\.schemaEntry)
            return ServerHTTPResponse.json(entries)
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/config/shell",
            endpointName: "config.shells",
            groupIdentifier: "server.config",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let shells = await loc.shellSelect.list().map {
                ConfigShellSchema.Option(path: $0.path, name: $0.name, acceptable: $0.acceptable)
            }
            return ServerHTTPResponse.json(shells)
        },
        ServerRoute(
            method: .patch,
            pathTemplate: "/api/experimental/config",
            endpointName: "config.update",
            groupIdentifier: "server.config",
            openAPIIdentifier: "experimental.config.update",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let patch = try ctx.decodeJSONBody(ConfigSchema.Patch.self)
            try await loc.config.update(patch)
            return ServerHTTPResponse.empty(statusCode: 204)
        },
    ]
)

// MARK: - 8. Credential Handler (server/src/handlers/credential.ts)

/// Handlers for `server.credential` (CRUD + activation + managed policy check against global config location).
// parity: server/src/handlers/credential.ts#CredentialHandler [status=implemented hash=b59e19ef6d14]
public let CredentialHandler = ServerHandlerGroup(
    groupIdentifier: "server.credential",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/credential",
            endpointName: "credential.list",
            groupIdentifier: "server.credential"
        ) { ctx in
            let all = try await ctx.runtime.credential.all()
            return ServerHTTPResponse.json(ServerDataWrapper(data: formatCredentialEntries(all)))
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/credential",
            endpointName: "credential.create",
            groupIdentifier: "server.credential"
        ) { ctx in
            let payload = try ctx.decodeJSONBody(CredentialSchema.CreateInput.self)
            let globalRef = LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: ctx.runtime.global.config))
            if let globalLoc = try? await ctx.runtime.resolveLocation(globalRef) {
                try await requireConnectable(payload.integrationID, globalLoc)
            }
            if let requestedID = payload.id, try await ctx.runtime.credential.get(requestedID) != nil {
                throw ConflictError(
                    message: "Credential already exists: \(requestedID.rawValue)",
                    resource: requestedID.rawValue
                )
            }
            let created = try await ctx.runtime.credential.create(
                id: payload.id,
                integrationID: payload.integrationID,
                value: payload.value,
                label: payload.label,
                activate: payload.activate ?? true
            )
            let list = try await ctx.runtime.credential.list(created.integrationID)
            let formatted = formatCredentialEntries(list)
            let entry = formatted.first(where: { $0.id == created.id })
                ?? CredentialSchema.Entry(
                    id: created.id,
                    integrationID: created.integrationID,
                    label: created.label,
                    active: false,
                    value: created.value
                )
            await emitIntegrationCatalogUpdated(ctx.runtime.bus)
            return ServerHTTPResponse.json(ServerDataWrapper(data: entry))
        },
        ServerRoute(
            method: .patch,
            pathTemplate: "/api/credential/:credentialID",
            endpointName: "credential.update",
            groupIdentifier: "server.credential"
        ) { ctx in
            struct UpdatePayload: Decodable { let label: String }
            let rawID = try ctx.requireParam("credentialID")
            let id = CredentialSchema.ID(rawValue: rawID)
            let payload = try ctx.decodeJSONBody(UpdatePayload.self)
            try await ctx.runtime.credential.update(id, label: payload.label, value: nil)
            await emitIntegrationCatalogUpdated(ctx.runtime.bus)
            return ServerHTTPResponse.empty(statusCode: 204)
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/credential/:credentialID/activate",
            endpointName: "credential.activate",
            groupIdentifier: "server.credential"
        ) { ctx in
            let rawID = try ctx.requireParam("credentialID")
            let id = CredentialSchema.ID(rawValue: rawID)
            try await ctx.runtime.credential.activate(id)
            await emitIntegrationCatalogUpdated(ctx.runtime.bus)
            return ServerHTTPResponse.empty(statusCode: 204)
        },
        ServerRoute(
            method: .delete,
            pathTemplate: "/api/credential/:credentialID",
            endpointName: "credential.remove",
            groupIdentifier: "server.credential"
        ) { ctx in
            let rawID = try ctx.requireParam("credentialID")
            let id = CredentialSchema.ID(rawValue: rawID)
            try await ctx.runtime.credential.remove(id)
            await emitIntegrationCatalogUpdated(ctx.runtime.bus)
            return ServerHTTPResponse.empty(statusCode: 204)
        },
    ]
)

private func emitIntegrationCatalogUpdated(_ bus: CoreBus.Service) async {
    let empty = JSONValue.object([:])
    await bus.emit(EventSchema.EphemeralDefinition<JSONValue>(type: "integration.updated"), data: empty)
    await bus.emit(EventSchema.EphemeralDefinition<JSONValue>(type: "provider.updated"), data: empty)
    await bus.emit(EventSchema.EphemeralDefinition<JSONValue>(type: "model.updated"), data: empty)
}

private func formatCredentialEntries(_ credentials: [CoreProvider.Credential.Info]) -> [CredentialSchema.Entry] {
    var selected: [IntegrationID: CredentialSchema.ID] = [:]
    for item in credentials {
        selected[item.integrationID] = item.id
    }
    return credentials.map { item in
        CredentialSchema.Entry(
            id: item.id,
            integrationID: item.integrationID,
            label: item.label,
            active: selected[item.integrationID] == item.id,
            value: item.value
        )
    }
}

// MARK: - 9. Debug Handler (server/src/handlers/debug.ts)

/// Handlers for `server.debug` (`POST /api/debug/heap-dump`, `GET /api/debug/location`, `DELETE /api/debug/location`).
// parity: server/src/handlers/debug.ts#DebugHandler [status=implemented hash=7433c3f7acf0]
public let DebugHandler = ServerHandlerGroup(
    groupIdentifier: "server.debug",
    routes: [
        ServerRoute(
            method: .post,
            pathTemplate: "/api/debug/heap-dump",
            endpointName: "debug.heapDump",
            groupIdentifier: "server.debug"
        ) { ctx in
            let directory = ctx.request.query("directory")
            if let directory, !directory.hasPrefix("/") {
                throw InvalidRequestError(message: "directory must be an absolute path", field: "directory")
            }
            do {
                let result = try await HeapSnapshot.write(
                    directory: directory ?? ctx.runtime.global.log,
                    fileSystem: ctx.runtime.fileSystem
                )
                return ServerHTTPResponse.json(result)
            } catch {
                let ref = "err_\(uuid().prefix(8))"
                throw UnknownError(
                    message: "Failed to write heap snapshot: \(String(describing: error))",
                    ref: ref
                )
            }
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/debug/location",
            endpointName: "debug.location",
            groupIdentifier: "server.debug",
            openAPIIdentifier: "debug.location.list"
        ) { ctx in
            let refs = ctx.runtime.locations.keys().map {
                LocationSchema.PublicRef(directory: $0.directory)
            }
            return ServerHTTPResponse.json(refs)
        },
        ServerRoute(
            method: .delete,
            pathTemplate: "/api/debug/location",
            endpointName: "debug.location.evict",
            groupIdentifier: "server.debug"
        ) { ctx in
            let ref = requestRef(ctx.request, defaultDirectory: ctx.runtime.defaultDirectory)
            await ctx.runtime.locations.invalidate(ref)
            return ServerHTTPResponse.empty(statusCode: 204)
        },
    ]
)

// MARK: - 10. Event Handler (server/src/handlers/event.ts)

/// Handlers for `server.event` (`GET /api/event` live SSE stream).
// parity: server/src/handlers/event.ts#EventHandler [status=implemented hash=8214489d3b96]
public let EventHandler = ServerHandlerGroup(
    groupIdentifier: "server.event",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/event",
            endpointName: "event.subscribe",
            groupIdentifier: "server.event"
        ) { ctx in
            let rawTypes = ctx.request.queryAll("types")
            let types: [String]? = rawTypes.isEmpty ? nil : rawTypes.flatMap {
                $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            return ServerSSEStream.makeResponse(feed: ctx.runtime.eventFeed, types: types)
        },
    ]
)

// MARK: - 11. Form Handler (server/src/handlers/form.ts)

/// Handlers for `server.form` (`GET /api/form`).
// parity: server/src/handlers/form.ts#FormHandler [status=implemented hash=574cff14f559]
public let FormHandler = ServerHandlerGroup(
    groupIdentifier: "server.form",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/form",
            endpointName: "form.list",
            groupIdentifier: "server.form",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let forms = await loc.form.list(nil)
            return ServerHTTPResponse.json(response(location: loc, data: forms))
        },
    ]
)

// MARK: - 12. FileSystem Handler (server/src/handlers/fs.ts)

/// Handlers for `server.fs` (read with ETag/Last-Modified/Range/304/206/416, list, find, write, watch, unwatch).
// parity: server/src/handlers/fs.ts#FileSystemHandler [status=implemented hash=9f20af3e4ef2]
public let FileSystemHandler = ServerHandlerGroup(
    groupIdentifier: "server.fs",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/fs/read/*",
            endpointName: "fs.read",
            groupIdentifier: "server.fs",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let prefix = "/api/fs/read/"
            let rawSegment = ctx.request.pathname.hasPrefix(prefix)
                ? String(ctx.request.pathname.dropFirst(prefix.count))
                : (ctx.wildcard ?? "")
            guard let decoded = ServerParsedURL.decodeURIComponentStrict(rawSegment) else {
                throw FileNotFoundError(path: rawSegment, message: "File not found: \(rawSegment)")
            }
            let relPath = SchemaPrimitive.RelativePath(rawValue: decoded)
            let file: CoreFilesystem.File
            do {
                file = try await loc.fileSystem.read(CoreFilesystem.ReadInput(path: relPath))
            } catch let e as CoreFilesystem.NotFoundError {
                throw FileNotFoundError(path: e.path.rawValue, message: "File not found: \(e.path.rawValue)")
            } catch let e as PlatformError {
                if case .notFound(let p) = e {
                    throw FileNotFoundError(path: p, message: "File not found: \(p)")
                }
                throw e
            }
            return try await serveFilesystemFile(
                request: ctx.request,
                file: file,
                contentHeaders: ContentHeaders.download(path: decoded, mime: file.mime)
            )
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/fs/list",
            endpointName: "fs.list",
            groupIdentifier: "server.fs",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let pathParam = ctx.request.query("path")
            do {
                let entries = try await loc.fileSystem.list(CoreFilesystem.ListInput(path: pathParam))
                return ServerHTTPResponse.json(response(location: loc, data: entries))
            } catch let e as CoreFilesystem.NotFoundError {
                throw FileNotFoundError(path: e.path.rawValue, message: "Directory not found: \(e.path.rawValue)")
            }
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/fs/find",
            endpointName: "fs.find",
            groupIdentifier: "server.fs",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            guard let query = ctx.request.query("query") else {
                throw InvalidRequestError(message: "Missing required query parameter: query", kind: "Query", field: "query")
            }
            let entryType: FileSystemSchema.EntryType? = try ctx.request.query("type").map { raw in
                guard let parsed = FileSystemSchema.EntryType(rawValue: raw) else {
                    throw InvalidRequestError(message: "Invalid entry type: \(raw)", kind: "Query", field: "type")
                }
                return parsed
            }
            let limitInt = try parseIntQuery(ctx.request.query("limit"), field: "limit")
            let limit: SchemaPrimitive.PositiveInt? = try limitInt.map { n in
                guard let pos = SchemaPrimitive.PositiveInt(rawValue: n) else {
                    throw InvalidRequestError(message: "limit must be positive", kind: "Query", field: "limit")
                }
                return pos
            }
            let found = await loc.fileSystem.find(FileSystemSchema.FindInput(query: query, type: entryType, limit: limit))
            return ServerHTTPResponse.json(response(location: loc, data: found))
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/experimental/fs/write",
            endpointName: "fs.write",
            groupIdentifier: "server.fs",
            openAPIIdentifier: "experimental.fs.write",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            guard let targetPath = ctx.request.query("path"), !targetPath.isEmpty else {
                throw InvalidRequestError(message: "Missing required query parameter: path", kind: "Query", field: "path")
            }
            let written = try await loc.fileSystem.write(
                CoreFilesystem.WriteInput(path: targetPath, data: ctx.request.body)
            )
            return ServerHTTPResponse.json(response(location: loc, data: written))
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/experimental/fs/watch",
            endpointName: "fs.watch",
            groupIdentifier: "server.fs",
            openAPIIdentifier: "experimental.fs.watch",
            requiresLocation: true
        ) { ctx in
            struct WatchPayload: Decodable { let path: String }
            let loc = try ctx.requireLocation()
            let payload = try ctx.decodeJSONBody(WatchPayload.self)
            do {
                _ = try await loc.fileSystem.read(CoreFilesystem.ReadInput(path: SchemaPrimitive.RelativePath(rawValue: payload.path)))
            } catch let e as CoreFilesystem.NotFoundError {
                throw FileNotFoundError(path: e.path.rawValue, message: "File not found: \(e.path.rawValue)")
            }
            let resolvedFile = serverResolvePath(base: loc.ref.directory.rawValue, relative: payload.path)
            do {
                try await ctx.runtime.fileWatch.watch(
                    CoreFilesystem.FileWatch.Input(
                        location: loc.ref,
                        file: resolvedFile
                    )
                )
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreFilesystem.FileWatch.DisabledError {
                throw ServiceUnavailableError(message: e.description, service: "filewatcher")
            }
        },
        ServerRoute(
            method: .delete,
            pathTemplate: "/api/experimental/fs/watch",
            endpointName: "fs.unwatch",
            groupIdentifier: "server.fs",
            openAPIIdentifier: "experimental.fs.unwatch",
            requiresLocation: true
        ) { ctx in
            struct WatchPayload: Decodable { let path: String }
            let loc = try ctx.requireLocation()
            let payload = try ctx.decodeJSONBody(WatchPayload.self)
            let resolvedFile = serverResolvePath(base: loc.ref.directory.rawValue, relative: payload.path)
            await ctx.runtime.fileWatch.unwatch(
                CoreFilesystem.FileWatch.Input(
                    location: loc.ref,
                    file: resolvedFile
                )
            )
            return ServerHTTPResponse.empty(statusCode: 204)
        },
    ]
)

private func serveFilesystemFile(
    request: ServerHTTPRequest,
    file: CoreFilesystem.File,
    contentHeaders: [String: String]
) async throws -> ServerHTTPResponse {
    let mtimeHex = file.modifiedAtMs.map { String($0, radix: 16) } ?? "0"
    let etag = "W/\"\(String(file.size, radix: 16))-\(mtimeHex)\""
    let lastModified = file.modifiedAtMs.map { ServerHTTPDate.formatUTCString(epochMs: $0) }

    var validators: [String: String] = [
        "cache-control": "no-cache, no-transform",
        "etag": etag,
    ]
    if let lastModified {
        validators["last-modified"] = lastModified
    }

    if isFileNotModified(request: request, etag: etag, lastModified: lastModified) {
        return ServerHTTPResponse.empty(
            statusCode: 304,
            headers: ServerHeaders.merge(validators, contentHeaders)
        )
    }

    let size = Int(file.size)
    let rangeHeader = request.method == "GET" ? request.header("range") : nil
    let range: ByteRange.ParseResult?
    if let rangeHeader, matchesFileIfRange(request.header("if-range"), etag: etag, lastModified: lastModified) {
        range = ByteRange.parse(rangeHeader, size: size)
    } else {
        range = nil
    }

    if case .unsatisfiable = range {
        return ServerHTTPResponse.empty(
            statusCode: 416,
            headers: [
                "accept-ranges": "bytes",
                "content-range": "bytes */\(size)",
            ]
        )
    }

    let offset: Int
    let length: Int
    var headers = ServerHeaders.merge(validators, contentHeaders)
    headers["accept-ranges"] = "bytes"
    let statusCode: Int
    if case .range(let slice) = range {
        offset = slice.start
        length = slice.end - slice.start + 1
        headers["content-range"] = "bytes \(slice.start)-\(slice.end)/\(size)"
        statusCode = 206
    } else {
        offset = 0
        length = size
        statusCode = 200
    }

    let bytes = length == 0 ? [] : try await file.readRange(offset, length)
    return ServerHTTPResponse.bytes(
        bytes,
        statusCode: statusCode,
        contentType: headers["content-type"] ?? file.mime,
        headers: headers
    )
}

private func isFileNotModified(request: ServerHTTPRequest, etag: String, lastModified: String?) -> Bool {
    if let ifNoneMatch = request.header("if-none-match") {
        return matchesIfNoneMatch(ifNoneMatch, etag: etag)
    }
    if let ifModifiedSince = request.header("if-modified-since"),
       let lastModified,
       let modMs = ServerHTTPDate.parseUTCString(lastModified),
       let sinceMs = ServerHTTPDate.parseUTCString(ifModifiedSince) {
        return modMs <= sinceMs
    }
    return false
}

private func matchesFileIfRange(_ ifRange: String?, etag: String, lastModified: String?) -> Bool {
    guard let ifRange else { return true }
    let trimmed = ifRange.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("\"") || trimmed.hasPrefix("W/\"") || trimmed.hasPrefix("w/\"") {
        return stripWeakETag(trimmed) == stripWeakETag(etag)
    }
    if let lastModified,
       let ifRangeMs = ServerHTTPDate.parseUTCString(trimmed),
       let modMs = ServerHTTPDate.parseUTCString(lastModified) {
        return ifRangeMs == modMs
    }
    return false
}

// MARK: - 13. Generate Handler (server/src/handlers/generate.ts)

/// Handlers for `server.generate` (`text`, `textLegacy`, `image`, `decisions`, `video.create`, `video.get`).
// parity: server/src/handlers/generate.ts#GenerateHandler [status=implemented hash=1a0df1289629]
public let GenerateHandler = ServerHandlerGroup(
    groupIdentifier: "server.generate",
    routes: [
        ServerRoute(
            method: .post,
            pathTemplate: "/api/experimental/generate/text",
            endpointName: "generate.text",
            groupIdentifier: "server.generate",
            openAPIIdentifier: "experimental.generate.text"
        ) { ctx in
            try await handleGenerateText(ctx)
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/experimental/generate",
            endpointName: "generate.textLegacy",
            groupIdentifier: "server.generate",
            openAPIIdentifier: "experimental.generate.textLegacy"
        ) { ctx in
            try await handleGenerateText(ctx)
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/experimental/generate/image",
            endpointName: "generate.image",
            groupIdentifier: "server.generate",
            openAPIIdentifier: "experimental.generate.image"
        ) { ctx in
            let payload = try ctx.decodeJSONBody(GenerateSchema.ImageRequest.self)
            let loc = try await resolveGenerateBaseLocation(ctx.runtime)
            let result = try await mapGenerateError { try await loc.generate.image(payload) }
            return ServerHTTPResponse.json(ServerDataWrapper(data: result))
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/experimental/generate/decisions",
            endpointName: "generate.decisions",
            groupIdentifier: "server.generate",
            openAPIIdentifier: "experimental.generate.decisions"
        ) { ctx in
            let payload = try ctx.decodeJSONBody(GenerateSchema.DecisionRequest.self)
            let names = Set(payload.questions.map { question -> String in
                switch question {
                case .predicate(let q): return q.name
                case .choice(let q): return q.name
                case .score(let q): return q.name
                }
            })
            if names.count != payload.questions.count {
                throw InvalidRequestError(message: "Decision question names must be unique", field: "questions")
            }
            let loc = try await resolveGenerateBaseLocation(ctx.runtime)
            let result = try await mapGenerateError { try await loc.generate.decisions(payload) }
            return ServerHTTPResponse.json(ServerDataWrapper(data: result))
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/experimental/generate/video",
            endpointName: "generate.video.create",
            groupIdentifier: "server.generate",
            openAPIIdentifier: "experimental.generate.video.create"
        ) { ctx in
            let payload = try ctx.decodeJSONBody(GenerateSchema.VideoRequest.self)
            let loc = try await resolveGenerateBaseLocation(ctx.runtime)
            guard await loc.flag.enabled(.videoGenerate) else {
                throw ForbiddenError(message: "Video generation is disabled; enable experimental.video_generate")
            }
            let started = try await mapGenerateError {
                try await ctx.runtime.videoGeneration.start(payload, options: nil)
            }
            return ServerHTTPResponse.json(ServerDataWrapper(data: started))
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/experimental/generate/video/:id",
            endpointName: "generate.video.get",
            groupIdentifier: "server.generate",
            openAPIIdentifier: "experimental.generate.video.get"
        ) { ctx in
            let rawID = try ctx.requireParam("id")
            guard let videoID = GenerateSchema.VideoID(rawValue: rawID) else {
                throw InvalidRequestError(message: "Invalid video ID: \(rawID)", field: "id")
            }
            let loc = try await resolveGenerateBaseLocation(ctx.runtime)
            guard await loc.flag.enabled(.videoGenerate) else {
                throw ForbiddenError(message: "Video generation is disabled; enable experimental.video_generate")
            }
            do {
                let job = try await ctx.runtime.videoGeneration.get(videoID)
                return ServerHTTPResponse.json(ServerDataWrapper(data: job))
            } catch let e as CoreIntegration.VideoGeneration.NotFoundError {
                throw VideoNotFoundError(videoID: e.id, message: e.description)
            }
        },
    ]
)

private func resolveGenerateBaseLocation(_ runtime: ServerAppRuntime) async throws -> LocationServices {
    let ref = LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: runtime.global.config))
    if await runtime.fileSystem.exists(at: runtime.global.config) {
        return try await runtime.resolveLocation(ref)
    }
    return try await runtime.resolveLocation(
        LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: runtime.defaultDirectory))
    )
}

private func handleGenerateText(_ ctx: ServerRouteContext) async throws -> ServerHTTPResponse {
    struct TextPayload: Decodable {
        let prompt: String
        let model: ModelSchema.Ref?
    }
    struct TextData: Encodable {
        let text: String
    }
    let payload = try ctx.decodeJSONBody(TextPayload.self)
    let loc = try await resolveGenerateBaseLocation(ctx.runtime)
    let text = try await mapGenerateError {
        try await loc.generate.text(CoreIntegration.Generate.TextInput(prompt: payload.prompt, model: payload.model))
    }
    return ServerHTTPResponse.json(ServerDataWrapper(data: TextData(text: text)))
}

private func mapGenerateError<T>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch let e as CoreIntegration.Generate.ModelNotFoundError {
        throw ModelNotFoundError(providerID: e.providerID, modelID: e.modelID, message: e.message)
    } catch let e as CoreIntegration.Generate.UnsupportedModelError {
        throw UnsupportedModelError(providerID: e.providerID, modelID: e.modelID, capability: e.capability, message: e.message)
    } catch let e as CoreIntegration.Generate.InvalidRequestError {
        throw InvalidRequestError(message: e.message, field: e.field)
    } catch let e as CoreIntegration.Generate.ProviderRequestError {
        let reason = ProviderRequestErrorReason(rawValue: e.reason.rawValue) ?? .provider
        throw ProviderRequestError(providerID: e.providerID, reason: reason, message: e.message, status: e.status, retryAfterMs: e.retryAfterMs)
    } catch let e as CoreIntegration.Generate.UnavailableError {
        throw ServiceUnavailableError(message: e.message, service: e.service)
    } catch let e as CoreIntegration.Generate.GenerateError {
        switch e {
        case .modelNotFound(let m):
            throw ModelNotFoundError(providerID: m.providerID, modelID: m.modelID, message: m.message)
        case .unsupportedModel(let u):
            throw UnsupportedModelError(providerID: u.providerID, modelID: u.modelID, capability: u.capability, message: u.message)
        case .invalidRequest(let i):
            throw InvalidRequestError(message: i.message, field: i.field)
        case .providerRequest(let p):
            let reason = ProviderRequestErrorReason(rawValue: p.reason.rawValue) ?? .provider
            throw ProviderRequestError(providerID: p.providerID, reason: reason, message: p.message, status: p.status, retryAfterMs: p.retryAfterMs)
        case .unavailable(let u):
            throw ServiceUnavailableError(message: u.message, service: u.service)
        }
    }
}

// MARK: - 14. Integration Handler (server/src/handlers/integration.ts)

private func isMcpIntegration(_ info: IntegrationSchema.Info?) -> Bool {
    guard let meta = info?.metadata, case .string(let src) = meta["source"] else { return false }
    return src == "mcp"
}

/// Checks `integration.connect` managed policy for `integrationID` (MCP OAuth integrations bypass integration policy).
// parity: server/src/handlers/integration.ts#requireConnectable [status=implemented hash=baf4dc27649c]
public let requireConnectable: @Sendable (IntegrationID, LocationServices) async throws -> Void = { integrationID, location in
    if isMcpIntegration(try await location.integration.get(integrationID)) {
        return
    }
    let entries = await location.config.entries()
    let statements = CoreManagedPolicy.statements(entries)
    if let denied = CoreManagedPolicy.match(statements, action: .integrationConnect, resource: integrationID.rawValue),
       denied.effect == .deny {
        throw InvalidRequestError(
            message: "\(denied.message): connecting \(integrationID.rawValue) is not allowed",
            kind: "integration_policy"
        )
    }
}

/// Handlers for `server.integration` (list, get, wellknown.add, connect.key, connect.external, oauth.*, command.*).
// parity: server/src/handlers/integration.ts#IntegrationHandler [status=implemented hash=f8b999017d78]
public let IntegrationHandler = ServerHandlerGroup(
    groupIdentifier: "server.integration",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/integration",
            endpointName: "integration.list",
            groupIdentifier: "server.integration",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let entries = await loc.config.entries()
            let statements = CoreManagedPolicy.statements(entries)
            let policyInfos = statements.map(\.policyInfo)
            let all = try await loc.integration.list()
            let filtered = all.filter { item in
                isMcpIntegration(item)
                    || CoreManagedPolicy.decision(policyInfos, action: .integrationConnect, resource: item.id.rawValue) != .deny
            }
            return ServerHTTPResponse.json(response(location: loc, data: filtered))
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/integration/:integrationID",
            endpointName: "integration.get",
            groupIdentifier: "server.integration",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let rawID = try ctx.requireParam("integrationID")
            guard let item = try await loc.integration.get(IntegrationID(rawValue: rawID)) else {
                throw IntegrationNotFoundError(integrationID: rawID, message: "Integration not found: \(rawID)")
            }
            return ServerHTTPResponse.json(response(location: loc, data: item))
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/experimental/integration/wellknown",
            endpointName: "integration.wellknown.add",
            groupIdentifier: "server.integration",
            openAPIIdentifier: "experimental.integration.wellknown.add",
            requiresLocation: true
        ) { ctx in
            struct WellKnownPayload: Decodable { let url: String }
            let loc = try ctx.requireLocation()
            let payload = try ctx.decodeJSONBody(WellKnownPayload.self)
            var origin = payload.url
            while origin.hasSuffix("/") { origin.removeLast() }
            try await requireConnectable(IntegrationID(rawValue: origin), loc)
            do {
                _ = try await ctx.runtime.wellKnown.add(origin: payload.url)
            } catch {
                throw InvalidRequestError(message: String(describing: error), kind: "well_known_discovery")
            }
            await loc.integration.reload()
            return ServerHTTPResponse.empty(statusCode: 204)
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/integration/:integrationID/connect/key",
            endpointName: "integration.connect.key",
            groupIdentifier: "server.integration",
            requiresLocation: true
        ) { ctx in
            struct KeyPayload: Decodable {
                let key: String
                let answer: FormSchema.Answer?
                let label: String?
            }
            let loc = try ctx.requireLocation()
            let rawID = try ctx.requireParam("integrationID")
            let integrationID = IntegrationID(rawValue: rawID)
            try await requireConnectable(integrationID, loc)
            guard try await loc.integration.get(integrationID) != nil else {
                throw IntegrationNotFoundError(integrationID: rawID, message: "Integration not found: \(rawID)")
            }
            let payload = try ctx.decodeJSONBody(KeyPayload.self)
            do {
                try await loc.integration.connectKey(
                    integrationID: integrationID,
                    key: payload.key,
                    answer: payload.answer,
                    label: payload.label
                )
            } catch {
                throw InvalidRequestError(message: String(describing: error), kind: "integration_authorization")
            }
            await emitIntegrationCatalogUpdated(ctx.runtime.bus)
            return ServerHTTPResponse.empty(statusCode: 204)
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/integration/:integrationID/connect/external",
            endpointName: "integration.connect.external",
            groupIdentifier: "server.integration",
            requiresLocation: true
        ) { ctx in
            struct ExternalPayload: Decodable {
                let methodID: IntegrationSchema.MethodID
                let answer: FormSchema.Answer?
                let label: String?
            }
            let loc = try ctx.requireLocation()
            let rawID = try ctx.requireParam("integrationID")
            let integrationID = IntegrationID(rawValue: rawID)
            try await requireConnectable(integrationID, loc)
            guard try await loc.integration.get(integrationID) != nil else {
                throw IntegrationNotFoundError(integrationID: rawID, message: "Integration not found: \(rawID)")
            }
            let payload = try ctx.decodeJSONBody(ExternalPayload.self)
            do {
                try await loc.integration.connectExternal(
                    integrationID: integrationID,
                    methodID: payload.methodID,
                    answer: payload.answer,
                    label: payload.label
                )
            } catch {
                throw InvalidRequestError(message: String(describing: error), kind: "integration_authorization")
            }
            await emitIntegrationCatalogUpdated(ctx.runtime.bus)
            return ServerHTTPResponse.empty(statusCode: 204)
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/integration/:integrationID/connect/oauth",
            endpointName: "integration.oauth.connect",
            groupIdentifier: "server.integration",
            requiresLocation: true
        ) { ctx in
            struct OAuthPayload: Decodable {
                let methodID: IntegrationSchema.MethodID
                let answer: FormSchema.Answer?
                let label: String?
            }
            let loc = try ctx.requireLocation()
            let rawID = try ctx.requireParam("integrationID")
            let integrationID = IntegrationID(rawValue: rawID)
            try await requireConnectable(integrationID, loc)
            let payload = try ctx.decodeJSONBody(OAuthPayload.self)
            let attempt = loc.integrationAttempts.createOAuth(
                integrationID: integrationID,
                methodID: payload.methodID,
                label: payload.label
            )
            return ServerHTTPResponse.json(response(location: loc, data: attempt))
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/integration/:integrationID/connect/oauth/:attemptID",
            endpointName: "integration.oauth.status",
            groupIdentifier: "server.integration",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let rawID = try ctx.requireParam("integrationID")
            let rawAttempt = try ctx.requireParam("attemptID")
            let integrationID = IntegrationID(rawValue: rawID)
            guard try await loc.integration.get(integrationID) != nil else {
                throw IntegrationNotFoundError(integrationID: rawID, message: "Integration not found: \(rawID)")
            }
            guard let status = loc.integrationAttempts.oauthStatus(
                integrationID: integrationID,
                attemptID: IntegrationSchema.AttemptID(rawValue: rawAttempt)
            ) else {
                throw IntegrationAttemptNotFoundError(
                    integrationID: rawID,
                    attemptID: rawAttempt,
                    message: "OAuth attempt not found: \(rawAttempt)"
                )
            }
            return ServerHTTPResponse.json(response(location: loc, data: status))
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/integration/:integrationID/connect/oauth/:attemptID/complete",
            endpointName: "integration.oauth.complete",
            groupIdentifier: "server.integration",
            requiresLocation: true
        ) { ctx in
            struct CompletePayload: Decodable { let code: String? }
            let loc = try ctx.requireLocation()
            let rawID = try ctx.requireParam("integrationID")
            let rawAttempt = try ctx.requireParam("attemptID")
            let integrationID = IntegrationID(rawValue: rawID)
            guard try await loc.integration.get(integrationID) != nil else {
                throw IntegrationNotFoundError(integrationID: rawID, message: "Integration not found: \(rawID)")
            }
            let payload = try ctx.decodeOptionalJSONBody(CompletePayload.self) ?? CompletePayload(code: nil)
            let entry = try loc.integrationAttempts.completeOAuth(
                integrationID: integrationID,
                attemptID: IntegrationSchema.AttemptID(rawValue: rawAttempt),
                code: payload.code
            )
            _ = try await ctx.runtime.credential.create(
                id: nil,
                integrationID: integrationID,
                value: .oauth(CredentialSchema.OAuth(
                    methodID: entry.methodID,
                    refresh: payload.code ?? "",
                    access: payload.code ?? "",
                    expires: SchemaPrimitive.NonNegativeInt(rawValue: 0)!
                )),
                label: entry.label,
                activate: true
            )
            await emitIntegrationCatalogUpdated(ctx.runtime.bus)
            return ServerHTTPResponse.empty(statusCode: 204)
        },
        ServerRoute(
            method: .delete,
            pathTemplate: "/api/integration/:integrationID/connect/oauth/:attemptID",
            endpointName: "integration.oauth.cancel",
            groupIdentifier: "server.integration",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let rawID = try ctx.requireParam("integrationID")
            let rawAttempt = try ctx.requireParam("attemptID")
            loc.integrationAttempts.cancelOAuth(
                integrationID: IntegrationID(rawValue: rawID),
                attemptID: IntegrationSchema.AttemptID(rawValue: rawAttempt)
            )
            return ServerHTTPResponse.empty(statusCode: 204)
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/integration/:integrationID/connect/command",
            endpointName: "integration.command.connect",
            groupIdentifier: "server.integration",
            requiresLocation: true
        ) { ctx in
            struct CommandPayload: Decodable {
                let methodID: IntegrationSchema.MethodID
                let label: String?
            }
            let loc = try ctx.requireLocation()
            let rawID = try ctx.requireParam("integrationID")
            let integrationID = IntegrationID(rawValue: rawID)
            try await requireConnectable(integrationID, loc)
            guard let integration = try await loc.integration.get(integrationID) else {
                throw IntegrationNotFoundError(integrationID: rawID, message: "Integration not found: \(rawID)")
            }
            let payload = try ctx.decodeJSONBody(CommandPayload.self)
            let hasCommandMethod = integration.methods.contains { method in
                if case .command(let cmd) = method { return cmd.id == payload.methodID }
                return false
            }
            guard hasCommandMethod else {
                throw IntegrationMethodNotFoundError(
                    integrationID: rawID,
                    methodID: payload.methodID.rawValue,
                    message: "Integration method not found: \(payload.methodID.rawValue)"
                )
            }
            let attempt = loc.integrationAttempts.createCommand(
                integrationID: integrationID,
                methodID: payload.methodID,
                label: payload.label
            )
            return ServerHTTPResponse.json(response(location: loc, data: attempt))
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/integration/:integrationID/connect/command/:attemptID",
            endpointName: "integration.command.status",
            groupIdentifier: "server.integration",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let rawID = try ctx.requireParam("integrationID")
            let rawAttempt = try ctx.requireParam("attemptID")
            let integrationID = IntegrationID(rawValue: rawID)
            guard try await loc.integration.get(integrationID) != nil else {
                throw IntegrationNotFoundError(integrationID: rawID, message: "Integration not found: \(rawID)")
            }
            guard let status = loc.integrationAttempts.commandStatus(
                integrationID: integrationID,
                attemptID: IntegrationSchema.AttemptID(rawValue: rawAttempt)
            ) else {
                throw IntegrationAttemptNotFoundError(
                    integrationID: rawID,
                    attemptID: rawAttempt,
                    message: "Command attempt not found: \(rawAttempt)"
                )
            }
            return ServerHTTPResponse.json(response(location: loc, data: status))
        },
        ServerRoute(
            method: .delete,
            pathTemplate: "/api/integration/:integrationID/connect/command/:attemptID",
            endpointName: "integration.command.cancel",
            groupIdentifier: "server.integration",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let rawID = try ctx.requireParam("integrationID")
            let rawAttempt = try ctx.requireParam("attemptID")
            loc.integrationAttempts.cancelCommand(
                integrationID: IntegrationID(rawValue: rawID),
                attemptID: IntegrationSchema.AttemptID(rawValue: rawAttempt)
            )
            return ServerHTTPResponse.empty(statusCode: 204)
        },
    ]
)

// MARK: - 15. Job Handler Helpers (server/src/handlers/job.ts)

public struct ServerJobHandlers: Sendable {
    public let list: @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse
}

/// Builds `job.list` handler for the `server.experimental` group.
// parity: server/src/handlers/job.ts#makeJob [status=implemented hash=8c1b836b1298]
public let makeJob: @Sendable () -> ServerJobHandlers = {
    ServerJobHandlers(
        list: { ctx in
            let sessionID: SessionID? = try ctx.request.query("sessionID").map { raw in
                do { return try SessionID(validating: raw) } catch {
                    throw InvalidRequestError(message: "Invalid session ID", field: "sessionID")
                }
            }
            if let sessionID {
                do {
                    _ = try ctx.runtime.session.get(sessionID)
                } catch let e as CoreSessionErrors.NotFoundError {
                    throw missingSession(e)
                }
            }
            let kind: JobSchema.Kind? = try ctx.request.query("kind").map { raw in
                guard let parsed = JobSchema.Kind(rawValue: raw) else {
                    throw InvalidRequestError(message: "Invalid job kind: \(raw)", kind: "Query", field: "kind")
                }
                return parsed
            }
            let status: JobSchema.Status? = try ctx.request.query("status").map { raw in
                guard let parsed = JobSchema.Status(rawValue: raw) else {
                    throw InvalidRequestError(message: "Invalid job status: \(raw)", kind: "Query", field: "status")
                }
                return parsed
            }
            let descendants = try parseBoolQuery(ctx.request.query("descendants")) ?? false
            let allRows = try await ctx.runtime.job.backgroundJobs()

            var ancestorSet: Set<SessionID>? = nil
            if let sessionID {
                var allowed: Set<SessionID> = [sessionID]
                if descendants {
                    var frontier: [SessionID] = [sessionID]
                    while !frontier.isEmpty {
                        let current = frontier.removeFirst()
                        let children = (try? ctx.runtime.sessionStore.list(
                            CoreSessionStore.ListInput(parentID: .session(current))
                        )) ?? []
                        for child in children where allowed.insert(child.id).inserted {
                            frontier.append(child.id)
                        }
                    }
                }
                ancestorSet = allowed
            }

            let items: [JobSchema.Info] = allRows.filter { row in
                let rowSessionID: SessionID
                let rowKind: JobSchema.Kind
                let rowStatus: JobSchema.Status
                switch row {
                case .shell(let s):
                    rowSessionID = s.sessionID; rowKind = .shell; rowStatus = s.status
                case .subagent(let s):
                    rowSessionID = s.sessionID; rowKind = .subagent; rowStatus = s.status
                case .image(let s):
                    rowSessionID = s.sessionID; rowKind = .image; rowStatus = s.status
                case .codemode(let s):
                    rowSessionID = s.sessionID; rowKind = .codemode; rowStatus = s.status
                }
                if let allowed = ancestorSet, !allowed.contains(rowSessionID) {
                    return false
                }
                if let kind, rowKind != kind {
                    return false
                }
                if let status, rowStatus != status {
                    return false
                }
                return true
            }
            return ServerHTTPResponse.json(ServerDataWrapper(data: items))
        }
    )
}

// MARK: - 16. Location Handler (server/src/handlers/location.ts)

/// Handlers for `server.location` (`GET /api/location`, `POST /api/location/reload`).
// parity: server/src/handlers/location.ts#LocationHandler [status=implemented hash=2783fc98f2e4]
public let LocationHandler = ServerHandlerGroup(
    groupIdentifier: "server.location",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/location",
            endpointName: "location.get",
            groupIdentifier: "server.location",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            return ServerHTTPResponse.json(loc.publicInfo)
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/location/reload",
            endpointName: "location.reload",
            groupIdentifier: "server.location"
        ) { ctx in
            do {
                try await CoreLocation.ServiceMap.reload(ctx.runtime.locations)
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ServiceUnavailableError(message: String(describing: error), service: "location")
            }
        },
    ]
)

// MARK: - 17. MCP Handler (server/src/handlers/mcp.ts)

/// Handlers for `server.mcp` (list, add, remove, connect, disconnect, resource.catalog, clientToken, client WebSocket).
// parity: server/src/handlers/mcp.ts#McpHandler [status=implemented hash=8fa1bf8c2773]
public let McpHandler = ServerHandlerGroup(
    groupIdentifier: "server.mcp",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/mcp",
            endpointName: "mcp.list",
            groupIdentifier: "server.mcp",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let servers = await loc.mcp.servers()
            return ServerHTTPResponse.json(response(location: loc, data: servers))
        },
        ServerRoute(
            method: .put,
            pathTemplate: "/api/experimental/mcp/:server",
            endpointName: "mcp.add",
            groupIdentifier: "server.mcp",
            openAPIIdentifier: "experimental.mcp.add",
            requiresLocation: true
        ) { ctx in
            struct AddPayload: Decodable { let config: McpSchema.ServerConfig }
            let loc = try ctx.requireLocation()
            let server = try ctx.requireParam("server")
            let payload = try ctx.decodeJSONBody(AddPayload.self)
            await loc.mcp.add(server: server, config: payload.config)
            return ServerHTTPResponse.empty(statusCode: 204)
        },
        ServerRoute(
            method: .delete,
            pathTemplate: "/api/experimental/mcp/:server",
            endpointName: "mcp.remove",
            groupIdentifier: "server.mcp",
            openAPIIdentifier: "experimental.mcp.remove",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let server = try ctx.requireParam("server")
            do {
                try await loc.mcp.remove(server: server)
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreMCP.Registry.NotFoundError {
                throw McpServerNotFoundError(server: e.server.rawValue, message: e.message)
            }
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/experimental/mcp/:server/connect",
            endpointName: "mcp.connect",
            groupIdentifier: "server.mcp",
            openAPIIdentifier: "experimental.mcp.connect",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let server = try ctx.requireParam("server")
            do {
                try await loc.mcp.connect(server: server)
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreMCP.Registry.NotFoundError {
                throw McpServerNotFoundError(server: e.server.rawValue, message: e.message)
            }
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/experimental/mcp/:server/disconnect",
            endpointName: "mcp.disconnect",
            groupIdentifier: "server.mcp",
            openAPIIdentifier: "experimental.mcp.disconnect",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let server = try ctx.requireParam("server")
            do {
                try await loc.mcp.disconnect(server: server)
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreMCP.Registry.NotFoundError {
                throw McpServerNotFoundError(server: e.server.rawValue, message: e.message)
            }
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/mcp/resource",
            endpointName: "mcp.resource.catalog",
            groupIdentifier: "server.mcp",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let catalog = await loc.mcp.resourceCatalog()
            return ServerHTTPResponse.json(response(location: loc, data: catalog))
        },
        ServerRoute(
            method: .post,
            pathTemplate: "\(MCP_CLIENT_PATH)/token",
            endpointName: "mcp.clientToken",
            groupIdentifier: "server.mcp",
            openAPIIdentifier: "experimental.mcp.client.token",
            requiresLocation: true
        ) { ctx in
            guard ctx.request.header(PTY_CONNECT_TOKEN_HEADER) == PTY_CONNECT_TOKEN_HEADER_VALUE,
                  isAllowedRequestOrigin(ctx.request.header("origin"), host: ctx.request.header("host"), opts: ctx.runtime.corsOptions) else {
                throw ForbiddenError(message: "Invalid client MCP connect token request")
            }
            guard let name = ctx.request.query("name"), !name.isEmpty else {
                throw InvalidRequestError(message: "Missing required query parameter: name", kind: "Query", field: "name")
            }
            let loc = try ctx.requireLocation()
            let token = await ctx.runtime.ptyTicket.issue(
                CorePty.Ticket.Scope(
                    target: .mcpClient(name),
                    directory: loc.ref.directory.rawValue,
                    workspaceID: loc.ref.workspaceID
                )
            )
            return ServerHTTPResponse.json(response(location: loc, data: token))
        },
        ServerRoute(
            method: .get,
            pathTemplate: MCP_CLIENT_PATH,
            endpointName: "mcp.client",
            groupIdentifier: "server.mcp",
            openAPIIdentifier: "experimental.mcp.client"
        ) { ctx in
            guard isAllowedRequestOrigin(ctx.request.header("origin"), host: ctx.request.header("host"), opts: ctx.runtime.corsOptions) else {
                return ServerHTTPResponse.empty(statusCode: 403)
            }
            guard let name = ctx.request.query("name"), !name.isEmpty else {
                return ServerHTTPResponse.empty(statusCode: 400)
            }
            let ref = CoreLocation.ServiceMap.canonical(requestRef(ctx.request, defaultDirectory: ctx.runtime.defaultDirectory))
            if let ticket = ctx.request.query(PTY_CONNECT_TICKET_QUERY), !ticket.isEmpty {
                let consumed = await ctx.runtime.ptyTicket.consume(
                    ticket: ticket,
                    scope: CorePty.Ticket.Scope(
                        target: .mcpClient(name),
                        directory: ref.directory.rawValue,
                        workspaceID: ref.workspaceID
                    )
                )
                guard consumed else {
                    return ServerHTTPResponse.empty(statusCode: 403)
                }
            }
            let loc = try await ctx.runtime.resolveLocation(ref)
            guard let upgrade = ctx.request.upgradeWebSocket else {
                return ServerHTTPResponse.empty(statusCode: 426)
            }
            let socket = try await upgrade()
            let (outbox, outboxCont) = AsyncStream<Outbound>.makeStream()
            let releaseHold = holdLocation(loc.lifecycle, outboxCont)
            defer { releaseHold() }
            let attachedFlag = Mutex(false)
            let disconnectedFlag = Mutex(false)
            let clientSocket = MCPWebSocketAdapter(
                sendText: { text in outboxCont.yield(.text(text)) },
                closeSocket: { code, reason in
                    if attachedFlag.withLock({ $0 }) {
                        outboxCont.yield(.close(ServerWebSocketCloseEvent(code: code, reason: reason)))
                    }
                }
            )
            let transport = CoreMCP.SocketClient.make(clientSocket)
            let attachTask = Task {
                do {
                    try await loc.mcp.attach(name: name, transport: transport)
                    attachedFlag.withLock { $0 = true }
                } catch {
                    if !disconnectedFlag.withLock({ $0 }) {
                        outboxCont.yield(.close(ServerWebSocketCloseEvent(code: 1011, reason: "attach failed")))
                    }
                }
            }
            await runPtySocket(
                socket: socket,
                outbox: outbox,
                onOpen: nil,
                onMessage: { message in
                    let text: String
                    switch message {
                    case .text(let s): text = s
                    case .binary(let b): text = String(decoding: b, as: UTF8.self)
                    }
                    transport.deliver(text)
                },
                detach: {
                    disconnectedFlag.withLock { $0 = true }
                    attachTask.cancel()
                    transport.ended()
                    outboxCont.finish()
                }
            )
            return ServerHTTPResponse(statusCode: 101, webSocketUpgraded: true)
        },
    ]
)

private final class MCPWebSocketAdapter: CoreMCP.SocketClient.Socket, Sendable {
    private let sendText: @Sendable (String) -> Void
    private let closeSocket: @Sendable (Int, String) -> Void

    init(
        sendText: @escaping @Sendable (String) -> Void,
        closeSocket: @escaping @Sendable (Int, String) -> Void
    ) {
        self.sendText = sendText
        self.closeSocket = closeSocket
    }

    func send(_ text: String) throws {
        sendText(text)
    }

    func close(code: Int?, reason: String?) throws {
        closeSocket(code ?? 1000, reason ?? "")
    }
}

// MARK: - 18. Media Blob Get Handler (server/src/handlers/media.ts)

private let inlineImageMimes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]
private let immutableMediaCacheControl = "private, max-age=31536000, immutable"

/// Builds `media.get` raw handler serving content-addressed session media blobs still referenced by a message or inbox row.
// parity: server/src/handlers/media.ts#makeMediaGet [status=implemented hash=4df203574840]
public let makeMediaGet: @Sendable () -> @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse = {
    { ctx in
        let hash = try ctx.requireParam("hash")
        guard MediaHash.isValid(hash) else {
            throw InvalidRequestError(message: "Invalid media hash: \(hash)", kind: "Params", field: "hash")
        }
        let path = "/api/experimental/media/\(hash)"
        guard let blob = try CoreSessionBlob.read(ctx.runtime.db, hash: hash) else {
            throw FileNotFoundError(path: path, message: "Media blob not found: \(hash)")
        }
        let etag = "\"\(hash)\""
        let isInline = inlineImageMimes.contains(blob.mime)
        let headers: [String: String] = [
            "cache-control": immutableMediaCacheControl,
            "etag": etag,
            "content-disposition": ContentHeaders.disposition(""),
            "content-security-policy": ContentHeaders.CONTENT_SECURITY_POLICY,
            "x-content-type-options": "nosniff",
        ]
        if matchesIfNoneMatch(ctx.request.header("if-none-match"), etag: etag) {
            return ServerHTTPResponse.empty(statusCode: 304, headers: headers)
        }
        return ServerHTTPResponse.bytes(
            blob.data,
            statusCode: 200,
            contentType: isInline ? blob.mime : "application/octet-stream",
            headers: headers
        )
    }
}

// MARK: - 19. Message Handler (server/src/handlers/message.ts)

private let defaultMessagesLimit = 50

private struct MessageCursorPayload: Codable {
    let id: String
    let order: String
    let direction: String
}

private func encodeMessageCursor(id: SessionMessageSchema.ID, order: SessionSchema.SortOrder, direction: SessionSchema.ListAnchor.Direction) -> String {
    let payload = MessageCursorPayload(id: id.rawValue, order: order.rawValue, direction: direction.rawValue)
    let bytes = (try? ServerCodec.encode(payload)) ?? []
    return ServerCrypto.base64URLEncode(bytes)
}

private func decodeMessageCursor(_ raw: String) -> (id: SessionMessageSchema.ID, order: SessionSchema.SortOrder, direction: SessionSchema.ListAnchor.Direction)? {
    guard let bytes = ServerCrypto.base64URLDecode(raw),
          let payload = try? ServerCodec.decode(MessageCursorPayload.self, from: bytes),
          let id = SessionMessageSchema.ID(rawValue: payload.id),
          let order = SessionSchema.SortOrder(rawValue: payload.order),
          let direction = SessionSchema.ListAnchor.Direction(rawValue: payload.direction) else {
        return nil
    }
    return (id, order, direction)
}

/// Handlers for `server.message` (`GET /api/session/:sessionID/message` with cursor pagination and `experimental-media-uri`).
// parity: server/src/handlers/message.ts#MessageHandler [status=implemented hash=b2253fea3947]
public let MessageHandler = ServerHandlerGroup(
    groupIdentifier: "server.message",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/session/:sessionID/message",
            endpointName: "session.messages",
            groupIdentifier: "server.message",
            openAPIIdentifier: "session.message.list"
        ) { ctx in
            let rawSessionID = try ctx.requireParam("sessionID")
            let sessionID: SessionID
            do {
                sessionID = try SessionID(validating: rawSessionID)
            } catch {
                throw InvalidRequestError(message: "Invalid session ID", kind: "Params", field: "sessionID")
            }

            let rawCursor = ctx.request.query("cursor")
            let rawOrder = ctx.request.query("order")
            if rawCursor != nil && rawOrder != nil {
                throw InvalidCursorError(message: "Cursor cannot be combined with order")
            }

            let decodedCursor: (id: SessionMessageSchema.ID, order: SessionSchema.SortOrder, direction: SessionSchema.ListAnchor.Direction)?
            if let rawCursor, !rawCursor.isEmpty {
                guard let parsed = decodeMessageCursor(rawCursor) else {
                    throw InvalidCursorError(message: "Invalid cursor")
                }
                decodedCursor = parsed
            } else {
                decodedCursor = nil
            }

            let order: SessionSchema.SortOrder
            if let decodedCursor {
                order = decodedCursor.order
            } else if let rawOrder {
                guard let parsed = SessionSchema.SortOrder(rawValue: rawOrder) else {
                    throw InvalidRequestError(message: "Invalid order: \(rawOrder)", kind: "Query", field: "order")
                }
                order = parsed
            } else {
                order = .desc
            }

            let limit = try parseIntQuery(ctx.request.query("limit"), field: "limit") ?? defaultMessagesLimit
            guard limit >= 1 && limit <= 200 else {
                throw InvalidRequestError(message: "limit must be between 1 and 200", kind: "Query", field: "limit")
            }

            let messageType: SessionMessageSchema.MessageType? = try ctx.request.query("type").map { raw in
                guard let parsed = SessionMessageSchema.MessageType(rawValue: raw) else {
                    throw InvalidRequestError(message: "Invalid message type: \(raw)", kind: "Query", field: "type")
                }
                return parsed
            }
            let input = CoreSessionStore.MessagesInput(
                sessionID: sessionID,
                limit: limit,
                order: order,
                type: messageType,
                cursor: decodedCursor.map { CoreSessionStore.MessagesInput.Cursor(id: $0.id, direction: $0.direction) }
            )

            struct Page<Item: Encodable>: Encodable {
                let data: [Item]
                let cursor: MessagesCursor
            }

            do {
                _ = try ctx.runtime.session.get(sessionID)
                if wantsMediaRefs(ctx.request) {
                    let messages = try ctx.runtime.sessionStore.messagesWithRefs(input)
                    let prev = messages.first.map { encodeMessageCursor(id: $0.id, order: order, direction: .previous) }
                    let next = messages.last.map { encodeMessageCursor(id: $0.id, order: order, direction: .next) }
                    return ServerHTTPResponse.json(Page(data: messages, cursor: MessagesCursor(previous: prev, next: next)))
                }
                let messages = try ctx.runtime.session.messages(input)
                let prev = messages.first.map { encodeMessageCursor(id: $0.id, order: order, direction: .previous) }
                let next = messages.last.map { encodeMessageCursor(id: $0.id, order: order, direction: .next) }
                return ServerHTTPResponse.json(Page(data: messages, cursor: MessagesCursor(previous: prev, next: next)))
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            } catch let e as CoreSessionErrors.MessageDecodeError {
                throw failedMessageDecode(e)
            }
        },
    ]
)

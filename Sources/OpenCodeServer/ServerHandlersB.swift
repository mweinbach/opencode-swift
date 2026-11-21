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

// MARK: - 1. Migration Handler (server/src/handlers/migration.ts)

/// Handlers for `server.migration` (`GET /api/experimental/migration/v1`).
// parity: server/src/handlers/migration.ts#MigrationHandler [status=implemented hash=cfef5574eaa5]
public let MigrationHandler = ServerHandlerGroup(
    groupIdentifier: "server.migration",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/experimental/migration/v1",
            endpointName: "migration.v1.status",
            groupIdentifier: "server.migration",
            openAPIIdentifier: "experimental.migration.v1.status"
        ) { ctx in
            let coreStatus = try CoreDatabaseV1Migration.status(db: ctx.runtime.db)
            let wireStatus: V1MigrationStatus
            switch coreStatus {
            case .required:
                wireStatus = .required
            case .completed:
                wireStatus = .completed
            case .running(let progress):
                wireStatus = .running(progress: V1MigrationProgress(
                    label: progress.label,
                    numerator: progress.numerator,
                    denominator: progress.denominator
                ))
            case .error(let msg):
                wireStatus = .error(msg)
            }
            return ServerHTTPResponse.json(wireStatus)
        },
    ]
)

// MARK: - 2. Model Handler (server/src/handlers/model.ts)

/// Handlers for `server.model` (`GET /api/model`, `GET /api/model/default`).
/// Never waits for async plugin loading; returns currently available models immediately.
// parity: server/src/handlers/model.ts#ModelHandler [status=implemented hash=03928556aebd]
public let ModelHandler = ServerHandlerGroup(
    groupIdentifier: "server.model",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/model",
            endpointName: "model.list",
            groupIdentifier: "server.model",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let rawTypes = ctx.request.queryAll("types")
            let types: [ModelSchema.ModelType]?
            if rawTypes.isEmpty {
                types = nil
            } else {
                var parsed: [ModelSchema.ModelType] = []
                for raw in rawTypes {
                    for part in raw.split(separator: ",") {
                        let token = String(part).trimmingCharacters(in: .whitespaces)
                        guard !token.isEmpty else { continue }
                        parsed.append(ModelSchema.ModelType(rawValue: token))
                    }
                }
                types = parsed
            }
            let models = try await loc.model.available(types: types)
            return ServerHTTPResponse.json(response(location: loc, data: models))
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/model/default",
            endpointName: "model.default",
            groupIdentifier: "server.model",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let model = try await loc.model.defaultModel()
            return ServerHTTPResponse.json(response(location: loc, data: model))
        },
    ]
)

// MARK: - 3. Permission Handler (server/src/handlers/permission.ts)

/// Handlers for `server.permission` (location pending requests, session permissions, and saved permissions).
// parity: server/src/handlers/permission.ts#PermissionHandler [status=implemented hash=fe5f143a6a01]
public let PermissionHandler = ServerHandlerGroup(
    groupIdentifier: "server.permission",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/permission/request",
            endpointName: "permission.request.list",
            groupIdentifier: "server.permission",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let list = await loc.permission.list()
            return ServerHTTPResponse.json(response(location: loc, data: list))
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/permission/saved",
            endpointName: "permission.saved.list",
            groupIdentifier: "server.permission",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let projectID: ProjectID
            if let raw = ctx.request.query("projectID"), !raw.isEmpty {
                projectID = ProjectID(rawValue: raw)
            } else {
                projectID = loc.location.info.project.id
            }
            let saved = try await ctx.runtime.permissionSaved.list(CorePermissionSaved.ListInput(projectID: projectID))
            return ServerHTTPResponse.json(ServerDataWrapper(data: saved))
        },
        ServerRoute(
            method: .patch,
            pathTemplate: "/api/permission/saved/:id",
            endpointName: "permission.saved.update",
            groupIdentifier: "server.permission"
        ) { ctx in
            struct UpdatePayload: Decodable {
                let action: String?
                let resource: String?
            }
            let rawID = try ctx.requireParam("id")
            let id = PermissionSavedSchema.ID(rawValue: rawID)
            let payload = try ctx.decodeJSONBody(UpdatePayload.self)
            do {
                let updated = try await ctx.runtime.permissionSaved.update(
                    CorePermissionSaved.UpdateInput(id: id, action: payload.action, resource: payload.resource)
                )
                return ServerHTTPResponse.json(ServerDataWrapper(data: updated))
            } catch let e as CorePermissionSaved.NotFoundError {
                throw PermissionSavedNotFoundError(id: e.id.rawValue, message: "Saved permission not found: \(e.id.rawValue)")
            } catch let e as CorePermissionSaved.ConflictError {
                throw ConflictError(
                    message: "A saved permission already allows \(e.action) for \(e.resource)",
                    resource: e.id.rawValue
                )
            }
        },
        ServerRoute(
            method: .delete,
            pathTemplate: "/api/permission/saved/:id",
            endpointName: "permission.saved.remove",
            groupIdentifier: "server.permission"
        ) { ctx in
            let rawID = try ctx.requireParam("id")
            let id = PermissionSavedSchema.ID(rawValue: rawID)
            try await ctx.runtime.permissionSaved.remove(id)
            return ServerHTTPResponse.empty(statusCode: 204)
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/session/:sessionID/permission",
            endpointName: "session.permission.create",
            groupIdentifier: "server.permission",
            requiresSessionLocation: true
        ) { ctx in
            struct CreatePayload: Decodable {
                let id: PermissionSchema.ID?
                let action: String
                let resources: [String]
                let save: [String]?
                let metadata: [String: JSONValue]?
                let source: PermissionSchema.Source?
                let agent: AgentSchema.ID?
            }
            struct CreateData: Encodable {
                let id: PermissionSchema.ID
                let effect: PermissionSchema.Effect
            }
            let loc = try ctx.requireLocation()
            let rawSessionID = try ctx.requireParam("sessionID")
            let sessionID = try parseValidatedSessionID(rawSessionID)
            let payload = try ctx.decodeJSONBody(CreatePayload.self)
            do {
                let result = try await loc.permission.ask(
                    CorePermission.AssertInput(
                        id: payload.id,
                        sessionID: sessionID,
                        agent: payload.agent,
                        action: payload.action,
                        resources: payload.resources,
                        save: payload.save,
                        metadata: payload.metadata,
                        source: payload.source
                    )
                )
                return ServerHTTPResponse.json(ServerDataWrapper(data: CreateData(id: result.id, effect: result.effect)))
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            }
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/session/:sessionID/permission",
            endpointName: "session.permission.list",
            groupIdentifier: "server.permission"
        ) { ctx in
            let rawSessionID = try ctx.requireParam("sessionID")
            let info = try sessionInfo(ctx.runtime.session, rawSessionID)
            let locRef = LocationSchema.Ref(
                directory: SchemaPrimitive.AbsolutePath(rawValue: info.location.directory),
                workspaceID: info.location.workspaceID
            )
            let loc = try await ctx.runtime.resolveLocation(locRef)
            let requests = await loc.permission.forSession(info.id)
            return ServerHTTPResponse.json(ServerDataWrapper(data: requests))
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/session/:sessionID/permission/:requestID",
            endpointName: "session.permission.get",
            groupIdentifier: "server.permission",
            requiresSessionLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let rawReqID = try ctx.requireParam("requestID")
            guard let reqID = PermissionSchema.ID(rawValue: rawReqID) else {
                throw InvalidRequestError(message: "Invalid permission request ID: \(rawReqID)", kind: "Params", field: "requestID")
            }
            guard let req = await loc.permission.get(reqID), req.sessionID == sessionID else {
                throw PermissionNotFoundError(requestID: rawReqID, message: "Permission request not found: \(rawReqID)")
            }
            return ServerHTTPResponse.json(ServerDataWrapper(data: req))
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/session/:sessionID/permission/:requestID/reply",
            endpointName: "session.permission.reply",
            groupIdentifier: "server.permission",
            requiresSessionLocation: true
        ) { ctx in
            struct ReplyPayload: Decodable {
                let decision: PermissionSchema.Reply
                let message: String?
            }
            let loc = try ctx.requireLocation()
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let rawReqID = try ctx.requireParam("requestID")
            guard let reqID = PermissionSchema.ID(rawValue: rawReqID) else {
                throw InvalidRequestError(message: "Invalid permission request ID: \(rawReqID)", kind: "Params", field: "requestID")
            }
            guard let req = await loc.permission.get(reqID), req.sessionID == sessionID else {
                throw PermissionNotFoundError(requestID: rawReqID, message: "Permission request not found: \(rawReqID)")
            }
            let payload = try ctx.decodeJSONBody(ReplyPayload.self)
            do {
                try await loc.permission.reply(
                    CorePermission.ReplyInput(requestID: reqID, reply: payload.decision, message: payload.message)
                )
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch is CorePermission.NotFoundError {
                throw PermissionNotFoundError(requestID: rawReqID, message: "Permission request not found: \(rawReqID)")
            }
        },
    ]
)

// MARK: - 4. PTY & Client MCP WebSocket Bridge (server/src/handlers/pty-socket.ts)

/// Outbound WebSocket frame type for PTY and client MCP sockets.
// parity: server/src/handlers/pty-socket.ts#Outbound [status=implemented hash=ecbae93be53e]
public enum Outbound: Equatable, Sendable {
    case text(String)
    case binary([UInt8])
    case close(ServerWebSocketCloseEvent)
}

public enum InboundSocketMessage: Equatable, Sendable {
    case text(String)
    case binary([UInt8])
}

/// Runs a single-writer outbound queue raced against inbound socket reads, guaranteeing detach on every exit.
// parity: server/src/handlers/pty-socket.ts#runPtySocket [status=implemented hash=49c4c36fa9da]
public func runPtySocket(
    socket: any ServerWebSocketConnection,
    outbox: AsyncStream<Outbound>,
    onOpen: (@Sendable () async -> Void)? = nil,
    onMessage: @escaping @Sendable (InboundSocketMessage) async -> Void,
    detach: @escaping @Sendable () -> Void
) async {
    defer { detach() }
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for await item in outbox {
                if Task.isCancelled { break }
                switch item {
                case .text(let s):
                    try? await socket.send(.text(s))
                case .binary(let b):
                    try? await socket.send(.binary(b))
                case .close(let ev):
                    await socket.close(code: ev.code, reason: ev.reason)
                    return
                }
            }
        }
        group.addTask {
            if let onOpen {
                await onOpen()
            }
            for await frame in socket.incoming {
                if Task.isCancelled { break }
                switch frame {
                case .text(let s):
                    await onMessage(.text(s))
                case .binary(let b):
                    await onMessage(.binary(b))
                case .close:
                    return
                }
            }
        }
        _ = await group.next()
        group.cancelAll()
    }
}

/// Retains a Location while a WebSocket is open and closes the socket with code `1012` if the Location shuts down.
// parity: server/src/handlers/pty-socket.ts#holdLocation [status=implemented hash=4b14b3ba7e29]
public let holdLocation: @Sendable (
    CoreLocation.Lifecycle.Service,
    AsyncStream<Outbound>.Continuation
) -> @Sendable () -> Void = { lifecycle, outbox in
    let lease = lifecycle.retain()
    let shutdownTask = Task {
        await lifecycle.awaitShutdown()
        outbox.yield(.close(ServerWebSocketCloseEvent(code: 1012, reason: "location shut down")))
    }
    return {
        shutdownTask.cancel()
        lease()
    }
}

// MARK: - 5. Experimental & Persistent PTY Group Handler (server/src/handlers/persistent-pty.ts)

/// Handlers for `server.experimental` composing media, blob, job, machine, artifacts, automation, and persistentPty routes.
// parity: server/src/handlers/persistent-pty.ts#PersistentPtyHandler [status=implemented hash=b839836ef1f1]
public let PersistentPtyHandler: ServerHandlerGroup = {
    let artifact = makeArtifact()
    let job = makeJob()
    let mediaGet = makeMediaGet()
    let blobGet = makeBlobGet()
    let automation = makeAutomation()
    let machine = ServerMachine.makeMachine()
    let machineLink = ServerMachine.makeMachineLink()

    @Sendable func mapUnavailableError(_ error: any Error) -> any Error {
        if let e = error as? CorePty.Persistent.UnavailableError {
            return ServiceUnavailableError(message: e.message, service: "opencode-pty")
        }
        return error
    }

    @Sendable func mapTerminalError(_ error: any Error) -> any Error {
        if let e = error as? CorePty.Persistent.NotFoundError {
            return PtyNotFoundError(ptyID: e.ptyID.rawValue, message: "PTY session not found: \(e.ptyID.rawValue)")
        }
        if let e = error as? CorePty.Persistent.UnavailableError {
            return ServiceUnavailableError(message: e.message, service: "opencode-pty")
        }
        return error
    }

    return ServerHandlerGroup(
        groupIdentifier: "server.experimental",
        routes: [
            // Media & Blob
            ServerRoute(method: .get, pathTemplate: "/api/experimental/media/:hash", endpointName: "media.get", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.media.get", handler: mediaGet),
            ServerRoute(method: .get, pathTemplate: "/api/experimental/blob/:id", endpointName: "blob.get", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.blob.get", handler: blobGet),
            // Jobs
            ServerRoute(method: .get, pathTemplate: "/api/experimental/job", endpointName: "job.list", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.job.list", handler: job.list),
            ServerRoute(method: .post, pathTemplate: "/api/experimental/job/:id/cancel", endpointName: "job.cancel", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.job.cancel", handler: job.cancel),
            // Machines
            ServerRoute(method: .get, pathTemplate: MACHINE_LINK_PATH, endpointName: "machine.link", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.machine.link", handler: machineLink),
            ServerRoute(method: .get, pathTemplate: "/api/experimental/machine", endpointName: "machine.list", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.machine.list", handler: machine.list),
            ServerRoute(method: .post, pathTemplate: "/api/experimental/machine", endpointName: "machine.add", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.machine.add", handler: machine.add),
            ServerRoute(method: .delete, pathTemplate: "/api/experimental/machine/:name", endpointName: "machine.remove", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.machine.remove", handler: machine.remove),
            // Artifacts
            ServerRoute(method: .get, pathTemplate: "/api/experimental/artifacts/providers", endpointName: "artifacts.providers", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.artifacts.providers", handler: artifact.providers),
            ServerRoute(method: .get, pathTemplate: "/api/experimental/artifacts", endpointName: "artifacts.list", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.artifacts.list", handler: artifact.list),
            ServerRoute(method: .post, pathTemplate: "/api/experimental/artifacts", endpointName: "artifacts.create", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.artifacts.create", handler: artifact.create),
            ServerRoute(method: .get, pathTemplate: "/api/experimental/artifacts/:artifactID", endpointName: "artifacts.get", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.artifacts.get", handler: artifact.get),
            ServerRoute(method: .patch, pathTemplate: "/api/experimental/artifacts/:artifactID", endpointName: "artifacts.update", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.artifacts.update", handler: artifact.update),
            ServerRoute(method: .delete, pathTemplate: "/api/experimental/artifacts/:artifactID", endpointName: "artifacts.delete", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.artifacts.delete", handler: artifact.remove),
            ServerRoute(method: .get, pathTemplate: "/api/experimental/artifacts/:artifactID/view", endpointName: "artifacts.view", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.artifacts.view", handler: artifact.view),
            ServerRoute(method: .get, pathTemplate: "/api/experimental/artifacts/:artifactID/view/*", endpointName: "artifacts.view", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.artifacts.view", handler: artifact.view),
            // Automations
            ServerRoute(method: .post, pathTemplate: "/api/experimental/automation", endpointName: "automation.create", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.automation.create", handler: automation.create),
            ServerRoute(method: .get, pathTemplate: "/api/experimental/automation", endpointName: "automation.list", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.automation.list", handler: automation.list),
            ServerRoute(method: .get, pathTemplate: "/api/experimental/automation/:automationID", endpointName: "automation.get", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.automation.get", handler: automation.get),
            ServerRoute(method: .post, pathTemplate: "/api/experimental/automation/:automationID/pause", endpointName: "automation.pause", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.automation.pause", handler: automation.pause),
            ServerRoute(method: .post, pathTemplate: "/api/experimental/automation/:automationID/resume", endpointName: "automation.resume", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.automation.resume", handler: automation.resume),
            ServerRoute(method: .delete, pathTemplate: "/api/experimental/automation/:automationID", endpointName: "automation.delete", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.automation.delete", handler: automation.remove),
            // Persistent PTY
            ServerRoute(method: .get, pathTemplate: "/api/experimental/session/:sessionID/terminal/read", endpointName: "persistentPty.read", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.persistentPty.read") { ctx in
                let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
                let lines = try parseIntQuery(ctx.request.query("lines"), field: "lines")
                do {
                    let result = try await ctx.runtime.persistentPty.read(sessionID: sessionID, lines: lines)
                    return ServerHTTPResponse.json(ServerDataWrapper(data: result))
                } catch {
                    throw mapUnavailableError(error)
                }
            },
            ServerRoute(method: .get, pathTemplate: "/api/experimental/session/:sessionID/terminal", endpointName: "persistentPty.list", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.persistentPty.list") { ctx in
                let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
                do {
                    let items = try await ctx.runtime.persistentPty.list(sessionID: sessionID)
                    return ServerHTTPResponse.json(ServerDataWrapper(data: items))
                } catch {
                    throw mapUnavailableError(error)
                }
            },
            ServerRoute(method: .post, pathTemplate: "/api/experimental/session/:sessionID/terminal", endpointName: "persistentPty.create", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.persistentPty.create") { ctx in
                struct CreatePayload: Decodable {
                    let command: String?
                    let args: [String]?
                    let cwd: String?
                    let title: String?
                    let env: [String: String]?
                    let size: PersistentPtySchema.Size?
                }
                let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
                let payload = try ctx.decodeJSONBody(CreatePayload.self)
                do {
                    let info = try await ctx.runtime.persistentPty.create(
                        sessionID: sessionID,
                        input: CorePty.Persistent.CreateTerminalInput(
                            command: payload.command,
                            args: payload.args ?? [],
                            cwd: payload.cwd,
                            title: payload.title ?? "",
                            env: payload.env ?? [:],
                            cols: payload.size.map { UInt16(clamping: $0.cols.rawValue) },
                            rows: payload.size.map { UInt16(clamping: $0.rows.rawValue) }
                        )
                    )
                    return ServerHTTPResponse.json(ServerDataWrapper(data: info))
                } catch let e as CorePty.Persistent.InvalidCwdError {
                    throw InvalidRequestError(message: e.description, kind: "invalid_cwd", field: "cwd")
                } catch {
                    throw mapUnavailableError(error)
                }
            },
            ServerRoute(method: .post, pathTemplate: "/api/experimental/persistent-pty/shutdown", endpointName: "persistentPty.shutdown", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.persistentPty.shutdown") { ctx in
                do {
                    try await ctx.runtime.persistentPty.shutdown()
                    return ServerHTTPResponse.empty(statusCode: 204)
                } catch {
                    throw mapUnavailableError(error)
                }
            },
            ServerRoute(method: .post, pathTemplate: "/api/experimental/persistent-pty/handoff", endpointName: "persistentPty.handoff", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.persistentPty.handoff") { ctx in
                struct HandoffEnvelope: Encodable {
                    let handoff: PersistentPtySchema.Handoff?
                }
                do {
                    let handoff = try await ctx.runtime.persistentPty.handoff()
                    return ServerHTTPResponse.json(HandoffEnvelope(handoff: handoff))
                } catch {
                    throw mapUnavailableError(error)
                }
            },
            ServerRoute(method: .get, pathTemplate: "/api/experimental/persistent-pty/:ptyID", endpointName: "persistentPty.get", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.persistentPty.get") { ctx in
                let ptyID = try parseValidatedPtyID(try ctx.requireParam("ptyID"))
                do {
                    let info = try await ctx.runtime.persistentPty.get(ptyID)
                    return ServerHTTPResponse.json(ServerDataWrapper(data: info))
                } catch {
                    throw mapTerminalError(error)
                }
            },
            ServerRoute(method: .put, pathTemplate: "/api/experimental/persistent-pty/:ptyID", endpointName: "persistentPty.update", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.persistentPty.update") { ctx in
                struct UpdatePayload: Decodable {
                    let attachmentID: String?
                    let size: PersistentPtySchema.Size?
                    let title: SchemaPrimitive.Nullable<String>?
                }
                let ptyID = try parseValidatedPtyID(try ctx.requireParam("ptyID"))
                let payload = try ctx.decodeJSONBody(UpdatePayload.self)
                do {
                    if let size = payload.size {
                        try await ctx.runtime.persistentPty.resize(
                            ptyID,
                            cols: UInt16(clamping: size.cols.rawValue),
                            rows: UInt16(clamping: size.rows.rawValue),
                            attachmentID: payload.attachmentID
                        )
                    }
                    if let title = payload.title {
                        let rawTitle: String?
                        switch title {
                        case .null: rawTitle = nil
                        case .value(let v): rawTitle = v
                        }
                        let renamed = try await ctx.runtime.persistentPty.rename(ptyID, title: rawTitle)
                        return ServerHTTPResponse.json(ServerDataWrapper(data: renamed))
                    }
                    let info = try await ctx.runtime.persistentPty.get(ptyID)
                    return ServerHTTPResponse.json(ServerDataWrapper(data: info))
                } catch {
                    throw mapTerminalError(error)
                }
            },
            ServerRoute(method: .get, pathTemplate: "/api/experimental/persistent-pty/:ptyID/snapshot", endpointName: "persistentPty.snapshot", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.persistentPty.snapshot") { ctx in
                let ptyID = try parseValidatedPtyID(try ctx.requireParam("ptyID"))
                do {
                    let snap = try await ctx.runtime.persistentPty.snapshot(ptyID)
                    return ServerHTTPResponse.json(ServerDataWrapper(data: snap))
                } catch {
                    throw mapTerminalError(error)
                }
            },
            ServerRoute(method: .delete, pathTemplate: "/api/experimental/persistent-pty/:ptyID", endpointName: "persistentPty.remove", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.persistentPty.remove") { ctx in
                let ptyID = try parseValidatedPtyID(try ctx.requireParam("ptyID"))
                do {
                    try await ctx.runtime.persistentPty.remove(ptyID)
                    return ServerHTTPResponse.empty(statusCode: 204)
                } catch {
                    throw mapTerminalError(error)
                }
            },
            ServerRoute(method: .post, pathTemplate: "/api/experimental/persistent-pty/:ptyID/connect-token", endpointName: "persistentPty.connectToken", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.persistentPty.connectToken") { ctx in
                guard ctx.request.header(PTY_CONNECT_TOKEN_HEADER) == PTY_CONNECT_TOKEN_HEADER_VALUE,
                      isAllowedRequestOrigin(ctx.request.header("origin"), host: ctx.request.header("host"), opts: ctx.runtime.corsOptions) else {
                    throw ForbiddenError(message: "Invalid persistent PTY connect token request")
                }
                let ptyID = try parseValidatedPtyID(try ctx.requireParam("ptyID"))
                do {
                    _ = try await ctx.runtime.persistentPty.get(ptyID)
                } catch {
                    throw mapTerminalError(error)
                }
                let token = await ctx.runtime.ptyTicket.issue(CorePty.Ticket.Scope(target: .pty(ptyID)))
                return ServerHTTPResponse.json(ServerDataWrapper(data: token))
            },
            ServerRoute(method: .get, pathTemplate: PERSISTENT_PTY_CONNECT_PATH, endpointName: "persistentPty.connect", groupIdentifier: "server.experimental", openAPIIdentifier: "experimental.persistentPty.connect") { ctx in
                guard isAllowedRequestOrigin(ctx.request.header("origin"), host: ctx.request.header("host"), opts: ctx.runtime.corsOptions) else {
                    return ServerHTTPResponse.empty(statusCode: 403)
                }
                let ptyID = try parseValidatedPtyID(try ctx.requireParam("ptyID"))
                if let ticket = ctx.request.query(PTY_CONNECT_TICKET_QUERY), !ticket.isEmpty {
                    let ok = await ctx.runtime.ptyTicket.consume(ticket: ticket, scope: CorePty.Ticket.Scope(target: .pty(ptyID)))
                    guard ok else { return ServerHTTPResponse.empty(statusCode: 403) }
                }
                let rawCursor = ctx.request.query("cursor") ?? "0"
                guard let cursor = UInt64(rawCursor) else {
                    return ServerHTTPResponse.empty(statusCode: 400)
                }
                let role: ProcessDaemon.AttachmentRole = ctx.request.query("role") == "observer" ? .observer : .controller
                let framedInput = ctx.request.query("input_protocol") == "1"
                let attachmentID = ctx.request.query("attachment_id") ?? uuid()
                let takeover = ctx.request.query("takeover") == "true"

                guard let upgrade = ctx.request.upgradeWebSocket else {
                    return ServerHTTPResponse.empty(statusCode: 426)
                }
                let socket = try await upgrade()
                let (outbox, outboxCont) = AsyncStream<Outbound>.makeStream()
                let attachmentBox = Mutex<CorePty.Persistent.Attachment?>(nil)
                let ptyService = ctx.runtime.persistentPty

                let onOpen: @Sendable () async -> Void = {
                    let attached: CorePty.Persistent.Attachment?
                    do {
                        attached = try await ptyService.attach(
                            ptyID,
                            input: CorePty.PersistentDaemon.SubscribeInput(
                                cursor: cursor,
                                attachmentID: attachmentID,
                                role: role,
                                takeover: takeover,
                                onEvent: { event in
                                    switch event {
                                    case .output(_, _, let bytes):
                                        outboxCont.yield(.binary(bytes))
                                    case .resized(let cols, let rows, let generation, let checkpoint):
                                        let payload: [String: JSONValue] = [
                                            "type": .string("resized"),
                                            "cols": .int(Int64(cols)),
                                            "rows": .int(Int64(rows)),
                                            "generation": .int(Int64(generation)),
                                            "checkpoint": .string(bytesToBase64(checkpoint)),
                                        ]
                                        if let str = try? ServerCodec.encodeString(payload) {
                                            outboxCont.yield(.text(str))
                                        }
                                    case .controllerChanged(let controllerID, let generation):
                                        let payload: [String: JSONValue] = [
                                            "type": .string("controller_changed"),
                                            "attachmentID": controllerID.map { .string($0) } ?? .null,
                                            "generation": .int(Int64(generation)),
                                        ]
                                        if let str = try? ServerCodec.encodeString(payload) {
                                            outboxCont.yield(.text(str))
                                        }
                                    case .titleChanged(let title):
                                        let payload: [String: JSONValue] = [
                                            "type": .string("title_changed"),
                                            "title": .string(title),
                                        ]
                                        if let str = try? ServerCodec.encodeString(payload) {
                                            outboxCont.yield(.text(str))
                                        }
                                    case .foregroundProcessChanged(let process):
                                        let payload: [String: JSONValue] = [
                                            "type": .string("foreground_process_changed"),
                                            "process": process.map { .string($0) } ?? .null,
                                        ]
                                        if let str = try? ServerCodec.encodeString(payload) {
                                            outboxCont.yield(.text(str))
                                        }
                                    case .exited(let exitInfo):
                                        let payload: [String: JSONValue] = [
                                            "type": .string("exited"),
                                            "exitCode": exitInfo.exitCode.map { .int(Int64($0)) } ?? .null,
                                            "signal": exitInfo.signal.map { .string($0) } ?? .null,
                                        ]
                                        if let str = try? ServerCodec.encodeString(payload) {
                                            outboxCont.yield(.text(str))
                                        }
                                    }
                                },
                                onEnd: {
                                    outboxCont.yield(.close(ServerWebSocketCloseEvent(code: 1000)))
                                }
                            )
                        )
                    } catch {
                        attached = nil
                    }
                    guard let attached else {
                        outboxCont.yield(.close(ServerWebSocketCloseEvent(code: 4404, reason: "terminal unavailable")))
                        return
                    }
                    attachmentBox.withLock { $0 = attached }
                    let infoJSON = (try? ServerCodec.toJSONValue(attached.info)) ?? .null
                    let attachedMsg: [String: JSONValue] = [
                        "type": .string("attached"),
                        "attachmentID": .string(attachmentID),
                        "inputProtocol": .int(framedInput ? 1 : 0),
                        "info": infoJSON,
                        "role": .string(attached.role.rawValue),
                        "generation": .int(Int64(attached.generation)),
                        "replay": .object([
                            "requestedOffset": .int(Int64(attached.replay.requestedOffset)),
                            "availableOffset": .int(Int64(attached.replay.availableOffset)),
                            "endOffset": .int(Int64(attached.replay.endOffset)),
                            "truncated": .bool(attached.replay.truncated),
                        ]),
                    ]
                    if let str = try? ServerCodec.encodeString(attachedMsg) {
                        outboxCont.yield(.text(str))
                    }
                    if !attached.replay.bytes.isEmpty {
                        outboxCont.yield(.binary(attached.replay.bytes))
                    }
                    let replayDone: [String: JSONValue] = [
                        "type": .string("replay_complete"),
                        "endOffset": .int(Int64(attached.replay.endOffset)),
                    ]
                    if let str = try? ServerCodec.encodeString(replayDone) {
                        outboxCont.yield(.text(str))
                    }
                    attached.activate()
                }

                await runPtySocket(
                    socket: socket,
                    outbox: outbox,
                    onOpen: onOpen,
                    onMessage: { msg in
                        guard let attached = attachmentBox.withLock({ $0 }) else { return }
                        let data: [UInt8]
                        switch msg {
                        case .text(let s): data = Array(s.utf8)
                        case .binary(let b): data = b
                        }
                        if !framedInput {
                            try? await ptyService.input(
                                ptyID,
                                attachmentID: attachmentID,
                                cols: UInt16(clamping: attached.info.size.cols.rawValue),
                                rows: UInt16(clamping: attached.info.size.rows.rawValue),
                                data: data
                            )
                            return
                        }
                        guard data.count >= 5 else { return }
                        let frameType = data[0]
                        let cols = (UInt16(data[1]) << 8) | UInt16(data[2])
                        let rows = (UInt16(data[3]) << 8) | UInt16(data[4])
                        guard (frameType == 0 || frameType == 1), cols > 0, rows > 0 else { return }
                        if frameType == 0 {
                            try? await ptyService.control(ptyID, attachmentID: attachmentID, cols: cols, rows: rows)
                        } else {
                            try? await ptyService.input(ptyID, attachmentID: attachmentID, cols: cols, rows: rows, data: Array(data.dropFirst(5)))
                        }
                    },
                    detach: {
                        attachmentBox.withLock { $0 }?.detach()
                        outboxCont.finish()
                    }
                )
                return ServerHTTPResponse(statusCode: 101, webSocketUpgraded: true)
            },
        ]
    )
}()

// MARK: - 6. Plugin Handler (server/src/handlers/plugin.ts)

/// Handlers for `server.plugin` (`list`, `gui`, `check`, `update`).
/// CRITICAL INVARIANT: Never waits for async plugin loading (`awaitActivation` is NEVER called).
// parity: server/src/handlers/plugin.ts#PluginHandler [status=implemented hash=09a6699d5d7b]
public let PluginHandler = ServerHandlerGroup(
    groupIdentifier: "server.plugin",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/plugin",
            endpointName: "plugin.list",
            groupIdentifier: "server.plugin",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            // Immediate non-blocking snapshot of currently known plugins.
            let list = loc.plugin.list()
            return ServerHTTPResponse.json(response(location: loc, data: list))
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/plugin/gui",
            endpointName: "plugin.gui",
            groupIdentifier: "server.plugin",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            guard let id = ctx.request.query("id"), !id.isEmpty else {
                throw InvalidRequestError(message: "Missing required query parameter: id", kind: "Query", field: "id")
            }
            guard let bundle = try await loc.plugin.gui(PluginSchema.ID(rawValue: id)) else {
                throw PluginNotFoundError(
                    pluginID: id,
                    message: "No active plugin with a ./gui-experimental bundle: \(id)"
                )
            }
            return ServerHTTPResponse.json(response(location: loc, data: bundle))
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/plugin/check",
            endpointName: "plugin.check",
            groupIdentifier: "server.plugin",
            requiresLocation: true
        ) { ctx in
            struct CheckPayload: Decodable { let target: String? }
            let loc = try ctx.requireLocation()
            let payload = try ctx.decodeOptionalJSONBody(CheckPayload.self) ?? CheckPayload(target: nil)
            let inventory = loc.plugin.list()
            var packageTargets: [String] = []
            var seenTargets: Set<String> = []
            for plugin in inventory {
                if case .package(let target, _, _, _) = plugin.source {
                    if payload.target == nil || payload.target == target {
                        if seenTargets.insert(target).inserted {
                            packageTargets.append(target)
                        }
                    }
                }
            }
            if let requested = payload.target, packageTargets.isEmpty {
                throw InvalidRequestError(
                    message: "Plugin package is not in the current server inventory: \(requested)",
                    field: "target"
                )
            }
            let updater = ctx.runtime.pluginUpdate
            var outdated: [String: Bool] = [:]
            await withTaskGroup(of: (String, Bool).self) { group in
                for target in packageTargets {
                    group.addTask {
                        let isOutdated = await updater.check(target, refresh: true)
                        return (target, isOutdated)
                    }
                }
                for await (target, isOutdated) in group {
                    outdated[target] = isOutdated
                }
            }
            let updatedInventory: [PluginSchema.Info] = inventory.map { plugin in
                guard case .package(let target, let version, _, let updating) = plugin.source,
                      let isOutdated = outdated[target] else {
                    return plugin
                }
                return PluginSchema.Info(
                    id: plugin.id,
                    source: .package(
                        target: target,
                        version: version,
                        outdated: isOutdated ? true : nil,
                        updating: updating
                    ),
                    features: plugin.features,
                    state: plugin.state
                )
            }
            return ServerHTTPResponse.json(response(location: loc, data: updatedInventory))
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/plugin/update",
            endpointName: "plugin.update",
            groupIdentifier: "server.plugin",
            requiresLocation: true
        ) { ctx in
            struct UpdatePayload: Decodable { let targets: [String] }
            let loc = try ctx.requireLocation()
            let payload = try ctx.decodeJSONBody(UpdatePayload.self)
            let inventoryTargets: Set<String> = Set(loc.plugin.list().compactMap { plugin in
                if case .package(let target, _, _, _) = plugin.source { return target }
                return nil
            })
            let unknown = payload.targets.filter { !inventoryTargets.contains($0) }
            if !unknown.isEmpty {
                throw InvalidRequestError(
                    message: "Plugin packages are not in the current server inventory: \(unknown.joined(separator: ", "))",
                    field: "targets"
                )
            }
            let updater = ctx.runtime.pluginUpdate
            var failures: [String] = []
            await withTaskGroup(of: String?.self) { group in
                for target in payload.targets {
                    group.addTask {
                        do {
                            try await updater.update(target)
                            return nil
                        } catch {
                            return "\(target): \(String(describing: error))"
                        }
                    }
                }
                for await failure in group {
                    if let failure { failures.append(failure) }
                }
            }
            if !failures.isEmpty {
                throw ServiceUnavailableError(
                    message: "Failed to update plugin packages: \(failures.joined(separator: "; "))",
                    service: "plugin"
                )
            }
            return ServerHTTPResponse.empty(statusCode: 204)
        },
    ]
)

// MARK: - 7. Project Handler (server/src/handlers/project.ts)

/// Handlers for `server.project` (`GET /api/project`, `PATCH /api/project/:projectID`).
// parity: server/src/handlers/project.ts#ProjectHandler [status=implemented hash=c61971fd1249]
public let ProjectHandler = ServerHandlerGroup(
    groupIdentifier: "server.project",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/project",
            endpointName: "project.list",
            groupIdentifier: "server.project"
        ) { ctx in
            let archived = try parseBoolQuery(ctx.request.query("archived"))
            let projects = try await ctx.runtime.project.list(CoreProject.Project.ListInput(archived: archived))
            return ServerHTTPResponse.json(projects)
        },
        ServerRoute(
            method: .patch,
            pathTemplate: "/api/project/:projectID",
            endpointName: "project.update",
            groupIdentifier: "server.project"
        ) { ctx in
            struct UpdatePayload: Decodable {
                let canonical: SchemaPrimitive.AbsolutePath?
                let name: String?
                let icon: ProjectSchema.Icon?
                let commands: ProjectSchema.Commands?
            }
            let rawID = try ctx.requireParam("projectID")
            let projectID = ProjectID(rawValue: rawID)
            let payload = try ctx.decodeJSONBody(UpdatePayload.self)
            do {
                let updated = try await ctx.runtime.project.update(
                    CoreProject.Project.UpdateInput(
                        projectID: projectID,
                        canonical: payload.canonical,
                        name: payload.name,
                        icon: payload.icon,
                        commands: payload.commands
                    )
                )
                return ServerHTTPResponse.json(updated)
            } catch {
                throw ProjectNotFoundError(projectID: rawID, message: "Project not found: \(rawID)")
            }
        },
    ]
)

// MARK: - 8. Provider Handler (server/src/handlers/provider.ts)

/// Handlers for `server.provider` (`GET /api/provider`, `GET /api/provider/:providerID`).
/// Never waits for async plugin loading; answers with currently registered providers immediately.
// parity: server/src/handlers/provider.ts#ProviderHandler [status=implemented hash=4c28000b5e57]
public let ProviderHandler = ServerHandlerGroup(
    groupIdentifier: "server.provider",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/provider",
            endpointName: "provider.list",
            groupIdentifier: "server.provider",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let providers = try await loc.provider.available()
            return ServerHTTPResponse.json(response(location: loc, data: providers))
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/provider/:providerID",
            endpointName: "provider.get",
            groupIdentifier: "server.provider",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let rawID = try ctx.requireParam("providerID")
            guard let provider = await loc.provider.get(ProviderSchema.ID(rawValue: rawID)) else {
                throw ProviderNotFoundError(providerID: rawID, message: "Provider not found: \(rawID)")
            }
            return ServerHTTPResponse.json(response(location: loc, data: provider))
        },
    ]
)

// MARK: - 9. PTY Handler (server/src/handlers/pty.ts)

/// Handlers for `server.pty` (list, create, get, update, remove, connectToken, connect WebSocket).
// parity: server/src/handlers/pty.ts#PtyHandler [status=implemented hash=16fde3d4916a]
public let PtyHandler = ServerHandlerGroup(
    groupIdentifier: "server.pty",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/pty",
            endpointName: "pty.list",
            groupIdentifier: "server.pty",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let list = await loc.pty.list()
            return ServerHTTPResponse.json(response(location: loc, data: list))
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/pty",
            endpointName: "pty.create",
            groupIdentifier: "server.pty",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let payload = try ctx.decodeOptionalJSONBody(PtySchema.CreateInput.self) ?? PtySchema.CreateInput()
            let effectiveCwd = (payload.cwd?.isEmpty == false) ? payload.cwd : loc.ref.directory.rawValue
            let created = try await loc.pty.create(
                PtySchema.CreateInput(
                    command: payload.command,
                    args: payload.args,
                    cwd: effectiveCwd,
                    title: payload.title,
                    env: payload.env
                )
            )
            return ServerHTTPResponse.json(response(location: loc, data: created))
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/pty/:ptyID",
            endpointName: "pty.get",
            groupIdentifier: "server.pty",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let ptyID = try parseValidatedPtyID(try ctx.requireParam("ptyID"))
            do {
                let info = try await loc.pty.get(ptyID)
                return ServerHTTPResponse.json(response(location: loc, data: info))
            } catch is CorePty.NotFoundError {
                throw PtyNotFoundError(ptyID: ptyID.rawValue, message: "PTY session not found: \(ptyID.rawValue)")
            }
        },
        ServerRoute(
            method: .put,
            pathTemplate: "/api/pty/:ptyID",
            endpointName: "pty.update",
            groupIdentifier: "server.pty",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let ptyID = try parseValidatedPtyID(try ctx.requireParam("ptyID"))
            let payload = try ctx.decodeJSONBody(PtySchema.UpdateInput.self)
            do {
                let updated = try await loc.pty.update(ptyID, input: payload)
                return ServerHTTPResponse.json(response(location: loc, data: updated))
            } catch is CorePty.NotFoundError {
                throw PtyNotFoundError(ptyID: ptyID.rawValue, message: "PTY session not found: \(ptyID.rawValue)")
            }
        },
        ServerRoute(
            method: .delete,
            pathTemplate: "/api/pty/:ptyID",
            endpointName: "pty.remove",
            groupIdentifier: "server.pty",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let ptyID = try parseValidatedPtyID(try ctx.requireParam("ptyID"))
            do {
                try await loc.pty.remove(ptyID)
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch is CorePty.NotFoundError {
                throw PtyNotFoundError(ptyID: ptyID.rawValue, message: "PTY session not found: \(ptyID.rawValue)")
            }
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/pty/:ptyID/connect-token",
            endpointName: "pty.connectToken",
            groupIdentifier: "server.pty",
            openAPIIdentifier: "pty.connect.token",
            requiresLocation: true
        ) { ctx in
            guard ctx.request.header(PTY_CONNECT_TOKEN_HEADER) == PTY_CONNECT_TOKEN_HEADER_VALUE,
                  isAllowedRequestOrigin(ctx.request.header("origin"), host: ctx.request.header("host"), opts: ctx.runtime.corsOptions) else {
                throw ForbiddenError(message: "Invalid PTY connect token request")
            }
            let loc = try ctx.requireLocation()
            let ptyID = try parseValidatedPtyID(try ctx.requireParam("ptyID"))
            do {
                _ = try await loc.pty.get(ptyID)
            } catch is CorePty.NotFoundError {
                throw PtyNotFoundError(ptyID: ptyID.rawValue, message: "PTY session not found: \(ptyID.rawValue)")
            }
            let token = await ctx.runtime.ptyTicket.issue(
                CorePty.Ticket.Scope(
                    target: .pty(ptyID),
                    directory: loc.ref.directory.rawValue,
                    workspaceID: loc.ref.workspaceID
                )
            )
            return ServerHTTPResponse.json(response(location: loc, data: token))
        },
        ServerRoute(
            method: .get,
            pathTemplate: PTY_CONNECT_PATH,
            endpointName: "pty.connect",
            groupIdentifier: "server.pty"
        ) { ctx in
            guard isAllowedRequestOrigin(ctx.request.header("origin"), host: ctx.request.header("host"), opts: ctx.runtime.corsOptions) else {
                return ServerHTTPResponse.empty(statusCode: 403)
            }
            let ref = CoreLocation.ServiceMap.canonical(requestRef(ctx.request, defaultDirectory: ctx.runtime.defaultDirectory))
            let ptyID = try parseValidatedPtyID(try ctx.requireParam("ptyID"))
            if let ticket = ctx.request.query(PTY_CONNECT_TICKET_QUERY), !ticket.isEmpty {
                let consumed = await ctx.runtime.ptyTicket.consume(
                    ticket: ticket,
                    scope: CorePty.Ticket.Scope(
                        target: .pty(ptyID),
                        directory: ref.directory.rawValue,
                        workspaceID: ref.workspaceID
                    )
                )
                guard consumed else { return ServerHTTPResponse.empty(statusCode: 403) }
            }
            let loc = try await ctx.runtime.resolveLocation(ref)
            let exists: Bool
            do {
                _ = try await loc.pty.get(ptyID)
                exists = true
            } catch is CorePty.NotFoundError {
                exists = false
            }
            guard exists else { return ServerHTTPResponse.empty(statusCode: 404) }

            let cursor: Int? = ctx.request.query("cursor").flatMap { raw in
                guard let n = Int(raw), n >= -1 else { return nil }
                return n
            }

            guard let upgrade = ctx.request.upgradeWebSocket else {
                return ServerHTTPResponse.empty(statusCode: 426)
            }
            let socket = try await upgrade()
            let (outbox, outboxCont) = AsyncStream<Outbound>.makeStream()
            let releaseHold = holdLocation(loc.lifecycle, outboxCont)
            defer { releaseHold() }

            let attachment: CorePty.Attachment?
            do {
                attachment = try await loc.pty.attach(
                    ptyID,
                    input: CorePty.AttachInput(
                        cursor: cursor,
                        onData: { chunk in outboxCont.yield(.text(chunk)) },
                        onEnd: { _ in outboxCont.yield(.close(ServerWebSocketCloseEvent(code: 1000))) }
                    )
                )
            } catch is CorePty.NotFoundError {
                outboxCont.yield(.close(ServerWebSocketCloseEvent(code: 4404, reason: "session not found")))
                attachment = nil
            } catch is CorePty.ExitedError {
                outboxCont.yield(.close(ServerWebSocketCloseEvent(code: 4404, reason: "session exited")))
                attachment = nil
            }

            if let attachment {
                for chunk in CorePty.WireProtocol.chunks(attachment.replay) {
                    outboxCont.yield(.text(chunk))
                }
                outboxCont.yield(.binary(CorePty.WireProtocol.metaFrame(cursor: attachment.cursor)))
                attachment.activate()
            }

            await runPtySocket(
                socket: socket,
                outbox: outbox,
                onOpen: nil,
                onMessage: { msg in
                    guard let attachment else { return }
                    let decoded: String?
                    switch msg {
                    case .text(let s): decoded = CorePty.WireProtocol.decodeInput(s)
                    case .binary(let b): decoded = CorePty.WireProtocol.decodeInput(b)
                    }
                    if let decoded {
                        attachment.write(decoded)
                    }
                },
                detach: {
                    attachment?.detach()
                    outboxCont.finish()
                }
            )
            return ServerHTTPResponse(statusCode: 101, webSocketUpgraded: true)
        },
    ]
)

// MARK: - 10. Reference Handler (server/src/handlers/reference.ts)

/// Handlers for `server.reference` (`GET /api/reference`).
// parity: server/src/handlers/reference.ts#ReferenceHandler [status=implemented hash=071ac5ebbdb0]
public let ReferenceHandler = ServerHandlerGroup(
    groupIdentifier: "server.reference",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/reference",
            endpointName: "reference.list",
            groupIdentifier: "server.reference",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let list = await loc.reference.list()
            return ServerHTTPResponse.json(response(location: loc, data: list))
        },
    ]
)

// MARK: - 11. RPC Handler (server/src/handlers/rpc.ts)

/// Handlers for `server.rpc` (`POST /api/rpc/:rpcID/:method`).
/// Never waits for async plugin loading; calls currently registered RPC handlers immediately.
// parity: server/src/handlers/rpc.ts#RpcHandler [status=implemented hash=4661ca4fbbe8]
public let RpcHandler = ServerHandlerGroup(
    groupIdentifier: "server.rpc",
    routes: [
        ServerRoute(
            method: .post,
            pathTemplate: "/api/rpc/:rpcID/:method",
            endpointName: "rpc.call",
            groupIdentifier: "server.rpc",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let rpcID = try ctx.requireParam("rpcID")
            let method = try ctx.requireParam("method")
            let payload = try ctx.decodeOptionalJSONBody(RpcInput.self) ?? RpcInput(input: nil)
            do {
                let output = try await loc.rpc.call(rpcID: rpcID, method: method, input: payload.input ?? .null)
                if case .null = output {
                    return ServerHTTPResponse.json(RpcOutput(output: nil))
                }
                return ServerHTTPResponse.json(RpcOutput(output: output))
            } catch let failure as RpcSchema.Failure<JSONValue> {
                if failure.type == "rpc.invalid_output" || failure.type == "rpc.internal" {
                    let kind = RpcInternalErrorType(rawValue: failure.type) ?? .rpcInternal
                    throw RpcInternalError(type: kind, message: failure.message)
                }
                throw RpcError(type: failure.type, message: failure.message, data: failure.data)
            } catch {
                throw RpcInternalError(type: .rpcInternal, message: "RPC call failed")
            }
        },
    ]
)

// MARK: - 12. Server Handler (server/src/handlers/server.ts) & Machine Link Carrier

/// `MachineLink.Carrier` backed by any `ServerWebSocketConnection`, carrying binary frames in order and honoring
/// task cancellation on `receive()`.
public final class ServerWebSocketCarrier: MachineLink.Carrier, Sendable {
    private struct QueueState {
        var buffered: [[UInt8]] = []
        var waiters: [(id: Int, continuation: CheckedContinuation<[UInt8], any Error>)] = []
        var nextWaiterID = 0
        var closed = false
    }

    private let socket: any ServerWebSocketConnection
    private let state = Mutex(QueueState())
    private let pumpTask: Mutex<Task<Void, Never>?> = Mutex(nil)

    public init(socket: any ServerWebSocketConnection) {
        self.socket = socket
        let task = Task { [weak self] in
            for await frame in socket.incoming {
                guard let self else { break }
                switch frame {
                case .binary(let bytes):
                    self.enqueue(bytes)
                case .text:
                    // Binary frames only; a text frame ends the carrier like a closed socket.
                    self.markClosed()
                    return
                case .close:
                    self.markClosed()
                    return
                }
            }
            self?.markClosed()
        }
        pumpTask.withLock { $0 = task }
    }

    deinit {
        stop()
    }

    public func stop() {
        let task = pumpTask.withLock { current -> Task<Void, Never>? in
            let existing = current
            current = nil
            return existing
        }
        task?.cancel()
        markClosed()
    }

    private func enqueue(_ bytes: [UInt8]) {
        let waiter: CheckedContinuation<[UInt8], any Error>? = state.withLock { s in
            if s.closed { return nil }
            if !s.waiters.isEmpty {
                return s.waiters.removeFirst().continuation
            }
            s.buffered.append(bytes)
            return nil
        }
        waiter?.resume(returning: bytes)
    }

    private func markClosed() {
        let waiters: [CheckedContinuation<[UInt8], any Error>] = state.withLock { s in
            guard !s.closed else { return [] }
            s.closed = true
            let pending = s.waiters.map(\.continuation)
            s.waiters.removeAll()
            return pending
        }
        for waiter in waiters {
            waiter.resume(throwing: MachineLink.Closed())
        }
    }

    public var describe: (@Sendable () -> MachineDriver.ConnectionInfo)? {
        { MachineDriver.ConnectionInfo(kind: .websocket) }
    }

    public func send(_ message: [UInt8]) async {
        try? await socket.send(.binary(message))
    }

    public func receive() async throws -> [UInt8] {
        let id = state.withLock { s -> Int in
            s.nextWaiterID += 1
            return s.nextWaiterID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], any Error>) in
                let immediate: Result<[UInt8], any Error>? = state.withLock { s in
                    if !s.buffered.isEmpty {
                        return .success(s.buffered.removeFirst())
                    }
                    if s.closed {
                        return .failure(MachineLink.Closed())
                    }
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    s.waiters.append((id: id, continuation: continuation))
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            let cancelled: CheckedContinuation<[UInt8], any Error>? = state.withLock { s in
                guard let idx = s.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return s.waiters.remove(at: idx).continuation
            }
            cancelled?.resume(throwing: CancellationError())
        }
    }
}

/// Bridges a WebSocket connection into `MachineLink.serve` + framed `MachineWire` + `Machines.Service.connect`.
public enum ServerMachineLink {
    /// Home side: authenticates the worker via `MachineLink.serve`, validates its framed `MachineWire.Hello`,
    /// and serves the connection under the handshake-proven machine ID through `machines`.
    public static func serve(
        socket: any ServerWebSocketConnection,
        identity: any MachineIdentity.Interface,
        machines: any Machines.Interface
    ) async {
        let carrier = ServerWebSocketCarrier(socket: socket)
        defer { carrier.stop() }

        let served: MachineLink.Served
        do {
            served = try await MachineLink.serve(carrier, identity: identity, machines: machines)
        } catch {
            await socket.close(code: 1008, reason: "")
            return
        }
        defer { served.close() }

        try? await machines.connect(served.machine, served.connection)
        await socket.close(code: 1008, reason: "")
    }
}

/// Handlers for `server.server` (`GET /api/info`, `POST /api/pair`, `GET /auth/connect/:code`).
// parity: server/src/handlers/server.ts#ServerHandler [status=implemented hash=d694cd8def2c]
public let ServerHandler = ServerHandlerGroup(
    groupIdentifier: "server.server",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/info",
            endpointName: "server.info",
            groupIdentifier: "server.server"
        ) { ctx in
            let info = ctx.runtime.serverInfo
            let wire = OpenCodeProtocol.ServerInfo(
                version: info.app.version ?? "unknown",
                pid: ServerHostInfo.processID(),
                hostname: ServerHostInfo.hostname(),
                urls: info.urls(),
                paths: OpenCodeProtocol.ServerInfo.Paths(tmp: info.paths.tmp),
                capabilities: OpenCodeProtocol.ServerInfo.Capabilities(persistentPty: CorePty.PersistentBinaryBun.available)
            )
            return ServerHTTPResponse.json(wire)
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/pair",
            endpointName: "server.pair",
            groupIdentifier: "server.server"
        ) { ctx in
            let code = ctx.runtime.pairing.issue()
            return ServerHTTPResponse.json(code)
        },
        ServerRoute(
            method: .get,
            pathTemplate: PAIRING_CONNECT_PATH,
            endpointName: "server.connect",
            groupIdentifier: "server.server"
        ) { ctx in
            let code = try ctx.requireParam("code")
            let accept = ctx.request.header("accept") ?? ""
            let isBrowser = accept.contains("text/html")
            let consumed = ctx.runtime.pairing.consume(code)
            let token: String? = consumed ? ServerAuth.issueSession(ctx.runtime.authConfig) : nil
            guard let token else {
                if !isBrowser {
                    throw UnauthorizedError(message: "Pairing link expired or already used")
                }
                return ServerHTTPResponse.text(
                    "This pairing link expired or was already used. Run `opencode pair` to get a new one.",
                    statusCode: 401
                )
            }
            if !isBrowser {
                return ServerHTTPResponse.json(PairingSession(token: token))
            }
            let cookieName = ServerAuth.sessionCookieName(ctx.request.header("host"))
            return ServerHTTPResponse.redirect(to: "/", statusCode: 302)
                .withCookie(
                    name: cookieName,
                    value: token,
                    path: "/",
                    httpOnly: true,
                    sameSite: "Lax",
                    maxAgeSeconds: ServerAuth.SESSION_TTL_SECONDS
                )
        },
    ]
)

// MARK: - 13. Session Handler (server/src/handlers/session.ts)

/// Handlers for `server.session` (all 35 session, inbox, revert, transfer, instructions, form, and log routes).
// parity: server/src/handlers/session.ts#SessionHandler [status=implemented hash=fca712728fe8]
public let SessionHandler = ServerHandlerGroup(
    groupIdentifier: "server.session",
    routes: [
        // GET /api/session
        ServerRoute(
            method: .get,
            pathTemplate: "/api/session",
            endpointName: "session.list",
            groupIdentifier: "server.session"
        ) { ctx in
            struct CursorEnvelope: Encodable {
                let previous: SessionsCursor?
                let next: SessionsCursor?
            }
            struct ListEnvelope: Encodable {
                let data: [SessionSchema.Info]
                let cursor: CursorEnvelope
            }

            let rawCursor = ctx.request.query("cursor")
            let rawOrder = ctx.request.query("order")
            if rawCursor != nil && rawOrder != nil {
                throw InvalidCursorError(message: "Cursor cannot be combined with order")
            }

            var anchor: SessionSchema.ListAnchor? = nil
            var order: SessionSchema.SortOrder? = nil
            if let rawCursor, !rawCursor.isEmpty {
                guard let decoded = decodeSessionListCursor(rawCursor) else {
                    throw InvalidCursorError(message: "Invalid session list cursor")
                }
                anchor = decoded.anchor
                order = decoded.order
            } else if let rawOrder {
                guard let parsed = SessionSchema.SortOrder(rawValue: rawOrder) else {
                    throw InvalidRequestError(message: "Invalid order: \(rawOrder)", kind: "Query", field: "order")
                }
                order = parsed
            }

            let limit = try parseIntQuery(ctx.request.query("limit"), field: "limit")
            if let limit, limit < 1 {
                throw InvalidRequestError(message: "limit must be positive", kind: "Query", field: "limit")
            }
            let archived = try parseBoolQuery(ctx.request.query("archived"))
            let parentFilter: SessionSchema.ParentFilter?
            if let rawParent = ctx.request.query("parentID") {
                if rawParent == "null" {
                    parentFilter = .root
                } else {
                    parentFilter = .session(try parseValidatedSessionID(rawParent))
                }
            } else {
                parentFilter = nil
            }
            let projectFilter: ProjectID? = ctx.request.query("project").map { ProjectID(rawValue: $0) }

            let input = CoreSessionStore.ListInput(
                directory: ctx.request.query("directory"),
                project: projectFilter,
                subpath: ctx.request.query("subpath"),
                search: ctx.request.query("search"),
                limit: limit,
                order: order,
                parentID: parentFilter,
                archived: archived,
                anchor: anchor
            )
            do {
                let page = try ctx.runtime.session.list(input)
                let effectiveOrder = order ?? .desc
                let prevCursor = page.data.first.map { encodeSessionListCursor(session: $0, order: effectiveOrder, direction: .previous) }
                let nextCursor = page.data.last.map { encodeSessionListCursor(session: $0, order: effectiveOrder, direction: .next) }
                return ServerHTTPResponse.json(ListEnvelope(
                    data: page.data,
                    cursor: CursorEnvelope(previous: prevCursor, next: nextCursor)
                ))
            } catch let e as CoreSessionErrors.InvalidListCursorError {
                throw InvalidCursorError(message: e.description)
            }
        },
        // GET /api/experimental/session/stats
        ServerRoute(
            method: .get,
            pathTemplate: "/api/experimental/session/stats",
            endpointName: "session.stats",
            groupIdentifier: "server.session",
            openAPIIdentifier: "experimental.session.stats"
        ) { ctx in
            let timezone = ctx.request.query("timezone") ?? "UTC"
            guard isValidTimeZoneIdentifier(timezone) else {
                throw InvalidRequestError(message: "Invalid time zone: \(timezone)")
            }
            let from = try parseInt64Query(ctx.request.query("from"), field: "from")
            let to = try parseInt64Query(ctx.request.query("to"), field: "to")
            let projectID: ProjectID? = ctx.request.query("project").map { ProjectID(rawValue: $0) }
            let tools: SessionStatsSchema.ToolMode
            if let rawTools = ctx.request.query("tools") {
                guard let parsed = SessionStatsSchema.ToolMode(rawValue: rawTools) else {
                    throw InvalidRequestError(message: "Invalid tools mode: \(rawTools)", kind: "Query", field: "tools")
                }
                tools = parsed
            } else {
                tools = .summary
            }
            do {
                let stats = try CoreSessionStats.get(
                    db: ctx.runtime.db,
                    input: CoreSessionStats.QueryInput(from: from, to: to, projectID: projectID, tools: tools)
                )
                return ServerHTTPResponse.json(ServerDataWrapper(data: stats))
            } catch is CoreSessionStats.InvalidRangeError {
                throw InvalidRequestError(message: "Stats range must end after it starts")
            }
        },
        // POST /api/session
        ServerRoute(
            method: .post,
            pathTemplate: "/api/session",
            endpointName: "session.create",
            groupIdentifier: "server.session"
        ) { ctx in
            struct CreatePayload: Decodable {
                let id: SessionID?
                let parentID: SessionID?
                let title: String?
                let agent: String?
                let model: SessionSchema.ModelRef?
                let location: LocationSchema.PublicRef?
                let metadata: SessionSchema.Metadata?
                let permissions: SessionSchema.PermissionRuleset?
            }
            let payload = try ctx.decodeOptionalJSONBody(CreatePayload.self)
                ?? CreatePayload(id: nil, parentID: nil, title: nil, agent: nil, model: nil, location: nil, metadata: nil, permissions: nil)
            let location: OpenCodeLocation?
            if payload.parentID == nil {
                let dir = payload.location?.directory.rawValue ?? ctx.runtime.defaultDirectory
                location = OpenCodeLocation(directory: dir)
            } else {
                location = nil
            }
            do {
                let created = try await ctx.runtime.session.create(
                    CoreSession.CreateInput(
                        id: payload.id,
                        location: location,
                        parentID: payload.parentID,
                        title: payload.title,
                        agent: payload.agent,
                        model: payload.model,
                        metadata: payload.metadata,
                        permissions: payload.permissions
                    )
                )
                return ServerHTTPResponse.json(ServerDataWrapper(data: created))
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            }
        },
        // POST /api/experimental/session/import
        ServerRoute(
            method: .post,
            pathTemplate: "/api/experimental/session/import",
            endpointName: "session.import",
            groupIdentifier: "server.session",
            openAPIIdentifier: "experimental.session.import"
        ) { ctx in
            struct ImportPayload: Decodable {
                let info: SessionSchema.Info
                let messages: [SessionMessageSchema.Info]
                let location: LocationSchema.PublicRef?
            }
            let payload = try ctx.decodeJSONBody(ImportPayload.self)
            let dir = payload.location?.directory.rawValue ?? ctx.runtime.defaultDirectory
            do {
                let imported = try await ctx.runtime.sessionTransfer.import(
                    data: SessionTransferSchema.Data(info: payload.info, messages: payload.messages),
                    location: OpenCodeLocation(directory: dir)
                )
                return ServerHTTPResponse.json(ServerDataWrapper(data: imported))
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            } catch let e as CoreSessionTransfer.ImportConflictError {
                throw ConflictError(message: "Session already exists: \(e.sessionID.rawValue)", resource: e.sessionID.rawValue)
            }
        },
        // GET /api/experimental/session/:sessionID/export
        ServerRoute(
            method: .get,
            pathTemplate: "/api/experimental/session/:sessionID/export",
            endpointName: "session.export",
            groupIdentifier: "server.session",
            openAPIIdentifier: "experimental.session.export"
        ) { ctx in
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let sanitize = try parseBoolQuery(ctx.request.query("sanitize")) ?? false
            do {
                let exported = try ctx.runtime.sessionTransfer.export(sessionID: sessionID, sanitize: sanitize)
                return ServerHTTPResponse.json(ServerDataWrapper(data: exported))
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            } catch let e as CoreSessionErrors.MessageDecodeError {
                throw failedMessageDecode(e)
            }
        },
        // GET /api/session/active
        ServerRoute(
            method: .get,
            pathTemplate: "/api/session/active",
            endpointName: "session.active",
            groupIdentifier: "server.session"
        ) { ctx in
            struct ActiveEntry: Encodable { let type: String = "running" }
            let active = await ctx.runtime.sessionExecution.active()
            var map: [String: ActiveEntry] = [:]
            for sid in active {
                map[sid.rawValue] = ActiveEntry()
            }
            return ServerHTTPResponse.json(ServerDataWrapper(data: map))
        },
        // GET /api/session/:sessionID
        ServerRoute(
            method: .get,
            pathTemplate: "/api/session/:sessionID",
            endpointName: "session.get",
            groupIdentifier: "server.session"
        ) { ctx in
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            do {
                let info = try ctx.runtime.session.get(sessionID)
                return ServerHTTPResponse.json(ServerDataWrapper(data: info))
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            }
        },
        // POST /api/session/:sessionID/view
        ServerRoute(
            method: .post,
            pathTemplate: "/api/session/:sessionID/view",
            endpointName: "session.view",
            groupIdentifier: "server.session"
        ) { ctx in
            struct ViewPayload: Decodable { let idle: Int64 }
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let payload = try ctx.decodeJSONBody(ViewPayload.self)
            do {
                _ = try ctx.runtime.session.get(sessionID)
                _ = try await ctx.runtime.bus.publish(
                    SessionEventSchema.Viewed,
                    data: SessionEventSchema.ViewedData(sessionID: sessionID, idle: payload.idle)
                )
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            }
        },
        // DELETE /api/session/:sessionID
        ServerRoute(
            method: .delete,
            pathTemplate: "/api/session/:sessionID",
            endpointName: "session.remove",
            groupIdentifier: "server.session"
        ) { ctx in
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            do {
                try await ctx.runtime.session.remove(sessionID)
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            }
        },
        // PUT /api/session/:sessionID/environment
        ServerRoute(
            method: .put,
            pathTemplate: "/api/session/:sessionID/environment",
            endpointName: "session.environment",
            groupIdentifier: "server.session"
        ) { ctx in
            struct EnvPayload: Decodable { let variables: [String: String] }
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let payload = try ctx.decodeJSONBody(EnvPayload.self)
            do {
                _ = try ctx.runtime.session.get(sessionID)
                ctx.runtime.sessionEnvironment.set(sessionID, variables: payload.variables)
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            }
        },
        // POST /api/session/:sessionID/fork
        ServerRoute(
            method: .post,
            pathTemplate: "/api/session/:sessionID/fork",
            endpointName: "session.fork",
            groupIdentifier: "server.session"
        ) { ctx in
            struct ForkPayload: Decodable { let before: SessionMessageSchema.ID? }
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let payload = try ctx.decodeOptionalJSONBody(ForkPayload.self) ?? ForkPayload(before: nil)
            do {
                let forked = try await ctx.runtime.session.fork(sessionID: sessionID, before: payload.before)
                return ServerHTTPResponse.json(ServerDataWrapper(data: forked))
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            } catch let e as CoreSessionErrors.MessageNotFoundError {
                throw missingMessage(e)
            } catch let e as CoreSessionErrors.ForkEmptyError {
                throw InvalidRequestError(message: e.description, kind: "empty_session")
            }
        },
        // POST /api/session/:sessionID/agent
        ServerRoute(
            method: .post,
            pathTemplate: "/api/session/:sessionID/agent",
            endpointName: "session.switchAgent",
            groupIdentifier: "server.session"
        ) { ctx in
            struct AgentPayload: Decodable { let agent: String }
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let payload = try ctx.decodeJSONBody(AgentPayload.self)
            do {
                try await ctx.runtime.session.selectAgent(sessionID: sessionID, agent: payload.agent)
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            }
        },
        // POST /api/session/:sessionID/model
        ServerRoute(
            method: .post,
            pathTemplate: "/api/session/:sessionID/model",
            endpointName: "session.switchModel",
            groupIdentifier: "server.session"
        ) { ctx in
            struct ModelPayload: Decodable { let model: SessionSchema.ModelRef }
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let payload = try ctx.decodeJSONBody(ModelPayload.self)
            do {
                try await ctx.runtime.session.selectModel(sessionID: sessionID, model: payload.model)
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            }
        },
        // PATCH /api/session/:sessionID
        ServerRoute(
            method: .patch,
            pathTemplate: "/api/session/:sessionID",
            endpointName: "session.update",
            groupIdentifier: "server.session"
        ) { ctx in
            struct UpdatePayload: Decodable {
                let title: String?
                let metadata: SessionSchema.Metadata?
                let permissions: SessionSchema.PermissionRuleset?
                let archived: Bool?
            }
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let payload = try ctx.decodeJSONBody(UpdatePayload.self)
            let info: SessionSchema.Info
            do {
                info = try ctx.runtime.session.get(sessionID)
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            }
            if let title = payload.title {
                if !title.isEmpty {
                    try await ctx.runtime.session.rename(sessionID: sessionID, title: title)
                } else {
                    let locRef = LocationSchema.Ref(
                        directory: SchemaPrimitive.AbsolutePath(rawValue: info.location.directory),
                        workspaceID: info.location.workspaceID
                    )
                    let loc = try await ctx.runtime.resolveLocation(locRef)
                    try await loc.sessionTitle?.generate(sessionID)
                }
            }
            if let metadata = payload.metadata {
                _ = try await ctx.runtime.bus.publish(
                    SessionEventSchema.MetadataUpdated,
                    data: SessionEventSchema.MetadataUpdatedData(sessionID: sessionID, metadata: metadata)
                )
            }
            if let permissions = payload.permissions {
                _ = try await ctx.runtime.bus.publish(
                    SessionEventSchema.Permissions,
                    data: SessionEventSchema.PermissionsData(sessionID: sessionID, permissions: permissions)
                )
            }
            if let archived = payload.archived {
                if archived {
                    try await ctx.runtime.session.archive(sessionID)
                } else {
                    try await ctx.runtime.session.unarchive(sessionID)
                }
            }
            return ServerHTTPResponse.empty(statusCode: 204)
        },
        // POST /api/session/:sessionID/move
        ServerRoute(
            method: .post,
            pathTemplate: "/api/session/:sessionID/move",
            endpointName: "session.move",
            groupIdentifier: "server.session"
        ) { ctx in
            struct MovePayload: Decodable {
                let directory: SchemaPrimitive.AbsolutePath
                let delivery: SessionInboxSchema.Delivery?
            }
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let payload = try ctx.decodeJSONBody(MovePayload.self)
            do {
                try await ctx.runtime.sessionMove.move(
                    CoreSessionMove.MoveInput(
                        sessionID: sessionID,
                        directory: payload.directory.rawValue,
                        delivery: payload.delivery ?? .steer
                    )
                )
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            } catch let e as CoreSessionMove.DestinationNotFoundError {
                throw InvalidRequestError(message: "Directory does not exist: \(e.directory)")
            } catch let e as CoreSessionMove.DestinationNotDirectoryError {
                throw InvalidRequestError(message: "Not a directory: \(e.directory)")
            } catch let e as CoreSessionMove.DestinationUnavailableError {
                throw InvalidRequestError(message: "Directory is unavailable: \(e.directory)")
            }
        },
        // POST /api/session/:sessionID/prompt
        ServerRoute(
            method: .post,
            pathTemplate: "/api/session/:sessionID/prompt",
            endpointName: "session.prompt",
            groupIdentifier: "server.session",
            requiresSessionLocation: true
        ) { ctx in
            struct PromptPayload: Decodable {
                let id: SessionMessageSchema.ID?
                let text: String?
                let files: [PromptInputSchema.FileAttachment]?
                let agents: [PromptSchema.AgentAttachment]?
                let skills: [PromptInputSchema.SkillAttachment]?
                let metadata: SessionSchema.Metadata?
                let delivery: SessionInboxSchema.Delivery?
                let resume: Bool?
            }
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let payload = try ctx.decodeJSONBody(PromptPayload.self)
            do {
                let admitted = try await ctx.runtime.session.prompt(
                    CoreSession.PromptRequest(
                        sessionID: sessionID,
                        id: payload.id,
                        input: CoreSessionPrompt.Input(
                            text: payload.text ?? "",
                            files: payload.files,
                            agents: payload.agents,
                            skills: payload.skills,
                            metadata: payload.metadata,
                            delivery: payload.delivery
                        ),
                        resume: payload.resume
                    )
                )
                guard case .user(let userItem) = admitted else {
                    throw ConflictError(
                        message: "Prompt message ID conflicts with an existing durable record: \(admitted.id.rawValue)",
                        resource: admitted.id.rawValue
                    )
                }
                return ServerHTTPResponse.json(ServerDataWrapper(data: userItem))
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            } catch let e as CoreSessionErrors.PromptConflictError {
                throw ConflictError(
                    message: "Prompt message ID conflicts with an existing durable record: \(e.messageID.rawValue)",
                    resource: e.messageID.rawValue
                )
            } catch let e as CoreSessionErrors.AttachmentError {
                throw InvalidRequestError(message: e.description, field: "files")
            } catch let e as CoreSessionErrors.SkillNotFoundError {
                throw InvalidRequestError(message: "Skill not found: \(e.skill)", field: "skills")
            }
        },
        // POST /api/session/:sessionID/command
        ServerRoute(
            method: .post,
            pathTemplate: "/api/session/:sessionID/command",
            endpointName: "session.command",
            groupIdentifier: "server.session",
            requiresSessionLocation: true
        ) { ctx in
            struct CommandPayload: Decodable {
                let name: String
                let text: String?
                let files: [PromptInputSchema.FileAttachment]?
                let agents: [PromptSchema.AgentAttachment]?
                let skills: [PromptInputSchema.SkillAttachment]?
                let delivery: SessionInboxSchema.Delivery?
            }
            let loc = try ctx.requireLocation()
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let payload = try ctx.decodeJSONBody(CommandPayload.self)
            do {
                _ = try ctx.runtime.session.get(sessionID)
                try await loc.command.execute(
                    name: payload.name,
                    invocation: CoreSubsystems.Command.Invocation(
                        sessionID: sessionID,
                        prompt: PromptInputSchema.Prompt(
                            text: payload.text ?? "",
                            files: payload.files,
                            agents: payload.agents,
                            skills: payload.skills
                        ),
                        delivery: payload.delivery ?? .steer
                    )
                )
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            } catch let e as CoreSubsystems.Command.NotFoundError {
                throw CommandNotFoundError(command: e.command, message: e.description)
            } catch let e as CoreSubsystems.Command.ExecutionError {
                throw CommandExecutionError(command: e.command, message: e.description)
            }
        },
        // POST /api/experimental/session/:sessionID/skill
        ServerRoute(
            method: .post,
            pathTemplate: "/api/experimental/session/:sessionID/skill",
            endpointName: "session.skill",
            groupIdentifier: "server.session",
            openAPIIdentifier: "experimental.session.skill",
            requiresSessionLocation: true
        ) { ctx in
            struct SkillPayload: Decodable {
                let id: SkillSchema.ID
                let resume: Bool?
            }
            let loc = try ctx.requireLocation()
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let payload = try ctx.decodeJSONBody(SkillPayload.self)
            do {
                let sessionInfo = try ctx.runtime.session.get(sessionID)
                guard let skillInfo = await loc.skill.get(payload.id) else {
                    throw SkillNotFoundError(skill: payload.id.rawValue, message: "Skill not found: \(payload.id.rawValue)")
                }
                let files = await loc.skill.files(payload.id) ?? [:]
                let body = skillInfo.content.isEmpty
                    ? (files["SKILL.md"] ?? skillInfo.description ?? "")
                    : skillInfo.content
                _ = try await ctx.runtime.bus.publish(
                    SessionEventSchema.Skill.Activated,
                    data: SessionEventSchema.Skill.ActivatedData(
                        sessionID: sessionInfo.id,
                        id: skillInfo.id.rawValue,
                        name: skillInfo.name.rawValue,
                        text: body
                    ),
                    options: CoreBus.PublishOptions(location: sessionInfo.location)
                )
                if payload.resume != false {
                    await ctx.runtime.sessionExecution.wake(sessionInfo.id)
                }
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            } catch let e as CoreSessionErrors.SkillNotFoundError {
                throw SkillNotFoundError(skill: e.skill, message: "Skill not found: \(e.skill)")
            }
        },
        // POST /api/session/:sessionID/synthetic
        ServerRoute(
            method: .post,
            pathTemplate: "/api/session/:sessionID/synthetic",
            endpointName: "session.synthetic",
            groupIdentifier: "server.session"
        ) { ctx in
            struct SyntheticPayload: Decodable {
                let id: SessionMessageSchema.ID?
                let text: String
                let description: String?
                let metadata: SessionSchema.Metadata?
                let delivery: SessionInboxSchema.Delivery?
                let resume: Bool?
            }
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let payload = try ctx.decodeJSONBody(SyntheticPayload.self)
            do {
                let admitted = try await ctx.runtime.session.synthetic(
                    CoreSessionSynthetic.Request(
                        sessionID: sessionID,
                        id: payload.id,
                        text: payload.text,
                        description: payload.description,
                        metadata: payload.metadata,
                        delivery: payload.delivery,
                        resume: payload.resume
                    )
                )
                guard case .synthetic(let synth) = admitted else {
                    throw ConflictError(
                        message: "Synthetic input ID conflicts with an existing durable record: \(admitted.id.rawValue)",
                        resource: admitted.id.rawValue
                    )
                }
                return ServerHTTPResponse.json(ServerDataWrapper(data: synth))
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            } catch let e as CoreSessionErrors.SyntheticConflictError {
                throw ConflictError(
                    message: "Synthetic input ID conflicts with an existing durable record: \(e.inputID.rawValue)",
                    resource: e.inputID.rawValue
                )
            }
        },
        // POST /api/session/:sessionID/shell
        ServerRoute(
            method: .post,
            pathTemplate: "/api/session/:sessionID/shell",
            endpointName: "session.shell",
            groupIdentifier: "server.session",
            requiresSessionLocation: true
        ) { ctx in
            struct ShellPayload: Decodable {
                let id: SessionMessageSchema.ID?
                let command: String
            }
            let loc = try ctx.requireLocation()
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let payload = try ctx.decodeJSONBody(ShellPayload.self)
            do {
                let sessionInfo = try ctx.runtime.session.get(sessionID)
                let started = try await loc.shell.create(
                    CoreShell.CreateRequest(
                        command: payload.command,
                        cwd: sessionInfo.location.directory
                    ),
                    before: nil
                )
                let startTime = SessionMessageSchema.ShellTime(started: Int64(started.time.started), completed: nil)
                let startWire = SessionMessageSchema.ShellInfo(
                    id: payload.id?.rawValue ?? started.id.rawValue,
                    status: .running,
                    command: started.command,
                    cwd: started.cwd,
                    shell: started.shell,
                    file: started.file,
                    pid: started.pid?.rawValue,
                    exit: started.exit,
                    signal: started.signal,
                    metadata: started.metadata,
                    time: startTime
                )
                _ = try await ctx.runtime.bus.publish(
                    SessionEventSchema.Shell.Started,
                    data: SessionEventSchema.Shell.StartedData(sessionID: sessionInfo.id, shell: startWire),
                    options: CoreBus.PublishOptions(location: sessionInfo.location)
                )
                let finalInfo = try await loc.shell.wait(started.id)
                let out = try? await loc.shell.output(started.id, input: nil)
                let endStatus = SessionMessageSchema.ShellStatus(rawValue: finalInfo.status.rawValue) ?? .exited
                let endWire = SessionMessageSchema.ShellInfo(
                    id: payload.id?.rawValue ?? finalInfo.id.rawValue,
                    status: endStatus,
                    command: finalInfo.command,
                    cwd: finalInfo.cwd,
                    shell: finalInfo.shell,
                    file: finalInfo.file,
                    pid: finalInfo.pid?.rawValue,
                    exit: finalInfo.exit,
                    signal: finalInfo.signal,
                    metadata: finalInfo.metadata,
                    time: SessionMessageSchema.ShellTime(
                        started: Int64(finalInfo.time.started),
                        completed: finalInfo.time.completed.map(Int64.init)
                    )
                )
                let outWire = SessionMessageSchema.ShellOutput(
                    output: out?.output ?? "",
                    cursor: out?.cursor.rawValue ?? 0,
                    size: out?.size.rawValue ?? 0,
                    truncated: out?.truncated ?? false
                )
                _ = try await ctx.runtime.bus.publish(
                    SessionEventSchema.Shell.Ended,
                    data: SessionEventSchema.Shell.EndedData(sessionID: sessionInfo.id, shell: endWire, output: outWire),
                    options: CoreBus.PublishOptions(location: sessionInfo.location)
                )
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            }
        },
        // POST /api/session/:sessionID/compact
        ServerRoute(
            method: .post,
            pathTemplate: "/api/session/:sessionID/compact",
            endpointName: "session.compact",
            groupIdentifier: "server.session"
        ) { ctx in
            struct CompactPayload: Decodable {
                let id: SessionMessageSchema.ID?
                let delivery: SessionInboxSchema.Delivery?
            }
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let payload = try ctx.decodeOptionalJSONBody(CompactPayload.self) ?? CompactPayload(id: nil, delivery: nil)
            do {
                let admitted = try await ctx.runtime.session.compact(
                    CoreSession.CompactRequest(sessionID: sessionID, id: payload.id, delivery: payload.delivery)
                )
                return ServerHTTPResponse.json(ServerDataWrapper(data: admitted))
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            } catch let e as CoreSessionErrors.CompactionConflictError {
                throw ConflictError(
                    message: "Compaction input ID conflicts with an existing durable record: \(e.inputID.rawValue)",
                    resource: e.inputID.rawValue
                )
            }
        },
        // POST /api/experimental/session/:sessionID/wait
        ServerRoute(
            method: .post,
            pathTemplate: "/api/experimental/session/:sessionID/wait",
            endpointName: "session.wait",
            groupIdentifier: "server.session",
            openAPIIdentifier: "experimental.session.wait"
        ) { ctx in
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            do {
                try await ctx.runtime.session.awaitIdle(sessionID)
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            }
        },
        // POST /api/session/:sessionID/revert/stage
        ServerRoute(
            method: .post,
            pathTemplate: "/api/session/:sessionID/revert/stage",
            endpointName: "session.revert.stage",
            groupIdentifier: "server.session",
            requiresSessionLocation: true
        ) { ctx in
            struct StagePayload: Decodable {
                let messageID: SessionMessageSchema.ID
                let files: Bool?
            }
            let loc = try ctx.requireLocation()
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let payload = try ctx.decodeJSONBody(StagePayload.self)
            do {
                let info = try ctx.runtime.session.get(sessionID)
                if await ctx.runtime.sessionExecution.isActive(sessionID) {
                    throw SessionBusyError(sessionID: sessionID.rawValue, message: "Session is busy: \(sessionID.rawValue)")
                }
                let snapshotBridge: any CoreSessionSnapshotBridge =
                    (loc.sessionRunner as? ServerLiveRuntime.LiveSessionRunner)?.snapshotBridge
                    ?? CoreSessionLiveSnapshotBridge(service: loc.snapshot)
                let revert = try await CoreSessionRevert.stage(
                    db: ctx.runtime.db,
                    bus: ctx.runtime.bus,
                    session: info,
                    messageID: payload.messageID,
                    restoreFiles: payload.files ?? true,
                    snapshot: snapshotBridge
                )
                return ServerHTTPResponse.json(ServerDataWrapper(data: revert))
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            } catch let e as CoreSessionErrors.MessageNotFoundError {
                throw missingMessage(e)
            } catch let e as CoreSessionErrors.BusyError {
                throw SessionBusyError(sessionID: e.sessionID.rawValue, message: "Session is busy: \(e.sessionID.rawValue)")
            } catch let e as CoreSnapshot.SnapshotError {
                throw failedSnapshot(operation: "stage session revert", sessionID: sessionID)(e)
            }
        },
        // DELETE /api/session/:sessionID/revert
        ServerRoute(
            method: .delete,
            pathTemplate: "/api/session/:sessionID/revert",
            endpointName: "session.revert.clear",
            groupIdentifier: "server.session",
            requiresSessionLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            do {
                let info = try ctx.runtime.session.get(sessionID)
                if await ctx.runtime.sessionExecution.isActive(sessionID) {
                    throw SessionBusyError(sessionID: sessionID.rawValue, message: "Session is busy: \(sessionID.rawValue)")
                }
                let snapshotBridge: any CoreSessionSnapshotBridge =
                    (loc.sessionRunner as? ServerLiveRuntime.LiveSessionRunner)?.snapshotBridge
                    ?? CoreSessionLiveSnapshotBridge(service: loc.snapshot)
                try await CoreSessionRevert.clear(
                    bus: ctx.runtime.bus,
                    session: info,
                    snapshot: snapshotBridge
                )
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            } catch let e as CoreSessionErrors.BusyError {
                throw SessionBusyError(sessionID: e.sessionID.rawValue, message: "Session is busy: \(e.sessionID.rawValue)")
            } catch let e as CoreSnapshot.SnapshotError {
                throw failedSnapshot(operation: "clear session revert", sessionID: sessionID)(e)
            }
        },
        // POST /api/session/:sessionID/revert/commit
        ServerRoute(
            method: .post,
            pathTemplate: "/api/session/:sessionID/revert/commit",
            endpointName: "session.revert.commit",
            groupIdentifier: "server.session"
        ) { ctx in
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            do {
                let info = try ctx.runtime.session.get(sessionID)
                if await ctx.runtime.sessionExecution.isActive(sessionID) {
                    throw SessionBusyError(sessionID: sessionID.rawValue, message: "Session is busy: \(sessionID.rawValue)")
                }
                try await CoreSessionRevert.commit(bus: ctx.runtime.bus, session: info)
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            } catch let e as CoreSessionErrors.BusyError {
                throw SessionBusyError(sessionID: e.sessionID.rawValue, message: "Session is busy: \(e.sessionID.rawValue)")
            }
        },
        // GET /api/session/:sessionID/context
        ServerRoute(
            method: .get,
            pathTemplate: "/api/session/:sessionID/context",
            endpointName: "session.context",
            groupIdentifier: "server.session"
        ) { ctx in
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            do {
                _ = try ctx.runtime.session.get(sessionID)
                let contextMessages = try ctx.runtime.sessionStore.context(sessionID)
                return ServerHTTPResponse.json(ServerDataWrapper(data: contextMessages))
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            } catch let e as CoreSessionErrors.MessageDecodeError {
                throw failedMessageDecode(e)
            }
        },
        // GET /api/session/:sessionID/diff
        ServerRoute(
            method: .get,
            pathTemplate: "/api/session/:sessionID/diff",
            endpointName: "session.diff",
            groupIdentifier: "server.session"
        ) { ctx in
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            do {
                let info = try ctx.runtime.session.get(sessionID)
                let rawFrom = ctx.request.query("from")
                let rawTo = ctx.request.query("to")
                let fromID: SessionMessageSchema.ID?
                if let rawFrom {
                    guard let parsed = SessionMessageSchema.ID(rawValue: rawFrom) else {
                        throw InvalidRequestError(message: "Invalid from message ID", kind: "Query", field: "from")
                    }
                    fromID = parsed
                } else {
                    fromID = try ctx.runtime.sessionStore.messages(
                        CoreSessionStore.MessagesInput(sessionID: sessionID, limit: 1, order: .desc, type: .user)
                    ).first?.id
                }
                guard let resolvedFrom = fromID else {
                    return ServerHTTPResponse.json(ServerDataWrapper(data: [FileDiffSchema.Info]()))
                }
                let resolvedTo: SessionMessageSchema.ID
                if let rawTo {
                    guard let parsed = SessionMessageSchema.ID(rawValue: rawTo) else {
                        throw InvalidRequestError(message: "Invalid to message ID", kind: "Query", field: "to")
                    }
                    resolvedTo = resolveTurnEndMessageID(
                        db: ctx.runtime.db,
                        sessionID: sessionID,
                        fromID: resolvedFrom,
                        toID: parsed,
                        explicitTo: true
                    )
                } else {
                    resolvedTo = resolveTurnEndMessageID(
                        db: ctx.runtime.db,
                        sessionID: sessionID,
                        fromID: resolvedFrom,
                        toID: resolvedFrom,
                        explicitTo: false
                    )
                }
                let locRef = LocationSchema.Ref(
                    directory: SchemaPrimitive.AbsolutePath(rawValue: info.location.directory),
                    workspaceID: info.location.workspaceID
                )
                let loc = try await ctx.runtime.resolveLocation(locRef)
                let snapshotBridge: any CoreSessionSnapshotBridge =
                    (loc.sessionRunner as? ServerLiveRuntime.LiveSessionRunner)?.snapshotBridge
                    ?? CoreSessionLiveSnapshotBridge(service: loc.snapshot)
                let diffs = try await CoreSessionDiff.turn(
                    db: ctx.runtime.db,
                    session: info,
                    from: resolvedFrom,
                    to: resolvedTo,
                    snapshot: snapshotBridge
                )
                return ServerHTTPResponse.json(ServerDataWrapper(data: diffs))
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            } catch let e as CoreSessionErrors.MessageNotFoundError {
                throw missingMessage(e)
            } catch let e as CoreSessionDiff.TurnRangeError {
                throw InvalidRequestError(message: e.description)
            } catch let e as CoreSnapshot.SnapshotError {
                throw failedSnapshot(operation: "diff session turn", sessionID: sessionID)(e)
            }
        },
        // GET /api/session/:sessionID/inbox
        ServerRoute(
            method: .get,
            pathTemplate: "/api/session/:sessionID/inbox",
            endpointName: "session.inbox.list",
            groupIdentifier: "server.session"
        ) { ctx in
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            do {
                _ = try ctx.runtime.session.get(sessionID)
                let items = try ctx.runtime.sessionInbox.list(sessionID)
                if wantsMediaRefs(ctx.request) {
                    let encoded = try items.map { try ServerCodec.toJSONValue($0) }
                    return ServerHTTPResponse.json(SessionMediaInboxResponse(data: encoded))
                }
                return ServerHTTPResponse.json(ServerDataWrapper(data: items))
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            }
        },
        // DELETE /api/session/:sessionID/inbox/:inboxID
        ServerRoute(
            method: .delete,
            pathTemplate: "/api/session/:sessionID/inbox/:inboxID",
            endpointName: "session.inbox.cancel",
            groupIdentifier: "server.session"
        ) { ctx in
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let rawInboxID = try ctx.requireParam("inboxID")
            guard let inboxID = SessionMessageSchema.ID(rawValue: rawInboxID) else {
                throw InvalidRequestError(message: "Invalid inbox ID: \(rawInboxID)", kind: "Params", field: "inboxID")
            }
            do {
                _ = try ctx.runtime.session.get(sessionID)
                try await ctx.runtime.sessionInbox.cancel(sessionID: sessionID, id: inboxID)
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            } catch is CoreSessionErrors.InboxConflictError {
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch is CoreSessionInbox.LifecycleConflict {
                return ServerHTTPResponse.empty(statusCode: 204)
            }
        },
        // PATCH /api/session/:sessionID/inbox/:inboxID
        ServerRoute(
            method: .patch,
            pathTemplate: "/api/session/:sessionID/inbox/:inboxID",
            endpointName: "session.inbox.update",
            groupIdentifier: "server.session"
        ) { ctx in
            struct InboxUpdatePayload: Decodable { let delivery: SessionInboxSchema.Delivery }
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let rawInboxID = try ctx.requireParam("inboxID")
            guard let inboxID = SessionMessageSchema.ID(rawValue: rawInboxID) else {
                throw InvalidRequestError(message: "Invalid inbox ID: \(rawInboxID)", kind: "Params", field: "inboxID")
            }
            let payload = try ctx.decodeJSONBody(InboxUpdatePayload.self)
            do {
                _ = try ctx.runtime.session.get(sessionID)
                if payload.delivery == .steer {
                    try await ctx.runtime.sessionInbox.steer(sessionID: sessionID, id: inboxID)
                    await ctx.runtime.sessionExecution.wake(sessionID)
                } else {
                    try await ctx.runtime.sessionInbox.queue(sessionID: sessionID, id: inboxID)
                }
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            } catch let e as CoreSessionErrors.InboxConflictError {
                throw ConflictError(
                    message: "Pending input cannot change to \(payload.delivery.rawValue): \(e.inboxID.rawValue)",
                    resource: e.inboxID.rawValue
                )
            } catch is CoreSessionInbox.LifecycleConflict {
                throw ConflictError(
                    message: "Pending input cannot change to \(payload.delivery.rawValue): \(inboxID.rawValue)",
                    resource: inboxID.rawValue
                )
            }
        },
        // GET /api/experimental/session/:sessionID/instructions/entries
        ServerRoute(
            method: .get,
            pathTemplate: "/api/experimental/session/:sessionID/instructions/entries",
            endpointName: "session.instructions.entry.list",
            groupIdentifier: "server.session",
            openAPIIdentifier: "experimental.session.instructions.entry.list"
        ) { ctx in
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            do {
                _ = try ctx.runtime.session.get(sessionID)
                let entries = try ctx.runtime.sessionInstructions.list(sessionID)
                let wire = entries.compactMap { entry -> InstructionEntrySchema.Info? in
                    guard let key = InstructionEntrySchema.Key(rawValue: entry.key) else { return nil }
                    return InstructionEntrySchema.Info(key: key, value: entry.value)
                }
                return ServerHTTPResponse.json(ServerDataWrapper(data: wire))
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            }
        },
        // PUT /api/experimental/session/:sessionID/instructions/entries/:key
        ServerRoute(
            method: .put,
            pathTemplate: "/api/experimental/session/:sessionID/instructions/entries/:key",
            endpointName: "session.instructions.entry.put",
            groupIdentifier: "server.session",
            openAPIIdentifier: "experimental.session.instructions.entry.put"
        ) { ctx in
            struct PutPayload: Decodable { let value: JSONValue }
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let rawKey = try ctx.requireParam("key")
            guard let validatedKey = InstructionEntrySchema.Key(rawValue: rawKey) else {
                throw InvalidRequestError(message: "Invalid instruction entry key: \(rawKey)", kind: "Params", field: "key")
            }
            let payload = try ctx.decodeJSONBody(PutPayload.self)
            do {
                _ = try ctx.runtime.session.get(sessionID)
                try ctx.runtime.sessionInstructions.put(sessionID: sessionID, key: validatedKey.rawValue, value: payload.value)
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            } catch let e as CoreSessionInstructionEntry.ValueTooLargeError {
                throw InstructionEntrySchema.ValueTooLargeError(
                    actualBytes: e.actualBytes,
                    maxBytes: e.maxBytes,
                    message: e.message
                )
            }
        },
        // DELETE /api/experimental/session/:sessionID/instructions/entries/:key
        ServerRoute(
            method: .delete,
            pathTemplate: "/api/experimental/session/:sessionID/instructions/entries/:key",
            endpointName: "session.instructions.entry.remove",
            groupIdentifier: "server.session",
            openAPIIdentifier: "experimental.session.instructions.entry.remove"
        ) { ctx in
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let rawKey = try ctx.requireParam("key")
            guard let validatedKey = InstructionEntrySchema.Key(rawValue: rawKey) else {
                throw InvalidRequestError(message: "Invalid instruction entry key: \(rawKey)", kind: "Params", field: "key")
            }
            do {
                _ = try ctx.runtime.session.get(sessionID)
                try ctx.runtime.sessionInstructions.remove(sessionID: sessionID, key: validatedKey.rawValue)
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            }
        },
        // POST /api/session/:sessionID/generate
        ServerRoute(
            method: .post,
            pathTemplate: "/api/session/:sessionID/generate",
            endpointName: "session.generate",
            groupIdentifier: "server.session",
            requiresSessionLocation: true
        ) { ctx in
            struct GeneratePayload: Decodable { let prompt: String }
            struct GenerateResult: Encodable {
                let text: String
                let tokens: TokenUsageSchema.Info
                let cost: MoneySchema.USD
            }
            let loc = try ctx.requireLocation()
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let payload = try ctx.decodeJSONBody(GeneratePayload.self)
            do {
                let info = try ctx.runtime.session.get(sessionID)
                let modelRef = info.model.map {
                    ModelSchema.Ref(
                        id: ModelSchema.ID(rawValue: $0.id),
                        providerID: ProviderSchema.ID(rawValue: $0.providerID),
                        variant: $0.variant.map { ModelSchema.VariantID(rawValue: $0) }
                    )
                }
                let text = try await loc.generate.text(
                    CoreIntegration.Generate.TextInput(prompt: payload.prompt, model: modelRef)
                )
                return ServerHTTPResponse.json(ServerDataWrapper(data: GenerateResult(
                    text: text,
                    tokens: TokenUsageSchema.Info(input: 0, output: 0, reasoning: 0, cache: TokenUsageSchema.Cache(read: 0, write: 0)),
                    cost: MoneySchema.USD(rawValue: 0)!
                )))
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            } catch {
                throw ServiceUnavailableError(message: String(describing: error), service: "session generation")
            }
        },
        // GET /api/experimental/session/:sessionID/log
        ServerRoute(
            method: .get,
            pathTemplate: "/api/experimental/session/:sessionID/log",
            endpointName: "session.log",
            groupIdentifier: "server.session",
            openAPIIdentifier: "experimental.session.log"
        ) { ctx in
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            do {
                _ = try ctx.runtime.session.get(sessionID)
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            }
            let after = try parseInt64Query(ctx.request.query("after"), field: "after")
            let follow = try parseBoolQuery(ctx.request.query("follow")) ?? false
            let logStream = ctx.runtime.bus.log(CoreBus.LogInput(
                aggregateID: sessionID.rawValue,
                after: after,
                follow: follow
            ))
            let sseChunks = AsyncThrowingStream<[UInt8], Error> { continuation in
                let task = Task {
                    for await item in logStream {
                        if Task.isCancelled { break }
                        switch item {
                        case .event(let ev):
                            let wire = OpenCodeEvent(
                                id: ev.id.rawValue,
                                type: ev.type,
                                created: Double(ev.created),
                                metadata: ev.metadata,
                                location: ev.location,
                                data: ev.data
                            )
                            continuation.yield(Array(EventFeed.frameUnsafe(wire).utf8))
                        case .synced(let synced):
                            if let json = try? ServerCodec.encodeString(synced) {
                                continuation.yield(Array("data: \(json)\n\n".utf8))
                            }
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return ServerHTTPResponse.stream(
                sseChunks,
                statusCode: 200,
                contentType: "text/event-stream",
                headers: ServerSSEStream.sseHeaders
            )
        },
        // POST /api/session/:sessionID/interrupt
        ServerRoute(
            method: .post,
            pathTemplate: "/api/session/:sessionID/interrupt",
            endpointName: "session.interrupt",
            groupIdentifier: "server.session"
        ) { ctx in
            struct InterruptResult: Encodable { let interrupted: Bool }
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let resume = try parseBoolQuery(ctx.request.query("resume")) ?? false
            do {
                let interrupted = try await ctx.runtime.session.interrupt(sessionID, resume: resume)
                return ServerHTTPResponse.json(InterruptResult(interrupted: interrupted))
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            }
        },
        // POST /api/session/:sessionID/background
        ServerRoute(
            method: .post,
            pathTemplate: "/api/session/:sessionID/background",
            endpointName: "session.background",
            groupIdentifier: "server.session"
        ) { ctx in
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            do {
                _ = try ctx.runtime.session.get(sessionID)
                _ = try await ctx.runtime.job.backgroundAll(CoreJob.BackgroundAllInput(sessionID: sessionID))
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            }
        },
        // GET /api/session/:sessionID/message/:messageID
        ServerRoute(
            method: .get,
            pathTemplate: "/api/session/:sessionID/message/:messageID",
            endpointName: "session.message",
            groupIdentifier: "server.session",
            openAPIIdentifier: "session.message.get"
        ) { ctx in
            let sessionID = try parseValidatedSessionID(try ctx.requireParam("sessionID"))
            let rawMsgID = try ctx.requireParam("messageID")
            guard let msgID = SessionMessageSchema.ID(rawValue: rawMsgID) else {
                throw InvalidRequestError(message: "Invalid message ID: \(rawMsgID)", kind: "Params", field: "messageID")
            }
            do {
                _ = try ctx.runtime.session.get(sessionID)
                if wantsMediaRefs(ctx.request) {
                    if let found = try ctx.runtime.sessionStore.messageWithRefs(msgID), found.sessionID == sessionID {
                        return ServerHTTPResponse.json(ServerDataWrapper(data: found.message))
                    }
                } else {
                    if let found = try ctx.runtime.sessionStore.message(msgID), found.sessionID == sessionID {
                        return ServerHTTPResponse.json(ServerDataWrapper(data: found.message))
                    }
                }
                throw MessageNotFoundError(
                    sessionID: sessionID.rawValue,
                    messageID: rawMsgID,
                    message: "Message not found: \(rawMsgID)"
                )
            } catch let e as CoreSessionErrors.NotFoundError {
                throw missingSession(e)
            }
        },
        // GET /api/session/:sessionID/form
        ServerRoute(
            method: .get,
            pathTemplate: "/api/session/:sessionID/form",
            endpointName: "session.form.list",
            groupIdentifier: "server.session",
            requiresFormLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let rawSessionID = try ctx.requireParam("sessionID")
            let forms = await loc.form.list(CoreIntegration.Form.ListInput(sessionID: rawSessionID))
            return ServerHTTPResponse.json(ServerDataWrapper(data: forms))
        },
        // POST /api/session/:sessionID/form
        ServerRoute(
            method: .post,
            pathTemplate: "/api/session/:sessionID/form",
            endpointName: "session.form.create",
            groupIdentifier: "server.session",
            requiresFormLocation: true
        ) { ctx in
            struct CreateFormPayload: Decodable {
                let id: FormSchema.ID?
                let title: String
                let metadata: [String: JSONValue]?
                let fields: FormSchema.Fields
            }
            let loc = try ctx.requireLocation()
            let rawSessionID = try ctx.requireParam("sessionID")
            let payload = try ctx.decodeJSONBody(CreateFormPayload.self)
            do {
                let created = try await loc.form.create(
                    CoreIntegration.Form.CreateInput(
                        id: payload.id,
                        sessionID: rawSessionID,
                        title: payload.title,
                        metadata: payload.metadata,
                        fields: payload.fields
                    )
                )
                return ServerHTTPResponse.json(ServerDataWrapper(data: created))
            } catch let e as CoreIntegration.Form.AlreadyExistsError {
                throw ConflictError(message: e.description, resource: e.id.rawValue)
            } catch let e as CoreIntegration.Form.InvalidFormError {
                throw InvalidRequestError(message: e.description, field: "fields")
            }
        },
        // GET /api/session/:sessionID/form/:formID
        ServerRoute(
            method: .get,
            pathTemplate: "/api/session/:sessionID/form/:formID",
            endpointName: "session.form.get",
            groupIdentifier: "server.session",
            requiresFormLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let rawSessionID = try ctx.requireParam("sessionID")
            let rawFormID = try ctx.requireParam("formID")
            guard let formID = FormSchema.ID(rawValue: rawFormID) else {
                throw InvalidRequestError(message: "Invalid form ID: \(rawFormID)", kind: "Params", field: "formID")
            }
            do {
                let info = try await loc.form.get(formID)
                guard info.sessionID == rawSessionID else {
                    throw FormNotFoundError(id: rawFormID, message: "Form not found: \(rawFormID)")
                }
                let state = try await loc.form.state(formID)
                let detail = FormSchema.Detail(
                    id: info.id,
                    sessionID: info.sessionID,
                    title: info.title,
                    metadata: info.metadata,
                    fields: info.fields,
                    state: state
                )
                return ServerHTTPResponse.json(ServerDataWrapper(data: detail))
            } catch is CoreIntegration.Form.NotFoundError {
                throw FormNotFoundError(id: rawFormID, message: "Form not found: \(rawFormID)")
            }
        },
        // POST /api/session/:sessionID/form/:formID/reply
        ServerRoute(
            method: .post,
            pathTemplate: "/api/session/:sessionID/form/:formID/reply",
            endpointName: "session.form.reply",
            groupIdentifier: "server.session",
            requiresFormLocation: true
        ) { ctx in
            struct ReplyPayload: Decodable { let answer: FormSchema.Answer }
            let loc = try ctx.requireLocation()
            let rawSessionID = try ctx.requireParam("sessionID")
            let rawFormID = try ctx.requireParam("formID")
            guard let formID = FormSchema.ID(rawValue: rawFormID) else {
                throw InvalidRequestError(message: "Invalid form ID: \(rawFormID)", kind: "Params", field: "formID")
            }
            let payload = try ctx.decodeJSONBody(ReplyPayload.self)
            do {
                let info = try await loc.form.get(formID)
                guard info.sessionID == rawSessionID else {
                    throw FormNotFoundError(id: rawFormID, message: "Form not found: \(rawFormID)")
                }
                try await loc.form.reply(CoreIntegration.Form.ReplyInput(id: formID, answer: payload.answer))
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch is CoreIntegration.Form.NotFoundError {
                throw FormNotFoundError(id: rawFormID, message: "Form not found: \(rawFormID)")
            } catch let e as CoreIntegration.Form.AlreadySettledError {
                throw FormAlreadySettledError(id: e.id.rawValue, message: e.description)
            } catch let e as CoreIntegration.Form.InvalidAnswerError {
                throw FormInvalidAnswerError(id: e.id.rawValue, message: e.description)
            }
        },
        // DELETE /api/session/:sessionID/form/:formID
        ServerRoute(
            method: .delete,
            pathTemplate: "/api/session/:sessionID/form/:formID",
            endpointName: "session.form.cancel",
            groupIdentifier: "server.session",
            requiresFormLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let rawSessionID = try ctx.requireParam("sessionID")
            let rawFormID = try ctx.requireParam("formID")
            guard let formID = FormSchema.ID(rawValue: rawFormID) else {
                throw InvalidRequestError(message: "Invalid form ID: \(rawFormID)", kind: "Params", field: "formID")
            }
            let message = ctx.request.query("message")
            do {
                let info = try await loc.form.get(formID)
                guard info.sessionID == rawSessionID else {
                    throw FormNotFoundError(id: rawFormID, message: "Form not found: \(rawFormID)")
                }
                try await loc.form.cancel(formID, options: CoreIntegration.Form.CancelOptions(message: message))
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch is CoreIntegration.Form.NotFoundError {
                throw FormNotFoundError(id: rawFormID, message: "Form not found: \(rawFormID)")
            } catch let e as CoreIntegration.Form.AlreadySettledError {
                throw FormAlreadySettledError(id: e.id.rawValue, message: e.description)
            }
        },
    ]
)

private struct SessionListCursorWire: Codable {
    let id: String
    let created: Int64
    let order: String
    let direction: String
}

private func encodeSessionListCursor(
    session: SessionSchema.Info,
    order: SessionSchema.SortOrder,
    direction: SessionSchema.ListAnchor.Direction
) -> SessionsCursor {
    let wire = SessionListCursorWire(
        id: session.id.rawValue,
        created: session.time.created,
        order: order.rawValue,
        direction: direction.rawValue
    )
    let bytes = (try? ServerCodec.encode(wire)) ?? []
    return SessionsCursor(rawValue: ServerCrypto.base64URLEncode(bytes))
}

private func decodeSessionListCursor(_ raw: String) -> (anchor: SessionSchema.ListAnchor, order: SessionSchema.SortOrder)? {
    guard let bytes = ServerCrypto.base64URLDecode(raw),
          let wire = try? ServerCodec.decode(SessionListCursorWire.self, from: bytes),
          let id = try? SessionID(validating: wire.id),
          let order = SessionSchema.SortOrder(rawValue: wire.order),
          let direction = SessionSchema.ListAnchor.Direction(rawValue: wire.direction) else {
        return nil
    }
    let anchor = SessionSchema.ListAnchor(id: id, time: wire.created, direction: direction)
    return (anchor, order)
}

private func parseValidatedSessionID(_ raw: String) throws -> SessionID {
    do {
        return try SessionID(validating: raw)
    } catch {
        throw InvalidRequestError(message: "Invalid session ID", kind: "Params", field: "sessionID")
    }
}

private func parseValidatedPtyID(_ raw: String) throws -> PtySchema.ID {
    guard let id = PtySchema.ID(rawValue: raw) else {
        throw InvalidRequestError(message: "Invalid PTY ID: \(raw)", kind: "Params", field: "ptyID")
    }
    return id
}

private func resolveTurnEndMessageID(
    db: any SQLiteDatabase,
    sessionID: SessionID,
    fromID: SessionMessageSchema.ID,
    toID: SessionMessageSchema.ID,
    explicitTo: Bool
) -> SessionMessageSchema.ID {
    guard let fromRow = try? db.queryOne(
        "SELECT `seq` FROM `session_message` WHERE `session_id` = ? AND `id` = ?",
        parameters: [.text(sessionID.rawValue), .text(fromID.rawValue)]
    ), let fromSeq = fromRow.int64("seq"),
          let toRow = try? db.queryOne(
              "SELECT `seq`, `type` FROM `session_message` WHERE `session_id` = ? AND `id` = ?",
              parameters: [.text(sessionID.rawValue), .text(toID.rawValue)]
          ), let toSeq = toRow.int64("seq"),
          let toType = toRow.string("type"),
          fromSeq <= toSeq
    else {
        return toID
    }
    if explicitTo && toType != "user" {
        return toID
    }

    let hasIdle = (try? db.queryOne(
        "SELECT 1 FROM `session_message` WHERE `session_id` = ? AND `type` = 'idle' LIMIT 1",
        parameters: [.text(sessionID.rawValue)]
    )) != nil
    let boundaryType = hasIdle ? "idle" : "user"
    let upperSeq = (try? db.queryOne(
        """
        SELECT `seq` FROM `session_message`
        WHERE `session_id` = ? AND `type` = ? AND `seq` > ?
        ORDER BY `seq` ASC LIMIT 1
        """,
        parameters: [.text(sessionID.rawValue), .text(boundaryType), .integer(toSeq)]
    ))?.int64("seq")

    let lastAssistantRow: SQLiteRow?
    if let upperSeq {
        lastAssistantRow = try? db.queryOne(
            """
            SELECT `id` FROM `session_message`
            WHERE `session_id` = ? AND `type` = 'assistant' AND `seq` > ? AND `seq` < ?
            ORDER BY `seq` DESC LIMIT 1
            """,
            parameters: [.text(sessionID.rawValue), .integer(toSeq), .integer(upperSeq)]
        )
    } else {
        lastAssistantRow = try? db.queryOne(
            """
            SELECT `id` FROM `session_message`
            WHERE `session_id` = ? AND `type` = 'assistant' AND `seq` > ?
            ORDER BY `seq` DESC LIMIT 1
            """,
            parameters: [.text(sessionID.rawValue), .integer(toSeq)]
        )
    }
    if let rawID = lastAssistantRow?.string("id"), let parsed = SessionMessageSchema.ID(rawValue: rawID) {
        return parsed
    }
    return toID
}

private func isValidTimeZoneIdentifier(_ identifier: String) -> Bool {
    guard !identifier.isEmpty else { return false }
    if identifier == "UTC" || identifier == "GMT" { return true }
    return TimeZone(identifier: identifier) != nil
}

// MARK: - 14. Shell Handler (server/src/handlers/shell.ts)

/// Handlers for `server.shell` (`list`, `create`, `get`, `output`, `remove`).
// parity: server/src/handlers/shell.ts#ShellHandler [status=implemented hash=e0792e7d2209]
public let ShellHandler = ServerHandlerGroup(
    groupIdentifier: "server.shell",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/shell",
            endpointName: "shell.list",
            groupIdentifier: "server.shell",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let list = await loc.shell.list()
            return ServerHTTPResponse.json(response(location: loc, data: list))
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/shell",
            endpointName: "shell.create",
            groupIdentifier: "server.shell",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let payload = try ctx.decodeJSONBody(ShellSchema.CreateInput.self)
            let cwd = (payload.cwd?.isEmpty == false) ? payload.cwd! : loc.ref.directory.rawValue
            let created = try await loc.shell.create(
                CoreShell.CreateRequest(
                    command: payload.command,
                    cwd: cwd,
                    timeout: payload.timeout?.rawValue,
                    metadata: payload.metadata ?? [:]
                ),
                before: nil
            )
            return ServerHTTPResponse.json(response(location: loc, data: created))
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/shell/:id",
            endpointName: "shell.get",
            groupIdentifier: "server.shell",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let rawID = try ctx.requireParam("id")
            guard let id = ShellSchema.ID(rawValue: rawID) else {
                throw InvalidRequestError(message: "Invalid shell ID: \(rawID)", kind: "Params", field: "id")
            }
            do {
                let info = try await loc.shell.get(id)
                return ServerHTTPResponse.json(response(location: loc, data: info))
            } catch is CoreShell.NotFoundError {
                throw ShellNotFoundError(id: rawID, message: "Shell command not found: \(rawID)")
            }
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/shell/:id/output",
            endpointName: "shell.output",
            groupIdentifier: "server.shell",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let rawID = try ctx.requireParam("id")
            guard let id = ShellSchema.ID(rawValue: rawID) else {
                throw InvalidRequestError(message: "Invalid shell ID: \(rawID)", kind: "Params", field: "id")
            }
            let cursor = try parseIntQuery(ctx.request.query("cursor"), field: "cursor")
            let limit = try parseIntQuery(ctx.request.query("limit"), field: "limit")
            let cursorVal = cursor.flatMap(SchemaPrimitive.NonNegativeInt.init(rawValue:))
            let limitVal = limit.flatMap(SchemaPrimitive.NonNegativeInt.init(rawValue:))
            do {
                let output = try await loc.shell.output(id, input: ShellSchema.OutputInput(cursor: cursorVal, limit: limitVal))
                return ServerHTTPResponse.json(response(location: loc, data: output))
            } catch is CoreShell.NotFoundError {
                throw ShellNotFoundError(id: rawID, message: "Shell command not found: \(rawID)")
            }
        },
        ServerRoute(
            method: .delete,
            pathTemplate: "/api/shell/:id",
            endpointName: "shell.remove",
            groupIdentifier: "server.shell",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let rawID = try ctx.requireParam("id")
            guard let id = ShellSchema.ID(rawValue: rawID) else {
                throw InvalidRequestError(message: "Invalid shell ID: \(rawID)", kind: "Params", field: "id")
            }
            do {
                try await loc.shell.remove(id)
            } catch is CoreShell.NotFoundError {
                // Idempotent no-op matching upstream.
            }
            return ServerHTTPResponse.empty(statusCode: 204)
        },
    ]
)

// MARK: - 15. Skill Handler (server/src/handlers/skill.ts)

/// Handlers for `server.skill` (`GET /api/skill`).
// parity: server/src/handlers/skill.ts#SkillHandler [status=implemented hash=c3956f7bf128]
public let SkillHandler = ServerHandlerGroup(
    groupIdentifier: "server.skill",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/skill",
            endpointName: "skill.list",
            groupIdentifier: "server.skill",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let skills = await loc.skill.list()
            return ServerHTTPResponse.json(response(location: loc, data: skills))
        },
    ]
)

// MARK: - 16. Usage Handler (server/src/handlers/usage.ts)

/// Handlers for `server.usage` (`GET /api/experimental/usage/limits`).
// parity: server/src/handlers/usage.ts#UsageHandler [status=implemented hash=da135e847ce1]
public let UsageHandler = ServerHandlerGroup(
    groupIdentifier: "server.usage",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/experimental/usage/limits",
            endpointName: "usage.limits",
            groupIdentifier: "server.usage",
            openAPIIdentifier: "experimental.usage.limits",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            do {
                let info = try await loc.usageLimits.get()
                return ServerHTTPResponse.json(response(location: loc, data: info))
            } catch {
                throw ServiceUnavailableError(message: String(describing: error), service: "opencode")
            }
        },
    ]
)

// MARK: - 17. VCS Handler (server/src/handlers/vcs.ts)

/// Handlers for `server.vcs` (`init`, `get`, `base`, `status`, `branch.list`, `diff`).
// parity: server/src/handlers/vcs.ts#VcsHandler [status=implemented hash=2a99ce07fef1]
public let VcsHandler = ServerHandlerGroup(
    groupIdentifier: "server.vcs",
    routes: [
        ServerRoute(
            method: .post,
            pathTemplate: "/api/vcs/init",
            endpointName: "vcs.init",
            groupIdentifier: "server.vcs",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let directory = loc.location.info.project.directory
            let providerID = ctx.request.query("provider") ?? "git"
            do {
                try await loc.vcs.initialize(providerID: providerID)
            } catch let e as CoreVcs.Vcs.InitializeError {
                switch e.kind {
                case .missing:
                    throw InvalidRequestError(message: "Project directory does not exist", field: "location")
                case .conflict:
                    throw ConflictError(message: "Project already has version control", resource: directory.rawValue)
                case .unknown:
                    throw InvalidRequestError(message: "Unknown VCS provider", field: "provider")
                case .unsupported:
                    throw VcsInitNotSupportedError(providerID: providerID, message: "VCS provider does not support initialization")
                case .failed:
                    throw ServiceUnavailableError(message: "VCS initialization failed", service: providerID)
                }
            }
            let resolved = try await ctx.runtime.project.resolve(directory, options: CoreProject.Project.ResolveOptions(persist: true))
            guard resolved.vcs != nil else {
                throw ServiceUnavailableError(message: "VCS initialization failed", service: providerID)
            }
            await ctx.runtime.locations.invalidate(loc.ref)
            _ = try? await ctx.runtime.bus.publishRaw(
                definition: EventSchema.Definition(type: "worktree.updated", durability: .ephemeral),
                data: .object(["projectID": .string(resolved.id.rawValue)]),
                options: nil
            )
            return ServerHTTPResponse.empty(statusCode: 204)
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/vcs",
            endpointName: "vcs.get",
            groupIdentifier: "server.vcs",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let info = await loc.vcs.info()
            return ServerHTTPResponse.json(response(location: loc, data: info))
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/vcs/base",
            endpointName: "vcs.base",
            groupIdentifier: "server.vcs",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            do {
                let base = try await loc.vcs.base()
                return ServerHTTPResponse.json(response(location: loc, data: base))
            } catch {
                throw ServiceUnavailableError(message: String(describing: error), service: "vcs")
            }
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/vcs/status",
            endpointName: "vcs.status",
            groupIdentifier: "server.vcs",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let status = await loc.vcs.status()
            return ServerHTTPResponse.json(response(location: loc, data: status))
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/vcs/branch",
            endpointName: "vcs.branch.list",
            groupIdentifier: "server.vcs",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let search = ctx.request.query("search")
            let rawLimit = try parseIntQuery(ctx.request.query("limit"), field: "limit") ?? 50
            let limit = min(max(1, rawLimit), 100)
            let branches = await loc.vcs.branches(CoreVcs.Vcs.BranchOptions(search: search, limit: limit))
            return ServerHTTPResponse.json(response(location: loc, data: branches))
        },
        ServerRoute(
            method: .get,
            pathTemplate: "/api/vcs/diff",
            endpointName: "vcs.diff",
            groupIdentifier: "server.vcs",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            guard let rawMode = ctx.request.query("mode"), let mode = VcsSchema.Mode(rawValue: rawMode) else {
                throw InvalidRequestError(message: "Invalid or missing query parameter: mode", kind: "Query", field: "mode")
            }
            let base = ctx.request.query("base")
            let contextLines = try parseIntQuery(ctx.request.query("context"), field: "context")
            let untracked: VcsSchema.Untracked? = try ctx.request.query("untracked").map { raw in
                guard let parsed = VcsSchema.Untracked(rawValue: raw) else {
                    throw InvalidRequestError(message: "Invalid untracked option: \(raw)", kind: "Query", field: "untracked")
                }
                return parsed
            }
            do {
                let diffs = try await loc.vcs.diff(
                    mode,
                    options: CoreVcs.Vcs.DiffOptions(context: contextLines, base: base, untracked: untracked)
                )
                return ServerHTTPResponse.json(response(location: loc, data: diffs))
            } catch {
                throw ServiceUnavailableError(message: String(describing: error), service: "vcs")
            }
        },
    ]
)

// MARK: - 18. Voice Handler (server/src/handlers/voice.ts)

/// Handlers for `server.voice` (`GET /api/experimental/voice/models`, `POST /api/experimental/voice/session`).
// parity: server/src/handlers/voice.ts#VoiceHandler [status=implemented hash=52d0823cb1b8]
public let VoiceHandler = ServerHandlerGroup(
    groupIdentifier: "server.voice",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/experimental/voice/models",
            endpointName: "voice.models",
            groupIdentifier: "server.voice",
            openAPIIdentifier: "experimental.voice.models"
        ) { ctx in
            struct VoiceModelsWire: Encodable {
                let models: [VoiceModel]
                let defaultModel: String?
                private enum CodingKeys: String, CodingKey {
                    case models
                    case defaultModel = "default"
                }
            }
            let loc = try await resolveVoiceBaseLocation(ctx.runtime)
            let result = try await loc.voice.models()
            let wireModels = result.models.map { m in
                VoiceModel(
                    model: m.model,
                    provider: m.provider,
                    transports: m.transports.compactMap(VoiceTransportType.init(rawValue:)),
                    available: m.available
                )
            }
            return ServerHTTPResponse.json(ServerDataWrapper(
                data: VoiceModelsWire(models: wireModels, defaultModel: result.defaultModel)
            ))
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/experimental/voice/session",
            endpointName: "voice.session",
            groupIdentifier: "server.voice",
            openAPIIdentifier: "experimental.voice.session"
        ) { ctx in
            struct VoiceSessionPayload: Decodable {
                let model: String
                let transport: VoiceTransportInput
            }
            struct VoiceSessionWire: Encodable {
                let transport: JSONValue
            }
            let payload = try ctx.decodeJSONBody(VoiceSessionPayload.self)
            let loc = try await resolveVoiceBaseLocation(ctx.runtime)
            let transportKind: String
            switch payload.transport {
            case .webrtc: transportKind = "webrtc"
            case .websocket: transportKind = "websocket"
            }
            do {
                let transportObj = try await loc.voice.session(
                    CoreIntegration.Voice.SessionInput(model: payload.model, transport: transportKind)
                )
                return ServerHTTPResponse.json(ServerDataWrapper(data: VoiceSessionWire(transport: .object(transportObj))))
            } catch let e as CoreIntegration.Voice.InvalidRequestError {
                throw InvalidRequestError(message: e.message)
            } catch let e as CoreIntegration.Voice.UnavailableError {
                throw ServiceUnavailableError(message: e.message, service: e.service)
            } catch let e as CoreIntegration.Voice.VoiceError {
                switch e {
                case .invalidRequest(let inv): throw InvalidRequestError(message: inv.message)
                case .unavailable(let unavail): throw ServiceUnavailableError(message: unavail.message, service: unavail.service)
                }
            }
        },
    ]
)

private func resolveVoiceBaseLocation(_ runtime: ServerAppRuntime) async throws -> LocationServices {
    let ref = LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: runtime.global.config))
    if await runtime.fileSystem.exists(at: runtime.global.config) {
        return try await runtime.resolveLocation(ref)
    }
    return try await runtime.resolveLocation(
        LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: runtime.defaultDirectory))
    )
}

// MARK: - 19. WebSearch Handler (server/src/handlers/websearch.ts)

/// Handlers for `server.websearch` (`GET /api/websearch/provider`, `POST /api/websearch`).
// parity: server/src/handlers/websearch.ts#WebSearchHandler [status=implemented hash=9cbe51ece627]
public let WebSearchHandler = ServerHandlerGroup(
    groupIdentifier: "server.websearch",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/websearch/provider",
            endpointName: "websearch.providers",
            groupIdentifier: "server.websearch",
            requiresLocation: true
        ) { ctx in
            let loc = try ctx.requireLocation()
            let providers = await loc.webSearch.providers()
            return ServerHTTPResponse.json(response(location: loc, data: providers))
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/websearch",
            endpointName: "websearch.query",
            groupIdentifier: "server.websearch",
            requiresLocation: true
        ) { ctx in
            struct QueryPayload: Decodable {
                let query: String
                let providerID: WebSearchSchema.ID?
            }
            let loc = try ctx.requireLocation()
            let payload = try ctx.decodeJSONBody(QueryPayload.self)
            do {
                let result = try await loc.webSearch.query(
                    CoreIntegration.WebSearch.Input(query: payload.query, providerID: payload.providerID),
                    sessionID: nil
                )
                return ServerHTTPResponse.json(response(location: loc, data: result))
            } catch is CoreIntegration.WebSearch.ProviderRequiredError {
                throw InvalidRequestError(
                    message: "Web search provider is required",
                    kind: "websearch_provider_required",
                    field: "providerID"
                )
            } catch let e as CoreIntegration.WebSearch.ProviderNotFoundError {
                throw InvalidRequestError(
                    message: "Web search provider not found: \(e.providerID.rawValue)",
                    kind: "websearch_provider_not_found",
                    field: "providerID"
                )
            } catch is CoreIntegration.WebSearch.DisabledError {
                throw InvalidRequestError(message: "Web search is disabled", kind: "websearch_disabled")
            } catch let e as CoreIntegration.WebSearch.RequestError {
                throw ServiceUnavailableError(
                    message: "Web search request failed: \(e.providerID.rawValue)",
                    service: e.providerID.rawValue
                )
            } catch let e as CoreIntegration.WebSearch.SearchError {
                switch e {
                case .providerRequired:
                    throw InvalidRequestError(
                        message: "Web search provider is required",
                        kind: "websearch_provider_required",
                        field: "providerID"
                    )
                case .providerNotFound(let pnf):
                    throw InvalidRequestError(
                        message: "Web search provider not found: \(pnf.providerID.rawValue)",
                        kind: "websearch_provider_not_found",
                        field: "providerID"
                    )
                case .disabled:
                    throw InvalidRequestError(message: "Web search is disabled", kind: "websearch_disabled")
                case .request(let reqErr):
                    throw ServiceUnavailableError(
                        message: "Web search request failed: \(reqErr.providerID.rawValue)",
                        service: reqErr.providerID.rawValue
                    )
                }
            }
        },
    ]
)

// MARK: - 20. Worktree Handler (server/src/handlers/worktree.ts)

/// Handlers for `server.worktree` (`list`, `create`, `remove`, `refresh`).
// parity: server/src/handlers/worktree.ts#WorktreeHandler [status=implemented hash=568a01e2de8b]
public let WorktreeHandler = ServerHandlerGroup(
    groupIdentifier: "server.worktree",
    routes: [
        ServerRoute(
            method: .get,
            pathTemplate: "/api/worktree",
            endpointName: "worktree.list",
            groupIdentifier: "server.worktree"
        ) { ctx in
            guard let rawProjectID = ctx.request.query("projectID"), !rawProjectID.isEmpty else {
                throw InvalidRequestError(message: "Missing required query parameter: projectID", kind: "Query", field: "projectID")
            }
            let projectID = ProjectID(rawValue: rawProjectID)
            do {
                let list = try await ctx.runtime.worktree.list(projectID: projectID)
                return ServerHTTPResponse.json(list)
            } catch let e as CoreProject.Project.NotFoundError {
                throw ProjectNotFoundError(projectID: e.projectID.rawValue, message: "Project not found: \(e.projectID.rawValue)")
            } catch let e as CoreWorktree.WorktreeError {
                throw mapWorktreeError(e)
            }
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/worktree",
            endpointName: "worktree.create",
            groupIdentifier: "server.worktree"
        ) { ctx in
            let payload = try ctx.decodeJSONBody(CoreWorktree.CreateInput.self)
            do {
                let created = try await ctx.runtime.worktree.create(payload, strategies: nil)
                return ServerHTTPResponse.json(created)
            } catch {
                throw mapAnyWorktreeError(error)
            }
        },
        ServerRoute(
            method: .delete,
            pathTemplate: "/api/worktree",
            endpointName: "worktree.remove",
            groupIdentifier: "server.worktree"
        ) { ctx in
            let payload = try ctx.decodeJSONBody(CoreWorktree.RemoveInput.self)
            do {
                try await ctx.runtime.worktree.remove(payload, strategies: nil)
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch {
                throw mapAnyWorktreeError(error)
            }
        },
        ServerRoute(
            method: .post,
            pathTemplate: "/api/worktree/refresh",
            endpointName: "worktree.refresh",
            groupIdentifier: "server.worktree"
        ) { ctx in
            struct RefreshPayload: Decodable { let projectID: ProjectID }
            let payload = try ctx.decodeJSONBody(RefreshPayload.self)
            do {
                try await ctx.runtime.worktree.refresh(projectID: payload.projectID, strategies: nil)
                return ServerHTTPResponse.empty(statusCode: 204)
            } catch {
                throw mapAnyWorktreeError(error)
            }
        },
    ]
)

private func mapWorktreeError(_ error: CoreWorktree.WorktreeError) -> any Error {
    switch error {
    case .projectNotFound(let p):
        return ProjectNotFoundError(projectID: p.projectID.rawValue, message: "Project not found: \(p.projectID.rawValue)")
    case .sourceDirectoryNotFound(let s):
        let msg = s.directory.map {
            "Cannot create a worktree from \($0.rawValue): it is not a checkout of this project that supports worktrees, such as a git repository"
        } ?? "Worktree source not found for project: \(s.projectID.rawValue)"
        return OpenCodeProtocol.WorktreeError(message: msg)
    case .destinationExists(let d):
        return OpenCodeProtocol.WorktreeError(message: "Worktree destination already exists: \(d.directory.rawValue)")
    case .directoryUnavailable(let d):
        return OpenCodeProtocol.WorktreeError(message: "Worktree directory unavailable: \(d.directory.rawValue)")
    case .invalidDirectory(let d):
        return OpenCodeProtocol.WorktreeError(message: "Invalid worktree directory: \(d.directory.rawValue)")
    case .strategyUnavailable(let s):
        return OpenCodeProtocol.WorktreeError(message: "Worktree strategy unavailable: \(s.strategy.rawValue)")
    case .operation(let op):
        return OpenCodeProtocol.WorktreeError(message: op.message, forceRequired: op.forceRequired)
    }
}

private func mapAnyWorktreeError(_ error: any Error) -> any Error {
    if let p = error as? CoreProject.Project.NotFoundError {
        return ProjectNotFoundError(projectID: p.projectID.rawValue, message: "Project not found: \(p.projectID.rawValue)")
    }
    if let w = error as? CoreWorktree.WorktreeError {
        return mapWorktreeError(w)
    }
    if let g = error as? CoreVcs.Git.WorktreeError {
        return OpenCodeProtocol.WorktreeError(message: g.description, forceRequired: g.forceRequired)
    }
    if let op = error as? WorktreeSchema.OperationError {
        return OpenCodeProtocol.WorktreeError(message: op.message, forceRequired: op.forceRequired)
    }
    return OpenCodeProtocol.WorktreeError(message: String(describing: error))
}

// MARK: - 21. Composed Server API & Handlers Registry (server/src/api.ts, server/src/handlers.ts)

/// Server HTTP API contract composed from `OpenCodeProtocol.makeDefaultApi` with concrete server middleware keys.
// parity: server/src/api.ts#Api [status=implemented hash=8592775bcdd7]
public let Api: ProtocolApi = makeDefaultApi(
    locationMiddleware: LocationMiddleware.descriptor,
    formLocationMiddleware: FormLocationMiddleware.descriptor,
    sessionLocationMiddleware: SessionLocationMiddleware.descriptor
)

/// Complete ordered list of all 32 composed server handler groups covering all 39 upstream handler files.
// parity: server/src/handlers.ts#handlers [status=implemented hash=f7814e6da0fd]
public let handlers: [ServerHandlerGroup] = [
    ServerHandler,
    DebugHandler,
    MigrationHandler,
    LocationHandler,
    AgentHandler,
    PluginHandler,
    SessionHandler,
    MessageHandler,
    ModelHandler,
    GenerateHandler,
    VoiceHandler,
    ProviderHandler,
    IntegrationHandler,
    WebSearchHandler,
    UsageHandler,
    McpHandler,
    CredentialHandler,
    ProjectHandler,
    FormHandler,
    PermissionHandler,
    FileSystemHandler,
    CommandHandler,
    SkillHandler,
    RpcHandler,
    EventHandler,
    PtyHandler,
    PersistentPtyHandler,
    ShellHandler,
    ReferenceHandler,
    WorktreeHandler,
    VcsHandler,
    ConfigHandler,
]

// MARK: - Server HTTP Router (Dispatching All Routes, Middlewares, OpenAPI & In-Process Transport)

/// Live HTTP router dispatching inbound `ServerHTTPRequest`s across all registered `OpenCodeServer` handler groups.
public final class ServerRouter: Sendable {
    private struct CompiledRoute: Sendable {
        enum Segment: Sendable {
            case literal(String)
            case param(String)
            case wildcard
        }

        let route: ServerRoute
        let segments: [Segment]
        let specificityScore: Int
        let endpoint: EndpointDescriptor?

        init(route: ServerRoute, endpoint: EndpointDescriptor?) {
            self.route = route
            let rawSegs = route.pathTemplate.split(separator: "/", omittingEmptySubsequences: true)
            var parsed: [Segment] = []
            var score = 0
            for seg in rawSegs {
                if seg == "*" {
                    parsed.append(.wildcard)
                    score += 1
                } else if seg.hasPrefix(":") && seg.count > 1 {
                    parsed.append(.param(String(seg.dropFirst())))
                    score += 10
                } else {
                    parsed.append(.literal(String(seg)))
                    score += 100
                }
            }
            self.segments = parsed
            self.specificityScore = score
            self.endpoint = endpoint
        }

        func match(pathname: String) -> (params: [String: String], wildcard: String?)? {
            let inputSegs = pathname.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            var params: [String: String] = [:]
            var i = 0
            for seg in segments {
                switch seg {
                case .wildcard:
                    let tail = inputSegs.dropFirst(i).joined(separator: "/")
                    return (params, tail)
                case .literal(let lit):
                    guard i < inputSegs.count, inputSegs[i] == lit else { return nil }
                    i += 1
                case .param(let name):
                    guard i < inputSegs.count else { return nil }
                    let raw = inputSegs[i]
                    params[name] = ServerParsedURL.decodeURIComponentStrict(raw) ?? raw
                    i += 1
                }
            }
            guard i == inputSegs.count else { return nil }
            return (params, nil)
        }
    }

    public let runtime: ServerAppRuntime
    public let api: ProtocolApi
    public let handlerGroups: [ServerHandlerGroup]
    private let compiledRoutes: [CompiledRoute]

    public init(
        runtime: ServerAppRuntime,
        api: ProtocolApi = Api,
        handlerGroups: [ServerHandlerGroup] = handlers
    ) {
        self.runtime = runtime
        self.api = api
        self.handlerGroups = handlerGroups
        var compiled: [CompiledRoute] = []
        for group in handlerGroups {
            for route in group.routes {
                let endpoint = api.endpoint(name: route.endpointName)
                compiled.append(CompiledRoute(route: route, endpoint: endpoint))
            }
        }
        // Sort so more specific static paths always win over `:param` and `*` wildcard routes.
        compiled.sort { lhs, rhs in
            if lhs.specificityScore != rhs.specificityScore {
                return lhs.specificityScore > rhs.specificityScore
            }
            return lhs.segments.count > rhs.segments.count
        }
        self.compiledRoutes = compiled
    }

    /// Portable in-process `OpenCodePlatform.HTTPTransport` adapter usable with `OpenCodeClient` on every platform (incl. WASI/iOS).
    public var transport: ServerInProcessTransport {
        let corsOpts = runtime.corsOptions
        let base: ServerHTTPHandler = { [self] request in
            await self.handle(request)
        }
        let guarded = ServerCORSMiddleware.wrap(
            options: corsOpts,
            next: RequestSite.middleware(corsOpts)(base)
        )
        return ServerInProcessTransport(handler: guarded)
    }

    /// Handles a single HTTP request through route matching, authorization, location middleware, handler execution, and defect mapping.
    public func handle(_ request: ServerHTTPRequest) async -> ServerHTTPResponse {
        let pathname = request.pathname

        if request.method == "GET" && pathname == "/openapi.json" {
            return openAPISpecResponse()
        }

        let effectiveMethod: HTTPMethod? = HTTPMethod(rawValue: request.method == "HEAD" ? "GET" : request.method)
        var pathMatchedOtherMethod = false
        var matched: (compiled: CompiledRoute, params: [String: String], wildcard: String?)? = nil

        for candidate in compiledRoutes {
            guard let m = candidate.match(pathname: pathname) else { continue }
            if candidate.route.method == effectiveMethod {
                matched = (candidate, m.params, m.wildcard)
                break
            } else {
                pathMatchedOtherMethod = true
            }
        }

        guard let match = matched else {
            if pathMatchedOtherMethod {
                return ServerHTTPResponse.empty(statusCode: 405)
            }
            return ServerHTTPResponse.json(
                InvalidRequestError(message: "Route not found: \(request.method) \(pathname)"),
                statusCode: 404
            )
        }

        let route = match.compiled.route

        // 1. Authorization middleware
        if let unauthorized = authorizationLayer(runtime.authConfig, route.pathTemplate, request) {
            return unauthorized
        }

        // 2. Location / SessionLocation / FormLocation middleware + handler execution
        do {
            let resolvedLocation: LocationServices?
            if route.requiresFormLocation {
                let sessionIDParam = match.params["sessionID"] ?? ""
                let resolution = try await formLocationLayer(
                    runtime,
                    request,
                    sessionIDParam,
                    route.openAPIIdentifier
                )
                switch resolution {
                case .emptyListShortcut:
                    return ServerHTTPResponse.json(ServerDataWrapper(data: [FormSchema.Info]()))
                case .location(let loc):
                    resolvedLocation = loc
                }
            } else if route.requiresSessionLocation {
                let sessionIDParam = match.params["sessionID"] ?? ""
                resolvedLocation = try await sessionLocationLayer(runtime, sessionIDParam)
            } else if route.requiresLocation {
                resolvedLocation = try await layer(runtime, request)
            } else {
                resolvedLocation = nil
            }

            let ctx = ServerRouteContext(
                runtime: runtime,
                request: request,
                params: match.params,
                wildcard: match.wildcard,
                endpoint: match.compiled.endpoint,
                location: resolvedLocation
            )
            return try await route.handler(ctx)
        } catch {
            return defectResponseLayer(error, request)
        }
    }

    private func openAPISpecResponse() -> ServerHTTPResponse {
        var paths: [String: JSONValue] = [:]
        for endpoint in api.endpoints {
            let openPath = endpoint.openAPIPath
            var methodMap: [String: JSONValue]
            if case .object(let existing) = paths[openPath] {
                methodMap = existing
            } else {
                methodMap = [:]
            }
            var op: [String: JSONValue] = [
                "operationId": .string(endpoint.openAPIIdentifier),
                "tags": .array(endpoint.tags.map { .string($0) }),
            ]
            if let summary = endpoint.summary {
                op["summary"] = .string(summary)
            }
            if let desc = endpoint.description {
                op["description"] = .string(desc)
            }
            methodMap[endpoint.method.rawValue.lowercased()] = .object(op)
            paths[openPath] = .object(methodMap)
        }
        let doc: [String: JSONValue] = [
            "openapi": .string("3.1.0"),
            "info": .object([
                "title": .string(api.title),
                "version": .string(api.version),
                "description": .string(api.description),
            ]),
            "paths": .object(paths),
        ]
        return ServerHTTPResponse.json(doc)
    }
}

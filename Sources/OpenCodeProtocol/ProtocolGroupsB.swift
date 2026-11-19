import OpenCodeSchema

// MARK: - 20. migration.ts

/// Progress payload for a running V1 to V2 session history migration.
public struct V1MigrationProgress: Equatable, Hashable, Sendable, Codable {
    public let label: String
    public let numerator: Int?
    public let denominator: Int?

    public init(label: String, numerator: Int? = nil, denominator: Int? = nil) {
        self.label = label
        self.numerator = numerator
        self.denominator = denominator
    }
}

/// Discriminated union representing V1 to V2 session history migration state.
// parity: protocol/src/groups/migration.ts#V1MigrationStatus [status=implemented hash=8e28ece7e2ec]
public enum V1MigrationStatus: Equatable, Hashable, Sendable, Codable {
    case required
    case completed
    case running(progress: V1MigrationProgress)
    case error(String)

    private enum CodingKeys: String, CodingKey {
        case status, progress, error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let status = try c.decode(String.self, forKey: .status)
        switch status {
        case "required":
            self = .required
        case "completed":
            self = .completed
        case "running":
            self = .running(progress: try c.decode(V1MigrationProgress.self, forKey: .progress))
        case "error":
            self = .error(try c.decode(String.self, forKey: .error))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .status,
                in: c,
                debugDescription: "Unknown V1MigrationStatus '\(status)'"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .required:
            try c.encode("required", forKey: .status)
        case .completed:
            try c.encode("completed", forKey: .status)
        case .running(let progress):
            try c.encode("running", forKey: .status)
            try c.encode(progress, forKey: .progress)
        case .error(let message):
            try c.encode("error", forKey: .status)
            try c.encode(message, forKey: .error)
        }
    }
}

// parity: protocol/src/groups/migration.ts#MigrationGroup [status=implemented hash=f3dccad737f4]
public let MigrationGroup = EndpointGroupDescriptor(
    identifier: "server.migration",
    title: "migration",
    endpoints: [
        EndpointDescriptor(
            group: "server.migration",
            name: "migration.v1.status",
            method: .get,
            path: "/api/experimental/migration/v1",
            experimental: true,
            openAPIIdentifier: "experimental.migration.v1.status",
            summary: "Get V1 migration status",
            description: "Return the progress of the V1 to V2 session history migration.",
            successType: "V1MigrationStatus"
        )
    ]
)

// MARK: - 21. model.ts

// parity: protocol/src/groups/model.ts#ModelGroup [status=implemented hash=988787f12f76]
public let ModelGroup = EndpointGroupDescriptor(
    identifier: "server.model",
    title: "model",
    description: "Experimental model routes.",
    endpoints: [
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.model",
                name: "model.list",
                method: .get,
                path: "/api/model",
                openAPIIdentifier: "model.list",
                summary: "List models",
                description: "Retrieve the current snapshot of available models of the requested types, chat by default, ordered by release date within each type. The snapshot may precede initial plugin settlement.",
                queryParameters: [
                    locationQueryParameter,
                    ParameterDescriptor(
                        name: "types",
                        location: .query,
                        required: false,
                        typeName: "Model.Type[]",
                        description: "Only list models of these types. Defaults to chat, the only type offered for sessions."
                    ),
                ],
                successType: "Location.response(Model.Info[])",
                errors: [ProtocolErrorRef(ServiceUnavailableError.self)]
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.model",
                name: "model.default",
                method: .get,
                path: "/api/model/default",
                openAPIIdentifier: "model.default",
                summary: "Get default model",
                description: "Retrieve the model used when a session has no explicit model selection.",
                queryParameters: [locationQueryParameter],
                successType: "Location.response(Model.Info?)",
                errors: [ProtocolErrorRef(ServiceUnavailableError.self)]
            )
        ),
    ]
)

// MARK: - 22. permission.ts

// parity: protocol/src/groups/permission.ts#makePermissionGroup [status=implemented hash=2555aacc2496]
public func makePermissionGroup(
    locationMiddleware: MiddlewareDescriptor,
    sessionLocationMiddleware: MiddlewareDescriptor
) -> EndpointGroupDescriptor {
    EndpointGroupDescriptor(
        identifier: "server.permission",
        title: "permission",
        description: "Experimental permission routes.",
        endpoints: [
            locationQueryOpenApi(
                EndpointDescriptor(
                    group: "server.permission",
                    name: "permission.request.list",
                    method: .get,
                    path: "/api/permission/request",
                    openAPIIdentifier: "permission.request.list",
                    summary: "List pending permission requests",
                    description: "Retrieve pending permission requests for a location.",
                    queryParameters: [locationQueryParameter],
                    successType: "Location.response(Permission.Request[])"
                ).withMiddleware(locationMiddleware)
            ),
            EndpointDescriptor(
                group: "server.permission",
                name: "permission.saved.list",
                method: .get,
                path: "/api/permission/saved",
                openAPIIdentifier: "permission.saved.list",
                summary: "List saved permissions",
                description: "Retrieve saved permissions, optionally filtered by project.",
                queryParameters: [
                    ParameterDescriptor(name: "projectID", location: .query, required: false, typeName: "Project.ID")
                ],
                successType: "{ data: PermissionSaved.Info[] }"
            ).withMiddleware(locationMiddleware),
            EndpointDescriptor(
                group: "server.permission",
                name: "permission.saved.update",
                method: .patch,
                path: "/api/permission/saved/:id",
                openAPIIdentifier: "permission.saved.update",
                summary: "Update saved permission",
                description: "Change the action or resource of a saved permission. Fails with a conflict when the project already has a saved permission with the same action and resource.",
                pathParameters: [
                    ParameterDescriptor(name: "id", location: .path, required: true, typeName: "PermissionSaved.ID")
                ],
                payloadType: "{ action?: String, resource?: String }",
                successType: "{ data: PermissionSaved.Info }",
                errors: [
                    ProtocolErrorRef(PermissionSavedNotFoundError.self),
                    ProtocolErrorRef(ConflictError.self),
                ]
            ),
            EndpointDescriptor(
                group: "server.permission",
                name: "permission.saved.remove",
                method: .delete,
                path: "/api/permission/saved/:id",
                openAPIIdentifier: "permission.saved.remove",
                summary: "Remove saved permission",
                description: "Remove a saved permission by ID.",
                pathParameters: [
                    ParameterDescriptor(name: "id", location: .path, required: true, typeName: "PermissionSaved.ID")
                ],
                successType: "NoContent",
                successEncoding: .noContent
            ),
            EndpointDescriptor(
                group: "server.permission",
                name: "session.permission.create",
                method: .post,
                path: "/api/session/:sessionID/permission",
                openAPIIdentifier: "session.permission.create",
                summary: "Create permission request",
                description: "Evaluate and, when approval is required, create a permission request for a session.",
                pathParameters: [
                    ParameterDescriptor(name: "sessionID", location: .path, required: true, typeName: "Session.ID")
                ],
                payloadType: "SessionPermissionCreatePayload",
                successType: "{ data: { id: Permission.ID, effect: Permission.Effect } }",
                errors: [ProtocolErrorRef(SessionNotFoundError.self)]
            ).withMiddleware(sessionLocationMiddleware),
            EndpointDescriptor(
                group: "server.permission",
                name: "session.permission.list",
                method: .get,
                path: "/api/session/:sessionID/permission",
                openAPIIdentifier: "session.permission.list",
                summary: "List session permission requests",
                description: "Retrieve pending permission requests owned by a session.",
                pathParameters: [
                    ParameterDescriptor(name: "sessionID", location: .path, required: true, typeName: "Session.ID")
                ],
                successType: "{ data: Permission.Request[] }",
                errors: [
                    ProtocolErrorRef(SessionNotFoundError.self),
                    ProtocolErrorRef(LocationNotFoundError.self),
                ]
            ),
            EndpointDescriptor(
                group: "server.permission",
                name: "session.permission.get",
                method: .get,
                path: "/api/session/:sessionID/permission/:requestID",
                openAPIIdentifier: "session.permission.get",
                summary: "Get permission request",
                description: "Retrieve a pending permission request owned by a session.",
                pathParameters: [
                    ParameterDescriptor(name: "sessionID", location: .path, required: true, typeName: "Session.ID"),
                    ParameterDescriptor(name: "requestID", location: .path, required: true, typeName: "Permission.ID"),
                ],
                successType: "{ data: Permission.Request }",
                errors: [
                    ProtocolErrorRef(SessionNotFoundError.self),
                    ProtocolErrorRef(PermissionNotFoundError.self),
                ]
            ).withMiddleware(sessionLocationMiddleware),
            EndpointDescriptor(
                group: "server.permission",
                name: "session.permission.reply",
                method: .post,
                path: "/api/session/:sessionID/permission/:requestID/reply",
                openAPIIdentifier: "session.permission.reply",
                summary: "Reply to pending permission request",
                description: "Respond to a pending permission request owned by a session.",
                pathParameters: [
                    ParameterDescriptor(name: "sessionID", location: .path, required: true, typeName: "Session.ID"),
                    ParameterDescriptor(name: "requestID", location: .path, required: true, typeName: "Permission.ID"),
                ],
                payloadType: "{ decision: Permission.Reply, message?: String }",
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [
                    ProtocolErrorRef(SessionNotFoundError.self),
                    ProtocolErrorRef(PermissionNotFoundError.self),
                ]
            ).withMiddleware(sessionLocationMiddleware),
        ]
    )
}

// MARK: - 23. persistent-pty.ts

// parity: protocol/src/groups/persistent-pty.ts#PERSISTENT_PTY_CONNECT_PATH [status=implemented hash=690d792af4d6]
public let PERSISTENT_PTY_CONNECT_PATH = "/api/experimental/persistent-pty/:ptyID/connect"

private func matchesSingleSegmentTemplate(pathname: String, prefix: String, suffix: String) -> Bool {
    guard pathname.hasPrefix(prefix), pathname.hasSuffix(suffix) else { return false }
    guard pathname.utf8.count > prefix.utf8.count + suffix.utf8.count else { return false }
    let start = pathname.index(pathname.startIndex, offsetBy: prefix.count)
    let end = pathname.index(pathname.endIndex, offsetBy: -suffix.count)
    let segment = pathname[start..<end]
    return !segment.isEmpty && !segment.contains("/")
}

/// Returns `true` when `url` matches `/api/experimental/persistent-pty/:ptyID/connect` with a non-empty `ticket` query parameter.
// parity: protocol/src/groups/persistent-pty.ts#hasPersistentPtyConnectTicketURL [status=implemented hash=2e0ab26b964d]
public func hasPersistentPtyConnectTicketURL(_ urlString: String) -> Bool {
    let parsed = ProtocolURLComponents(urlString: urlString)
    return matchesSingleSegmentTemplate(
        pathname: parsed.pathname,
        prefix: "/api/experimental/persistent-pty/",
        suffix: "/connect"
    ) && parsed.hasNonEmptyQueryValue(for: PTY_CONNECT_TICKET_QUERY)
}

private let persistentPtyErrors: [ProtocolErrorRef] = [
    ProtocolErrorRef(InvalidRequestError.self),
    ProtocolErrorRef(ServiceUnavailableError.self),
]
private let persistentPtyTerminalErrors: [ProtocolErrorRef] = [
    ProtocolErrorRef(PtyNotFoundError.self),
    ProtocolErrorRef(ServiceUnavailableError.self),
]

// parity: protocol/src/groups/persistent-pty.ts#PersistentPtyGroup [status=implemented hash=745d48925794]
public let PersistentPtyGroup = EndpointGroupDescriptor(
    identifier: "server.experimental",
    title: "persistentPty",
    description: "Prototype persistent PTY routes.",
    endpoints: [
        EndpointDescriptor(
            group: "server.experimental",
            name: "persistentPty.read",
            method: .get,
            path: "/api/experimental/session/:sessionID/terminal/read",
            experimental: true,
            openAPIIdentifier: "experimental.persistentPty.read",
            summary: "Read the session's most recently controlled terminal",
            description: "Read the last physical rows without changing selection or taking control. Omitted lines uses the live terminal height; larger counts include retained history. Blank rows are preserved. Screen dimensions and cursor remain relative to the live screen. Returns null when no current terminal exists. Selection is server-local and resets on restart. Experimental: may change without compatibility guarantees.",
            pathParameters: [
                ParameterDescriptor(name: "sessionID", location: .path, required: true, typeName: "Session.ID")
            ],
            queryParameters: [
                ParameterDescriptor(name: "lines", location: .query, required: false, typeName: "PersistentPty.ReadLines")
            ],
            successType: "{ data: PersistentPty.ReadResult? }",
            errors: [ProtocolErrorRef(ServiceUnavailableError.self)]
        ),
        EndpointDescriptor(
            group: "server.experimental",
            name: "persistentPty.list",
            method: .get,
            path: "/api/experimental/session/:sessionID/terminal",
            experimental: true,
            openAPIIdentifier: "experimental.persistentPty.list",
            pathParameters: [
                ParameterDescriptor(name: "sessionID", location: .path, required: true, typeName: "Session.ID")
            ],
            successType: "{ data: PersistentPty.Info[] }",
            errors: persistentPtyErrors
        ),
        EndpointDescriptor(
            group: "server.experimental",
            name: "persistentPty.create",
            method: .post,
            path: "/api/experimental/session/:sessionID/terminal",
            experimental: true,
            openAPIIdentifier: "experimental.persistentPty.create",
            pathParameters: [
                ParameterDescriptor(name: "sessionID", location: .path, required: true, typeName: "Session.ID")
            ],
            payloadType: "PersistentPty.CreateInput",
            successType: "{ data: PersistentPty.Info }",
            errors: persistentPtyErrors
        ),
        EndpointDescriptor(
            group: "server.experimental",
            name: "persistentPty.shutdown",
            method: .post,
            path: "/api/experimental/persistent-pty/shutdown",
            experimental: true,
            openAPIIdentifier: "experimental.persistentPty.shutdown",
            successType: "NoContent",
            successEncoding: .noContent,
            errors: [ProtocolErrorRef(ServiceUnavailableError.self)]
        ),
        EndpointDescriptor(
            group: "server.experimental",
            name: "persistentPty.handoff",
            method: .post,
            path: "/api/experimental/persistent-pty/handoff",
            experimental: true,
            openAPIIdentifier: "experimental.persistentPty.handoff",
            successType: "{ handoff: PersistentPty.Handoff? }",
            errors: [ProtocolErrorRef(ServiceUnavailableError.self)]
        ),
        EndpointDescriptor(
            group: "server.experimental",
            name: "persistentPty.get",
            method: .get,
            path: "/api/experimental/persistent-pty/:ptyID",
            experimental: true,
            openAPIIdentifier: "experimental.persistentPty.get",
            pathParameters: [
                ParameterDescriptor(name: "ptyID", location: .path, required: true, typeName: "Pty.ID")
            ],
            successType: "{ data: PersistentPty.Info }",
            errors: persistentPtyTerminalErrors
        ),
        EndpointDescriptor(
            group: "server.experimental",
            name: "persistentPty.update",
            method: .put,
            path: "/api/experimental/persistent-pty/:ptyID",
            experimental: true,
            openAPIIdentifier: "experimental.persistentPty.update",
            description: "Resize when size is present and rename when title is present; a null title clears the user title so the shell's title shows again. Renaming fails with 501 while the terminal service predates renaming.",
            pathParameters: [
                ParameterDescriptor(name: "ptyID", location: .path, required: true, typeName: "Pty.ID")
            ],
            payloadType: "PersistentPty.UpdateInput",
            successType: "{ data: PersistentPty.Info }",
            errors: persistentPtyTerminalErrors + [ProtocolErrorRef(PtyFeatureUnsupportedError.self)]
        ),
        EndpointDescriptor(
            group: "server.experimental",
            name: "persistentPty.snapshot",
            method: .get,
            path: "/api/experimental/persistent-pty/:ptyID/snapshot",
            experimental: true,
            openAPIIdentifier: "experimental.persistentPty.snapshot",
            pathParameters: [
                ParameterDescriptor(name: "ptyID", location: .path, required: true, typeName: "Pty.ID")
            ],
            successType: "{ data: PersistentPty.Snapshot }",
            errors: persistentPtyTerminalErrors
        ),
        EndpointDescriptor(
            group: "server.experimental",
            name: "persistentPty.remove",
            method: .delete,
            path: "/api/experimental/persistent-pty/:ptyID",
            experimental: true,
            openAPIIdentifier: "experimental.persistentPty.remove",
            pathParameters: [
                ParameterDescriptor(name: "ptyID", location: .path, required: true, typeName: "Pty.ID")
            ],
            successType: "NoContent",
            successEncoding: .noContent,
            errors: persistentPtyTerminalErrors
        ),
        EndpointDescriptor(
            group: "server.experimental",
            name: "persistentPty.connectToken",
            method: .post,
            path: "/api/experimental/persistent-pty/:ptyID/connect-token",
            experimental: true,
            openAPIIdentifier: "experimental.persistentPty.connectToken",
            pathParameters: [
                ParameterDescriptor(name: "ptyID", location: .path, required: true, typeName: "Pty.ID")
            ],
            headerParameters: [
                ParameterDescriptor(name: PTY_CONNECT_TOKEN_HEADER, location: .header, required: false, typeName: "String")
            ],
            successType: "{ data: PtyTicket.ConnectToken }",
            errors: [
                ProtocolErrorRef(ForbiddenError.self),
                ProtocolErrorRef(PtyNotFoundError.self),
                ProtocolErrorRef(ServiceUnavailableError.self),
            ]
        ),
        EndpointDescriptor(
            group: "server.experimental",
            name: "persistentPty.connect",
            method: .get,
            path: PERSISTENT_PTY_CONNECT_PATH,
            experimental: true,
            openAPIIdentifier: "experimental.persistentPty.connect",
            summary: "Connect to a persistent PTY",
            description: "Stream persistent PTY output through the OpenCode server.",
            pathParameters: [
                ParameterDescriptor(name: "ptyID", location: .path, required: true, typeName: "Pty.ID")
            ],
            queryParameters: [
                ParameterDescriptor(name: "cursor", location: .query, required: false, typeName: "String"),
                ParameterDescriptor(name: "role", location: .query, required: false, typeName: "String"),
                ParameterDescriptor(name: "attachment_id", location: .query, required: false, typeName: "String"),
                ParameterDescriptor(name: "takeover", location: .query, required: false, typeName: "String"),
                ParameterDescriptor(name: "input_protocol", location: .query, required: false, typeName: "String"),
                ParameterDescriptor(name: PTY_CONNECT_TICKET_QUERY, location: .query, required: false, typeName: "String"),
            ],
            successType: "Boolean",
            successEncoding: .websocket,
            errors: [
                ProtocolErrorRef(ForbiddenError.self),
                ProtocolErrorRef(PtyNotFoundError.self),
                ProtocolErrorRef(ServiceUnavailableError.self),
            ],
            isWebSocket: true
        ),
    ]
)

// MARK: - 24. plugin.ts

// parity: protocol/src/groups/plugin.ts#PluginGroup [status=implemented hash=b0246fde58ac]
public let PluginGroup = EndpointGroupDescriptor(
    identifier: "server.plugin",
    title: "plugin",
    description: "Experimental plugin routes.",
    endpoints: [
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.plugin",
                name: "plugin.list",
                method: .get,
                path: "/api/plugin",
                openAPIIdentifier: "plugin.list",
                summary: "List plugins",
                description: "Retrieve enabled server plugins and their current status.",
                queryParameters: [locationQueryParameter],
                successType: "Location.response(Plugin.Info[])"
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.plugin",
                name: "plugin.gui",
                method: .get,
                path: "/api/plugin/gui",
                openAPIIdentifier: "plugin.gui",
                summary: "Read plugin GUI bundle",
                description: "Read an active plugin's prebuilt CommonJS `./gui-experimental` bundle. Desktop app windows run its default export; the desktop app's main process runs its `main` export. Fails with not found when no active plugin has the id or the plugin exports no `./gui-experimental`.",
                queryParameters: [
                    locationQueryParameter,
                    ParameterDescriptor(name: "id", location: .query, required: true, typeName: "Plugin.ID"),
                ],
                successType: "Location.response(Plugin.GuiBundle)",
                errors: [ProtocolErrorRef(PluginNotFoundError.self)]
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.plugin",
                name: "plugin.check",
                method: .post,
                path: "/api/plugin/check",
                openAPIIdentifier: "plugin.check",
                summary: "Check plugin updates",
                description: "Check one or all package plugins for available updates.",
                queryParameters: [locationQueryParameter],
                payloadType: "{ target?: String }",
                successType: "Location.response(Plugin.Info[])",
                errors: [ProtocolErrorRef(InvalidRequestError.self)]
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.plugin",
                name: "plugin.update",
                method: .post,
                path: "/api/plugin/update",
                openAPIIdentifier: "plugin.update",
                summary: "Update plugins",
                description: "Update package plugins concurrently and notify active locations to reload them. Responds once every update has finished; fails when any update fails.",
                queryParameters: [locationQueryParameter],
                payloadType: "{ targets: String[] }",
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [
                    ProtocolErrorRef(InvalidRequestError.self),
                    ProtocolErrorRef(ServiceUnavailableError.self),
                ]
            )
        ),
    ]
)

// MARK: - 25. project.ts

// parity: protocol/src/groups/project.ts#ProjectGroup [status=implemented hash=88aa847e1907]
public let ProjectGroup = EndpointGroupDescriptor(
    identifier: "server.project",
    title: "project",
    description: "Project routes.",
    endpoints: [
        EndpointDescriptor(
            group: "server.project",
            name: "project.list",
            method: .get,
            path: "/api/project",
            openAPIIdentifier: "project.list",
            summary: "List projects",
            description: "List known projects. Archived projects are excluded unless archived=true.",
            queryParameters: [
                ParameterDescriptor(name: "archived", location: .query, required: false, typeName: "BooleanFromString")
            ],
            successType: "Project.Info[]"
        ),
        EndpointDescriptor(
            group: "server.project",
            name: "project.update",
            method: .patch,
            path: "/api/project/:projectID",
            openAPIIdentifier: "project.update",
            summary: "Update project",
            description: "Update the project canonical directory, display metadata, and workspace commands.",
            pathParameters: [
                ParameterDescriptor(name: "projectID", location: .path, required: true, typeName: "Project.ID")
            ],
            payloadType: "Project.UpdatePayload",
            successType: "Project.Info",
            errors: [ProtocolErrorRef(ProjectNotFoundError.self)]
        ),
    ]
)

// MARK: - 26. provider.ts

// parity: protocol/src/groups/provider.ts#ProviderGroup [status=implemented hash=d16b9d24d823]
public let ProviderGroup = EndpointGroupDescriptor(
    identifier: "server.provider",
    title: "provider",
    description: "Experimental provider routes.",
    endpoints: [
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.provider",
                name: "provider.list",
                method: .get,
                path: "/api/provider",
                openAPIIdentifier: "provider.list",
                summary: "List providers",
                description: "Retrieve active AI providers so clients can show provider availability and configuration.",
                queryParameters: [locationQueryParameter],
                successType: "Location.response(Provider.Info[])",
                errors: [ProtocolErrorRef(ServiceUnavailableError.self)]
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.provider",
                name: "provider.get",
                method: .get,
                path: "/api/provider/:providerID",
                openAPIIdentifier: "provider.get",
                summary: "Get provider",
                description: "Retrieve a single AI provider so clients can inspect its availability and endpoint settings.",
                pathParameters: [
                    ParameterDescriptor(name: "providerID", location: .path, required: true, typeName: "Provider.ID")
                ],
                queryParameters: [locationQueryParameter],
                successType: "Location.response(Provider.Info)",
                errors: [
                    ProtocolErrorRef(ProviderNotFoundError.self),
                    ProtocolErrorRef(ServiceUnavailableError.self),
                ]
            )
        ),
    ]
)

// MARK: - 27. pty.ts

// parity: protocol/src/groups/pty.ts#PTY_CONNECT_TICKET_QUERY [status=implemented hash=8486eacacd9d]
public let PTY_CONNECT_TICKET_QUERY = "ticket"

// parity: protocol/src/groups/pty.ts#PTY_CONNECT_TOKEN_HEADER [status=implemented hash=9136f0dc28d9]
public let PTY_CONNECT_TOKEN_HEADER = "x-opencode-ticket"

// parity: protocol/src/groups/pty.ts#PTY_CONNECT_TOKEN_HEADER_VALUE [status=implemented hash=6b69888365de]
public let PTY_CONNECT_TOKEN_HEADER_VALUE = "1"

// parity: protocol/src/groups/pty.ts#PTY_CONNECT_PATH [status=implemented hash=1b7056178250]
public let PTY_CONNECT_PATH = "/api/pty/:ptyID/connect"

/// Returns `true` when `url` matches `/api/pty/:ptyID/connect` with a non-empty `ticket` query parameter.
// parity: protocol/src/groups/pty.ts#hasPtyConnectTicketURL [status=implemented hash=4c01636e3e92]
public func hasPtyConnectTicketURL(_ urlString: String) -> Bool {
    let parsed = ProtocolURLComponents(urlString: urlString)
    return matchesSingleSegmentTemplate(
        pathname: parsed.pathname,
        prefix: "/api/pty/",
        suffix: "/connect"
    ) && parsed.hasNonEmptyQueryValue(for: PTY_CONNECT_TICKET_QUERY)
}

// parity: protocol/src/groups/pty.ts#makePtyGroup [status=implemented hash=c40a7b721fab]
public func makePtyGroup(locationMiddleware: MiddlewareDescriptor) -> EndpointGroupDescriptor {
    EndpointGroupDescriptor(
        identifier: "server.pty",
        title: "pty",
        description: "Experimental location-scoped PTY routes.",
        endpoints: [
            locationQueryOpenApi(
                EndpointDescriptor(
                    group: "server.pty",
                    name: "pty.list",
                    method: .get,
                    path: "/api/pty",
                    openAPIIdentifier: "pty.list",
                    summary: "List PTY sessions",
                    description: "List PTY sessions for a location, including exited sessions retained until removal.",
                    queryParameters: [locationQueryParameter],
                    successType: "Location.response(Pty.Info[])"
                )
            ),
            locationQueryOpenApi(
                EndpointDescriptor(
                    group: "server.pty",
                    name: "pty.create",
                    method: .post,
                    path: "/api/pty",
                    openAPIIdentifier: "pty.create",
                    summary: "Create PTY session",
                    description: "Create a pseudo-terminal session for a location.",
                    queryParameters: [locationQueryParameter],
                    payloadType: "Pty.CreateInput",
                    successType: "Location.response(Pty.Info)"
                )
            ),
            locationQueryOpenApi(
                EndpointDescriptor(
                    group: "server.pty",
                    name: "pty.get",
                    method: .get,
                    path: "/api/pty/:ptyID",
                    openAPIIdentifier: "pty.get",
                    summary: "Get PTY session",
                    description: "Get one PTY session, including its exit code once exited.",
                    pathParameters: [
                        ParameterDescriptor(name: "ptyID", location: .path, required: true, typeName: "Pty.ID")
                    ],
                    queryParameters: [locationQueryParameter],
                    successType: "Location.response(Pty.Info)",
                    errors: [ProtocolErrorRef(PtyNotFoundError.self)]
                )
            ),
            locationQueryOpenApi(
                EndpointDescriptor(
                    group: "server.pty",
                    name: "pty.update",
                    method: .put,
                    path: "/api/pty/:ptyID",
                    openAPIIdentifier: "pty.update",
                    summary: "Update PTY session",
                    description: "Update the title or viewport size of one PTY session.",
                    pathParameters: [
                        ParameterDescriptor(name: "ptyID", location: .path, required: true, typeName: "Pty.ID")
                    ],
                    queryParameters: [locationQueryParameter],
                    payloadType: "Pty.UpdateInput",
                    successType: "Location.response(Pty.Info)",
                    errors: [ProtocolErrorRef(PtyNotFoundError.self)]
                )
            ),
            locationQueryOpenApi(
                EndpointDescriptor(
                    group: "server.pty",
                    name: "pty.remove",
                    method: .delete,
                    path: "/api/pty/:ptyID",
                    openAPIIdentifier: "pty.remove",
                    summary: "Remove PTY session",
                    description: "Terminate and remove one PTY session.",
                    pathParameters: [
                        ParameterDescriptor(name: "ptyID", location: .path, required: true, typeName: "Pty.ID")
                    ],
                    queryParameters: [locationQueryParameter],
                    successType: "NoContent",
                    successEncoding: .noContent,
                    errors: [ProtocolErrorRef(PtyNotFoundError.self)]
                )
            ),
            locationQueryOpenApi(
                EndpointDescriptor(
                    group: "server.pty",
                    name: "pty.connectToken",
                    method: .post,
                    path: "/api/pty/:ptyID/connect-token",
                    openAPIIdentifier: "pty.connect.token",
                    summary: "Create PTY WebSocket token",
                    description: "Create a short-lived single-use ticket for opening a PTY WebSocket connection.",
                    pathParameters: [
                        ParameterDescriptor(name: "ptyID", location: .path, required: true, typeName: "Pty.ID")
                    ],
                    queryParameters: [locationQueryParameter],
                    headerParameters: [
                        ParameterDescriptor(name: PTY_CONNECT_TOKEN_HEADER, location: .header, required: false, typeName: "String")
                    ],
                    successType: "Location.response(PtyTicket.ConnectToken)",
                    errors: [
                        ProtocolErrorRef(ForbiddenError.self),
                        ProtocolErrorRef(PtyNotFoundError.self),
                    ]
                )
            ),
        ]
    )
    .middleware(locationMiddleware)
    .adding(
        EndpointDescriptor(
            group: "server.pty",
            name: "pty.connect",
            method: .get,
            path: PTY_CONNECT_PATH,
            openAPIIdentifier: "pty.connect",
            summary: "Connect to PTY session",
            description: "Establish a WebSocket connection streaming PTY output and accepting terminal input.",
            pathParameters: [
                ParameterDescriptor(name: "ptyID", location: .path, required: true, typeName: "Pty.ID")
            ],
            queryParameters: [
                ParameterDescriptor(name: "location[directory]", location: .query, required: false, typeName: "String"),
                ParameterDescriptor(name: "cursor", location: .query, required: false, typeName: "String"),
                ParameterDescriptor(name: PTY_CONNECT_TICKET_QUERY, location: .query, required: false, typeName: "String"),
            ],
            successType: "Boolean",
            successEncoding: .websocket,
            errors: [
                ProtocolErrorRef(ForbiddenError.self),
                ProtocolErrorRef(PtyNotFoundError.self),
                ProtocolErrorRef(LocationNotFoundError.self),
            ],
            isWebSocket: true
        )
    )
}

// MARK: - 28. reference.ts

// parity: protocol/src/groups/reference.ts#ReferenceGroup [status=implemented hash=99dce7662f29]
public let ReferenceGroup = EndpointGroupDescriptor(
    identifier: "server.reference",
    title: "reference",
    description: "Location-scoped project references.",
    endpoints: [
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.reference",
                name: "reference.list",
                method: .get,
                path: "/api/reference",
                openAPIIdentifier: "reference.list",
                summary: "List references",
                description: "List references available in the requested location.",
                queryParameters: [locationQueryParameter],
                successType: "Location.response(Reference.Info[])"
            )
        )
    ]
)

// MARK: - 29. rpc.ts

// parity: protocol/src/groups/rpc.ts#RpcInput [status=implemented hash=f25c74154948]
public struct RpcInput: Equatable, Hashable, Sendable, Codable {
    public let input: JSONValue?

    public init(input: JSONValue? = nil) {
        self.input = input
    }
}

// parity: protocol/src/groups/rpc.ts#RpcOutput [status=implemented hash=508b71164b6f]
public struct RpcOutput: Equatable, Hashable, Sendable, Codable {
    public let output: JSONValue?

    public init(output: JSONValue? = nil) {
        self.output = output
    }
}

// parity: protocol/src/groups/rpc.ts#RpcGroup [status=implemented hash=a1695460d294]
public let RpcGroup = EndpointGroupDescriptor(
    identifier: "server.rpc",
    title: "rpc",
    description: "Plugin RPC routes.",
    endpoints: [
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.rpc",
                name: "rpc.call",
                method: .post,
                path: "/api/rpc/:rpcID/:method",
                openAPIIdentifier: "rpc.call",
                summary: "Call a plugin RPC",
                description: "Dispatch a method to the currently registered RPC at the requested location.",
                pathParameters: [
                    ParameterDescriptor(name: "rpcID", location: .path, required: true, typeName: "String"),
                    ParameterDescriptor(name: "method", location: .path, required: true, typeName: "String"),
                ],
                queryParameters: [locationQueryParameter],
                payloadType: "Rpc.Input",
                successType: "Rpc.Output",
                errors: [
                    ProtocolErrorRef(RpcError.self),
                    ProtocolErrorRef(RpcInternalError.self),
                ]
            )
        )
    ]
)

// MARK: - 30. server.ts

// parity: protocol/src/groups/server.ts#ServerInfo [status=implemented hash=23926263d3f0]
public struct ServerInfo: Equatable, Hashable, Sendable, Codable {
    public struct Paths: Equatable, Hashable, Sendable, Codable {
        public let tmp: String

        public init(tmp: String) {
            self.tmp = tmp
        }
    }

    public struct Capabilities: Equatable, Hashable, Sendable, Codable {
        public let persistentPty: Bool?

        public init(persistentPty: Bool? = nil) {
            self.persistentPty = persistentPty
        }
    }

    public let version: String
    /// `0` means the runtime has no OS process identity (e.g. workerd).
    public let pid: Int
    /// The machine's name, absent where the runtime has none (e.g. workerd).
    public let hostname: String?
    public let urls: [String]
    public let paths: Paths
    /// Optional at every level so clients still decode servers that predate a capability.
    public let capabilities: Capabilities?

    public init(
        version: String,
        pid: Int,
        hostname: String? = nil,
        urls: [String],
        paths: Paths,
        capabilities: Capabilities? = nil
    ) {
        self.version = version
        self.pid = pid
        self.hostname = hostname
        self.urls = urls
        self.paths = paths
        self.capabilities = capabilities
    }
}

// parity: protocol/src/groups/server.ts#PairingCode [status=implemented hash=14360c5caa93]
public struct PairingCode: Equatable, Hashable, Sendable, Codable {
    public let code: String
    public let expiresIn: Int

    public init(code: String, expiresIn: Int) {
        self.code = code
        self.expiresIn = expiresIn
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case expiresIn = "expires_in"
    }
}

// parity: protocol/src/groups/server.ts#PairingSession [status=implemented hash=de19bed760dc]
public struct PairingSession: Equatable, Hashable, Sendable, Codable {
    public let token: String

    public init(token: String) {
        self.token = token
    }
}

// parity: protocol/src/groups/server.ts#PAIRING_CONNECT_PATH [status=implemented hash=9ae208b275e8]
public let PAIRING_CONNECT_PATH = "/auth/connect/:code"

/// Returns `true` when `url` matches `/auth/connect/:code`.
// parity: protocol/src/groups/server.ts#isPairingConnectURL [status=implemented hash=4fd52aa72e77]
public func isPairingConnectURL(_ urlString: String) -> Bool {
    let parsed = ProtocolURLComponents(urlString: urlString)
    return matchesSingleSegmentTemplate(pathname: parsed.pathname, prefix: "/auth/connect/", suffix: "")
}

// parity: protocol/src/groups/server.ts#ServerGroup [status=implemented hash=bebe0377553f]
public let ServerGroup = EndpointGroupDescriptor(
    identifier: "server.server",
    title: "server",
    endpoints: [
        EndpointDescriptor(
            group: "server.server",
            name: "server.info",
            method: .get,
            path: "/api/info",
            openAPIIdentifier: "server.info",
            summary: "Get server info",
            description: "Return the server identity, connection URLs, paths, and readiness status.",
            successType: "ServerInfo"
        ),
        EndpointDescriptor(
            group: "server.server",
            name: "server.pair",
            method: .post,
            path: "/api/pair",
            openAPIIdentifier: "server.pair",
            summary: "Create pairing code",
            description: "Create a short-lived, single-use code for a /auth/connect/:code pairing link.",
            successType: "PairingCode"
        ),
        EndpointDescriptor(
            group: "server.server",
            name: "server.connect",
            method: .get,
            path: PAIRING_CONNECT_PATH,
            openAPIIdentifier: "server.connect",
            summary: "Redeem pairing code",
            description: "Redeem a pairing code. Browsers receive a session cookie and a redirect to the web app; requests that accept JSON receive a session token to use as the password.",
            pathParameters: [
                ParameterDescriptor(name: "code", location: .path, required: true, typeName: "String")
            ],
            successType: "PairingSession",
            errors: [ProtocolErrorRef(UnauthorizedError.self)]
        ),
    ]
)

// MARK: - 31. session.ts

/// Experimental: `session.inbox.list` response for clients opting into `experimental-media-uri`.
// parity: protocol/src/groups/session.ts#SessionMediaInboxResponse [status=implemented hash=b8d506d49c7e]
public struct SessionMediaInboxResponse: Equatable, Hashable, Sendable, Codable {
    public let data: [JSONValue]

    public init(data: [JSONValue]) {
        self.data = data
    }
}

/// Canonical opaque session list pagination cursor (`Session.ListCursor`).
// parity: protocol/src/groups/session.ts#SessionsCursor [status=implemented hash=8d4637361c2e]
public struct SessionsCursor: RawRepresentable, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Filter for `SessionsQuery.parentID`: either a specific `SessionID` or `"null"` (root sessions only).
public enum SessionParentFilter: Equatable, Hashable, Sendable, Codable {
    case session(SessionID)
    case root

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .root
            return
        }
        let raw = try container.decode(String.self)
        if raw == "null" {
            self = .root
            return
        }
        self = .session(try SessionID(validating: raw))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .session(let id):
            try container.encode(id.rawValue)
        case .root:
            try container.encode("null")
        }
    }
}

/// Query parameters for `GET /api/session` (`SessionsQuery`).
// parity: protocol/src/groups/session.ts#SessionsQuery [status=implemented hash=a4dbb0b17e9c]
public struct SessionsQuery: Equatable, Hashable, Sendable, Codable {
    public let limit: Int?
    public let order: ProtocolSortOrder?
    public let search: String?
    public let parentID: SessionParentFilter?
    public let archived: Bool?
    public let directory: String?
    public let project: ProjectID?
    public let subpath: String?
    public let cursor: SessionsCursor?

    public init(
        limit: Int? = nil,
        order: ProtocolSortOrder? = nil,
        search: String? = nil,
        parentID: SessionParentFilter? = nil,
        archived: Bool? = nil,
        directory: String? = nil,
        project: ProjectID? = nil,
        subpath: String? = nil,
        cursor: SessionsCursor? = nil
    ) {
        self.limit = limit
        self.order = order
        self.search = search
        self.parentID = parentID
        self.archived = archived
        self.directory = directory
        self.project = project
        self.subpath = subpath
        self.cursor = cursor
    }
}

private let instructionEntryValueTooLargeErrorRef = ProtocolErrorRef(
    tag: "InstructionEntryValueTooLargeError",
    httpStatusCode: 413
)

// parity: protocol/src/groups/session.ts#makeSessionGroup [status=implemented hash=222e78c497b7]
public func makeSessionGroup(
    sessionLocationMiddleware: MiddlewareDescriptor,
    formLocationMiddleware: MiddlewareDescriptor
) -> EndpointGroupDescriptor {
    let sessionIDParam = ParameterDescriptor(name: "sessionID", location: .path, required: true, typeName: "Session.ID")
    let formSessionIDParam = ParameterDescriptor(name: "sessionID", location: .path, required: true, typeName: "String")
    let formIDParam = ParameterDescriptor(name: "formID", location: .path, required: true, typeName: "Form.ID")
    let inboxIDParam = ParameterDescriptor(name: "inboxID", location: .path, required: true, typeName: "SessionMessage.ID")
    let keyParam = ParameterDescriptor(name: "key", location: .path, required: true, typeName: "InstructionEntry.Key")

    return EndpointGroupDescriptor(
        identifier: "server.session",
        title: "session",
        description: "Experimental session routes.",
        endpoints: [
            EndpointDescriptor(
                group: "server.session",
                name: "session.list",
                method: .get,
                path: "/api/session",
                openAPIIdentifier: "session.list",
                summary: "List sessions",
                description: "Retrieve sessions in the requested order. Items keep that order across pages; use cursor.next or cursor.previous to move through the ordered list.",
                queryParameters: [
                    ParameterDescriptor(name: "limit", location: .query, required: false, typeName: "PositiveInt", description: "Maximum number of sessions to return. Defaults to the newest 50 sessions."),
                    ParameterDescriptor(name: "order", location: .query, required: false, typeName: "asc|desc", description: "Session order for the first page. Use desc for newest first or asc for oldest first."),
                    ParameterDescriptor(name: "search", location: .query, required: false, typeName: "String"),
                    ParameterDescriptor(name: "parentID", location: .query, required: false, typeName: "Session.ID|null", description: "Filter by parent session. Use null to return only root sessions."),
                    ParameterDescriptor(name: "archived", location: .query, required: false, typeName: "BooleanFromString", description: "Filter by archive state. Use true to return only archived sessions or false to exclude them. Omit to include both."),
                    ParameterDescriptor(name: "directory", location: .query, required: false, typeName: "AbsolutePath"),
                    ParameterDescriptor(name: "project", location: .query, required: false, typeName: "Project.ID"),
                    ParameterDescriptor(name: "subpath", location: .query, required: false, typeName: "RelativePath"),
                    ParameterDescriptor(name: "cursor", location: .query, required: false, typeName: "SessionsCursor", description: "Opaque pagination cursor returned as cursor.previous or cursor.next in the previous response."),
                ],
                successType: "SessionsResponse",
                errors: [
                    ProtocolErrorRef(InvalidCursorError.self),
                    ProtocolErrorRef(InvalidRequestError.self),
                ]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.stats",
                method: .get,
                path: "/api/experimental/session/stats",
                experimental: true,
                openAPIIdentifier: "experimental.session.stats",
                summary: "Get session statistics",
                description: "Aggregate local session activity, usage, and tool reliability for a time range.",
                queryParameters: [
                    ParameterDescriptor(name: "from", location: .query, required: false, typeName: "NumberFromString"),
                    ParameterDescriptor(name: "to", location: .query, required: false, typeName: "NumberFromString"),
                    ParameterDescriptor(name: "project", location: .query, required: false, typeName: "Project.ID"),
                    ParameterDescriptor(name: "timezone", location: .query, required: false, typeName: "String"),
                    ParameterDescriptor(name: "tools", location: .query, required: false, typeName: "SessionStats.ToolMode"),
                ],
                successType: "{ data: SessionStats.Info }",
                errors: [ProtocolErrorRef(InvalidRequestError.self)]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.create",
                method: .post,
                path: "/api/session",
                openAPIIdentifier: "session.create",
                summary: "Create session",
                description: "Create a session at the requested location. A parentID creates a linked child session at its parent's location.",
                payloadType: "SessionCreatePayload",
                successType: "{ data: Session.Info }",
                errors: [ProtocolErrorRef(SessionNotFoundError.self)]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.import",
                method: .post,
                path: "/api/experimental/session/import",
                experimental: true,
                openAPIIdentifier: "experimental.session.import",
                summary: "Import session",
                description: "Import a projected session transcript at the requested location. Accepts transcripts exported by earlier releases. If parentID is supplied, the parent session must already exist; import parents before children.",
                payloadType: "SessionImportPayload",
                successType: "{ data: Session.Info }",
                errors: [
                    ProtocolErrorRef(ConflictError.self),
                    ProtocolErrorRef(SessionNotFoundError.self),
                ]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.export",
                method: .get,
                path: "/api/experimental/session/:sessionID/export",
                experimental: true,
                openAPIIdentifier: "experimental.session.export",
                summary: "Export session",
                description: "Export a complete projected session transcript.",
                pathParameters: [sessionIDParam],
                queryParameters: [
                    ParameterDescriptor(name: "sanitize", location: .query, required: false, typeName: "BooleanFromString")
                ],
                successType: "{ data: SessionTransfer.Data }",
                errors: [
                    ProtocolErrorRef(SessionNotFoundError.self),
                    ProtocolErrorRef(UnknownError.self),
                ]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.active",
                method: .get,
                path: "/api/session/active",
                openAPIIdentifier: "session.active",
                summary: "List active sessions",
                description: "Retrieve foreground Session drains currently owned by this OpenCode process. Sessions absent from the result are inactive.",
                successType: "{ data: Record<Session.ID, SessionActive> }"
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.get",
                method: .get,
                path: "/api/session/:sessionID",
                openAPIIdentifier: "session.get",
                summary: "Get session",
                description: "Retrieve a session by ID.",
                pathParameters: [sessionIDParam],
                successType: "{ data: Session.Info }",
                errors: [ProtocolErrorRef(SessionNotFoundError.self)]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.remove",
                method: .delete,
                path: "/api/session/:sessionID",
                openAPIIdentifier: "session.remove",
                summary: "Delete session",
                description: "Delete a session and its child sessions.",
                pathParameters: [sessionIDParam],
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [ProtocolErrorRef(SessionNotFoundError.self)]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.fork",
                method: .post,
                path: "/api/session/:sessionID/fork",
                openAPIIdentifier: "session.fork",
                summary: "Fork session",
                description: "Create a child session by copying projected history before a message. Omit before to copy the full history.",
                pathParameters: [sessionIDParam],
                payloadType: "{ before?: SessionMessage.ID }",
                successType: "{ data: Session.Info }",
                errors: [
                    ProtocolErrorRef(SessionNotFoundError.self),
                    ProtocolErrorRef(MessageNotFoundError.self),
                    ProtocolErrorRef(InvalidRequestError.self),
                ]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.switchAgent",
                method: .post,
                path: "/api/session/:sessionID/agent",
                openAPIIdentifier: "session.switchAgent",
                summary: "Switch session agent",
                description: "Switch the agent used by subsequent provider turns.",
                pathParameters: [sessionIDParam],
                payloadType: "{ agent: Agent.ID }",
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [ProtocolErrorRef(SessionNotFoundError.self)]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.switchModel",
                method: .post,
                path: "/api/session/:sessionID/model",
                openAPIIdentifier: "session.switchModel",
                summary: "Switch session model",
                description: "Switch the model used by subsequent provider turns.",
                pathParameters: [sessionIDParam],
                payloadType: "{ model: Model.Ref }",
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [ProtocolErrorRef(SessionNotFoundError.self)]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.update",
                method: .patch,
                path: "/api/session/:sessionID",
                openAPIIdentifier: "session.update",
                summary: "Update session",
                description: "Update mutable session properties.",
                pathParameters: [sessionIDParam],
                payloadType: "SessionUpdatePayload",
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [
                    ProtocolErrorRef(SessionNotFoundError.self),
                    ProtocolErrorRef(LocationNotFoundError.self),
                ]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.move",
                method: .post,
                path: "/api/session/:sessionID/move",
                openAPIIdentifier: "session.move",
                summary: "Move session",
                description: "Move a session to another project directory at the requested delivery boundary.",
                pathParameters: [sessionIDParam],
                payloadType: "{ directory: AbsolutePath, delivery?: SessionInbox.Delivery }",
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [
                    ProtocolErrorRef(SessionNotFoundError.self),
                    ProtocolErrorRef(InvalidRequestError.self),
                ]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.prompt",
                method: .post,
                path: "/api/session/:sessionID/prompt",
                openAPIIdentifier: "session.prompt",
                summary: "Send message",
                description: "Durably admit one session input and schedule agent-loop execution unless resume is false.",
                pathParameters: [sessionIDParam],
                payloadType: "SessionPromptPayload",
                successType: "{ data: SessionInbox.User }",
                errors: [
                    ProtocolErrorRef(ConflictError.self),
                    ProtocolErrorRef(InvalidRequestError.self),
                    ProtocolErrorRef(SessionNotFoundError.self),
                ]
            ).withMiddleware(sessionLocationMiddleware),
            EndpointDescriptor(
                group: "server.session",
                name: "session.command",
                method: .post,
                path: "/api/session/:sessionID/command",
                openAPIIdentifier: "session.command",
                summary: "Run command",
                description: "Execute a slash command callback immediately.",
                pathParameters: [sessionIDParam],
                payloadType: "SessionCommandPayload",
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [
                    ProtocolErrorRef(SessionNotFoundError.self),
                    ProtocolErrorRef(CommandNotFoundError.self),
                    ProtocolErrorRef(CommandExecutionError.self),
                ]
            ).withMiddleware(sessionLocationMiddleware),
            EndpointDescriptor(
                group: "server.session",
                name: "session.skill",
                method: .post,
                path: "/api/experimental/session/:sessionID/skill",
                experimental: true,
                openAPIIdentifier: "experimental.session.skill",
                summary: "Activate skill",
                description: "Activate a skill for a session by appending a skill message and resuming execution.",
                pathParameters: [sessionIDParam],
                payloadType: "{ id: Skill.ID, resume?: Boolean }",
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [
                    ProtocolErrorRef(SessionNotFoundError.self),
                    ProtocolErrorRef(SkillNotFoundError.self),
                ]
            ).withMiddleware(sessionLocationMiddleware),
            EndpointDescriptor(
                group: "server.session",
                name: "session.synthetic",
                method: .post,
                path: "/api/session/:sessionID/synthetic",
                openAPIIdentifier: "session.synthetic",
                summary: "Add synthetic message",
                description: "Durably admit synthetic session input and schedule execution unless resume is false.",
                pathParameters: [sessionIDParam],
                payloadType: "SessionSyntheticPayload",
                successType: "{ data: SessionInbox.Synthetic }",
                errors: [
                    ProtocolErrorRef(ConflictError.self),
                    ProtocolErrorRef(SessionNotFoundError.self),
                ]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.shell",
                method: .post,
                path: "/api/session/:sessionID/shell",
                openAPIIdentifier: "session.shell",
                summary: "Run shell command",
                description: "Execute one shell command in the session's working directory. Emits a shell.started event before execution and a shell.ended event with the merged output after.",
                pathParameters: [sessionIDParam],
                payloadType: "{ id?: SessionMessage.ID, command: String }",
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [ProtocolErrorRef(SessionNotFoundError.self)]
            ).withMiddleware(sessionLocationMiddleware),
            EndpointDescriptor(
                group: "server.session",
                name: "session.compact",
                method: .post,
                path: "/api/session/:sessionID/compact",
                openAPIIdentifier: "session.compact",
                summary: "Compact session",
                description: "Durably admit a session compaction request. Steers by default: it runs at the next step boundary instead of waiting behind queued prompts.",
                pathParameters: [sessionIDParam],
                payloadType: "{ id?: SessionMessage.ID, delivery?: SessionInbox.Delivery }",
                successType: "{ data: SessionInbox.Compaction }",
                errors: [
                    ProtocolErrorRef(ConflictError.self),
                    ProtocolErrorRef(SessionNotFoundError.self),
                ]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.wait",
                method: .post,
                path: "/api/experimental/session/:sessionID/wait",
                experimental: true,
                openAPIIdentifier: "experimental.session.wait",
                summary: "Wait for session",
                description: "Wait for a session agent loop to become idle.",
                pathParameters: [sessionIDParam],
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [
                    ProtocolErrorRef(SessionNotFoundError.self),
                    ProtocolErrorRef(ServiceUnavailableError.self),
                ]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.revert.stage",
                method: .post,
                path: "/api/session/:sessionID/revert/stage",
                openAPIIdentifier: "session.revert.stage",
                summary: "Stage session revert",
                description: "Stage or move a reversible session boundary and optionally apply its file changes.",
                pathParameters: [sessionIDParam],
                payloadType: "{ messageID: SessionMessage.ID, files?: Boolean }",
                successType: "{ data: Session.Revert }",
                errors: [
                    ProtocolErrorRef(MessageNotFoundError.self),
                    ProtocolErrorRef(SessionNotFoundError.self),
                    ProtocolErrorRef(SessionBusyError.self),
                    ProtocolErrorRef(UnknownError.self),
                ]
            ).withMiddleware(sessionLocationMiddleware),
            EndpointDescriptor(
                group: "server.session",
                name: "session.revert.clear",
                method: .delete,
                path: "/api/session/:sessionID/revert",
                openAPIIdentifier: "session.revert.clear",
                summary: "Clear staged revert",
                pathParameters: [sessionIDParam],
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [
                    ProtocolErrorRef(SessionNotFoundError.self),
                    ProtocolErrorRef(SessionBusyError.self),
                    ProtocolErrorRef(UnknownError.self),
                ]
            ).withMiddleware(sessionLocationMiddleware),
            EndpointDescriptor(
                group: "server.session",
                name: "session.revert.commit",
                method: .post,
                path: "/api/session/:sessionID/revert/commit",
                openAPIIdentifier: "session.revert.commit",
                summary: "Commit staged revert",
                pathParameters: [sessionIDParam],
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [
                    ProtocolErrorRef(SessionNotFoundError.self),
                    ProtocolErrorRef(SessionBusyError.self),
                ]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.context",
                method: .get,
                path: "/api/session/:sessionID/context",
                openAPIIdentifier: "session.context",
                summary: "Get session context",
                description: "Retrieve the active context messages for a session (all messages after the last compaction).",
                pathParameters: [sessionIDParam],
                successType: "{ data: Session.Message.Info[] }",
                errors: [
                    ProtocolErrorRef(SessionNotFoundError.self),
                    ProtocolErrorRef(UnknownError.self),
                ]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.diff",
                method: .get,
                path: "/api/session/:sessionID/diff",
                openAPIIdentifier: "session.diff",
                summary: "Diff session turns",
                description: "Structured per-file diffs of the files a turn changed. A turn runs from the first prompt after the session was last idle until its next idle marker, so prompts steered in while it was busy belong to the same turn; `to` extends the range through a later turn. Compares the range's first recorded snapshot with its last; a step still running in the active session compares against the working copy. Ranges that span a location change are rejected. In sessions without any idle marker, a prompt's turn spans until the next user message.",
                pathParameters: [sessionIDParam],
                queryParameters: [
                    ParameterDescriptor(name: "from", location: .query, required: false, typeName: "SessionMessage.ID", description: "User message whose turn to diff. Defaults to the turn of the newest user message."),
                    ParameterDescriptor(name: "to", location: .query, required: false, typeName: "SessionMessage.ID", description: "Later user message whose turn ends the range. Defaults to the turn of `from` alone."),
                    ParameterDescriptor(name: "context", location: .query, required: false, typeName: "NonNegativeInt", description: "Unchanged lines around each hunk. Omit for full-file patches."),
                ],
                successType: "{ data: FileDiff.Info[] }",
                errors: [
                    ProtocolErrorRef(InvalidRequestError.self),
                    ProtocolErrorRef(MessageNotFoundError.self),
                    ProtocolErrorRef(SessionNotFoundError.self),
                    ProtocolErrorRef(UnknownError.self),
                    ProtocolErrorRef(LocationNotFoundError.self),
                ]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.inbox.list",
                method: .get,
                path: "/api/session/:sessionID/inbox",
                openAPIIdentifier: "session.inbox.list",
                summary: "List session inbox",
                description: "List durable enqueued session work not yet delivered, ordered by enqueue sequence. Includes user, synthetic, compaction, and move items.",
                pathParameters: [sessionIDParam],
                successType: "{ data: Session.Inbox.Info[] }",
                errors: [ProtocolErrorRef(SessionNotFoundError.self)]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.inbox.cancel",
                method: .delete,
                path: "/api/session/:sessionID/inbox/:inboxID",
                openAPIIdentifier: "session.inbox.cancel",
                summary: "Cancel inbox input",
                description: "Cancel an inbox item that has not yet been delivered. Unavailable items are a no-op.",
                pathParameters: [sessionIDParam, inboxIDParam],
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [ProtocolErrorRef(SessionNotFoundError.self)]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.inbox.update",
                method: .patch,
                path: "/api/session/:sessionID/inbox/:inboxID",
                openAPIIdentifier: "session.inbox.update",
                summary: "Update inbox item",
                description: "Change a pending inbox item's delivery mode. Steering wakes session execution.",
                pathParameters: [sessionIDParam, inboxIDParam],
                payloadType: "{ delivery: SessionInbox.Delivery }",
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [
                    ProtocolErrorRef(ConflictError.self),
                    ProtocolErrorRef(SessionNotFoundError.self),
                ]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.instructions.entry.list",
                method: .get,
                path: "/api/experimental/session/:sessionID/instructions/entries",
                experimental: true,
                openAPIIdentifier: "experimental.session.instructions.entry.list",
                summary: "List instruction entries",
                description: "List API-managed instruction entries attached to the session.",
                pathParameters: [sessionIDParam],
                successType: "{ data: InstructionEntry.Info[] }",
                errors: [ProtocolErrorRef(SessionNotFoundError.self)]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.instructions.entry.put",
                method: .put,
                path: "/api/experimental/session/:sessionID/instructions/entries/:key",
                experimental: true,
                openAPIIdentifier: "experimental.session.instructions.entry.put",
                summary: "Put instruction entry",
                description: "Attach or replace one durable instruction entry. Changes announce as updates at the next step boundary.",
                pathParameters: [sessionIDParam, keyParam],
                payloadType: "{ value: Json }",
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [
                    ProtocolErrorRef(SessionNotFoundError.self),
                    instructionEntryValueTooLargeErrorRef,
                ]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.instructions.entry.remove",
                method: .delete,
                path: "/api/experimental/session/:sessionID/instructions/entries/:key",
                experimental: true,
                openAPIIdentifier: "experimental.session.instructions.entry.remove",
                summary: "Remove instruction entry",
                description: "Remove one instruction entry; the removal is announced to the model at the next step boundary.",
                pathParameters: [sessionIDParam, keyParam],
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [ProtocolErrorRef(SessionNotFoundError.self)]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.generate",
                method: .post,
                path: "/api/session/:sessionID/generate",
                openAPIIdentifier: "session.generate",
                summary: "Generate text from session context",
                description: "Generate transient text from the current session context without mutating session history. Its tokens and cost count toward the session's totals.",
                pathParameters: [sessionIDParam],
                payloadType: "{ prompt: String }",
                successType: "SessionGenerateResponse",
                errors: [
                    ProtocolErrorRef(SessionNotFoundError.self),
                    ProtocolErrorRef(ServiceUnavailableError.self),
                ]
            ).withMiddleware(sessionLocationMiddleware),
            EndpointDescriptor(
                group: "server.session",
                name: "session.log",
                method: .get,
                path: "/api/experimental/session/:sessionID/log",
                experimental: true,
                openAPIIdentifier: "experimental.session.log",
                summary: "Read the session log",
                description: "Experimental durable session event log. Reads events after an exclusive aggregate sequence and continues with live events when follow=true.",
                pathParameters: [sessionIDParam],
                queryParameters: [
                    ParameterDescriptor(name: "after", location: .query, required: false, typeName: "Event.Seq"),
                    ParameterDescriptor(name: "follow", location: .query, required: false, typeName: "BooleanFromString"),
                ],
                successType: "StreamSse(SessionLogItem)",
                successEncoding: .sse,
                errors: [ProtocolErrorRef(SessionNotFoundError.self)]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.interrupt",
                method: .post,
                path: "/api/session/:sessionID/interrupt",
                openAPIIdentifier: "session.interrupt",
                summary: "Interrupt session execution",
                description: "Interrupt active execution owned by this OpenCode process. Returns interrupted=true when an active execution was interrupted and false for the idle no-op. When resume=true, execution resumes pending steering input and next-in-line control items (manual compaction, moves) while queued prompts remain parked.",
                pathParameters: [sessionIDParam],
                queryParameters: [
                    ParameterDescriptor(name: "resume", location: .query, required: false, typeName: "BooleanFromString")
                ],
                successType: "SessionInterruptResponse",
                errors: [ProtocolErrorRef(SessionNotFoundError.self)]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.background",
                method: .post,
                path: "/api/session/:sessionID/background",
                openAPIIdentifier: "session.background",
                summary: "Background blocking session tools",
                description: "Move active foreground backgroundable tools for this session into background observation. Idle requests are a no-op.",
                pathParameters: [sessionIDParam],
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [ProtocolErrorRef(SessionNotFoundError.self)]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.message",
                method: .get,
                path: "/api/session/:sessionID/message/:messageID",
                openAPIIdentifier: "session.message.get",
                summary: "Get session message",
                description: "Retrieve one projected message owned by the Session.",
                pathParameters: [
                    sessionIDParam,
                    ParameterDescriptor(name: "messageID", location: .path, required: true, typeName: "SessionMessage.ID"),
                ],
                successType: "{ data: Session.Message.Info }",
                errors: [
                    ProtocolErrorRef(SessionNotFoundError.self),
                    ProtocolErrorRef(MessageNotFoundError.self),
                ]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.form.list",
                method: .get,
                path: "/api/session/:sessionID/form",
                openAPIIdentifier: "session.form.list",
                summary: "List session forms",
                description: "Retrieve pending forms for a session.",
                pathParameters: [formSessionIDParam],
                successType: "{ data: Form.Info[] }",
                errors: [ProtocolErrorRef(SessionNotFoundError.self)]
            ).withMiddleware(formLocationMiddleware),
            EndpointDescriptor(
                group: "server.session",
                name: "session.form.create",
                method: .post,
                path: "/api/session/:sessionID/form",
                openAPIIdentifier: "session.form.create",
                summary: "Create session form",
                description: "Create a form for a session.",
                pathParameters: [formSessionIDParam],
                payloadType: "Form.CreatePayload",
                successType: "{ data: Form.Info }",
                errors: [
                    ProtocolErrorRef(SessionNotFoundError.self),
                    ProtocolErrorRef(ConflictError.self),
                    ProtocolErrorRef(InvalidRequestError.self),
                ]
            ).withMiddleware(formLocationMiddleware),
            EndpointDescriptor(
                group: "server.session",
                name: "session.form.get",
                method: .get,
                path: "/api/session/:sessionID/form/:formID",
                openAPIIdentifier: "session.form.get",
                summary: "Get session form",
                description: "Retrieve a form and its current state for a session.",
                pathParameters: [formSessionIDParam, formIDParam],
                successType: "{ data: Form.Detail }",
                errors: [
                    ProtocolErrorRef(SessionNotFoundError.self),
                    ProtocolErrorRef(FormNotFoundError.self),
                ]
            ).withMiddleware(formLocationMiddleware),
            EndpointDescriptor(
                group: "server.session",
                name: "session.form.reply",
                method: .post,
                path: "/api/session/:sessionID/form/:formID/reply",
                openAPIIdentifier: "session.form.reply",
                summary: "Reply to form",
                description: "Submit an answer to a pending form.",
                pathParameters: [formSessionIDParam, formIDParam],
                payloadType: "Form.Reply",
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [
                    ProtocolErrorRef(SessionNotFoundError.self),
                    ProtocolErrorRef(FormAlreadySettledError.self),
                    ProtocolErrorRef(FormInvalidAnswerError.self),
                    ProtocolErrorRef(FormNotFoundError.self),
                ]
            ).withMiddleware(formLocationMiddleware),
            EndpointDescriptor(
                group: "server.session",
                name: "session.form.cancel",
                method: .delete,
                path: "/api/session/:sessionID/form/:formID",
                openAPIIdentifier: "session.form.cancel",
                summary: "Cancel form",
                description: "Cancel a pending form, optionally telling the asker why it was not answered.",
                pathParameters: [formSessionIDParam, formIDParam],
                queryParameters: [
                    ParameterDescriptor(name: "message", location: .query, required: false, typeName: "String")
                ],
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [
                    ProtocolErrorRef(SessionNotFoundError.self),
                    ProtocolErrorRef(FormAlreadySettledError.self),
                    ProtocolErrorRef(FormNotFoundError.self),
                ]
            ).withMiddleware(formLocationMiddleware),
            EndpointDescriptor(
                group: "server.session",
                name: "session.environment",
                method: .put,
                path: "/api/session/:sessionID/environment",
                openAPIIdentifier: "session.environment",
                summary: "Set session environment",
                description: "Replace the process environment used by local shell commands for this session.",
                pathParameters: [sessionIDParam],
                payloadType: "{ variables: Record<String, String> }",
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [ProtocolErrorRef(SessionNotFoundError.self)]
            ),
            EndpointDescriptor(
                group: "server.session",
                name: "session.view",
                method: .post,
                path: "/api/session/:sessionID/view",
                openAPIIdentifier: "session.view",
                summary: "View session",
                description: "Mark the idle transition observed by the viewer as viewed.",
                pathParameters: [sessionIDParam],
                payloadType: "{ idle: DateTimeUtcFromMillis }",
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [ProtocolErrorRef(SessionNotFoundError.self)]
            ),
        ]
    )
}

// MARK: - 32. shell.ts

// parity: protocol/src/groups/shell.ts#ShellGroup [status=implemented hash=55ac8f60a5bb]
public let ShellGroup = EndpointGroupDescriptor(
    identifier: "server.shell",
    title: "shell",
    description: "Location-scoped shell command routes.",
    endpoints: [
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.shell",
                name: "shell.list",
                method: .get,
                path: "/api/shell",
                openAPIIdentifier: "shell.list",
                summary: "List running shell commands",
                description: "List currently running shell commands for a location. Exited commands are not included.",
                queryParameters: [locationQueryParameter],
                successType: "Location.response(Shell.Info[])"
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.shell",
                name: "shell.create",
                method: .post,
                path: "/api/shell",
                openAPIIdentifier: "shell.create",
                summary: "Run shell command",
                description: "Spawn one non-interactive shell command for a location. Combined stdout/stderr is captured to a file pageable via output.",
                queryParameters: [locationQueryParameter],
                payloadType: "Shell.CreateInput",
                successType: "Location.response(Shell.Info)"
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.shell",
                name: "shell.get",
                method: .get,
                path: "/api/shell/:id",
                openAPIIdentifier: "shell.get",
                summary: "Get shell command",
                description: "Get one shell command, including its status and exit code once exited.",
                pathParameters: [
                    ParameterDescriptor(name: "id", location: .path, required: true, typeName: "Shell.ID")
                ],
                queryParameters: [locationQueryParameter],
                successType: "Location.response(Shell.Info)",
                errors: [ProtocolErrorRef(ShellNotFoundError.self)]
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.shell",
                name: "shell.output",
                method: .get,
                path: "/api/shell/:id/output",
                openAPIIdentifier: "shell.output",
                summary: "Read shell output",
                description: "Page through captured combined output by absolute byte cursor.",
                pathParameters: [
                    ParameterDescriptor(name: "id", location: .path, required: true, typeName: "Shell.ID")
                ],
                queryParameters: [
                    locationQueryParameter,
                    ParameterDescriptor(name: "cursor", location: .query, required: false, typeName: "NonNegativeInt"),
                    ParameterDescriptor(name: "limit", location: .query, required: false, typeName: "NonNegativeInt"),
                ],
                successType: "Location.response(Shell.Output)",
                errors: [ProtocolErrorRef(ShellNotFoundError.self)]
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.shell",
                name: "shell.remove",
                method: .delete,
                path: "/api/shell/:id",
                openAPIIdentifier: "shell.remove",
                summary: "Remove shell command",
                description: "Terminate and remove one shell command and its retained output.",
                pathParameters: [
                    ParameterDescriptor(name: "id", location: .path, required: true, typeName: "Shell.ID")
                ],
                queryParameters: [locationQueryParameter],
                successType: "NoContent",
                successEncoding: .noContent
            )
        ),
    ]
)

// MARK: - 33. skill.ts

// parity: protocol/src/groups/skill.ts#SkillGroup [status=implemented hash=02137f0c62e4]
public let SkillGroup = EndpointGroupDescriptor(
    identifier: "server.skill",
    title: "skill",
    description: "Experimental skill routes.",
    endpoints: [
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.skill",
                name: "skill.list",
                method: .get,
                path: "/api/skill",
                openAPIIdentifier: "skill.list",
                summary: "List skills",
                description: "Retrieve currently registered skills.",
                queryParameters: [locationQueryParameter],
                successType: "Location.response(Skill.Info[])"
            )
        )
    ]
)

// MARK: - 34. usage.ts

// parity: protocol/src/groups/usage.ts#UsageGroup [status=implemented hash=20fbe3a3d17a]
public let UsageGroup = EndpointGroupDescriptor(
    identifier: "server.usage",
    title: "usage",
    description: "Experimental usage limit routes.",
    endpoints: [
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.usage",
                name: "usage.limits",
                method: .get,
                path: "/api/experimental/usage/limits",
                experimental: true,
                openAPIIdentifier: "experimental.usage.limits",
                summary: "Get usage limits",
                description: "Return the OpenCode Go allowance and Console budgets of the OpenCode Console workspace the location is signed in to, or null when it isn't signed in.",
                queryParameters: [locationQueryParameter],
                successType: "Location.response(UsageLimits.Info?)",
                errors: [ProtocolErrorRef(ServiceUnavailableError.self)]
            )
        )
    ]
)

// MARK: - 35. vcs.ts

// parity: protocol/src/groups/vcs.ts#VcsInitNotSupportedError [status=implemented hash=d6fc64421433]
public struct VcsInitNotSupportedError: ProtocolError {
    public static let tag = "VcsInitNotSupportedError"
    public static let httpStatusCode = 501

    public let providerID: String
    public let message: String

    public init(providerID: String, message: String) {
        self.providerID = providerID
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, providerID, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.providerID = try c.decode(String.self, forKey: .providerID)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(providerID, forKey: .providerID)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/groups/vcs.ts#VcsGroup [status=implemented hash=28457bc4a3bb]
public let VcsGroup = EndpointGroupDescriptor(
    identifier: "server.vcs",
    title: "vcs",
    description: "Location-scoped version control routes.",
    endpoints: [
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.vcs",
                name: "vcs.init",
                method: .post,
                path: "/api/vcs/init",
                openAPIIdentifier: "vcs.init",
                summary: "Initialize VCS repository",
                description: "Initialize a repository using the selected VCS provider in a markerless project's directory and refresh its location services. Omitting provider defaults to git; built-in git and hg providers support initialization. An unknown provider returns 400; a registered provider without init returns 501.",
                queryParameters: [
                    locationQueryParameter,
                    ParameterDescriptor(name: "provider", location: .query, required: false, typeName: "String"),
                ],
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [
                    ProtocolErrorRef(ConflictError.self),
                    ProtocolErrorRef(InvalidRequestError.self),
                    ProtocolErrorRef(VcsInitNotSupportedError.self),
                    ProtocolErrorRef(ServiceUnavailableError.self),
                ]
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.vcs",
                name: "vcs.get",
                method: .get,
                path: "/api/vcs",
                openAPIIdentifier: "vcs.get",
                summary: "VCS info",
                description: "Get current and default branch information for the requested location.",
                queryParameters: [locationQueryParameter],
                successType: "Location.response(Vcs.Info)"
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.vcs",
                name: "vcs.base",
                method: .get,
                path: "/api/vcs/base",
                openAPIIdentifier: "vcs.base",
                summary: "VCS review base",
                description: "Infer a local review base from named branch creation history, or the repository default only when currently on that branch. Returns null before the first commit or when the provider lacks base metadata; ambiguous Git history requires an explicit base on diff requests.",
                queryParameters: [locationQueryParameter],
                successType: "Location.response(Vcs.Base?)",
                errors: [ProtocolErrorRef(ServiceUnavailableError.self)]
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.vcs",
                name: "vcs.status",
                method: .get,
                path: "/api/vcs/status",
                openAPIIdentifier: "vcs.status",
                summary: "VCS status",
                description: "List uncommitted working-copy changes relative to the requested location.",
                queryParameters: [locationQueryParameter],
                successType: "Location.response(Vcs.FileStatus[])"
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.vcs",
                name: "vcs.branch.list",
                method: .get,
                path: "/api/vcs/branch",
                openAPIIdentifier: "vcs.branch.list",
                summary: "VCS branches",
                description: "List local and remote branches available at the requested location.",
                queryParameters: [
                    locationQueryParameter,
                    ParameterDescriptor(name: "search", location: .query, required: false, typeName: "String"),
                    ParameterDescriptor(name: "limit", location: .query, required: false, typeName: "PositiveInt"),
                ],
                successType: "Location.response(Vcs.BranchList)"
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.vcs",
                name: "vcs.diff",
                method: .get,
                path: "/api/vcs/diff",
                openAPIIdentifier: "vcs.diff",
                summary: "VCS diff",
                description: "Diff HEAD to the working copy (working), the base merge-base to the working copy (branch), or the base merge-base to HEAD (committed). Omitting base preserves repository-default comparison; supplying it overrides the comparison without saving it.",
                queryParameters: [
                    locationQueryParameter,
                    ParameterDescriptor(name: "mode", location: .query, required: true, typeName: "Vcs.Mode"),
                    ParameterDescriptor(name: "base", location: .query, required: false, typeName: "String"),
                    ParameterDescriptor(name: "context", location: .query, required: false, typeName: "NonNegativeInt"),
                    ParameterDescriptor(name: "untracked", location: .query, required: false, typeName: "Vcs.Untracked"),
                ],
                successType: "Location.response(FileDiff.Info[])",
                errors: [ProtocolErrorRef(ServiceUnavailableError.self)]
            )
        ),
    ]
)

// MARK: - 36. voice.ts

// parity: protocol/src/groups/voice.ts#VoiceTransportType [status=implemented hash=66736ceb8281]
public enum VoiceTransportType: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case webrtc
    case websocket
}

// parity: protocol/src/groups/voice.ts#VoiceModel [status=implemented hash=7faec1da7329]
public struct VoiceModel: Equatable, Hashable, Sendable, Codable {
    public let model: String
    public let provider: String
    public let transports: [VoiceTransportType]
    public let available: Bool

    public init(model: String, provider: String, transports: [VoiceTransportType], available: Bool) {
        self.model = model
        self.provider = provider
        self.transports = transports
        self.available = available
    }
}

// parity: protocol/src/groups/voice.ts#VoiceWebRTCTransportInput [status=implemented hash=9d26ff9e5d4f]
public struct VoiceWebRTCTransportInput: Equatable, Hashable, Sendable, Codable {
    public let type: String
    public let sdp: String
    public let dcid: Double?

    public init(sdp: String, dcid: Double? = nil) {
        self.type = "webrtc"
        self.sdp = sdp
        self.dcid = dcid
    }

    private enum CodingKeys: String, CodingKey {
        case type, sdp, dcid
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        guard type == "webrtc" else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "Expected type 'webrtc', got '\(type)'"
            )
        }
        self.type = type
        self.sdp = try c.decode(String.self, forKey: .sdp)
        self.dcid = try c.decodeIfPresent(Double.self, forKey: .dcid)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("webrtc", forKey: .type)
        try c.encode(sdp, forKey: .sdp)
        try c.encodeIfPresent(dcid, forKey: .dcid)
    }
}

// parity: protocol/src/groups/voice.ts#VoiceWebSocketTransportInput [status=implemented hash=83beef344d4c]
public struct VoiceWebSocketTransportInput: Equatable, Hashable, Sendable, Codable {
    public let type: String

    public init() {
        self.type = "websocket"
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        guard type == "websocket" else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "Expected type 'websocket', got '\(type)'"
            )
        }
        self.type = type
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("websocket", forKey: .type)
    }
}

// parity: protocol/src/groups/voice.ts#VoiceTransportInput [status=implemented hash=af447a72775e]
public enum VoiceTransportInput: Equatable, Hashable, Sendable, Codable {
    case webrtc(VoiceWebRTCTransportInput)
    case websocket(VoiceWebSocketTransportInput)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(VoiceTransportType.self, forKey: .type)
        switch type {
        case .webrtc:
            self = .webrtc(try VoiceWebRTCTransportInput(from: decoder))
        case .websocket:
            self = .websocket(try VoiceWebSocketTransportInput(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .webrtc(let v): try v.encode(to: encoder)
        case .websocket(let v): try v.encode(to: encoder)
        }
    }
}

// parity: protocol/src/groups/voice.ts#VoiceWebRTCTransport [status=implemented hash=ec4155be63fe]
public struct VoiceWebRTCTransport: Equatable, Hashable, Sendable, Codable {
    public let type: String
    public let sdp: String

    public init(sdp: String) {
        self.type = "webrtc"
        self.sdp = sdp
    }

    private enum CodingKeys: String, CodingKey {
        case type, sdp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        guard type == "webrtc" else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "Expected type 'webrtc', got '\(type)'"
            )
        }
        self.type = type
        self.sdp = try c.decode(String.self, forKey: .sdp)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("webrtc", forKey: .type)
        try c.encode(sdp, forKey: .sdp)
    }
}

// parity: protocol/src/groups/voice.ts#VoiceWebSocketTransport [status=implemented hash=a53b34283b47]
public struct VoiceWebSocketTransport: Equatable, Hashable, Sendable, Codable {
    public let type: String
    public let url: String
    public let token: String
    public let expiresAt: Double

    public init(url: String, token: String, expiresAt: Double) {
        self.type = "websocket"
        self.url = url
        self.token = token
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case type, url, token, expiresAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        guard type == "websocket" else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "Expected type 'websocket', got '\(type)'"
            )
        }
        self.type = type
        self.url = try c.decode(String.self, forKey: .url)
        self.token = try c.decode(String.self, forKey: .token)
        self.expiresAt = try c.decode(Double.self, forKey: .expiresAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("websocket", forKey: .type)
        try c.encode(url, forKey: .url)
        try c.encode(token, forKey: .token)
        try c.encode(expiresAt, forKey: .expiresAt)
    }
}

// parity: protocol/src/groups/voice.ts#VoiceTransport [status=implemented hash=625a072b22c5]
public enum VoiceTransport: Equatable, Hashable, Sendable, Codable {
    case webrtc(VoiceWebRTCTransport)
    case websocket(VoiceWebSocketTransport)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(VoiceTransportType.self, forKey: .type)
        switch type {
        case .webrtc:
            self = .webrtc(try VoiceWebRTCTransport(from: decoder))
        case .websocket:
            self = .websocket(try VoiceWebSocketTransport(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .webrtc(let v): try v.encode(to: encoder)
        case .websocket(let v): try v.encode(to: encoder)
        }
    }
}

// parity: protocol/src/groups/voice.ts#VoiceGroup [status=implemented hash=ed6a58e0fedf]
public let VoiceGroup = EndpointGroupDescriptor(
    identifier: "server.voice",
    title: "voice",
    description: "Experimental server-brokered voice session routes.",
    endpoints: [
        EndpointDescriptor(
            group: "server.voice",
            name: "voice.models",
            method: .get,
            path: "/api/experimental/voice/models",
            experimental: true,
            openAPIIdentifier: "experimental.voice.models",
            summary: "List voice models",
            description: "List supported voice models, their transports, and whether the server has a usable API key for each provider.",
            successType: "VoiceModelsResponse",
            errors: [
                ProtocolErrorRef(ServiceUnavailableError.self),
                ProtocolErrorRef(LocationNotFoundError.self),
            ]
        ),
        EndpointDescriptor(
            group: "server.voice",
            name: "voice.session",
            method: .post,
            path: "/api/experimental/voice/session",
            experimental: true,
            openAPIIdentifier: "experimental.voice.session",
            summary: "Create voice session",
            description: "Create a server-brokered voice session using the server's configured provider credentials and return the WebRTC SDP answer or WebSocket ephemeral token.",
            payloadType: "{ model: String, session?: Record<String, Unknown>, transport: VoiceTransportInput }",
            successType: "VoiceSessionResponse",
            errors: [
                ProtocolErrorRef(InvalidRequestError.self),
                ProtocolErrorRef(ServiceUnavailableError.self),
                ProtocolErrorRef(LocationNotFoundError.self),
            ]
        ),
    ]
)

// MARK: - 37. websearch.ts

// parity: protocol/src/groups/websearch.ts#WebSearchGroup [status=implemented hash=1a88069fc991]
public let WebSearchGroup = EndpointGroupDescriptor(
    identifier: "server.websearch",
    title: "websearch",
    description: "Location-scoped web search routes.",
    endpoints: [
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.websearch",
                name: "websearch.providers",
                method: .get,
                path: "/api/websearch/provider",
                openAPIIdentifier: "websearch.providers",
                summary: "List web search providers",
                description: "Return the registered web search providers.",
                queryParameters: [locationQueryParameter],
                successType: "Location.response(WebSearch.Provider[])",
                errors: [ProtocolErrorRef(ServiceUnavailableError.self)]
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.websearch",
                name: "websearch.query",
                method: .post,
                path: "/api/websearch",
                openAPIIdentifier: "websearch.query",
                summary: "Search the web",
                description: "Run one web search through the selected provider. Specify a provider to override the configured default.",
                queryParameters: [locationQueryParameter],
                payloadType: "WebSearch.Input",
                successType: "Location.response(WebSearch.Response)",
                errors: [
                    ProtocolErrorRef(InvalidRequestError.self),
                    ProtocolErrorRef(ServiceUnavailableError.self),
                ]
            )
        ),
    ]
)

// MARK: - 38. worktree.ts

// parity: protocol/src/groups/worktree.ts#WorktreeError [status=implemented hash=f980a02f5d9b]
public struct WorktreeError: ProtocolError {
    public static let tag = "WorktreeError"
    public static let httpStatusCode = 400

    public struct DataPayload: Equatable, Hashable, Sendable, Codable {
        public let message: String
        public let forceRequired: Bool?

        public init(message: String, forceRequired: Bool? = nil) {
            self.message = message
            self.forceRequired = forceRequired
        }
    }

    public let name: String
    public let data: DataPayload

    public var message: String { data.message }

    public init(data: DataPayload) {
        self.name = Self.tag
        self.data = data
    }

    public init(message: String, forceRequired: Bool? = nil) {
        self.name = Self.tag
        self.data = DataPayload(message: message, forceRequired: forceRequired)
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, name, data
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        let decodedName = try c.decode(String.self, forKey: .name)
        guard decodedName == Self.tag else {
            throw DecodingError.dataCorruptedError(
                forKey: .name,
                in: c,
                debugDescription: "Expected name '\(Self.tag)', got '\(decodedName)'"
            )
        }
        self.name = decodedName
        self.data = try c.decode(DataPayload.self, forKey: .data)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(name, forKey: .name)
        try c.encode(data, forKey: .data)
    }
}

// parity: protocol/src/groups/worktree.ts#WorktreeGroup [status=implemented hash=b919fbc0fa18]
public let WorktreeGroup = EndpointGroupDescriptor(
    identifier: "server.worktree",
    title: "worktree",
    description: "Project-based worktree management routes.",
    endpoints: [
        EndpointDescriptor(
            group: "server.worktree",
            name: "worktree.list",
            method: .get,
            path: "/api/worktree",
            openAPIIdentifier: "worktree.list",
            summary: "List worktrees",
            description: "Return the project's saved worktree inventory without loading configuration or running discovery.",
            queryParameters: [
                ParameterDescriptor(name: "projectID", location: .query, required: true, typeName: "Project.ID")
            ],
            successType: "Worktree.List",
            errors: [ProtocolErrorRef(ProjectNotFoundError.self)]
        ),
        EndpointDescriptor(
            group: "server.worktree",
            name: "worktree.create",
            method: .post,
            path: "/api/worktree",
            openAPIIdentifier: "worktree.create",
            summary: "Create worktree",
            description: "Load the project's canonical configuration, create a local worktree using its selected strategy, then run the project's setup script.",
            payloadType: "Worktree.CreateInput",
            successType: "Worktree.Info",
            errors: [
                ProtocolErrorRef(WorktreeError.self),
                ProtocolErrorRef(ProjectNotFoundError.self),
            ]
        ),
        EndpointDescriptor(
            group: "server.worktree",
            name: "worktree.remove",
            method: .delete,
            path: "/api/worktree",
            openAPIIdentifier: "worktree.remove",
            summary: "Remove worktree",
            description: "Load the project's canonical configuration and remove a saved worktree using its recorded strategy.",
            payloadType: "Worktree.RemoveInput",
            successType: "NoContent",
            successEncoding: .noContent,
            errors: [
                ProtocolErrorRef(WorktreeError.self),
                ProtocolErrorRef(ProjectNotFoundError.self),
            ]
        ),
        EndpointDescriptor(
            group: "server.worktree",
            name: "worktree.refresh",
            method: .post,
            path: "/api/worktree/refresh",
            openAPIIdentifier: "worktree.refresh",
            summary: "Refresh worktrees",
            description: "Load the project's canonical configuration, discover worktrees across known checkout roots using all available strategies, and reconcile saved state.",
            payloadType: "{ projectID: Project.ID }",
            successType: "NoContent",
            successEncoding: .noContent,
            errors: [
                ProtocolErrorRef(WorktreeError.self),
                ProtocolErrorRef(ProjectNotFoundError.self),
            ]
        ),
    ]
)

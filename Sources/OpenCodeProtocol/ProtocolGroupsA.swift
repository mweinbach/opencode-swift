import OpenCodeSchema

// MARK: - Helper Parameter Factories

internal let locationQueryParameter = ParameterDescriptor(
    name: "location",
    location: .query,
    required: false,
    typeName: "LocationQuery"
)

// MARK: - 1. agent.ts

// parity: protocol/src/groups/agent.ts#AgentGroup [status=implemented hash=d454e44ad27d]
public let AgentGroup: EndpointGroupDescriptor = EndpointGroupDescriptor(
    identifier: "server.agent",
    title: "agent",
    endpoints: [
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.agent",
                name: "agent.list",
                method: .get,
                path: "/api/agent",
                openAPIIdentifier: "agent.list",
                summary: "List agents",
                description: "Retrieve currently registered agents.",
                queryParameters: [locationQueryParameter],
                successType: "Location.response(Agent.Info[])"
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.agent",
                name: "agent.get",
                method: .get,
                path: "/api/agent/:agentID",
                openAPIIdentifier: "agent.get",
                summary: "Get agent",
                description: "Retrieve a single currently registered agent.",
                pathParameters: [
                    ParameterDescriptor(name: "agentID", location: .path, required: true, typeName: "Agent.ID")
                ],
                queryParameters: [locationQueryParameter],
                successType: "Location.response(Agent.Info)",
                errors: [ProtocolErrorRef(AgentNotFoundError.self)]
            )
        ),
    ]
)

// MARK: - 2. artifact.ts

private let artifactExperimentalNote =
    "Experimental: needs experimental.artifacts in the Location's config and may change without notice."
private let artifactCommonErrors: [ProtocolErrorRef] = [
    ProtocolErrorRef(ForbiddenError.self),
    ProtocolErrorRef(LocationNotFoundError.self),
    ProtocolErrorRef(ServiceUnavailableError.self),
]
private let artifactItemErrors: [ProtocolErrorRef] = [
    ProtocolErrorRef(ArtifactNotFoundError.self),
] + artifactCommonErrors

/// Lives in the `server.experimental` group (see `ExperimentalGroup`).
// parity: protocol/src/groups/artifact.ts#ArtifactEndpoints [status=implemented hash=282d9fb24602]
public let ArtifactEndpoints: [EndpointDescriptor] = [
    locationQueryOpenApi(
        EndpointDescriptor(
            group: "server.experimental",
            name: "artifacts.providers",
            method: .get,
            path: "/api/experimental/artifacts/providers",
            experimental: true,
            openAPIIdentifier: "experimental.artifacts.providers",
            summary: "List artifact providers",
            description: "Return active artifact providers and default. \(artifactExperimentalNote)",
            queryParameters: [locationQueryParameter],
            successType: "Location.response(Artifact.Provider[])",
            errors: artifactCommonErrors,
            tags: ["experimental"]
        )
    ),
    locationQueryOpenApi(
        EndpointDescriptor(
            group: "server.experimental",
            name: "artifacts.list",
            method: .get,
            path: "/api/experimental/artifacts",
            experimental: true,
            openAPIIdentifier: "experimental.artifacts.list",
            summary: "List artifacts",
            description: "List published artifacts, newest update first. \(artifactExperimentalNote)",
            queryParameters: [
                locationQueryParameter,
                ParameterDescriptor(name: "sessionID", location: .query, required: false, typeName: "Session.ID"),
                ParameterDescriptor(name: "provider", location: .query, required: false, typeName: "Artifact.ProviderID"),
            ],
            successType: "Location.response(Artifact.Info[])",
            errors: [ProtocolErrorRef(SessionNotFoundError.self)] + artifactCommonErrors,
            tags: ["experimental"]
        )
    ),
    locationQueryOpenApi(
        EndpointDescriptor(
            group: "server.experimental",
            name: "artifacts.create",
            method: .post,
            path: "/api/experimental/artifacts",
            experimental: true,
            openAPIIdentifier: "experimental.artifacts.create",
            summary: "Create artifact",
            description: "Publish a new artifact through the selected or default artifact provider. \(artifactExperimentalNote)",
            queryParameters: [locationQueryParameter],
            payloadType: "Artifact.CreateInput",
            successType: "Location.response(Artifact.Info)",
            errors: [
                ProtocolErrorRef(InvalidRequestError.self),
                ProtocolErrorRef(ProviderNotFoundError.self),
                ProtocolErrorRef(SessionNotFoundError.self),
            ] + artifactCommonErrors,
            tags: ["experimental"]
        )
    ),
    locationQueryOpenApi(
        EndpointDescriptor(
            group: "server.experimental",
            name: "artifacts.get",
            method: .get,
            path: "/api/experimental/artifacts/:artifactID",
            experimental: true,
            openAPIIdentifier: "experimental.artifacts.get",
            summary: "Read artifact",
            description: "Read an artifact's metadata and file contents. \(artifactExperimentalNote)",
            pathParameters: [
                ParameterDescriptor(name: "artifactID", location: .path, required: true, typeName: "Artifact.ID")
            ],
            queryParameters: [locationQueryParameter],
            successType: "Location.response(Artifact.Content)",
            errors: artifactItemErrors,
            tags: ["experimental"]
        )
    ),
    locationQueryOpenApi(
        EndpointDescriptor(
            group: "server.experimental",
            name: "artifacts.update",
            method: .patch,
            path: "/api/experimental/artifacts/:artifactID",
            experimental: true,
            openAPIIdentifier: "experimental.artifacts.update",
            summary: "Update artifact",
            description: "Replace an artifact's files at the same ID and URL. \(artifactExperimentalNote)",
            pathParameters: [
                ParameterDescriptor(name: "artifactID", location: .path, required: true, typeName: "Artifact.ID")
            ],
            queryParameters: [locationQueryParameter],
            payloadType: "Artifact.UpdateInput",
            successType: "Location.response(Artifact.Info)",
            errors: [
                ProtocolErrorRef(InvalidRequestError.self),
                ProtocolErrorRef(SessionNotFoundError.self),
            ] + artifactItemErrors,
            tags: ["experimental"]
        )
    ),
    locationQueryOpenApi(
        EndpointDescriptor(
            group: "server.experimental",
            name: "artifacts.delete",
            method: .delete,
            path: "/api/experimental/artifacts/:artifactID",
            experimental: true,
            openAPIIdentifier: "experimental.artifacts.delete",
            summary: "Delete artifact",
            description: "Remove an artifact and its stored files. \(artifactExperimentalNote)",
            pathParameters: [
                ParameterDescriptor(name: "artifactID", location: .path, required: true, typeName: "Artifact.ID")
            ],
            queryParameters: [locationQueryParameter],
            successType: "NoContent",
            successEncoding: .noContent,
            errors: artifactItemErrors,
            tags: ["experimental"]
        )
    ),
    locationQueryOpenApi(
        EndpointDescriptor(
            group: "server.experimental",
            name: "artifacts.view",
            method: .get,
            path: "/api/experimental/artifacts/:artifactID/view/*",
            experimental: true,
            openAPIIdentifier: "experimental.artifacts.view",
            summary: "View local artifact",
            description: "Serve HTML and static files from the local provider. \(artifactExperimentalNote)",
            pathParameters: [
                ParameterDescriptor(name: "artifactID", location: .path, required: true, typeName: "Artifact.ID")
            ],
            queryParameters: [locationQueryParameter],
            successType: "Uint8Array",
            successEncoding: .binary,
            errors: [
                ProtocolErrorRef(FileNotFoundError.self),
                ProtocolErrorRef(InvalidRequestError.self),
            ] + artifactItemErrors,
            tags: ["experimental"]
        )
    ),
]

// MARK: - 3. automation.ts

private let automationExperimentalNote =
    "Experimental: needs experimental.automations in the config of the automation's directory and may change without compatibility guarantees."
private let automationItemErrors: [ProtocolErrorRef] = [
    ProtocolErrorRef(AutomationNotFoundError.self),
    ProtocolErrorRef(ForbiddenError.self),
]

/// Request payload for `POST /api/experimental/automation` (`Automation.CreatePayload`).
// parity: protocol/src/groups/automation.ts#CreatePayload [status=implemented hash=161b353c838a]
public struct AutomationCreatePayload: Equatable, Hashable, Sendable, Codable {
    public let payload: [String: JSONValue]

    public init(payload: [String: JSONValue]) {
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.payload = try container.decode([String: JSONValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(payload)
    }
}

/// Query parameters for `GET /api/experimental/automation` (`Automation.ListQuery`).
// parity: protocol/src/groups/automation.ts#ListQuery [status=implemented hash=6101403f4322]
public struct AutomationListQuery: Equatable, Hashable, Sendable, Codable {
    public let sessionID: SessionID?
    public let directory: String?

    public init(sessionID: SessionID? = nil, directory: String? = nil) {
        self.sessionID = sessionID
        self.directory = directory
    }
}

/// Lives in the `server.experimental` group (see `ExperimentalGroup`).
// parity: protocol/src/groups/automation.ts#AutomationEndpoints [status=implemented hash=84dc5ea0bd86]
public let AutomationEndpoints: [EndpointDescriptor] = [
    EndpointDescriptor(
        group: "server.experimental",
        name: "automation.create",
        method: .post,
        path: "/api/experimental/automation",
        experimental: true,
        openAPIIdentifier: "experimental.automation.create",
        summary: "Create automation",
        description: "Create an automation that sends a prompt or runs a Code Mode program at a time, every interval, or on a cron. Creating an MCP event watch requires the automation_create tool in a local session; a session ID over HTTP is not a watch authorization. \(automationExperimentalNote)",
        payloadType: "Automation.CreatePayload",
        successType: "{ data: Automation.Info }",
        errors: [
            ProtocolErrorRef(InvalidRequestError.self),
            ProtocolErrorRef(SessionNotFoundError.self),
            ProtocolErrorRef(ForbiddenError.self),
        ],
        tags: ["experimental"]
    ),
    EndpointDescriptor(
        group: "server.experimental",
        name: "automation.list",
        method: .get,
        path: "/api/experimental/automation",
        experimental: true,
        openAPIIdentifier: "experimental.automation.list",
        summary: "List automations",
        description: "List automations, oldest first. \(automationExperimentalNote)",
        queryParameters: [
            ParameterDescriptor(
                name: "sessionID",
                location: .query,
                required: false,
                typeName: "Session.ID",
                description: "Only automations created by this Session."
            ),
            ParameterDescriptor(
                name: "directory",
                location: .query,
                required: false,
                typeName: "String",
                description: "Only automations in the project that owns this directory."
            ),
        ],
        successType: "{ data: Automation.Info[] }",
        errors: [
            ProtocolErrorRef(SessionNotFoundError.self),
            ProtocolErrorRef(ForbiddenError.self),
            ProtocolErrorRef(InvalidRequestError.self),
        ],
        tags: ["experimental"]
    ),
    EndpointDescriptor(
        group: "server.experimental",
        name: "automation.get",
        method: .get,
        path: "/api/experimental/automation/:automationID",
        experimental: true,
        openAPIIdentifier: "experimental.automation.get",
        summary: "Get automation",
        description: "Read one automation. \(automationExperimentalNote)",
        pathParameters: [
            ParameterDescriptor(name: "automationID", location: .path, required: true, typeName: "Automation.ID")
        ],
        successType: "{ data: Automation.Info }",
        errors: automationItemErrors,
        tags: ["experimental"]
    ),
    EndpointDescriptor(
        group: "server.experimental",
        name: "automation.pause",
        method: .post,
        path: "/api/experimental/automation/:automationID/pause",
        experimental: true,
        openAPIIdentifier: "experimental.automation.pause",
        summary: "Pause automation",
        description: "Stop an automation from running until it is resumed. \(automationExperimentalNote)",
        pathParameters: [
            ParameterDescriptor(name: "automationID", location: .path, required: true, typeName: "Automation.ID")
        ],
        successType: "{ data: Automation.Info }",
        errors: automationItemErrors,
        tags: ["experimental"]
    ),
    EndpointDescriptor(
        group: "server.experimental",
        name: "automation.resume",
        method: .post,
        path: "/api/experimental/automation/:automationID/resume",
        experimental: true,
        openAPIIdentifier: "experimental.automation.resume",
        summary: "Resume automation",
        description: "Resume a paused automation. A missed `at` runs once; repeating timers resume at their next slot. Event watches request replay from their saved cursor. \(automationExperimentalNote)",
        pathParameters: [
            ParameterDescriptor(name: "automationID", location: .path, required: true, typeName: "Automation.ID")
        ],
        successType: "{ data: Automation.Info }",
        errors: automationItemErrors,
        tags: ["experimental"]
    ),
    EndpointDescriptor(
        group: "server.experimental",
        name: "automation.delete",
        method: .delete,
        path: "/api/experimental/automation/:automationID",
        experimental: true,
        openAPIIdentifier: "experimental.automation.delete",
        summary: "Delete automation",
        description: "Delete an automation. \(automationExperimentalNote)",
        pathParameters: [
            ParameterDescriptor(name: "automationID", location: .path, required: true, typeName: "Automation.ID")
        ],
        successType: "NoContent",
        successEncoding: .noContent,
        errors: automationItemErrors,
        tags: ["experimental"]
    ),
]

// MARK: - 4. blob.ts

/// Lives in the `server.experimental` group (see `ExperimentalGroup`).
// parity: protocol/src/groups/blob.ts#BlobGetEndpoint [status=implemented hash=2f0cdfbdcedb]
public let BlobGetEndpoint = EndpointDescriptor(
    group: "server.experimental",
    name: "blob.get",
    method: .get,
    path: "/api/experimental/blob/:id",
    experimental: true,
    openAPIIdentifier: "experimental.blob.get",
    summary: "Read a blob",
    description: "Stream a stored blob's bytes, such as a generated video, with single byte Range, ETag and 304 Not Modified support. Blobs are kept until removed. Experimental: may change without compatibility guarantees.",
    pathParameters: [
        ParameterDescriptor(name: "id", location: .path, required: true, typeName: "BlobStore.ID")
    ],
    successType: "Uint8Array",
    successEncoding: .binary,
    errors: [ProtocolErrorRef(BlobNotFoundError.self)],
    tags: ["experimental"]
)

// MARK: - 5. command.ts

// parity: protocol/src/groups/command.ts#CommandGroup [status=implemented hash=fefd6088aa9c]
public let CommandGroup = EndpointGroupDescriptor(
    identifier: "server.command",
    title: "command",
    description: "Experimental command routes.",
    endpoints: [
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.command",
                name: "command.list",
                method: .get,
                path: "/api/command",
                openAPIIdentifier: "command.list",
                summary: "List commands",
                description: "Retrieve currently registered commands.",
                queryParameters: [locationQueryParameter],
                successType: "Location.response(Command.Info[])"
            )
        )
    ]
)

// MARK: - 6. config.ts

// parity: protocol/src/groups/config.ts#ConfigGroup [status=implemented hash=5297d8600c60]
public let ConfigGroup = EndpointGroupDescriptor(
    identifier: "server.config",
    title: "config",
    description: "Location-scoped configuration routes.",
    endpoints: [
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.config",
                name: "config.get",
                method: .get,
                path: "/api/config",
                openAPIIdentifier: "config.get",
                summary: "Get configuration",
                description: "Return configuration documents and discovery sources for the requested location, from lowest to highest priority.",
                queryParameters: [locationQueryParameter],
                successType: "Config.Entry[]"
            )
        ),
        EndpointDescriptor(
            group: "server.config",
            name: "config.shells",
            method: .get,
            path: "/api/config/shell",
            openAPIIdentifier: "config.shells",
            summary: "List available shells",
            description: "Return shells available to terminal and agent execution.",
            successType: "ConfigShell.Option[]"
        ),
        EndpointDescriptor(
            group: "server.config",
            name: "config.update",
            method: .patch,
            path: "/api/experimental/config",
            experimental: true,
            openAPIIdentifier: "experimental.config.update",
            summary: "Update global configuration",
            description: "Patch supported fields in the highest-precedence global configuration document.",
            payloadType: "Config.Patch",
            successType: "NoContent",
            successEncoding: .noContent
        ),
    ]
)

// MARK: - 7. credential.ts

// parity: protocol/src/groups/credential.ts#CredentialGroup [status=implemented hash=57c5e765a32b]
public let CredentialGroup = EndpointGroupDescriptor(
    identifier: "server.credential",
    title: "credential",
    endpoints: [
        EndpointDescriptor(
            group: "server.credential",
            name: "credential.list",
            method: .get,
            path: "/api/credential",
            openAPIIdentifier: "credential.list",
            summary: "List credentials",
            description: "List every stored integration credential, including its secret value.",
            successType: "{ data: Credential.Entry[] }"
        ),
        EndpointDescriptor(
            group: "server.credential",
            name: "credential.create",
            method: .post,
            path: "/api/credential",
            openAPIIdentifier: "credential.create",
            summary: "Create credential",
            description: "Store an integration credential. It becomes the integration's active credential unless activate is false and the integration already has one. Fails with a conflict when the requested ID already exists, and with an invalid request when an `integration.connect` policy denies the integration.",
            payloadType: "Credential.CreateInput",
            successType: "{ data: Credential.Entry }",
            errors: [
                ProtocolErrorRef(ConflictError.self),
                ProtocolErrorRef(InvalidRequestError.self),
            ]
        ),
        EndpointDescriptor(
            group: "server.credential",
            name: "credential.update",
            method: .patch,
            path: "/api/credential/:credentialID",
            openAPIIdentifier: "credential.update",
            summary: "Update credential",
            description: "Update a stored credential label.",
            pathParameters: [
                ParameterDescriptor(name: "credentialID", location: .path, required: true, typeName: "Credential.ID")
            ],
            payloadType: "{ label: String }",
            successType: "NoContent",
            successEncoding: .noContent
        ),
        EndpointDescriptor(
            group: "server.credential",
            name: "credential.activate",
            method: .post,
            path: "/api/credential/:credentialID/activate",
            openAPIIdentifier: "credential.activate",
            summary: "Activate credential",
            description: "Activate a stored integration credential.",
            pathParameters: [
                ParameterDescriptor(name: "credentialID", location: .path, required: true, typeName: "Credential.ID")
            ],
            successType: "NoContent",
            successEncoding: .noContent
        ),
        EndpointDescriptor(
            group: "server.credential",
            name: "credential.remove",
            method: .delete,
            path: "/api/credential/:credentialID",
            openAPIIdentifier: "credential.remove",
            summary: "Remove credential",
            description: "Remove a stored integration credential.",
            pathParameters: [
                ParameterDescriptor(name: "credentialID", location: .path, required: true, typeName: "Credential.ID")
            ],
            successType: "NoContent",
            successEncoding: .noContent
        ),
    ]
)

// MARK: - 8. debug.ts

// parity: protocol/src/groups/debug.ts#DebugGroup [status=implemented hash=5efa98195ede]
public let DebugGroup = EndpointGroupDescriptor(
    identifier: "server.debug",
    title: "debug",
    endpoints: [
        EndpointDescriptor(
            group: "server.debug",
            name: "debug.heapDump",
            method: .post,
            path: "/api/debug/heap-dump",
            openAPIIdentifier: "debug.heapDump",
            summary: "Write a heap snapshot",
            description: "Write a JavaScript heap snapshot of the server process into its log directory, or the requested directory, and return the server-local path once the file is complete. Pauses the server while the heap serializes and can temporarily increase its memory use. The snapshot can contain credentials, prompts, and file contents.",
            queryParameters: [
                ParameterDescriptor(
                    name: "directory",
                    location: .query,
                    required: false,
                    typeName: "String",
                    description: "Absolute server-local directory to write the snapshot into, created when missing. Defaults to the server's log directory."
                )
            ],
            successType: "{ path: String, pid: Int, memory: ProcessMemoryUsage }",
            errors: [
                ProtocolErrorRef(InvalidRequestError.self),
                ProtocolErrorRef(UnknownError.self),
            ]
        ),
        EndpointDescriptor(
            group: "server.debug",
            name: "debug.location",
            method: .get,
            path: "/api/debug/location",
            openAPIIdentifier: "debug.location.list",
            summary: "List loaded locations",
            description: "List locations currently loaded by the server.",
            successType: "Location.PublicRef[]"
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.debug",
                name: "debug.location.evict",
                method: .delete,
                path: "/api/debug/location",
                openAPIIdentifier: "debug.location.evict",
                summary: "Evict a loaded location",
                description: "Dispose the requested location's cached services so its next use boots them fresh.",
                queryParameters: [locationQueryParameter],
                successType: "NoContent",
                successEncoding: .noContent
            )
        ),
    ]
)

// MARK: - 9. event.ts

/// Wire-ready public server event envelope (`V2Event`), covering all `EventManifest.ServerDefinitions`,
/// `server.connected`, and `rpc.*` events.
// parity: protocol/src/groups/event.ts#OpenCodeEvent [status=implemented hash=d199ef27fc02]
public struct OpenCodeEvent: Equatable, Hashable, Sendable, Codable {
    public let id: String
    public let type: String
    public let created: Double?
    public let metadata: [String: JSONValue]?
    public let location: OpenCodeLocation?
    public let data: JSONValue

    public init(
        id: String,
        type: String,
        created: Double? = nil,
        metadata: [String: JSONValue]? = nil,
        location: OpenCodeLocation? = nil,
        data: JSONValue = .object([:])
    ) {
        self.id = id
        self.type = type
        self.created = created
        self.metadata = metadata
        self.location = location
        self.data = data
    }

    /// Canonical ordered list of all 99 public server event types from `EventManifest.ServerDefinitions`.
    public static let serverEventTypeList: [String] = [
        "location.shutdown",
        "models-dev.refreshed",
        "credential.updated",
        "credential.switched",
        "integration.updated",
        "provider.updated",
        "model.updated",
        "agent.updated",
        "session.created",
        "session.agent.selected",
        "session.model.selected",
        "session.moved",
        "session.renamed",
        "session.metadata.updated",
        "session.permissions",
        "session.viewed",
        "session.archived",
        "session.unarchived",
        "session.usage.updated",
        "session.deleted",
        "session.forked",
        "session.inbox.delivered",
        "session.inbox.enqueued",
        "session.inbox.cancelled",
        "session.inbox.delivery.changed",
        "session.execution.started",
        "session.execution.succeeded",
        "session.execution.failed",
        "session.execution.interrupted",
        "session.instructions.updated",
        "session.synthetic",
        "session.skill.activated",
        "session.shell.started",
        "session.shell.ended",
        "session.step.started",
        "session.step.first-token",
        "session.step.streamed",
        "session.step.ended",
        "session.step.failed",
        "session.text.started",
        "session.text.delta",
        "session.text.ended",
        "session.reasoning.started",
        "session.reasoning.delta",
        "session.reasoning.ended",
        "session.tool.input.started",
        "session.tool.input.delta",
        "session.tool.input.ended",
        "session.tool.called",
        "session.tool.progress",
        "session.tool.success",
        "session.tool.failed",
        "session.retry.scheduled",
        "session.compaction.started",
        "session.compaction.delta",
        "session.compaction.ended",
        "session.compaction.failed",
        "session.revert.staged",
        "session.revert.cleared",
        "session.revert.committed",
        "filesystem.changed",
        "reference.updated",
        "permission.asked",
        "permission.replied",
        "plugin.updated",
        "project.updated",
        "worktree.updated",
        "worktree.resolved",
        "command.updated",
        "config.updated",
        "skill.updated",
        "pty.created",
        "pty.updated",
        "pty.exited",
        "pty.deleted",
        "persistent-pty.added",
        "persistent-pty.removed",
        "persistent-pty.updated",
        "shell.created",
        "shell.exited",
        "shell.deleted",
        "experimental.job.updated",
        "form.created",
        "form.replied",
        "form.cancelled",
        "websearch.updated",
        "artifact.updated",
        "session.status",
        "session.idle",
        "tui.prompt.append",
        "tui.command.execute",
        "tui.toast.show",
        "tui.session.select",
        "installation.updated",
        "installation.update-available",
        "vcs.branch.updated",
        "mcp.status.changed",
        "mcp.resources.changed",
        "experimental.mcp.event",
    ]

    /// Fast lookup set of `EventManifest.ServerDefinitions` event type names.
    public static let serverEventTypes: Set<String> = Set(serverEventTypeList)
}

/// Wire-encoded representation of `OpenCodeEvent`.
// parity: protocol/src/groups/event.ts#OpenCodeEventEncoded [status=implemented hash=94e4897561f3]
public typealias OpenCodeEventEncoded = OpenCodeEvent

/// Classifies whether an event type belongs to the public `OpenCodeEvent` SSE stream.
// parity: protocol/src/groups/event.ts#isOpenCodeEvent [status=implemented hash=f51aa4210484]
public func isOpenCodeEvent(type: String) -> Bool {
    type == "server.connected" || OpenCodeEvent.serverEventTypes.contains(type) || type.hasPrefix("rpc.")
}

/// Overload classifying an `OpenCodeEvent` value.
public func isOpenCodeEvent(_ event: OpenCodeEvent) -> Bool {
    isOpenCodeEvent(type: event.type)
}

/// Builds the `server.event` SSE subscription group for the supplied event definitions.
// parity: protocol/src/groups/event.ts#makeEventGroup [status=implemented hash=dfa09bccd758]
public func makeEventGroup(definitions: [String] = OpenCodeEvent.serverEventTypeList) -> EndpointGroupDescriptor {
    _ = definitions
    return EndpointGroupDescriptor(
        identifier: "server.event",
        title: "event",
        description: "Experimental event stream routes.",
        endpoints: [
            EndpointDescriptor(
                group: "server.event",
                name: "event.subscribe",
                method: .get,
                path: "/api/event",
                openAPIIdentifier: "event.subscribe",
                summary: "Subscribe to events",
                description: "Subscribe to native events and plugin RPC events across all server locations. Volatile by contract: a slow consumer overflows and fails the stream, and events during disconnection are missed.",
                queryParameters: [
                    ParameterDescriptor(
                        name: "types",
                        location: .query,
                        required: false,
                        typeName: "EventSubscribeQuery.types",
                        description: "Only send events of these types, plus the initial server.connected event. When omitted, all events are sent."
                    )
                ],
                successType: "StreamSse(V2Event)",
                successEncoding: .sse
            )
        ]
    )
}

/// Default `server.event` group built from `EventManifest.ServerDefinitions`.
// parity: protocol/src/groups/event.ts#EventGroup [status=implemented hash=4d875adab07e]
public let EventGroup: EndpointGroupDescriptor = makeEventGroup(definitions: OpenCodeEvent.serverEventTypeList)

// MARK: - 10. experimental.ts

/// `server.experimental`: routes under `/api/experimental`, without compatibility guarantees.
// parity: protocol/src/groups/experimental.ts#ExperimentalGroup [status=implemented hash=8ccf1cbcb6ce]
public let ExperimentalGroup: EndpointGroupDescriptor = PersistentPtyGroup
    .adding(MediaGetEndpoint)
    .adding(BlobGetEndpoint)
    .adding(AutomationEndpoints)
    .adding(ArtifactEndpoints)
    .adding(JobEndpoints)

// MARK: - 11. form.ts

// parity: protocol/src/groups/form.ts#makeFormGroup [status=implemented hash=e650d6b452f4]
public func makeFormGroup(locationMiddleware: MiddlewareDescriptor) -> EndpointGroupDescriptor {
    EndpointGroupDescriptor(
        identifier: "server.form",
        title: "form",
        description: "Location form routes.",
        endpoints: [
            locationQueryOpenApi(
                EndpointDescriptor(
                    group: "server.form",
                    name: "form.list",
                    method: .get,
                    path: "/api/form",
                    openAPIIdentifier: "form.list",
                    summary: "List pending forms",
                    description: "Retrieve pending forms for a location.",
                    queryParameters: [locationQueryParameter],
                    successType: "Location.response(Form.Info[])"
                )
            )
        ]
    ).middleware(locationMiddleware)
}

// MARK: - 12. fs.ts

// parity: protocol/src/groups/fs.ts#FileSystemGroup [status=implemented hash=d181938a3f4e]
public let FileSystemGroup = EndpointGroupDescriptor(
    identifier: "server.fs",
    title: "filesystem",
    description: "Experimental location-scoped filesystem routes.",
    endpoints: [
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.fs",
                name: "fs.read",
                method: .get,
                path: "/api/fs/read/*",
                openAPIIdentifier: "fs.read",
                summary: "Read file",
                description: "Stream one file relative to the requested location with ETag, Last-Modified, and single-range HTTP Range support (206 Partial Content, 416 Range Not Satisfiable, and 304 Not Modified; multi-range and malformed Range headers fall back to 200).",
                queryParameters: [locationQueryParameter],
                successType: "Uint8Array",
                successEncoding: .binary,
                errors: [ProtocolErrorRef(FileNotFoundError.self)]
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.fs",
                name: "fs.list",
                method: .get,
                path: "/api/fs/list",
                openAPIIdentifier: "fs.list",
                summary: "List directory",
                description: "List direct children using an absolute path or a path relative to the requested location, including parents and siblings outside its directory. Entry paths remain relative to the requested location; listing does not switch locations.",
                queryParameters: [
                    locationQueryParameter,
                    ParameterDescriptor(
                        name: "path",
                        location: .query,
                        required: false,
                        typeName: "String",
                        description: "An absolute path or a path relative to the requested location. Defaults to the location directory."
                    ),
                ],
                successType: "Location.response(FileSystem.Entry[])",
                errors: [ProtocolErrorRef(FileNotFoundError.self)]
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.fs",
                name: "fs.find",
                method: .get,
                path: "/api/fs/find",
                openAPIIdentifier: "fs.find",
                summary: "Find files",
                description: "Find recursively ranked filesystem entries relative to the requested location.",
                queryParameters: [
                    locationQueryParameter,
                    ParameterDescriptor(name: "query", location: .query, required: true, typeName: "String"),
                    ParameterDescriptor(name: "type", location: .query, required: false, typeName: "FileSystem.EntryType"),
                    ParameterDescriptor(name: "limit", location: .query, required: false, typeName: "PositiveInt"),
                ],
                successType: "Location.response(FileSystem.Entry[])"
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.fs",
                name: "fs.write",
                method: .post,
                path: "/api/experimental/fs/write",
                experimental: true,
                openAPIIdentifier: "experimental.fs.write",
                summary: "Write file",
                description: "Write the raw request body to an absolute path or a path relative to the requested location, creating parent directories, and return the resolved absolute path. Unlike read, the target is not confined to the location. Experimental: may change without compatibility guarantees.",
                queryParameters: [
                    locationQueryParameter,
                    ParameterDescriptor(
                        name: "path",
                        location: .query,
                        required: true,
                        typeName: "String",
                        description: "An absolute path or a path relative to the requested location. Missing parent directories are created."
                    ),
                ],
                payloadType: "Uint8Array",
                payloadEncoding: .binary,
                successType: "Location.response(FileSystem.Write)"
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.fs",
                name: "fs.watch",
                method: .post,
                path: "/api/experimental/fs/watch",
                experimental: true,
                openAPIIdentifier: "experimental.fs.watch",
                summary: "Watch file",
                description: "Watch one file relative to the requested location for 24 hours, publishing filesystem.changed on that location when it changes. Watching an already watched file resets its expiry. Paths follow read confinement. Experimental: may change without compatibility guarantees.",
                queryParameters: [locationQueryParameter],
                payloadType: "{ path: String }",
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [
                    ProtocolErrorRef(FileNotFoundError.self),
                    ProtocolErrorRef(ServiceUnavailableError.self),
                ]
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.fs",
                name: "fs.unwatch",
                method: .delete,
                path: "/api/experimental/fs/watch",
                experimental: true,
                openAPIIdentifier: "experimental.fs.unwatch",
                summary: "Unwatch file",
                description: "Stop watching one file relative to the requested location. Experimental: may change without compatibility guarantees.",
                queryParameters: [locationQueryParameter],
                payloadType: "{ path: String }",
                successType: "NoContent",
                successEncoding: .noContent
            )
        ),
    ]
)

// MARK: - 13. generate.ts

private let generateErrors: [ProtocolErrorRef] = [
    ProtocolErrorRef(InvalidRequestError.self),
    ProtocolErrorRef(ProviderNotFoundError.self),
    ProtocolErrorRef(ModelNotFoundError.self),
    ProtocolErrorRef(UnsupportedModelError.self),
    ProtocolErrorRef(ProviderRequestError.self),
    ProtocolErrorRef(ServiceUnavailableError.self),
    ProtocolErrorRef(LocationNotFoundError.self),
]

// parity: protocol/src/groups/generate.ts#GenerateGroup [status=implemented hash=236a35cf31f2]
public let GenerateGroup = EndpointGroupDescriptor(
    identifier: "server.generate",
    title: "generate",
    description: "Experimental one-shot generation routes.",
    endpoints: [
        EndpointDescriptor(
            group: "server.generate",
            name: "generate.text",
            method: .post,
            path: "/api/experimental/generate/text",
            experimental: true,
            openAPIIdentifier: "experimental.generate.text",
            summary: "Generate text",
            description: "Run one stateless model generation using the server's base configuration and return the assistant text. Uses the base configuration's default model when none is specified.",
            payloadType: "{ prompt: String, model?: Model.Ref }",
            successType: "GenerateTextResponse",
            errors: generateErrors
        ),
        EndpointDescriptor(
            group: "server.generate",
            name: "generate.textLegacy",
            method: .post,
            path: "/api/experimental/generate",
            experimental: true,
            openAPIIdentifier: "experimental.generate.textLegacy",
            summary: "Generate text (deprecated path)",
            description: "Deprecated alias of POST /api/experimental/generate/text.",
            payloadType: "{ prompt: String, model?: Model.Ref }",
            successType: "GenerateTextResponse",
            errors: generateErrors,
            isDeprecated: true
        ),
        EndpointDescriptor(
            group: "server.generate",
            name: "generate.image",
            method: .post,
            path: "/api/experimental/generate/image",
            experimental: true,
            openAPIIdentifier: "experimental.generate.image",
            summary: "Generate images",
            description: "Generate or edit images with an image model using the server's base configuration and return them as base64. Stateless: nothing is stored.",
            payloadType: "Generate.ImageRequest",
            successType: "GenerateImageResponse",
            errors: generateErrors
        ),
        EndpointDescriptor(
            group: "server.generate",
            name: "generate.video.create",
            method: .post,
            path: "/api/experimental/generate/video",
            experimental: true,
            openAPIIdentifier: "experimental.generate.video.create",
            summary: "Create a video generation",
            description: "Submit a video job to a video model using the server's base configuration and return its ID once the provider accepted it. The server polls the job and stores the finished videos as blobs; read the job with GET /api/experimental/generate/video/:id and the video with GET /api/experimental/blob/:id. Behind the video_generate flag. Experimental: may change without compatibility guarantees.",
            payloadType: "Generate.VideoRequest",
            successType: "GenerateVideoCreateResponse",
            errors: generateErrors + [ProtocolErrorRef(ForbiddenError.self)]
        ),
        EndpointDescriptor(
            group: "server.generate",
            name: "generate.video.get",
            method: .get,
            path: "/api/experimental/generate/video/:id",
            experimental: true,
            openAPIIdentifier: "experimental.generate.video.get",
            summary: "Read a video generation",
            description: "Read a video job: running, completed with its videos' blobs, or error with a reason. Jobs survive a server restart, which resumes polling running ones. A job is not found 24 hours after it finished, or once none of its blobs remain. Behind the video_generate flag. Experimental: may change without compatibility guarantees.",
            pathParameters: [
                ParameterDescriptor(name: "id", location: .path, required: true, typeName: "Generate.VideoID")
            ],
            successType: "GenerateVideoGetResponse",
            errors: [
                ProtocolErrorRef(VideoNotFoundError.self),
                ProtocolErrorRef(ForbiddenError.self),
                ProtocolErrorRef(LocationNotFoundError.self),
            ]
        ),
        EndpointDescriptor(
            group: "server.generate",
            name: "generate.decisions",
            method: .post,
            path: "/api/experimental/generate/decisions",
            experimental: true,
            openAPIIdentifier: "experimental.generate.decisions",
            summary: "Generate decisions",
            description: "Ask a decision model typed predicate, choice and score questions about the input and return one probability-bearing answer per question, in question order. Stateless: nothing is stored.",
            payloadType: "Generate.DecisionRequest",
            successType: "GenerateDecisionsResponse",
            errors: generateErrors
        ),
    ]
)

// MARK: - 14. integration.ts

// parity: protocol/src/groups/integration.ts#IntegrationGroup [status=implemented hash=06f590bb6c70]
public let IntegrationGroup = EndpointGroupDescriptor(
    identifier: "server.integration",
    title: "integration",
    description: "Integration discovery and authentication routes.",
    endpoints: [
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.integration",
                name: "integration.list",
                method: .get,
                path: "/api/integration",
                openAPIIdentifier: "integration.list",
                summary: "List integrations",
                description: "Retrieve available integrations and their authentication methods.",
                queryParameters: [locationQueryParameter],
                successType: "Location.response(Integration.Info[])"
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.integration",
                name: "integration.get",
                method: .get,
                path: "/api/integration/:integrationID",
                openAPIIdentifier: "integration.get",
                summary: "Get integration",
                description: "Retrieve one integration and its authentication methods.",
                pathParameters: [
                    ParameterDescriptor(name: "integrationID", location: .path, required: true, typeName: "Integration.ID")
                ],
                queryParameters: [locationQueryParameter],
                successType: "Location.response(Integration.Info)",
                errors: [ProtocolErrorRef(IntegrationNotFoundError.self)]
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.integration",
                name: "integration.wellknown.add",
                method: .post,
                path: "/api/experimental/integration/wellknown",
                experimental: true,
                openAPIIdentifier: "experimental.integration.wellknown.add",
                summary: "Add wellknown integration",
                description: "Discover and persist an experimental wellknown integration source.",
                queryParameters: [locationQueryParameter],
                payloadType: "{ url: String }",
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [ProtocolErrorRef(InvalidRequestError.self)]
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.integration",
                name: "integration.connect.key",
                method: .post,
                path: "/api/integration/:integrationID/connect/key",
                openAPIIdentifier: "integration.connect.key",
                summary: "Connect with key",
                description: "Run a key authentication method and store the resulting credential.",
                pathParameters: [
                    ParameterDescriptor(name: "integrationID", location: .path, required: true, typeName: "Integration.ID")
                ],
                queryParameters: [locationQueryParameter],
                payloadType: "{ key: String, answer?: Form.Answer, label?: String }",
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [
                    ProtocolErrorRef(IntegrationNotFoundError.self),
                    ProtocolErrorRef(InvalidRequestError.self),
                ]
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.integration",
                name: "integration.connect.external",
                method: .post,
                path: "/api/integration/:integrationID/connect/external",
                openAPIIdentifier: "integration.connect.external",
                summary: "Connect with external credentials",
                description: "Run an external authentication method and store a reference to its credential source.",
                pathParameters: [
                    ParameterDescriptor(name: "integrationID", location: .path, required: true, typeName: "Integration.ID")
                ],
                queryParameters: [locationQueryParameter],
                payloadType: "{ methodID: Integration.MethodID, answer?: Form.Answer, label?: String }",
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [
                    ProtocolErrorRef(IntegrationNotFoundError.self),
                    ProtocolErrorRef(InvalidRequestError.self),
                ]
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.integration",
                name: "integration.oauth.connect",
                method: .post,
                path: "/api/integration/:integrationID/connect/oauth",
                openAPIIdentifier: "integration.oauth.connect",
                summary: "Begin OAuth connection",
                description: "Start an OAuth attempt and return the authorization details.",
                pathParameters: [
                    ParameterDescriptor(name: "integrationID", location: .path, required: true, typeName: "Integration.ID")
                ],
                queryParameters: [locationQueryParameter],
                payloadType: "{ methodID: Integration.MethodID, answer?: Form.Answer, label?: String }",
                successType: "Location.response(Integration.Attempt)",
                errors: [ProtocolErrorRef(InvalidRequestError.self)]
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.integration",
                name: "integration.oauth.status",
                method: .get,
                path: "/api/integration/:integrationID/connect/oauth/:attemptID",
                openAPIIdentifier: "integration.oauth.status",
                summary: "Get OAuth attempt status",
                description: "Poll the current status of an OAuth attempt.",
                pathParameters: [
                    ParameterDescriptor(name: "integrationID", location: .path, required: true, typeName: "Integration.ID"),
                    ParameterDescriptor(name: "attemptID", location: .path, required: true, typeName: "Integration.AttemptID"),
                ],
                queryParameters: [locationQueryParameter],
                successType: "Location.response(Integration.AttemptStatus)",
                errors: [
                    ProtocolErrorRef(IntegrationNotFoundError.self),
                    ProtocolErrorRef(IntegrationAttemptNotFoundError.self),
                ]
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.integration",
                name: "integration.oauth.complete",
                method: .post,
                path: "/api/integration/:integrationID/connect/oauth/:attemptID/complete",
                openAPIIdentifier: "integration.oauth.complete",
                summary: "Complete OAuth connection",
                description: "Complete a code-based OAuth attempt and store the resulting credential. For an automatic attempt with `paste`, `code` is the redirect URL copied from the browser, and the result arrives through the attempt status.",
                pathParameters: [
                    ParameterDescriptor(name: "integrationID", location: .path, required: true, typeName: "Integration.ID"),
                    ParameterDescriptor(name: "attemptID", location: .path, required: true, typeName: "Integration.AttemptID"),
                ],
                queryParameters: [locationQueryParameter],
                payloadType: "{ code?: String }",
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [
                    ProtocolErrorRef(IntegrationNotFoundError.self),
                    ProtocolErrorRef(IntegrationAttemptNotFoundError.self),
                    ProtocolErrorRef(InvalidRequestError.self),
                ]
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.integration",
                name: "integration.oauth.cancel",
                method: .delete,
                path: "/api/integration/:integrationID/connect/oauth/:attemptID",
                openAPIIdentifier: "integration.oauth.cancel",
                summary: "Cancel OAuth connection",
                description: "Cancel an OAuth attempt and release its resources.",
                pathParameters: [
                    ParameterDescriptor(name: "integrationID", location: .path, required: true, typeName: "Integration.ID"),
                    ParameterDescriptor(name: "attemptID", location: .path, required: true, typeName: "Integration.AttemptID"),
                ],
                queryParameters: [locationQueryParameter],
                successType: "NoContent",
                successEncoding: .noContent
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.integration",
                name: "integration.command.connect",
                method: .post,
                path: "/api/integration/:integrationID/connect/command",
                openAPIIdentifier: "integration.command.connect",
                summary: "Begin command connection",
                description: "Start a command authentication attempt.",
                pathParameters: [
                    ParameterDescriptor(name: "integrationID", location: .path, required: true, typeName: "Integration.ID")
                ],
                queryParameters: [locationQueryParameter],
                payloadType: "{ methodID: Integration.MethodID, label?: String }",
                successType: "Location.response(Integration.CommandAttempt)",
                errors: [
                    ProtocolErrorRef(IntegrationNotFoundError.self),
                    ProtocolErrorRef(IntegrationMethodNotFoundError.self),
                    ProtocolErrorRef(InvalidRequestError.self),
                ]
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.integration",
                name: "integration.command.status",
                method: .get,
                path: "/api/integration/:integrationID/connect/command/:attemptID",
                openAPIIdentifier: "integration.command.status",
                summary: "Get command attempt status",
                description: "Poll the current status and output of a command authentication attempt.",
                pathParameters: [
                    ParameterDescriptor(name: "integrationID", location: .path, required: true, typeName: "Integration.ID"),
                    ParameterDescriptor(name: "attemptID", location: .path, required: true, typeName: "Integration.AttemptID"),
                ],
                queryParameters: [locationQueryParameter],
                successType: "Location.response(Integration.CommandAttemptStatus)",
                errors: [
                    ProtocolErrorRef(IntegrationNotFoundError.self),
                    ProtocolErrorRef(IntegrationAttemptNotFoundError.self),
                ]
            )
        ),
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.integration",
                name: "integration.command.cancel",
                method: .delete,
                path: "/api/integration/:integrationID/connect/command/:attemptID",
                openAPIIdentifier: "integration.command.cancel",
                summary: "Cancel command connection",
                description: "Cancel a command authentication attempt and terminate its process.",
                pathParameters: [
                    ParameterDescriptor(name: "integrationID", location: .path, required: true, typeName: "Integration.ID"),
                    ParameterDescriptor(name: "attemptID", location: .path, required: true, typeName: "Integration.AttemptID"),
                ],
                queryParameters: [locationQueryParameter],
                successType: "NoContent",
                successEncoding: .noContent
            )
        ),
    ]
)

// MARK: - 15. job.ts

/// Background job kind literals (`Job.Kind`).
public enum ProtocolJobKind: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case shell
    case subagent
    case image
    case video
    case codemode
}

/// Background job status literals (`Job.Status`).
public enum ProtocolJobStatus: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case running
    case completed
    case error
    case cancelled
}

/// Query parameters for `GET /api/experimental/job` (`Job.ListQuery`).
// parity: protocol/src/groups/job.ts#ListQuery [status=implemented hash=41d18184eaff]
public struct JobListQuery: Equatable, Hashable, Sendable, Codable {
    public let sessionID: SessionID?
    public let kind: ProtocolJobKind?
    public let status: ProtocolJobStatus?
    public let descendants: Bool?

    public init(
        sessionID: SessionID? = nil,
        kind: ProtocolJobKind? = nil,
        status: ProtocolJobStatus? = nil,
        descendants: Bool? = nil
    ) {
        self.sessionID = sessionID
        self.kind = kind
        self.status = status
        self.descendants = descendants
    }
}

/// Lives in the `server.experimental` group (see `ExperimentalGroup`).
// parity: protocol/src/groups/job.ts#JobEndpoints [status=implemented hash=ec42e3f6d0b6]
public let JobEndpoints: [EndpointDescriptor] = [
    EndpointDescriptor(
        group: "server.experimental",
        name: "job.list",
        method: .get,
        path: "/api/experimental/job",
        experimental: true,
        openAPIIdentifier: "experimental.job.list",
        summary: "List background jobs",
        description: "List active and unconsumed background jobs, optionally filtered by owning session, descendants, or kind. Experimental: may change without compatibility guarantees.",
        queryParameters: [
            ParameterDescriptor(
                name: "sessionID",
                location: .query,
                required: false,
                typeName: "Session.ID",
                description: "Filter to background jobs owned by this session."
            ),
            ParameterDescriptor(
                name: "kind",
                location: .query,
                required: false,
                typeName: "Job.Kind",
                description: "Filter by background job kind."
            ),
            ParameterDescriptor(
                name: "status",
                location: .query,
                required: false,
                typeName: "Job.Status",
                description: "Filter by job status (running, completed, error, or cancelled)."
            ),
            ParameterDescriptor(
                name: "descendants",
                location: .query,
                required: false,
                typeName: "BooleanFromString",
                description: "When sessionID is set, also include background jobs owned by child and nested subagent sessions."
            ),
        ],
        successType: "{ data: Job.Info[] }",
        errors: [
            ProtocolErrorRef(InvalidRequestError.self),
            ProtocolErrorRef(SessionNotFoundError.self),
        ],
        tags: ["experimental"]
    ),
    EndpointDescriptor(
        group: "server.experimental",
        name: "job.cancel",
        method: .post,
        path: "/api/experimental/job/:id/cancel",
        experimental: true,
        openAPIIdentifier: "experimental.job.cancel",
        summary: "Cancel background job",
        description: "Cancel a running background job, interrupting the work it started. Cancelling a job that already finished does nothing. Experimental: may change without compatibility guarantees.",
        pathParameters: [
            ParameterDescriptor(name: "id", location: .path, required: true, typeName: "String")
        ],
        successType: "NoContent",
        successEncoding: .noContent,
        tags: ["experimental"]
    ),
]

// MARK: - 16. location.ts

/// Deep-object query parameter selecting a target workspace location (`location[directory]=...`).
// parity: protocol/src/groups/location.ts#LocationQuery [status=implemented hash=ffe0eaf400b9]
public struct LocationQuery: Equatable, Hashable, Sendable, Codable {
    public struct LocationField: Equatable, Hashable, Sendable, Codable {
        public let directory: String?

        public init(directory: String? = nil) {
            self.directory = directory
        }
    }

    public let location: LocationField?

    public init(location: LocationField? = nil) {
        self.location = location
    }

    public init(directory: String?) {
        self.location = directory.map { LocationField(directory: $0) }
    }
}

/// OpenAPI parameter transform setting `style: "deepObject"` and `explode: true` on the `location` query parameter.
// parity: protocol/src/groups/location.ts#locationQueryOpenApi [status=implemented hash=84808764b99f]
public let locationQueryOpenApi: @Sendable (EndpointDescriptor) -> EndpointDescriptor = { endpoint in
    endpoint.mappingQueryParameters { parameter in
        if parameter.name == "location" && parameter.location == .query {
            return parameter.withOpenAPIStyle(.deepObject, explode: true)
        }
        return parameter
    }
}

/// Middleware is applied per endpoint: reload acts on every loaded location and must not boot the caller's location first.
// parity: protocol/src/groups/location.ts#makeLocationGroup [status=implemented hash=172e274eea74]
public func makeLocationGroup(locationMiddleware: MiddlewareDescriptor) -> EndpointGroupDescriptor {
    EndpointGroupDescriptor(
        identifier: "server.location",
        title: "location",
        endpoints: [
            locationQueryOpenApi(
                EndpointDescriptor(
                    group: "server.location",
                    name: "location.get",
                    method: .get,
                    path: "/api/location",
                    openAPIIdentifier: "location.get",
                    summary: "Get location",
                    description: "Resolve the requested location or the server default location.",
                    queryParameters: [locationQueryParameter],
                    successType: "Location.PublicInfo"
                ).withMiddleware(locationMiddleware)
            ),
            EndpointDescriptor(
                group: "server.location",
                name: "location.reload",
                method: .post,
                path: "/api/location/reload",
                openAPIIdentifier: "location.reload",
                summary: "Reload configuration",
                description: "Shut down and rebuild every loaded location. Pending permissions and forms are cancelled; running sessions continue with fresh services at the next step boundary. Emits location.shutdown for client recovery and responds once all replacement builds settle.",
                successType: "NoContent",
                successEncoding: .noContent,
                errors: [ProtocolErrorRef(ServiceUnavailableError.self)]
            ),
        ]
    )
}

// MARK: - 17. mcp.ts

// parity: protocol/src/groups/mcp.ts#MCP_CLIENT_PATH [status=implemented hash=91e5b669f40f]
public let MCP_CLIENT_PATH = "/api/experimental/client-mcp"

/// Returns `true` when `url` targets `MCP_CLIENT_PATH` and includes a non-empty `ticket` query parameter.
// parity: protocol/src/groups/mcp.ts#hasMcpClientTicketURL [status=implemented hash=d2945743e84c]
public func hasMcpClientTicketURL(_ urlString: String) -> Bool {
    let parsed = ProtocolURLComponents(urlString: urlString)
    return parsed.pathname == MCP_CLIENT_PATH && parsed.hasNonEmptyQueryValue(for: PTY_CONNECT_TICKET_QUERY)
}

// parity: protocol/src/groups/mcp.ts#makeMcpGroup [status=implemented hash=2def12c89d40]
public func makeMcpGroup(locationMiddleware: MiddlewareDescriptor) -> EndpointGroupDescriptor {
    let mcpClientNameParam = ParameterDescriptor(
        name: "name",
        location: .query,
        required: true,
        typeName: "String",
        pattern: "^[a-zA-Z0-9_-]+$"
    )
    return EndpointGroupDescriptor(
        identifier: "server.mcp",
        title: "mcp",
        description: "MCP server and resource routes.",
        endpoints: [
            locationQueryOpenApi(
                EndpointDescriptor(
                    group: "server.mcp",
                    name: "mcp.list",
                    method: .get,
                    path: "/api/mcp",
                    openAPIIdentifier: "mcp.list",
                    summary: "List MCP servers",
                    description: "Retrieve configured MCP servers and their connection status.",
                    queryParameters: [locationQueryParameter],
                    successType: "Location.response(Mcp.Server[])"
                )
            ),
            locationQueryOpenApi(
                EndpointDescriptor(
                    group: "server.mcp",
                    name: "mcp.add",
                    method: .put,
                    path: "/api/experimental/mcp/:server",
                    experimental: true,
                    openAPIIdentifier: "experimental.mcp.add",
                    summary: "Add MCP server",
                    description: "Add an MCP server at runtime or replace an existing one, connecting it immediately.",
                    pathParameters: [
                        ParameterDescriptor(name: "server", location: .path, required: true, typeName: "String")
                    ],
                    queryParameters: [locationQueryParameter],
                    payloadType: "{ config: Mcp.ServerConfig }",
                    successType: "NoContent",
                    successEncoding: .noContent
                )
            ),
            locationQueryOpenApi(
                EndpointDescriptor(
                    group: "server.mcp",
                    name: "mcp.remove",
                    method: .delete,
                    path: "/api/experimental/mcp/:server",
                    experimental: true,
                    openAPIIdentifier: "experimental.mcp.remove",
                    summary: "Remove MCP server",
                    description: "Stop an MCP server and remove it from the runtime set until restart.",
                    pathParameters: [
                        ParameterDescriptor(name: "server", location: .path, required: true, typeName: "String")
                    ],
                    queryParameters: [locationQueryParameter],
                    successType: "NoContent",
                    successEncoding: .noContent,
                    errors: [ProtocolErrorRef(McpServerNotFoundError.self)]
                )
            ),
            locationQueryOpenApi(
                EndpointDescriptor(
                    group: "server.mcp",
                    name: "mcp.connect",
                    method: .post,
                    path: "/api/experimental/mcp/:server/connect",
                    experimental: true,
                    openAPIIdentifier: "experimental.mcp.connect",
                    summary: "Connect MCP server",
                    description: "Connect an MCP server at runtime, overriding a disabled configuration until restart.",
                    pathParameters: [
                        ParameterDescriptor(name: "server", location: .path, required: true, typeName: "String")
                    ],
                    queryParameters: [locationQueryParameter],
                    successType: "NoContent",
                    successEncoding: .noContent,
                    errors: [ProtocolErrorRef(McpServerNotFoundError.self)]
                )
            ),
            locationQueryOpenApi(
                EndpointDescriptor(
                    group: "server.mcp",
                    name: "mcp.disconnect",
                    method: .post,
                    path: "/api/experimental/mcp/:server/disconnect",
                    experimental: true,
                    openAPIIdentifier: "experimental.mcp.disconnect",
                    summary: "Disconnect MCP server",
                    description: "Disconnect an MCP server at runtime, removing its tools until reconnected.",
                    pathParameters: [
                        ParameterDescriptor(name: "server", location: .path, required: true, typeName: "String")
                    ],
                    queryParameters: [locationQueryParameter],
                    successType: "NoContent",
                    successEncoding: .noContent,
                    errors: [ProtocolErrorRef(McpServerNotFoundError.self)]
                )
            ),
            locationQueryOpenApi(
                EndpointDescriptor(
                    group: "server.mcp",
                    name: "mcp.resource.catalog",
                    method: .get,
                    path: "/api/mcp/resource",
                    openAPIIdentifier: "mcp.resource.catalog",
                    summary: "List MCP resources",
                    description: "Retrieve resources and resource templates from connected MCP servers.",
                    queryParameters: [locationQueryParameter],
                    successType: "Location.response(Mcp.ResourceCatalog)"
                )
            ),
            locationQueryOpenApi(
                EndpointDescriptor(
                    group: "server.mcp",
                    name: "mcp.clientToken",
                    method: .post,
                    path: "\(MCP_CLIENT_PATH)/token",
                    experimental: true,
                    openAPIIdentifier: "experimental.mcp.client.token",
                    summary: "Create client MCP WebSocket token",
                    description: "Create a short-lived single-use ticket for opening a client MCP WebSocket connection from a browser.",
                    queryParameters: [locationQueryParameter, mcpClientNameParam],
                    headerParameters: [
                        ParameterDescriptor(name: PTY_CONNECT_TOKEN_HEADER, location: .header, required: false, typeName: "String")
                    ],
                    successType: "Location.response(PtyTicket.ConnectToken)",
                    errors: [ProtocolErrorRef(ForbiddenError.self)]
                )
            ),
        ]
    )
    // The client handler checks origin and ticket before it boots the location itself.
    .middleware(locationMiddleware)
    .adding(
        locationQueryOpenApi(
            EndpointDescriptor(
                group: "server.mcp",
                name: "mcp.client",
                method: .get,
                path: MCP_CLIENT_PATH,
                experimental: true,
                openAPIIdentifier: "experimental.mcp.client",
                summary: "Attach client MCP server",
                description: "Upgrade to a WebSocket over which the client hosts an MCP server named after `name`; its tools stay available while the socket is open. One JSON-RPC message per text frame. Experimental: may change without compatibility guarantees.",
                queryParameters: [
                    locationQueryParameter,
                    mcpClientNameParam,
                    ParameterDescriptor(name: PTY_CONNECT_TICKET_QUERY, location: .query, required: false, typeName: "String"),
                ],
                successType: "Boolean",
                successEncoding: .websocket,
                errors: [
                    ProtocolErrorRef(ForbiddenError.self),
                    ProtocolErrorRef(LocationNotFoundError.self),
                ],
                isWebSocket: true
            )
        )
    )
}

// MARK: - 18. media.ts

/// Validated 64-character lowercase hexadecimal SHA-256 media blob hash (`^[0-9a-f]{64}$`).
// parity: protocol/src/groups/media.ts#MediaHash [status=implemented hash=8acd4632bdf8]
public struct MediaHash: RawRepresentable, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
    public static let pattern = "^[0-9a-f]{64}$"

    public let rawValue: String

    public init?(rawValue: String) {
        guard MediaHash.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public static func isValid(_ value: String) -> Bool {
        let utf8 = value.utf8
        guard utf8.count == 64 else { return false }
        for b in utf8 {
            let isHex = (b >= 48 && b <= 57) || (b >= 97 && b <= 102) // '0'...'9', 'a'...'f'
            if !isHex { return false }
        }
        return true
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let validated = MediaHash(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid MediaHash '\(raw)': expected 64 lowercase hexadecimal characters"
            )
        }
        self = validated
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Lives in the `server.experimental` group (see `ExperimentalGroup`).
// parity: protocol/src/groups/media.ts#MediaGetEndpoint [status=implemented hash=e3dd9dcae074]
public let MediaGetEndpoint = EndpointDescriptor(
    group: "server.experimental",
    name: "media.get",
    method: .get,
    path: "/api/experimental/media/:hash",
    experimental: true,
    openAPIIdentifier: "experimental.media.get",
    summary: "Read media blob",
    description: "Read a content-addressed media blob by SHA-256 hash with immutable Cache-Control, ETag, and 304 Not Modified support. Only blobs a stored message or inbox item still references are served. Experimental: may change without compatibility guarantees.",
    pathParameters: [
        ParameterDescriptor(
            name: "hash",
            location: .path,
            required: true,
            typeName: "MediaHash",
            pattern: MediaHash.pattern
        )
    ],
    successType: "Uint8Array",
    successEncoding: .binary,
    errors: [
        ProtocolErrorRef(FileNotFoundError.self),
        ProtocolErrorRef(InvalidRequestError.self),
    ],
    tags: ["experimental"]
)

// MARK: - 19. message.ts

/// Canonical projected session message types supported by `SessionMessagesQuery.type`.
public enum SessionMessageType: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case agentSwitched = "agent-switched"
    case modelSwitched = "model-switched"
    case locationSwitched = "location-switched"
    case user
    case synthetic
    case system
    case skill
    case shell
    case assistant
    case compaction
    case idle
}

/// Pagination sort direction (`asc` or `desc`).
public enum ProtocolSortOrder: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case asc
    case desc
}

/// Opaque forward/backward pagination cursors for `session.messages`.
public struct MessagesCursor: Equatable, Hashable, Sendable, Codable {
    public let previous: String?
    public let next: String?

    public init(previous: String? = nil, next: String? = nil) {
        self.previous = previous
        self.next = next
    }
}

/// Query parameters for `GET /api/session/:sessionID/message`.
// parity: protocol/src/groups/message.ts#SessionMessagesQuery [status=implemented hash=ebdd08384162]
public struct SessionMessagesQuery: Equatable, Hashable, Sendable, Codable {
    public static let minLimit = 1
    public static let maxLimit = 200

    public let limit: Int?
    public let order: ProtocolSortOrder?
    public let cursor: String?
    public let type: SessionMessageType?

    public init(
        limit: Int? = nil,
        order: ProtocolSortOrder? = nil,
        cursor: String? = nil,
        type: SessionMessageType? = nil
    ) {
        self.limit = limit
        self.order = order
        self.cursor = cursor
        self.type = type
    }

    public var isLimitValid: Bool {
        guard let limit else { return true }
        return limit >= Self.minLimit && limit <= Self.maxLimit
    }
}

/// Public wire representation of a projected session message (`Session.Message.Info`).
// parity: protocol/src/groups/message.ts#PublicSessionMessage [status=implemented hash=a43fcf19943f]
public struct PublicSessionMessage: Equatable, Hashable, Sendable, Codable {
    public let fields: [String: JSONValue]

    public init(fields: [String: JSONValue]) {
        self.fields = fields
    }

    public var id: String? {
        if case .string(let s) = fields["id"] { return s }
        return nil
    }

    public var type: SessionMessageType? {
        if case .string(let s) = fields["type"] { return SessionMessageType(rawValue: s) }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.fields = try container.decode([String: JSONValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }
}

/// Experimental: `PublicSessionMessage` for clients opting in with `X-OpenCode-Capabilities: experimental-media-uri`
/// (`Session.Message.MediaInfo`).
// parity: protocol/src/groups/message.ts#PublicMediaSessionMessage [status=implemented hash=4f4bad164626]
public struct PublicMediaSessionMessage: Equatable, Hashable, Sendable, Codable {
    public let fields: [String: JSONValue]

    public init(fields: [String: JSONValue]) {
        self.fields = fields
    }

    public var id: String? {
        if case .string(let s) = fields["id"] { return s }
        return nil
    }

    public var type: SessionMessageType? {
        if case .string(let s) = fields["type"] { return SessionMessageType(rawValue: s) }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.fields = try container.decode([String: JSONValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }
}

/// Experimental: `session.messages` response for clients opting into `experimental-media-uri`.
// parity: protocol/src/groups/message.ts#SessionMediaMessagesResponse [status=implemented hash=d888c6217999]
public struct SessionMediaMessagesResponse: Equatable, Hashable, Sendable, Codable {
    public let data: [PublicMediaSessionMessage]
    public let cursor: MessagesCursor

    public init(data: [PublicMediaSessionMessage], cursor: MessagesCursor) {
        self.data = data
        self.cursor = cursor
    }
}

/// Experimental: `session.message` response for clients opting into `experimental-media-uri`.
// parity: protocol/src/groups/message.ts#SessionMediaMessageResponse [status=implemented hash=c7ce3c8f959e]
public struct SessionMediaMessageResponse: Equatable, Hashable, Sendable, Codable {
    public let data: PublicMediaSessionMessage

    public init(data: PublicMediaSessionMessage) {
        self.data = data
    }
}

// parity: protocol/src/groups/message.ts#MessageGroup [status=implemented hash=405be35b6846]
public let MessageGroup = EndpointGroupDescriptor(
    identifier: "server.message",
    title: "session",
    description: "Experimental message routes.",
    endpoints: [
        EndpointDescriptor(
            group: "server.message",
            name: "session.messages",
            method: .get,
            path: "/api/session/:sessionID/message",
            openAPIIdentifier: "session.message.list",
            summary: "Get session messages",
            description: "Retrieve projected messages for a session, optionally filtered by type. Items keep the requested order across pages; use cursor.next or cursor.previous to move through the ordered timeline, passing the same type filter on each page.",
            pathParameters: [
                ParameterDescriptor(name: "sessionID", location: .path, required: true, typeName: "Session.ID")
            ],
            queryParameters: [
                ParameterDescriptor(
                    name: "limit",
                    location: .query,
                    required: false,
                    typeName: "Int(1..200)",
                    description: "Maximum number of messages to return. When omitted, the endpoint returns its default page size."
                ),
                ParameterDescriptor(
                    name: "order",
                    location: .query,
                    required: false,
                    typeName: "asc|desc",
                    description: "Message order for the first page. Use desc for newest first or asc for oldest first."
                ),
                ParameterDescriptor(
                    name: "cursor",
                    location: .query,
                    required: false,
                    typeName: "String",
                    description: "Opaque pagination cursor returned as cursor.previous or cursor.next in the previous response. Do not combine with order."
                ),
                ParameterDescriptor(
                    name: "type",
                    location: .query,
                    required: false,
                    typeName: "SessionMessage.Type",
                    description: "Filter by message type before pagination. When omitted, all message types are returned. Pass the same type when following cursors."
                ),
            ],
            successType: "SessionMessagesResponse",
            errors: [
                ProtocolErrorRef(InvalidCursorError.self),
                ProtocolErrorRef(SessionNotFoundError.self),
                ProtocolErrorRef(UnknownError.self),
            ]
        )
    ]
)

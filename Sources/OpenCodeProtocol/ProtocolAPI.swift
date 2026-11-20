import OpenCodeSchema

/// Composed HTTP API contract matching `packages/protocol/src/api.ts#Api`.
// parity: protocol/src/api.ts#Api [status=implemented hash=fa1e3141881d]
public struct ProtocolApi: Equatable, Hashable, Sendable, Codable {
    public let identifier: String
    public let title: String
    public let version: String
    public let description: String
    public let groups: [EndpointGroupDescriptor]
    public let middlewares: [MiddlewareDescriptor]

    public init(
        identifier: String = "server",
        title: String = "opencode HttpApi",
        version: String = "0.0.1",
        description: String = "Experimental HttpApi surface for selected instance routes.",
        groups: [EndpointGroupDescriptor],
        middlewares: [MiddlewareDescriptor] = [
            Authorization.descriptor,
            SchemaErrorMiddleware.descriptor,
        ]
    ) {
        self.identifier = identifier
        self.title = title
        self.version = version
        self.description = description
        self.groups = groups.map { group in
            middlewares.reduce(group) { current, mw in
                current.middleware(mw)
            }
        }
        self.middlewares = middlewares
    }

    /// Flattened list of all endpoints across all groups in canonical registration order.
    public var endpoints: [EndpointDescriptor] {
        groups.flatMap(\.endpoints)
    }

    /// Looks up an endpoint by its exact OpenAPI operation identifier.
    public func endpoint(openAPIIdentifier: String) -> EndpointDescriptor? {
        endpoints.first { $0.openAPIIdentifier == openAPIIdentifier }
    }

    /// Looks up an endpoint by its internal endpoint name (`HttpApiEndpoint` name).
    public func endpoint(name: String) -> EndpointDescriptor? {
        endpoints.first { $0.name == name }
    }

    /// Looks up an endpoint by HTTP method and route template path (accepts either `:param` or `{param}`).
    public func endpoint(method: HTTPMethod, path: String) -> EndpointDescriptor? {
        endpoints.first { $0.method == method && ($0.path == path || $0.openAPIPath == path) }
    }
}

/// Canonical alias matching upstream `Api`.
public typealias Api = ProtocolApi

private func makeApiFromGroup(
    eventGroup: EndpointGroupDescriptor,
    locationMiddleware: MiddlewareDescriptor,
    formLocationMiddleware: MiddlewareDescriptor,
    sessionLocationMiddleware: MiddlewareDescriptor
) -> ProtocolApi {
    ProtocolApi(
        identifier: "server",
        title: "opencode HttpApi",
        version: "0.0.1",
        description: "Experimental HttpApi surface for selected instance routes.",
        groups: [
            ServerGroup,
            makeLocationGroup(locationMiddleware: locationMiddleware),
            AgentGroup.middleware(locationMiddleware),
            PluginGroup.middleware(locationMiddleware),
            makeSessionGroup(
                sessionLocationMiddleware: sessionLocationMiddleware,
                formLocationMiddleware: formLocationMiddleware
            ),
            MessageGroup,
            ModelGroup.middleware(locationMiddleware),
            GenerateGroup,
            VoiceGroup,
            ProviderGroup.middleware(locationMiddleware),
            IntegrationGroup.middleware(locationMiddleware),
            makeMcpGroup(locationMiddleware: locationMiddleware),
            CredentialGroup,
            ProjectGroup,
            makeFormGroup(locationMiddleware: locationMiddleware),
            makePermissionGroup(
                locationMiddleware: locationMiddleware,
                sessionLocationMiddleware: sessionLocationMiddleware
            ),
            FileSystemGroup.middleware(locationMiddleware),
            CommandGroup.middleware(locationMiddleware),
            SkillGroup.middleware(locationMiddleware),
            RpcGroup.middleware(locationMiddleware),
            eventGroup,
            makePtyGroup(locationMiddleware: locationMiddleware),
            ExperimentalGroup,
            ShellGroup.middleware(locationMiddleware),
            ReferenceGroup.middleware(locationMiddleware),
            WorktreeGroup,
            VcsGroup.middleware(locationMiddleware),
            DebugGroup,
            MigrationGroup,
            WebSearchGroup.middleware(locationMiddleware),
            UsageGroup.middleware(locationMiddleware),
            ConfigGroup.middleware(locationMiddleware),
        ],
        middlewares: [
            Authorization.descriptor,
            SchemaErrorMiddleware.descriptor,
        ]
    )
}

/// Composes the full OpenCode HTTP API contract with custom event definitions and injected middleware descriptors.
/// Protocol owns middleware placement, while Server injects concrete keys so Core service identities stay downstream.
// parity: protocol/src/api.ts#makeApi [status=implemented hash=9767cbefeb43]
public func makeApi(
    definitions: [String],
    locationMiddleware: MiddlewareDescriptor,
    formLocationMiddleware: MiddlewareDescriptor,
    sessionLocationMiddleware: MiddlewareDescriptor
) -> ProtocolApi {
    makeApiFromGroup(
        eventGroup: makeEventGroup(definitions: definitions),
        locationMiddleware: locationMiddleware,
        formLocationMiddleware: formLocationMiddleware,
        sessionLocationMiddleware: sessionLocationMiddleware
    )
}

/// Composes the full OpenCode HTTP API contract using the default `EventGroup` (`EventManifest.ServerDefinitions`).
// parity: protocol/src/api.ts#makeDefaultApi [status=implemented hash=94c9a7f6658f]
public func makeDefaultApi(
    locationMiddleware: MiddlewareDescriptor,
    formLocationMiddleware: MiddlewareDescriptor,
    sessionLocationMiddleware: MiddlewareDescriptor
) -> ProtocolApi {
    makeApiFromGroup(
        eventGroup: EventGroup,
        locationMiddleware: locationMiddleware,
        formLocationMiddleware: formLocationMiddleware,
        sessionLocationMiddleware: sessionLocationMiddleware
    )
}

import Testing
import OpenCodeProtocol
import OpenCodeSchema

@Suite("OpenCodeProtocol Contract & Parity Tests")
struct ProtocolContractTests {

    // MARK: - Catalog & API Composition

    @Test("ProtocolCatalog enumerates all 39 upstream groups")
    func catalogHasAllGroups() {
        #expect(ProtocolCatalog.upstreamGroups.count == 39)
        #expect(Set(ProtocolCatalog.upstreamGroups).count == 39)
    }

    @Test("ClientApi composes all 32 API groups and all 178 upstream endpoints")
    func clientApiComposition() {
        #expect(ClientApi.identifier == "server")
        #expect(ClientApi.title == "opencode HttpApi")
        #expect(ClientApi.version == "0.0.1")
        #expect(ClientApi.groups.count == 32)
        #expect(ClientApi.endpoints.count == 178)
        #expect(groupNames.count == 32)

        let composedGroupIDs = Set(ClientApi.groups.map(\.identifier))
        #expect(composedGroupIDs == Set(groupNames.keys))
        #expect(groupNames["server.fs"] == "file")
    }

    // MARK: - Experimental Identifier & Route Invariants (packages/protocol/test/experimental-identifiers.test.ts)

    @Test("Routes under /api/experimental, and only those, have experimental.* identifiers")
    func experimentalIdentifiersBijection() {
        let endpoints = ClientApi.endpoints
        #expect(endpoints.count > 100)

        var offenders: [String] = []
        for endpoint in endpoints {
            let isExperimentalPath =
                endpoint.path == "/api/experimental" || endpoint.path.hasPrefix("/api/experimental/")
            let isExperimentalID = endpoint.openAPIIdentifier.hasPrefix("experimental.")
            if isExperimentalPath != isExperimentalID {
                offenders.append("\(endpoint.openAPIIdentifier) \(endpoint.path)")
            }
            #expect(endpoint.experimental == isExperimentalPath)
            #expect((clientNamespace(endpoint) == "experimental") == isExperimentalPath)
        }
        #expect(offenders.isEmpty)
    }

    @Test("No duplicate (method, path), (method, openAPIPath), openAPIIdentifier, or endpoint name")
    func noDuplicateRoutesOrIdentifiers() {
        var seenRoutes = Set<String>()
        var seenOpenAPIRoutes = Set<String>()
        var seenOpenAPIIDs = Set<String>()
        var seenNames = Set<String>()

        for endpoint in ClientApi.endpoints {
            let routeKey = "\(endpoint.method.rawValue) \(endpoint.path)"
            let openAPIRouteKey = "\(endpoint.method.rawValue) \(endpoint.openAPIPath)"
            #expect(seenRoutes.insert(routeKey).inserted, "Duplicate route: \(routeKey)")
            #expect(seenOpenAPIRoutes.insert(openAPIRouteKey).inserted, "Duplicate OpenAPI route: \(openAPIRouteKey)")
            #expect(seenOpenAPIIDs.insert(endpoint.openAPIIdentifier).inserted, "Duplicate openAPIIdentifier: \(endpoint.openAPIIdentifier)")
            #expect(seenNames.insert(endpoint.name).inserted, "Duplicate endpoint name: \(endpoint.name)")
        }
    }

    @Test("Every :param template segment matches declared pathParameters and location query uses deepObject style")
    func parameterAndMiddlewareConsistency() throws {
        for endpoint in ClientApi.endpoints {
            let templateParams = endpoint.path
                .split(separator: "/")
                .filter { $0.hasPrefix(":") && $0.count > 1 }
                .map { String($0.dropFirst()) }

            let declaredPathParams = endpoint.pathParameters.map(\.name)
            #expect(declaredPathParams == templateParams, "Path params mismatch for \(endpoint.openAPIIdentifier)")
            #expect(endpoint.pathParameters.allSatisfy { $0.location == .path && $0.required })

            for queryParam in endpoint.queryParameters where queryParam.name == "location" {
                #expect(queryParam.style == .deepObject, "Expected deepObject style on \(endpoint.openAPIIdentifier)")
                #expect(queryParam.explode == true, "Expected explode=true on \(endpoint.openAPIIdentifier)")
            }

            // Every endpoint inherits global Authorization (401) and SchemaErrorMiddleware (400)
            #expect(endpoint.middlewares.contains(Authorization.descriptor))
            #expect(endpoint.middlewares.contains(SchemaErrorMiddleware.descriptor))
            #expect(endpoint.errors.contains(ProtocolErrorRef(UnauthorizedError.self)))
            #expect(endpoint.errors.contains(ProtocolErrorRef(InvalidRequestError.self)))
        }

        // Verify per-endpoint middleware placement invariants
        let locationGet = try #require(ClientApi.endpoint(openAPIIdentifier: "location.get"))
        let locationReload = try #require(ClientApi.endpoint(openAPIIdentifier: "location.reload"))
        #expect(locationGet.errors.contains(ProtocolErrorRef(LocationNotFoundError.self)))
        #expect(!locationReload.errors.contains(ProtocolErrorRef(LocationNotFoundError.self)))

        let ptyList = try #require(ClientApi.endpoint(openAPIIdentifier: "pty.list"))
        let ptyConnect = try #require(ClientApi.endpoint(openAPIIdentifier: "pty.connect"))
        #expect(ptyList.middlewares.contains { $0.id == "@opencode/client/LocationMiddleware" })
        #expect(!ptyConnect.middlewares.contains { $0.id == "@opencode/client/LocationMiddleware" })
        #expect(ptyConnect.errors.contains(ProtocolErrorRef(LocationNotFoundError.self)))
        #expect(ptyConnect.isWebSocket)

        let mcpClient = try #require(ClientApi.endpoint(openAPIIdentifier: "experimental.mcp.client"))
        #expect(!mcpClient.middlewares.contains { $0.id == "@opencode/client/LocationMiddleware" })
        #expect(mcpClient.isWebSocket)

        let legacyGenerate = try #require(ClientApi.endpoint(openAPIIdentifier: "experimental.generate.textLegacy"))
        #expect(legacyGenerate.isDeprecated)

        let sessionPrompt = try #require(ClientApi.endpoint(openAPIIdentifier: "session.prompt"))
        let sessionGet = try #require(ClientApi.endpoint(openAPIIdentifier: "session.get"))
        #expect(sessionPrompt.middlewares.contains { $0.id == "@opencode/client/SessionLocationMiddleware" })
        #expect(!sessionGet.middlewares.contains { $0.id == "@opencode/client/SessionLocationMiddleware" })
    }

    @Test("Client metadata sets match real endpoints and frozen counts")
    func clientMetadataSets() {
        let allNames = Set(ClientApi.endpoints.map(\.name))
        #expect(deprecatedClientPaths.count == 26)
        #expect(promiseOmitEndpoints.count == 5)
        #expect(effectOmitEndpoints.count == 10)

        for name in promiseOmitEndpoints {
            #expect(allNames.contains(name), "promiseOmitEndpoints contains unknown endpoint '\(name)'")
        }
        for name in effectOmitEndpoints {
            #expect(allNames.contains(name), "effectOmitEndpoints contains unknown endpoint '\(name)'")
        }
        #expect(promiseOmitEndpoints.isSubset(of: effectOmitEndpoints))
    }

    @Test("makeApi supports custom event definitions and custom middleware injection")
    func makeApiCustomComposition() throws {
        let customLocation = MiddlewareDescriptor(id: "@test/Location", errors: [ProtocolErrorRef(LocationNotFoundError.self)])
        let customForm = MiddlewareDescriptor(id: "@test/Form", errors: [ProtocolErrorRef(FormNotFoundError.self)])
        let customSession = MiddlewareDescriptor(id: "@test/Session", errors: [ProtocolErrorRef(SessionNotFoundError.self)])

        let api = makeApi(
            definitions: ["session.created"],
            locationMiddleware: customLocation,
            formLocationMiddleware: customForm,
            sessionLocationMiddleware: customSession
        )
        #expect(api.groups.count == 32)
        #expect(api.endpoints.count == 178)

        let formList = try #require(api.endpoint(openAPIIdentifier: "session.form.list"))
        #expect(formList.middlewares.contains(customForm))
        let agentList = try #require(api.endpoint(openAPIIdentifier: "agent.list"))
        #expect(agentList.middlewares.contains(customLocation))
        let prompt = try #require(api.endpoint(openAPIIdentifier: "session.prompt"))
        #expect(prompt.middlewares.contains(customSession))
    }

    // MARK: - Tagged Protocol Errors (all 40 core + VcsInitNotSupportedError + WorktreeError)

    @Test("All 42 tagged protocol errors encode/decode cleanly with exact _tag and HTTP status codes")
    func allProtocolErrorsRoundTrip() throws {
        let samples: [(ProtocolErrorEnvelope, String, Int)] = [
            (.locationNotFound(LocationNotFoundError(location: OpenCodeLocation(directory: "/tmp/proj"), message: "not found")), "LocationNotFoundError", 404),
            (.invalidRequest(InvalidRequestError(message: "bad input", kind: "validation", field: "limit")), "InvalidRequestError", 400),
            (.rpc(RpcError(type: "custom.err", message: "failed", data: .object(["detail": .int(1)]))), "RpcError", 400),
            (.rpcInternal(RpcInternalError(type: .rpcInvalidOutput, message: "bad output", data: .string("raw"))), "RpcInternalError", 500),
            (.unauthorized(UnauthorizedError(message: "missing auth")), "UnauthorizedError", 401),
            (.conflict(ConflictError(message: "exists", resource: "cred_1")), "ConflictError", 409),
            (.sessionBusy(SessionBusyError(sessionID: "ses_1", message: "busy")), "SessionBusyError", 409),
            (.serviceUnavailable(ServiceUnavailableError(message: "offline", service: "pty")), "ServiceUnavailableError", 503),
            (.unknown(UnknownError(message: "boom", ref: "ref_1")), "UnknownError", 500),
            (.providerNotFound(ProviderNotFoundError(providerID: "openai", message: "missing")), "ProviderNotFoundError", 404),
            (.integrationNotFound(IntegrationNotFoundError(integrationID: "gh", message: "missing")), "IntegrationNotFoundError", 404),
            (.integrationAttemptNotFound(IntegrationAttemptNotFoundError(integrationID: "gh", attemptID: "att_1", message: "missing")), "IntegrationAttemptNotFoundError", 404),
            (.integrationMethodNotFound(IntegrationMethodNotFoundError(integrationID: "gh", methodID: "oauth", message: "missing")), "IntegrationMethodNotFoundError", 404),
            (.projectNotFound(ProjectNotFoundError(projectID: "prj_1", message: "missing")), "ProjectNotFoundError", 404),
            (.fileNotFound(FileNotFoundError(path: "a.txt", message: "missing")), "FileNotFoundError", 404),
            (.pluginNotFound(PluginNotFoundError(pluginID: "plug_1", message: "missing")), "PluginNotFoundError", 404),
            (.agentNotFound(AgentNotFoundError(agentID: "coder", message: "missing")), "AgentNotFoundError", 404),
            (.sessionNotFound(SessionNotFoundError(sessionID: "ses_1", message: "missing")), "SessionNotFoundError", 404),
            (.messageNotFound(MessageNotFoundError(sessionID: "ses_1", messageID: "msg_1", message: "missing")), "MessageNotFoundError", 404),
            (.skillNotFound(SkillNotFoundError(skill: "review", message: "missing")), "SkillNotFoundError", 404),
            (.mcpServerNotFound(McpServerNotFoundError(server: "linear", message: "missing")), "McpServerNotFoundError", 404),
            (.commandNotFound(CommandNotFoundError(command: "deploy", message: "missing")), "CommandNotFoundError", 404),
            (.commandExecution(CommandExecutionError(command: "deploy", message: "exit 1")), "CommandExecutionError", 500),
            (.invalidCursor(InvalidCursorError(message: "corrupt cursor")), "InvalidCursorError", 400),
            (.permissionNotFound(PermissionNotFoundError(requestID: "perm_1", message: "missing")), "PermissionNotFoundError", 404),
            (.permissionSavedNotFound(PermissionSavedNotFoundError(id: "ps_1", message: "missing")), "PermissionSavedNotFoundError", 404),
            (.formNotFound(FormNotFoundError(id: "frm_1", message: "missing")), "FormNotFoundError", 404),
            (.formAlreadySettled(FormAlreadySettledError(id: "frm_1", message: "settled")), "FormAlreadySettledError", 409),
            (.formInvalidAnswer(FormInvalidAnswerError(id: "frm_1", message: "invalid")), "FormInvalidAnswerError", 400),
            (.forbidden(ForbiddenError(message: "denied")), "ForbiddenError", 403),
            (.ptyNotFound(PtyNotFoundError(ptyID: "pty_1", message: "missing")), "PtyNotFoundError", 404),
            (.ptyFeatureUnsupported(PtyFeatureUnsupportedError(feature: "rename", message: "unsupported")), "PtyFeatureUnsupportedError", 501),
            (.shellNotFound(ShellNotFoundError(id: "sh_1", message: "missing")), "ShellNotFoundError", 404),
            (.modelNotFound(ModelNotFoundError(providerID: "openai", modelID: "gpt-x", message: "missing")), "ModelNotFoundError", 404),
            (.unsupportedModel(UnsupportedModelError(providerID: "openai", modelID: "gpt-x", capability: "image", message: "no image")), "UnsupportedModelError", 422),
            (.providerRequest(ProviderRequestError(providerID: "openai", reason: .rateLimit, message: "429", status: 429, retryAfterMs: 2500)), "ProviderRequestError", 502),
            (.automationNotFound(AutomationNotFoundError(automationID: "aut_1", message: "missing")), "AutomationNotFoundError", 404),
            (.videoNotFound(VideoNotFoundError(videoID: "vid_1", message: "missing")), "VideoNotFoundError", 404),
            (.blobNotFound(BlobNotFoundError(blobID: "blb_1", message: "missing")), "BlobNotFoundError", 404),
            (.artifactNotFound(ArtifactNotFoundError(artifactID: "art_1", message: "missing")), "ArtifactNotFoundError", 404),
            (.machineNotFound(MachineNotFoundError(machine: "gpu", message: "missing")), "MachineNotFoundError", 404),
            (.vcsInitNotSupported(VcsInitNotSupportedError(providerID: "svn", message: "no init")), "VcsInitNotSupportedError", 501),
            (.worktree(WorktreeError(message: "dirty worktree", forceRequired: true)), "WorktreeError", 400),
        ]

        #expect(ProtocolErrorEnvelope.allCoreErrorRefs.count == 41)
        #expect(samples.count == 43)

        for (envelope, expectedTag, expectedStatus) in samples {
            #expect(envelope.tag == expectedTag)
            #expect(envelope.httpStatusCode == expectedStatus)

            let fields = try ProtocolTestCodec.encodeObjectFields(envelope)
            #expect(fields["_tag"] == .string(expectedTag))

            let decoded = try ProtocolTestCodec.roundTrip(envelope)
            #expect(decoded == envelope)
        }

        // Verify LocationNotFoundError omits workspaceID when nil (Location.PublicRef)
        let locErr = LocationNotFoundError(location: OpenCodeLocation(directory: "/work"), message: "missing")
        let locFields = try ProtocolTestCodec.encodeObjectFields(locErr)
        #expect(locFields["location"] == .object(["directory": .string("/work")]))

        // Verify WorktreeError carries literal `name: "WorktreeError"` alongside `_tag`
        let wtErr = WorktreeError(message: "dirty", forceRequired: true)
        let wtFields = try ProtocolTestCodec.encodeObjectFields(wtErr)
        #expect(wtFields["_tag"] == .string("WorktreeError"))
        #expect(wtFields["name"] == .string("WorktreeError"))
        #expect(wtFields["data"] == .object(["forceRequired": .bool(true), "message": .string("dirty")]))

        // Verify mismatched _tag fails decoding
        #expect(throws: Error.self) {
            _ = try ProtocolTestCodec.decodeFromString(
                UnauthorizedError.self,
                json: #"{"_tag":"ForbiddenError","message":"wrong tag"}"#
            )
        }
    }

    // MARK: - Event Classification (packages/protocol/test/event.test.ts)

    @Test("isOpenCodeEvent classifies public events by type matching upstream event.test.ts")
    func classifiesPublicEvents() {
        #expect(isOpenCodeEvent(type: "server.connected") == true)
        #expect(isOpenCodeEvent(type: "mcp.status.changed") == true)
        #expect(isOpenCodeEvent(type: "mcp.resources.changed") == true)
        #expect(isOpenCodeEvent(type: "mcp.tools.changed") == false)
        #expect(isOpenCodeEvent(type: "acme.updated") == false)
        #expect(isOpenCodeEvent(type: "rpc.plugin.ping") == true)
        #expect(isOpenCodeEvent(type: "rpc.") == true)
        #expect(isOpenCodeEvent(type: "session.created") == true)
        #expect(isOpenCodeEvent(type: "message.updated") == false)
        #expect(OpenCodeEvent.serverEventTypeList.count == 99)

        let event = OpenCodeEvent(id: "evt_1", type: "server.connected")
        #expect(isOpenCodeEvent(event) == true)
    }

    // MARK: - URL Matchers & Client Namespace

    @Test("URL predicate functions match exact upstream path and query semantics")
    func urlPredicateFunctions() {
        // clientNamespace
        #expect(clientNamespace(path: "/api/experimental") == "experimental")
        #expect(clientNamespace(path: "/api/experimental/blob/:id") == "experimental")
        #expect(clientNamespace(path: "/api/experimental-v2/foo") == nil)
        #expect(clientNamespace(path: "/api/session") == nil)

        // hasMcpClientTicketURL
        #expect(hasMcpClientTicketURL("ws://127.0.0.1:4096/api/experimental/client-mcp?name=local&ticket=tok123") == true)
        #expect(hasMcpClientTicketURL("/api/experimental/client-mcp?ticket=abc#frag") == true)
        #expect(hasMcpClientTicketURL("/api/experimental/client-mcp?ticket=") == false)
        #expect(hasMcpClientTicketURL("/api/experimental/client-mcp?name=local") == false)
        #expect(hasMcpClientTicketURL("/api/experimental/client-mcp/token?ticket=abc") == false)

        // hasPtyConnectTicketURL
        #expect(hasPtyConnectTicketURL("ws://localhost:4096/api/pty/pty_1/connect?ticket=t1") == true)
        #expect(hasPtyConnectTicketURL("/api/pty/pty_1/connect?cursor=0&ticket=t1") == true)
        #expect(hasPtyConnectTicketURL("/api/pty/pty_1/connect?ticket=") == false)
        #expect(hasPtyConnectTicketURL("/api/pty//connect?ticket=t1") == false)
        #expect(hasPtyConnectTicketURL("/api/pty/a/b/connect?ticket=t1") == false)
        #expect(hasPtyConnectTicketURL("/api/pty/pty_1/connect") == false)

        // hasPersistentPtyConnectTicketURL
        #expect(hasPersistentPtyConnectTicketURL("ws://localhost:4096/api/experimental/persistent-pty/pty_1/connect?ticket=t1") == true)
        #expect(hasPersistentPtyConnectTicketURL("/api/experimental/persistent-pty/pty_1/connect?ticket=") == false)
        #expect(hasPersistentPtyConnectTicketURL("/api/experimental/persistent-pty/a/b/connect?ticket=t1") == false)
        #expect(hasPersistentPtyConnectTicketURL("/api/pty/pty_1/connect?ticket=t1") == false)

        // isPairingConnectURL
        #expect(isPairingConnectURL("https://example.com/auth/connect/ABCD1234") == true)
        #expect(isPairingConnectURL("/auth/connect/code-1?foo=bar") == true)
        #expect(isPairingConnectURL("/auth/connect/") == false)
        #expect(isPairingConnectURL("/auth/connect/a/b") == false)
        #expect(isPairingConnectURL("/auth/connect") == false)
        #expect(isPairingConnectURL("/api/pair") == false)
    }

    // MARK: - Protocol Data Contracts Round-Trip

    @Test("MediaHash, V1MigrationStatus, VoiceTransport, ServerInfo, PairingCode, and SessionsQuery encode/decode cleanly")
    func protocolDataContracts() throws {
        // MediaHash
        let validHash = String(repeating: "a1b2c3d4", count: 8)
        let hash = try #require(MediaHash(rawValue: validHash))
        #expect(try ProtocolTestCodec.roundTrip(hash) == hash)
        #expect(MediaHash(rawValue: String(repeating: "A", count: 64)) == nil)
        #expect(MediaHash(rawValue: "abcd") == nil)
        #expect(throws: Error.self) {
            _ = try ProtocolTestCodec.decodeFromString(MediaHash.self, json: #""not-a-hash""#)
        }

        // V1MigrationStatus
        let statuses: [V1MigrationStatus] = [
            .required,
            .completed,
            .running(progress: V1MigrationProgress(label: "sessions", numerator: 3, denominator: 10)),
            .error("disk full"),
        ]
        for status in statuses {
            #expect(try ProtocolTestCodec.roundTrip(status) == status)
        }

        // Voice transports
        let inputs: [VoiceTransportInput] = [
            .webrtc(VoiceWebRTCTransportInput(sdp: "v=0", dcid: 1)),
            .websocket(VoiceWebSocketTransportInput()),
        ]
        for input in inputs {
            #expect(try ProtocolTestCodec.roundTrip(input) == input)
        }
        let outputs: [VoiceTransport] = [
            .webrtc(VoiceWebRTCTransport(sdp: "v=0")),
            .websocket(VoiceWebSocketTransport(url: "wss://example.com", token: "tok", expiresAt: 1700000000)),
        ]
        for output in outputs {
            #expect(try ProtocolTestCodec.roundTrip(output) == output)
        }

        // PairingCode uses snake_case `expires_in`
        let pairingCode = PairingCode(code: "XYZ", expiresIn: 300)
        let pairingFields = try ProtocolTestCodec.encodeObjectFields(pairingCode)
        #expect(pairingFields["expires_in"] == .int(300))
        #expect(try ProtocolTestCodec.roundTrip(pairingCode) == pairingCode)

        // ServerInfo
        let info = ServerInfo(
            version: "2.0.0",
            pid: 42,
            hostname: "devbox",
            urls: ["http://127.0.0.1:4096"],
            paths: .init(tmp: "/tmp"),
            capabilities: .init(persistentPty: true)
        )
        #expect(try ProtocolTestCodec.roundTrip(info) == info)

        // SessionsQuery & SessionParentFilter ("null" vs SessionID)
        let rootQuery = SessionsQuery(
            limit: 25,
            order: .desc,
            parentID: .root,
            archived: false,
            project: ProjectID(rawValue: "prj_1"),
            cursor: SessionsCursor(rawValue: "cur_abc")
        )
        let encodedQuery = try ProtocolTestCodec.encodeObjectFields(rootQuery)
        #expect(encodedQuery["parentID"] == .string("null"))
        #expect(try ProtocolTestCodec.roundTrip(rootQuery) == rootQuery)

        let childSession = try SessionID(validating: "ses_1234567890abcdef")
        let childQuery = SessionsQuery(parentID: .session(childSession))
        #expect(try ProtocolTestCodec.roundTrip(childQuery) == childQuery)
    }

    // MARK: - Simulation Protocol (packages/protocol/src/simulation.ts)

    @Test("JsonRpc.success, JsonRpc.failure, and Response oneOf semantics")
    func jsonRpcHelpers() throws {
        #expect(JsonRpc.success(id: nil, result: .bool(true)) == nil)
        let ok = try #require(JsonRpc.success(id: .number(7), result: .object(["ok": .bool(true)])))
        #expect(try ProtocolTestCodec.roundTrip(ok) == ok)
        let okFields = try ProtocolTestCodec.encodeObjectFields(ok)
        #expect(okFields["jsonrpc"] == .string("2.0"))
        #expect(okFields["id"] == .int(7))

        let fail = JsonRpc.failure(id: nil, message: "boom")
        #expect(fail == .failure(id: .null, error: JsonRpc.ErrorObject(code: -32000, message: "boom")))
        #expect(try ProtocolTestCodec.roundTrip(fail) == fail)

        // Response cannot have both result and error
        #expect(throws: Error.self) {
            _ = try ProtocolTestCodec.decodeFromString(
                JsonRpc.Response.self,
                json: #"{"jsonrpc":"2.0","id":1,"result":true,"error":{"code":-1,"message":"bad"}}"#
            )
        }
    }

    @Test("Handshake.dispatch validates role, protocol version, and required capabilities")
    func handshakeDispatch() throws {
        let server = Handshake.Identity(name: "opencode", version: "2.0.0")
        let client = Handshake.Identity(name: "sim", version: "1.0.0")
        let action = Handshake.DispatchAction(
            role: .ui,
            server: server,
            capabilities: ["ui.state", "ui.type", "ui.state"]
        )

        // Success deduplicates capabilities while preserving insertion order
        let okParams = Handshake.Params(
            client: client,
            expectedRole: .ui,
            offeredVersions: [1, 2],
            requiredCapabilities: ["ui.state"],
            optionalCapabilities: ["ui.capture"]
        )
        let response = try Handshake.dispatch(action: action, params: okParams)
        #expect(response.protocolVersion == .v1)
        #expect(response.role == .ui)
        #expect(response.capabilities == ["ui.state", "ui.type"])

        // Role mismatch
        let wrongRole = Handshake.Params(client: client, expectedRole: .backend, offeredVersions: [1])
        #expect {
            _ = try Handshake.dispatch(action: action, params: wrongRole)
        } throws: { err in
            guard case Handshake.DispatchError.roleMismatch(let detail) = err else { return false }
            return detail.expected == .backend && detail.actual == .ui
        }

        // Unsupported protocol
        let wrongVersion = Handshake.Params(client: client, expectedRole: .ui, offeredVersions: [2, 3])
        #expect {
            _ = try Handshake.dispatch(action: action, params: wrongVersion)
        } throws: { err in
            guard case Handshake.DispatchError.unsupportedProtocol(let detail) = err else { return false }
            return detail.offered == [2, 3] && detail.supported == [.v1]
        }

        // Missing capabilities
        let missingCaps = Handshake.Params(
            client: client,
            expectedRole: .ui,
            offeredVersions: [1],
            requiredCapabilities: ["ui.state", "ui.capture", "ui.mouse"]
        )
        #expect {
            _ = try Handshake.dispatch(action: action, params: missingCaps)
        } throws: { err in
            guard case Handshake.DispatchError.missingCapability(let detail) = err else { return false }
            return detail.missing == ["ui.capture", "ui.mouse"]
        }
    }

    @Test("Frontend simulation types, SemanticSnapshot graph validation, pressParams, and request decoding")
    func frontendSimulation() throws {
        #expect(Frontend.Capabilities.count == 15)
        #expect(Frontend.Capability.allCases.map(\.rawValue) == Frontend.Capabilities)
        #expect(UiRpcs.methods.count == 14)

        let p = Frontend.pressParams("Enter", modifiers: Frontend.KeyModifiers(ctrl: true, superKey: true))
        let pFields = try ProtocolTestCodec.encodeObjectFields(p)
        #expect(pFields["key"] == .string("Enter"))
        #expect(pFields["modifiers"] == .object(["ctrl": .bool(true), "super": .bool(true)]))

        // Color encodes as 4-element JSON array
        let color = Frontend.Color(1, 0.5, 0, 1)
        #expect(try ProtocolTestCodec.encodeToString(color) == "[1,0.5,0,1]")
        #expect(try ProtocolTestCodec.roundTrip(color) == color)

        // SemanticSnapshot valid tree
        let root = Frontend.SemanticNode(id: "root", role: "window", element: 1)
        let child = Frontend.SemanticNode(id: "btn", parent: "root", role: "button", label: "Send", element: 2)
        let snap = try Frontend.SemanticSnapshot(nodes: [root, child])
        #expect(try ProtocolTestCodec.roundTrip(snap) == snap)

        // Duplicate id rejected
        #expect(throws: SimulationDecodeError.self) {
            _ = try Frontend.SemanticSnapshot(nodes: [
                Frontend.SemanticNode(id: "dup", role: "box", element: 1),
                Frontend.SemanticNode(id: "dup", role: "box", element: 2),
            ])
        }
        // Missing parent rejected
        #expect(throws: SimulationDecodeError.self) {
            _ = try Frontend.SemanticSnapshot(nodes: [
                Frontend.SemanticNode(id: "orphan", parent: "ghost", role: "box", element: 1),
            ])
        }
        // Cycle rejected
        #expect(throws: SimulationDecodeError.self) {
            _ = try Frontend.SemanticSnapshot(nodes: [
                Frontend.SemanticNode(id: "a", parent: "b", role: "box", element: 1),
                Frontend.SemanticNode(id: "b", parent: "a", role: "box", element: 2),
            ])
        }

        // Pure-Swift JSON string request decoding
        let req = try Frontend.decodeRequestEffect(
            #"{"jsonrpc":"2.0","id":"r1","method":"ui.press","params":{"key":"a","modifiers":{"super":true}}}"#
        )
        #expect(req == .uiPress(id: .string("r1"), params: Frontend.PressParams(key: "a", modifiers: Frontend.KeyModifiers(superKey: true))))

        let stateReq = try Frontend.decodeRequestEffect(#"{"jsonrpc":"2.0","id":2,"method":"ui.state"}"#)
        #expect(stateReq == .uiState(id: .number(2)))
    }

    @Test("Backend simulation types, exposedToolName, ToolAttachParams validation, and notification decoding")
    func backendSimulation() throws {
        #expect(Backend.Capabilities.count == 13)
        #expect(BackendRpcs.methods.count == 10)

        let direct = Backend.ToolRegistration(name: "search", description: "Search", inputSchema: [:])
        #expect(Backend.exposedToolName(direct) == "search")

        let namespaced = Backend.ToolRegistration(
            name: "create_issue",
            description: "Create issue",
            inputSchema: [:],
            options: .init(namespace: "acme.github", codemode: true)
        )
        #expect(Backend.exposedToolName(namespaced) == "acme_github_create_issue")

        let attach = try Backend.ToolAttachParams(tools: [direct, namespaced])
        #expect(try ProtocolTestCodec.roundTrip(attach) == attach)

        // Direct "execute" with codemode == false is reserved
        #expect(throws: SimulationDecodeError.self) {
            _ = try Backend.ToolAttachParams(tools: [
                Backend.ToolRegistration(
                    name: "execute",
                    description: "bad",
                    inputSchema: [:],
                    options: .init(namespace: nil, codemode: false)
                )
            ])
        }

        // Duplicate exposed name via namespace flattening is rejected
        #expect(throws: SimulationDecodeError.self) {
            _ = try Backend.ToolAttachParams(tools: [
                Backend.ToolRegistration(name: "foo_bar", description: "a", inputSchema: [:]),
                Backend.ToolRegistration(name: "bar", description: "b", inputSchema: [:], options: .init(namespace: "foo")),
            ])
        }

        // FinishParams defaults missing reason to .stop
        let finishReq = try Backend.decodeRequestEffect(
            #"{"jsonrpc":"2.0","id":9,"method":"llm.finish","params":{"id":"inv_1"}}"#
        )
        #expect(finishReq == .llmFinish(id: .number(9), params: Backend.FinishParams(id: "inv_1", reason: .stop)))

        // Notification decoding
        let notif = try Backend.decodeNotificationEffect(
            #"{"jsonrpc":"2.0","method":"tool.cancel","params":{"id":"call_1","reason":"interrupted"}}"#
        )
        #expect(notif == .toolCancel(Backend.ToolCancellation(id: "call_1")))
    }
}

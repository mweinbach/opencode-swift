#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - CoreTool Registry, Runtime & MCP Tool Bridge (`tool.ts`, `tool/runtime.ts`, `tool/mcp.ts`)

public enum CoreTool {
    /// Dynamic JSON-based registered tool entry stored in `CoreTool.Service`.
    public struct RegisteredTool: Sendable {
        public let id: String
        public var name: String
        public var description: String
        public var inputSchema: AISchema.JsonSchema
        public var outputSchema: AISchema.JsonSchema?
        public var freeform: AISchema.Freeform?
        public var options: ToolSchema.Options?
        public var execute: @Sendable (JSONValue, ToolSchema.Context) async throws -> ToolSchema.Result<JSONValue>

        public init(
            id: String? = nil,
            name: String,
            description: String,
            inputSchema: AISchema.JsonSchema = ["type": .string("object"), "properties": .object([:])],
            outputSchema: AISchema.JsonSchema? = nil,
            freeform: AISchema.Freeform? = nil,
            options: ToolSchema.Options? = nil,
            execute: @escaping @Sendable (JSONValue, ToolSchema.Context) async throws -> ToolSchema.Result<JSONValue>
        ) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
            self.outputSchema = outputSchema
            self.freeform = freeform
            self.options = options
            self.execute = execute
            self.id = id ?? Runtime.effectiveName(name: name, options: options)
        }
    }

    // MARK: - Tool Runtime Helpers (`core/src/tool/runtime.ts`)

    public enum Runtime {
        public struct JsonSchemaCodec: Sendable {
            public let schema: AISchema.JsonSchema

            public init(schema: AISchema.JsonSchema) {
                self.schema = schema
            }

            public func validate(_ value: JSONValue) -> [String] {
                var issues: [String] = []
                if case .string("object") = schema["type"] {
                    guard case .object(let obj) = value else {
                        return ["root: expected object"]
                    }
                    if case .array(let req) = schema["required"] {
                        for r in req {
                            if case .string(let key) = r, obj[key] == nil {
                                issues.append("\(key): missing required property")
                            }
                        }
                    }
                }
                return issues
            }
        }

        // parity: core/src/tool/runtime.ts#codecFor [status=adapted hash=9739d1b89f59]
        public static func codecFor(_ schema: AISchema.JsonSchema) -> JsonSchemaCodec {
            JsonSchemaCodec(schema: schema)
        }

        // parity: core/src/tool/runtime.ts#definition [status=implemented hash=fbd6ab9a713a]
        public static func definition(_ tool: RegisteredTool) -> AISchema.ToolDefinition {
            AISchema.ToolDefinition(
                name: effectiveName(name: tool.name, options: tool.options),
                description: tool.description,
                inputSchema: tool.inputSchema,
                outputSchema: tool.outputSchema,
                freeform: tool.freeform
            )
        }

        // parity: core/src/tool/runtime.ts#execute [status=implemented hash=eaacedb56015]
        public static func execute(
            _ tool: RegisteredTool,
            input: JSONValue,
            context: ToolSchema.Context
        ) async throws -> NormalizedResult {
            let codec = codecFor(tool.inputSchema)
            let issues = codec.validate(input)
            if !issues.isEmpty {
                let details = issues.prefix(5).map { "- \($0)" }.joined(separator: "\n")
                let renderedInput = stringify(input)
                throw AISchema.ToolFailure(
                    message: "Invalid arguments for tool \"\(effectiveName(name: tool.name, options: tool.options))\":\n\(details)\n\nArguments provided:\n\(renderedInput)\n\nUpdate the arguments and call the tool again."
                )
            }
            let rawResult: ToolSchema.Result<JSONValue>
            do {
                rawResult = try await tool.execute(input, context)
            } catch let err as AISchema.ToolFailure {
                throw err
            } catch let err as CorePermission.DeclinedError {
                throw err
            } catch {
                throw AISchema.ToolFailure(message: String(describing: error))
            }

            if tool.outputSchema == nil {
                if rawResult.output != nil {
                    throw AISchema.ToolFailure(message: "Tool result declared output without an output schema")
                }
                return NormalizedResult(
                    output: nil,
                    content: normalizeContent(rawResult.content, output: nil),
                    metadata: rawResult.metadata
                )
            }
            guard let out = rawResult.output else {
                throw AISchema.ToolFailure(message: "Tool did not return its declared output")
            }
            return NormalizedResult(
                output: out,
                content: normalizeContent(rawResult.content, output: out),
                metadata: rawResult.metadata
            )
        }

        // parity: core/src/tool/runtime.ts#normalizeContent [status=implemented hash=5f5e280bb1ae]
        public static func normalizeContent(
            _ value: ToolSchema.ResultContent?,
            output: JSONValue? = nil
        ) -> [ToolSchema.Content] {
            if let value {
                switch value {
                case .text(let s):
                    return [.text(ToolSchema.TextContent(text: s))]
                case .parts(let parts):
                    if !parts.isEmpty { return parts }
                }
            }
            return [.text(ToolSchema.TextContent(text: stringify(output ?? .null)))]
        }

        // parity: core/src/tool/runtime.ts#stringify [status=implemented hash=c0364388b9cf]
        public static func stringify(_ value: JSONValue) -> String {
            if case .string(let s) = value { return s }
            if let data = try? JSONEncoder().encode(value) {
                return String(decoding: data, as: UTF8.self)
            }
            return String(describing: value)
        }

        // parity: core/src/tool/runtime.ts#normalizedName [status=implemented hash=50d687712be6]
        public static func normalizedName(_ name: String) -> String {
            String(name.map { ch in
                guard let ascii = ch.asciiValue else { return "_" }
                let ok = (ascii >= 0x30 && ascii <= 0x39)
                    || (ascii >= 0x41 && ascii <= 0x5A)
                    || (ascii >= 0x61 && ascii <= 0x7A)
                    || ascii == 0x5F || ascii == 0x2D
                return ok ? ch : "_"
            })
        }

        // parity: core/src/tool/runtime.ts#effectiveName [status=implemented hash=b7c205956951]
        public static func effectiveName(name: String, options: ToolSchema.Options? = nil) -> String {
            let norm = normalizedName(name)
            guard let ns = options?.namespace else { return norm }
            return "\(ns.replacing(".", with: "_"))_\(norm)"
        }

        // parity: core/src/tool/runtime.ts#toolFailure [status=implemented hash=52a93de96d56]
        public static func toolFailure(_ message: String) -> @Sendable (any Swift.Error) -> AISchema.ToolFailure {
            { error in
                if let failure = error as? AISchema.ToolFailure { return failure }
                return AISchema.ToolFailure(message: message, error: .string(String(describing: error)))
            }
        }
    }

    // MARK: - Tool Registry (`core/src/tool.ts`)

    // parity: core/src/tool.ts#RegistrationError [status=implemented hash=4978aa6c2c35]
    public struct RegistrationError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "Tool.RegistrationError"
        public let name: String
        public let message: String

        public init(name: String, message: String) {
            self.name = name
            self.message = message
        }

        public var description: String { message }
    }

    // parity: core/src/tool.ts#NormalizedResult [status=implemented hash=806052d1ab85]
    public typealias NormalizedResult = CoreToolOutput.NormalizedResult

    // parity: core/src/tool.ts#CheckInput [status=adapted hash=b508f8164bc8]
    public struct CheckInput: Sendable {
        public let code: String
        public let tools: [String]
        public let bindings: [String: JSONValue]
        public let permissions: PermissionSchema.Ruleset
        public let context: ToolSchema.Context

        public init(
            code: String,
            tools: [String],
            bindings: [String: JSONValue] = [:],
            permissions: PermissionSchema.Ruleset = [],
            context: ToolSchema.Context
        ) {
            self.code = code
            self.tools = tools
            self.bindings = bindings
            self.permissions = permissions
            self.context = context
        }
    }

    public struct CheckResult: Equatable, Sendable {
        public let ok: Bool
        public let error: String?
        public let availableTools: [String]

        public init(ok: Bool, error: String? = nil, availableTools: [String] = []) {
            self.ok = ok
            self.error = error
            self.availableTools = availableTools
        }
    }

    // parity: core/src/tool.ts#Editor [status=adapted hash=f0f95cb00195]
    public final class Editor: @unchecked Sendable {
        public private(set) var tools: [String: RegisteredTool] = [:]
        public private(set) var definitions: [String: AISchema.ToolDefinition] = [:]
        public private(set) var namespaces: [String: ToolSchema.Namespace] = [:]
        public private(set) var errors: [RegistrationError] = []

        public init() {}

        public func list() -> [RegisteredTool] {
            Array(tools.values)
        }

        public func get(_ id: String) -> RegisteredTool? {
            tools[id]
        }

        public func namespace(_ namespace: ToolSchema.Namespace) {
            if let err = Self.validateNamespace(namespace.name) {
                errors.append(err)
                return
            }
            namespaces[namespace.name] = namespace
        }

        public func add(_ tool: RegisteredTool) {
            if let ns = tool.options?.namespace, let err = Self.validateNamespace(ns) {
                errors.append(err)
                return
            }
            let norm = Runtime.normalizedName(tool.name)
            guard !norm.isEmpty && Self.isValidSegment(norm) else {
                errors.append(RegistrationError(name: norm, message: "Invalid tool name: \(norm)"))
                return
            }
            let id = Runtime.effectiveName(name: tool.name, options: tool.options)
            if tool.options?.codemode == false && id == "execute" {
                errors.append(RegistrationError(name: id, message: "Tool name \"execute\" is reserved for CodeMode"))
                return
            }
            let stored = RegisteredTool(
                id: id,
                name: tool.name,
                description: tool.description,
                inputSchema: tool.inputSchema,
                outputSchema: tool.outputSchema,
                freeform: tool.freeform,
                options: tool.options,
                execute: tool.execute
            )
            tools[id] = stored
            definitions[id] = Runtime.definition(stored)
        }

        public func update(_ id: String, _ mutate: (inout RegisteredTool) -> Void) {
            guard var current = tools[id] else { return }
            let origName = current.name
            let origNs = current.options?.namespace
            mutate(&current)
            current.name = origName
            if current.options?.namespace != origNs {
                current.options = ToolSchema.Options(
                    namespace: origNs,
                    permission: current.options?.permission,
                    codemode: current.options?.codemode,
                    pinned: current.options?.pinned
                )
            }
            add(current)
        }

        public func remove(_ id: String) {
            tools.removeValue(forKey: id)
            definitions.removeValue(forKey: id)
        }

        private static func isValidSegment(_ s: String) -> Bool {
            guard !s.isEmpty else { return false }
            return s.utf8.allSatisfy { b in
                (b >= 0x30 && b <= 0x39)
                    || (b >= 0x41 && b <= 0x5A)
                    || (b >= 0x61 && b <= 0x7A)
                    || b == 0x5F || b == 0x2D
            }
        }

        private static func validateNamespace(_ name: String) -> RegistrationError? {
            let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            if parts.allSatisfy(isValidSegment) { return nil }
            return RegistrationError(name: name, message: "Invalid tool namespace: \"\(name)\"")
        }
    }

    public struct ExecuteCallInput: Sendable {
        public let sessionID: SessionID
        public let agent: AgentSchema.ID
        public let messageID: String
        public let callID: ToolSchema.CallID
        public let name: String
        public let input: JSONValue
        public let progress: (@Sendable (ToolSchema.Metadata) async -> Void)?
        public let cancel: (@Sendable () async -> Void)?

        public init(
            sessionID: SessionID,
            agent: AgentSchema.ID,
            messageID: String,
            callID: ToolSchema.CallID,
            name: String,
            input: JSONValue,
            progress: (@Sendable (ToolSchema.Metadata) async -> Void)? = nil,
            cancel: (@Sendable () async -> Void)? = nil
        ) {
            self.sessionID = sessionID
            self.agent = agent
            self.messageID = messageID
            self.callID = callID
            self.name = name
            self.input = input
            self.progress = progress
            self.cancel = cancel
        }
    }

    // parity: core/src/tool.ts#Snapshot [status=adapted hash=d7ce31a23629]
    public struct Snapshot: Sendable {
        public let definitions: [AISchema.ToolDefinition]
        private let executeImpl: @Sendable (ExecuteCallInput) async throws -> NormalizedResult

        public init(
            definitions: [AISchema.ToolDefinition],
            execute: @escaping @Sendable (ExecuteCallInput) async throws -> NormalizedResult
        ) {
            self.definitions = definitions
            self.executeImpl = execute
        }

        public func execute(_ input: ExecuteCallInput) async throws -> NormalizedResult {
            try await executeImpl(input)
        }
    }

    // parity: core/src/tool.ts#Interface [status=adapted hash=6e4c7e999245]
    public protocol Interface: Sendable {
        func transform(_ fn: @escaping @Sendable (Editor) -> Void) async -> CoreFilesystem.LocationWatcherPolicy.Registration
        func reload() async
        func list() async -> [RegisteredTool]
        func snapshot(permissions: PermissionSchema.Ruleset?) async -> Snapshot
        func check(_ input: CheckInput) async -> CheckResult
    }

    // parity: core/src/tool.ts#Service [status=adapted hash=8f91e19ff0f9]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/Tool"

        private struct State: Sendable {
            var transforms: [UInt64: @Sendable (Editor) -> Void] = [:]
            var order: [UInt64] = []
            var tools: [String: RegisteredTool] = [:]
            var definitions: [String: AISchema.ToolDefinition] = [:]
            var namespaces: [String: ToolSchema.Namespace] = [:]
            var errors: [RegistrationError] = []
            var nextID: UInt64 = 1
        }

        private let state = Mutex(State())

        public init() {}

        public func transform(
            _ fn: @escaping @Sendable (Editor) -> Void
        ) async -> CoreFilesystem.LocationWatcherPolicy.Registration {
            let id = state.withLock { s -> UInt64 in
                let id = s.nextID
                s.nextID &+= 1
                s.transforms[id] = fn
                s.order.append(id)
                return id
            }
            await reload()
            return CoreFilesystem.LocationWatcherPolicy.Registration { [weak self] in
                self?.state.withLock { s in
                    _ = s.transforms.removeValue(forKey: id)
                    s.order.removeAll { $0 == id }
                }
            }
        }

        public func reload() async {
            state.withLock { s in
                let editor = Editor()
                for id in s.order { s.transforms[id]?(editor) }
                s.tools = editor.tools
                s.definitions = editor.definitions
                s.namespaces = editor.namespaces
                s.errors = editor.errors
            }
        }

        public func list() async -> [RegisteredTool] {
            state.withLock { Array($0.tools.values).sorted { $0.id < $1.id } }
        }

        public func registrationErrors() async -> [RegistrationError] {
            state.withLock { $0.errors }
        }

        public func snapshot(permissions: PermissionSchema.Ruleset? = nil) async -> Snapshot {
            let rules = permissions ?? []
            let (activeTools, activeDefs): ([String: RegisteredTool], [AISchema.ToolDefinition]) = state.withLock { s in
                var active: [String: RegisteredTool] = [:]
                for (name, tool) in s.tools {
                    let action = tool.options?.permission ?? name
                    if Self.whollyDisabled(action: action, rules: rules) { continue }
                    active[name] = tool
                }
                let defs = active.keys.sorted().compactMap { s.definitions[$0] }
                return (active, defs)
            }

            return Snapshot(definitions: activeDefs) { call in
                guard let tool = activeTools[call.name] else {
                    throw AISchema.ToolFailure(
                        message: "No tool named \"\(call.name)\" is currently available. Please use a tool from the available tool list."
                    )
                }
                let context = ToolSchema.Context(
                    sessionID: call.sessionID,
                    agent: call.agent,
                    messageID: call.messageID,
                    id: call.callID,
                    progress: call.progress ?? { _ in },
                    cancel: call.cancel
                )
                return try await Runtime.execute(tool, input: call.input, context: context)
            }
        }

        public func check(_ input: CheckInput) async -> CheckResult {
            if Self.whollyDisabled(action: "execute", rules: input.permissions) {
                return CheckResult(ok: false, error: "Code Mode is disabled for this agent", availableTools: [])
            }
            let allowedSet = Set(input.tools)
            let visible: [String] = state.withLock { s in
                s.tools.compactMap { name, tool -> String? in
                    guard tool.options?.codemode != false else { return nil }
                    guard allowedSet.contains(name) || allowedSet.contains(tool.name) else { return nil }
                    let action = tool.options?.permission ?? name
                    if Self.whollyDisabled(action: action, rules: input.permissions) { return nil }
                    return name
                }.sorted()
            }
            return CheckResult(ok: true, error: nil, availableTools: visible)
        }

        private static func whollyDisabled(action: String, rules: PermissionSchema.Ruleset) -> Bool {
            for rule in rules.reversed() {
                if CorePermissionWildcard.match(action, pattern: rule.action) {
                    return rule.resource == "*" && rule.effect == .deny
                }
            }
            return false
        }
    }

    // parity: core/src/tool.ts#node [status=adapted hash=ea7fd70a84ed]
    public static let node: LayerNode.Provider = AppNode.makeLocationNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer.succeed(key: Service.serviceKey, value: Service() as any Interface),
        [CorePermission.node, CoreFlag.node]
    )

    // MARK: - MCP Tool Bridge (`core/src/tool/mcp.ts`)

    public enum Mcp {
        public struct ToolDescriptor: Equatable, Sendable {
            public let server: String
            public let name: String
            public let description: String?
            public let inputSchema: AISchema.JsonSchema
            public let outputSchema: AISchema.JsonSchema?
            public let codemode: Bool?

            public init(
                server: String,
                name: String,
                description: String? = nil,
                inputSchema: AISchema.JsonSchema = ["type": .string("object"), "properties": .object([:])],
                outputSchema: AISchema.JsonSchema? = nil,
                codemode: Bool? = nil
            ) {
                self.server = server
                self.name = name
                self.description = description
                self.inputSchema = inputSchema
                self.outputSchema = outputSchema
                self.codemode = codemode
            }
        }

        public enum ToolResultPart: Equatable, Sendable {
            case text(String)
            case blob(dataBase64: String, mimeType: String, uri: String? = nil)
        }

        public struct ToolCallResult: Equatable, Sendable {
            public let isError: Bool
            public let content: [ToolResultPart]
            public let structured: JSONValue?

            public init(isError: Bool = false, content: [ToolResultPart] = [], structured: JSONValue? = nil) {
                self.isError = isError
                self.content = content
                self.structured = structured
            }
        }

        public protocol ClientBridge: Sendable {
            func tools() async -> [ToolDescriptor]
            func callTool(server: String, name: String, args: JSONValue, sessionID: SessionID) async throws -> ToolCallResult
        }

        // parity: core/src/tool/mcp.ts#namespace [status=implemented hash=9fe05130ab65]
        public static func namespace(_ server: String) -> String {
            Runtime.normalizedName(server)
        }

        // parity: core/src/tool/mcp.ts#name [status=implemented hash=6debf12e0b78]
        public static func name(server: String, tool: String) -> String {
            Runtime.effectiveName(name: tool, options: ToolSchema.Options(namespace: namespace(server)))
        }

        // parity: core/src/tool/mcp.ts#Interface [status=adapted hash=603b803bcd4e]
        public protocol Interface: Sendable {
            func flush() async
        }

        // parity: core/src/tool/mcp.ts#Service [status=adapted hash=1066b8a79aae]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/McpTool"

            private let toolsRegistry: any CoreTool.Interface
            private let permission: any CorePermission.Interface
            private let toolOutput: any CoreToolOutput.Interface
            private let client: (any ClientBridge)?
            private let discovered = Mutex<[ToolDescriptor]>([])

            public init(
                toolsRegistry: any CoreTool.Interface,
                permission: any CorePermission.Interface = CorePermission.Service(),
                toolOutput: any CoreToolOutput.Interface = CoreToolOutput.Service(),
                client: (any ClientBridge)? = nil
            ) {
                self.toolsRegistry = toolsRegistry
                self.permission = permission
                self.toolOutput = toolOutput
                self.client = client
            }

            public func flush() async {
                guard let client else { return }
                let latest = await client.tools()
                let changed = discovered.withLock { current -> Bool in
                    if current == latest { return false }
                    current = latest
                    return true
                }
                if !changed { return }
                let perm = self.permission
                let outputSvc = self.toolOutput
                _ = await toolsRegistry.transform { editor in
                    for descriptor in latest {
                        let ns = Mcp.namespace(descriptor.server)
                        let actionName = Mcp.name(server: descriptor.server, tool: descriptor.name)
                        editor.add(RegisteredTool(
                            name: descriptor.name,
                            description: descriptor.description ?? "",
                            inputSchema: descriptor.inputSchema,
                            outputSchema: descriptor.outputSchema ?? [:],
                            options: ToolSchema.Options(namespace: ns, codemode: descriptor.codemode != false)
                        ) { input, context in
                            let inv = CorePermission.invocation(context)
                            do {
                                try await perm.assert(CorePermission.AssertInput(
                                    sessionID: inv.sessionID,
                                    agent: inv.agent,
                                    action: actionName,
                                    resources: ["*"],
                                    save: ["*"],
                                    metadata: ["input": input],
                                    source: inv.source
                                ))
                            } catch let err as CorePermission.BlockedError {
                                throw AISchema.ToolFailure(message: err.message)
                            } catch let err as CorePermission.CorrectedError {
                                throw AISchema.ToolFailure(message: err.feedback)
                            } catch {
                                throw AISchema.ToolFailure(message: "Unable to execute \(actionName): \(error)")
                            }

                            let callResult: ToolCallResult
                            do {
                                callResult = try await client.callTool(
                                    server: descriptor.server,
                                    name: descriptor.name,
                                    args: input,
                                    sessionID: context.sessionID
                                )
                            } catch {
                                throw AISchema.ToolFailure(message: "Unable to execute \(actionName): \(error)")
                            }

                            if callResult.isError {
                                let errText = callResult.content.compactMap { part -> String? in
                                    if case .text(let s) = part { return s }
                                    return nil
                                }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                                throw AISchema.ToolFailure(message: errText.isEmpty ? "MCP tool returned an error" : errText)
                            }

                            var contentParts: [ToolSchema.Content] = []
                            for part in callResult.content {
                                switch part {
                                case .text(let t):
                                    contentParts.append(.text(ToolSchema.TextContent(text: t)))
                                case .blob(let b64, let mimeType, let uri):
                                    let mime = mimeType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                                    if CoreToolOutput.ReadFilesystem.MEDIA_MIMES.contains(mime) {
                                        contentParts.append(.file(ToolSchema.FileContent(
                                            uri: "data:\(mimeType);base64,\(b64)",
                                            mime: mimeType
                                        )))
                                    } else {
                                        let bytes = (try? base64ToBytes(b64)) ?? []
                                        let label = uri ?? "content"
                                        if CoreFilesystem.Mime.isTextual(mime) {
                                            let decoded = String(decoding: bytes, as: UTF8.self)
                                            contentParts.append(.text(ToolSchema.TextContent(
                                                text: "[Resource \(label) (\(mimeType))]\n\(decoded)"
                                            )))
                                        } else {
                                            let savedPath = (try? await outputSvc.save(bytes, extension: "")) ?? label
                                            contentParts.append(.text(ToolSchema.TextContent(
                                                text: "[Binary resource \(label) (\(mimeType), \(bytes.count) bytes) saved to \(savedPath)]"
                                            )))
                                        }
                                    }
                                }
                            }

                            let joinedText = contentParts.compactMap { part -> String? in
                                if case .text(let tc) = part { return tc.text }
                                return nil
                            }.joined(separator: "\n")

                            let outVal: JSONValue
                            if let structured = callResult.structured {
                                outVal = structured
                            } else if joinedText.isEmpty {
                                outVal = .null
                            } else if descriptor.outputSchema == nil && (joinedText.hasPrefix("{") || joinedText.hasPrefix("[")),
                                      let parsed = try? CoreConfigJSONC.parse(joinedText)
                            {
                                outVal = parsed
                            } else {
                                outVal = .string(joinedText)
                            }

                            return ToolSchema.Result(
                                output: outVal,
                                content: contentParts.isEmpty ? nil : .parts(contentParts)
                            )
                        })
                    }
                }
            }
        }

        // parity: core/src/tool/mcp.ts#layer [status=adapted hash=3c823506e2c6]
        public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { deps, _ in
            let tools = deps.get(CoreTool.Service.serviceKey, as: (any CoreTool.Interface).self) ?? CoreTool.Service()
            let perm = deps.get(CorePermission.Service.serviceKey, as: (any CorePermission.Interface).self) ?? CorePermission.Service()
            let out = deps.get(CoreToolOutput.Service.serviceKey, as: (any CoreToolOutput.Interface).self) ?? CoreToolOutput.Service()
            let svc = Service(toolsRegistry: tools, permission: perm, toolOutput: out)
            return LayerNode.Output([Service.serviceKey: svc as any Interface])
        }

        // parity: core/src/tool/mcp.ts#node [status=adapted hash=596c4d76753c]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            layer,
            [CoreTool.node, CorePermission.node, CoreToolOutput.node]
        )
    }
}

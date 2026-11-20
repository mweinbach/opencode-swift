import Foundation
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil
import Synchronization

/// OpenCode Core integration for Code Mode: catalog summarization, instruction rendering/updates,
/// permission-checked `fetch` (strictly via `OpenCodePlatform.HTTPTransport`), sandboxed `path` and `Bun`
/// file/glob APIs (strictly via `OpenCodePlatform.OpenCodeFileSystem`), background job notices,
/// and the `execute` tool registration.
/// Ports 100% of `packages/core/src/codemode/*` (29 symbols).
public enum CoreCodemode {
    // MARK: - Permission Hook Contract

    public struct PermissionRequest: Equatable, Sendable {
        public let action: String
        public let resources: [String]
        public let metadata: [String: JSONValue]
        public let sessionID: SessionID
        public let agent: AgentSchema.ID
        public let messageID: String
        public let callID: ToolSchema.CallID
        public let isRedirectCheck: Bool

        public init(
            action: String,
            resources: [String],
            metadata: [String: JSONValue] = [:],
            sessionID: SessionID,
            agent: AgentSchema.ID,
            messageID: String,
            callID: ToolSchema.CallID,
            isRedirectCheck: Bool = false
        ) {
            self.action = action
            self.resources = resources
            self.metadata = metadata
            self.sessionID = sessionID
            self.agent = agent
            self.messageID = messageID
            self.callID = callID
            self.isRedirectCheck = isRedirectCheck
        }
    }

    public struct PermissionRejectedError: Error, Equatable, Sendable, CustomStringConvertible {
        public let feedback: String?
        public let message: String

        public init(message: String, feedback: String? = nil) {
            self.message = message
            self.feedback = feedback
        }

        public var description: String { message }
    }

    public struct PermissionHook: Sendable {
        public let assertAllowed: @Sendable (PermissionRequest) async throws -> Void
        public let assertNotDenied: @Sendable (PermissionRequest) async throws -> Void

        public init(
            assertAllowed: @escaping @Sendable (PermissionRequest) async throws -> Void = { _ in },
            assertNotDenied: @escaping @Sendable (PermissionRequest) async throws -> Void = { _ in }
        ) {
            self.assertAllowed = assertAllowed
            self.assertNotDenied = assertNotDenied
        }

        public static let allowAll = PermissionHook()

        /// Routes Code Mode's checks (the `fetch` global, its redirect hops, `path`/`Bun` file access) through the
        /// session permission service, as upstream's Code Mode does with `Permission.Service`: `assertAllowed` may ask
        /// the user, while `assertNotDenied` only enforces deny rules.
        public static func service(_ permission: CorePermission.Service) -> PermissionHook {
            PermissionHook(
                assertAllowed: { request in try await permission.assert(assertInput(request, save: ["*"])) },
                assertNotDenied: { request in try await permission.assertNotDenied(assertInput(request, save: nil)) }
            )
        }

        static func assertInput(_ request: PermissionRequest, save: [String]?) -> CorePermission.AssertInput {
            CorePermission.AssertInput(
                sessionID: request.sessionID,
                agent: request.agent,
                action: request.action,
                resources: request.resources,
                save: save,
                metadata: request.metadata.isEmpty ? nil : request.metadata,
                source: .tool(messageID: request.messageID, id: request.callID.rawValue)
            )
        }
    }

    // MARK: - Execution Context (core/src/codemode/execution.ts)

    public enum Execution {
        // parity: core/src/codemode/execution.ts#Service [status=adapted hash=4fd3c41fd608]
        public final class Service: Sendable {
            public let context: ToolSchema.Context
            public let permission: PermissionHook
            public let transport: (any HTTPTransport)?
            private let cancelledBox = Mutex<Bool>(false)

            public init(
                context: ToolSchema.Context,
                permission: PermissionHook = .allowAll,
                transport: (any HTTPTransport)? = nil
            ) {
                self.context = context
                self.permission = permission
                self.transport = transport
            }

            public var isCancelled: Bool { cancelledBox.withLock { $0 } }
            public func cancel() { cancelledBox.withLock { $0 = true } }
        }
    }

    // MARK: - Catalog Summarization (core/src/codemode/catalog.ts)

    public enum Catalog {
        // parity: core/src/codemode/catalog.ts#Tool [status=implemented hash=1a77509c3c8f]
        public struct ToolEntry: Equatable, Hashable, Sendable, Codable {
            public let type: String
            public let name: String
            public let description: String
            public let signature: String
            public let pinned: Bool?

            public init(name: String, description: String, signature: String, pinned: Bool? = nil) {
                self.type = "tool"
                self.name = name
                self.description = description
                self.signature = signature
                self.pinned = pinned
            }
        }

        // parity: core/src/codemode/catalog.ts#Namespace [status=implemented hash=7beee575fbd9]
        public struct NamespaceEntry: Equatable, Hashable, Sendable, Codable {
            public let type: String
            public let name: String
            public let description: String?
            public let tools: [Entry]

            public init(name: String, description: String? = nil, tools: [Entry]) {
                self.type = "namespace"
                self.name = name
                self.description = description
                self.tools = tools
            }
        }

        public enum Entry: Equatable, Hashable, Sendable, Codable {
            case tool(ToolEntry)
            case namespace(NamespaceEntry)
        }

        // parity: core/src/codemode/catalog.ts#Inventory [status=implemented hash=87510fd180d2]
        public struct Inventory: Equatable, Hashable, Sendable, Codable {
            public let tools: [Entry]

            public init(tools: [Entry]) {
                self.tools = tools
            }
        }

        // parity: core/src/codemode/catalog.ts#Listing [status=implemented hash=c98e21a4e54c]
        public struct Listing: Equatable, Hashable, Sendable, Codable {
            public let path: String
            public let line: String

            public init(path: String, line: String) {
                self.path = path
                self.line = line
            }
        }

        // parity: core/src/codemode/catalog.ts#NamespaceSummary [status=implemented hash=dece5141b31f]
        public struct NamespaceSummary: Equatable, Hashable, Sendable, Codable {
            public let name: String
            public let description: String?
            public let tools: [String]
            public let entries: [Listing]

            public init(name: String, description: String? = nil, tools: [String], entries: [Listing]) {
                self.name = name
                self.description = description
                self.tools = tools
                self.entries = entries
            }
        }

        // parity: core/src/codemode/catalog.ts#Summary [status=implemented hash=bc0ca1687df8]
        public struct Summary: Equatable, Hashable, Sendable, Codable {
            public let total: Int
            public let namespaces: [NamespaceSummary]

            public init(total: Int, namespaces: [NamespaceSummary]) {
                self.total = total
                self.namespaces = namespaces
            }
        }

        // parity: core/src/codemode/catalog.ts#Options [status=implemented hash=d1334fba1b2f]
        public struct Options: Equatable, Hashable, Sendable, Codable {
            public let budget: Int?

            public init(budget: Int? = nil) {
                self.budget = budget
            }
        }

        private static let descriptionLimit = 500
        private static let charactersPerToken = 4.0
        private static let inlineBudget = 2_000

        /// Estimates token cost of a catalog line (`Math.round(text.length / 4)` over UTF-16 code units).
        // parity: core/src/codemode/catalog.ts#cost [status=implemented hash=08eb9a5f4685]
        public static func cost(_ text: String) -> Int {
            Int((Double(text.utf16.count) / charactersPerToken + 0.5).rounded(.down))
        }

        private static func listing(path: String, tool: ToolEntry) -> Listing {
            let firstLine = tool.description.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
            let desc = firstLine.count > descriptionLimit
                ? String(firstLine.prefix(descriptionLimit - 3)) + "..."
                : firstLine
            let suffix = desc.isEmpty ? "" : " // \(desc)"
            return Listing(path: path, line: "  - \(tool.signature)\(suffix)")
        }

        private static func flatten(_ entries: [Entry], path: [String] = []) -> (tools: [(path: String, tool: ToolEntry)], namespaces: [String: NamespaceEntry]) {
            var tools: [(path: String, tool: ToolEntry)] = []
            var namespaces: [String: NamespaceEntry] = [:]
            for entry in entries {
                switch entry {
                case .tool(let t):
                    tools.append((path: (path + [t.name]).joined(separator: "."), tool: t))
                case .namespace(let ns):
                    let next = path + [ns.name]
                    namespaces[next.joined(separator: ".")] = ns
                    let nested = flatten(ns.tools, path: next)
                    tools.append(contentsOf: nested.tools)
                    for (k, v) in nested.namespaces { namespaces[k] = v }
                }
            }
            return (tools, namespaces)
        }

        // parity: core/src/codemode/catalog.ts#namespaceLine [status=implemented hash=416066b3579b]
        public static func namespaceLine(_ namespace: NamespaceSummary, shown: Int? = nil) -> String {
            let shownCount = shown ?? namespace.entries.count
            let count = namespace.tools.count == 1 ? "1 tool" : "\(namespace.tools.count) tools"
            let label = shownCount == namespace.tools.count
                ? count
                : (shownCount == 0 ? "\(count), none shown" : "\(count), \(shownCount) shown")
            let descSuffix = namespace.description.map { " // \($0)" } ?? ""
            return "- \(namespace.name) (\(label))\(descSuffix)"
        }

        // parity: core/src/codemode/catalog.ts#summarize [status=implemented hash=021c7c39482b]
        public static func summarize(_ inventory: Inventory, options: Options = Options()) -> Summary {
            let budget = options.budget ?? inlineBudget
            let flattened = flatten(inventory.tools)
            var grouped: [String: [(path: String, tool: ToolEntry)]] = [:]
            for item in flattened.tools {
                let nsName = String(item.path.split(separator: ".", maxSplits: 1).first ?? Substring(item.path))
                grouped[nsName, default: []].append(item)
            }

            struct Bucket {
                let name: String
                let description: String?
                let tools: [String]
                let selectionOrder: [(path: String, tool: ToolEntry)]
                var selectedListings: [Listing]
                var selectionIndex: Int = 0
            }

            var buckets: [Bucket] = grouped.keys.sorted().map { name in
                let sorted = (grouped[name] ?? []).sorted { $0.path < $1.path }
                let pinned = sorted.filter { $0.tool.pinned == true }.map { listing(path: $0.path, tool: $0.tool) }
                let unpinned = sorted.filter { $0.tool.pinned != true }
                return Bucket(
                    name: name,
                    description: flattened.namespaces[name]?.description,
                    tools: sorted.map(\.path),
                    selectionOrder: unpinned,
                    selectedListings: pinned
                )
            }

            var remaining = budget
            for b in buckets {
                remaining -= cost(namespaceLine(NamespaceSummary(name: b.name, description: b.description, tools: b.tools, entries: [])))
                for l in b.selectedListings { remaining -= cost(l.line) }
            }

            var active = Array(0..<buckets.count)
            while !active.isEmpty {
                var nextActive: [Int] = []
                for idx in active {
                    if buckets[idx].selectionIndex >= buckets[idx].selectionOrder.count { continue }
                    let entry = buckets[idx].selectionOrder[buckets[idx].selectionIndex]
                    let candidate = listing(path: entry.path, tool: entry.tool)
                    let c = cost(candidate.line)
                    if c > remaining { continue }
                    buckets[idx].selectedListings.append(candidate)
                    buckets[idx].selectionIndex += 1
                    remaining -= c
                    if buckets[idx].selectionIndex < buckets[idx].selectionOrder.count {
                        nextActive.append(idx)
                    }
                }
                active = nextActive
            }

            return Summary(
                total: flattened.tools.count,
                namespaces: buckets.map {
                    NamespaceSummary(name: $0.name, description: $0.description, tools: $0.tools, entries: $0.selectedListings)
                }
            )
        }

        // parity: core/src/codemode/catalog.ts#lookup [status=implemented hash=1836e347eadd]
        public static func lookup(_ inventory: Inventory) -> @Sendable (String) -> Listing? {
            let flat = flatten(inventory.tools).tools
            var map: [String: (path: String, tool: ToolEntry)] = [:]
            for item in flat { map[item.path] = item }
            let immutableMap = map
            return { path in
                guard let entry = immutableMap[path] else { return nil }
                return listing(path: entry.path, tool: entry.tool)
            }
        }
    }

    // MARK: - Instructions Renderer & Delta Updates (core/src/codemode/instructions.ts)

    public enum Instructions {
        private static let updateBudget = 1_000

        private static func prompt(hasMoreTools: Bool) -> String {
            let searchPart = hasMoreTools ? ", and `search`," : ""
            let body = hasMoreTools
                ? """
                The catalog is partial. Before calling a tool that is not listed below, find it with the global `search(...)` function. Do not guess tool names. Each result's `path` is the complete call expression: write it out as code, for example `await tools.ns.tool_name({ ... })`. Do not use it as a key such as `tools[path]`.

                - \(CodemodeEngine.ToolRuntime.searchSignature)
                """
                : "The catalog is complete. Do not guess tool names."
            return """
            # Code Mode

            The tools listed below\(searchPart) cannot be called directly: they only work as JavaScript inside the `execute` tool. Every other tool you have is a normal tool call: call it directly, never inside `execute`.

            \(body)

            ## Code Mode tools (call only inside `execute`)
            """
        }

        private static var searchNote: String {
            """
            You can also look up tools that aren't listed with the global `search(...)` function inside `execute`. Before calling a tool that is not listed, find it this way. Do not guess tool names. Each result's `path` is the complete call expression: write it out as code, for example `await tools.ns.tool_name({ ... })`. Do not use it as a key such as `tools[path]`.

            - \(CodemodeEngine.ToolRuntime.searchSignature)
            """
        }

        private static func isComplete(_ catalog: Catalog.Summary) -> Bool {
            catalog.namespaces.allSatisfy { $0.entries.count == $0.tools.count }
        }

        private static func fit(_ listings: [Catalog.Listing], budget: Double) -> [Catalog.Listing] {
            var total = 0.0
            var kept: [Catalog.Listing] = []
            for entry in listings {
                total += Double(Catalog.cost(entry.line))
                if total > budget { break }
                kept.append(entry)
            }
            return kept
        }

        // parity: core/src/codemode/instructions.ts#render [status=implemented hash=72f7fe206c25]
        public static func render(_ catalog: Catalog.Summary) -> String {
            if catalog.total == 0 {
                return "No Code Mode tools are currently available. Later Code Mode catalog updates may add or remove tools. Do not call `execute` unless there is at least one available Code Mode tool."
            }
            var lines: [String] = []
            for ns in catalog.namespaces {
                lines.append(Catalog.namespaceLine(ns))
                for entry in ns.entries { lines.append(entry.line) }
            }
            return "\(prompt(hasMoreTools: !isComplete(catalog)))\n\n\(lines.joined(separator: "\n"))"
        }

        // parity: core/src/codemode/instructions.ts#update [status=implemented hash=c6ffc98f61de]
        public static func update(
            previous: Catalog.Summary,
            current: Catalog.Summary,
            lookup: (String) -> Catalog.Listing?
        ) -> String? {
            let replacement = "The Code Mode tool catalog has changed. This catalog supersedes the previous Code Mode tool catalog.\n\n\(render(current))"
            if current.total == 0 || previous.total == 0 { return replacement }

            let prevByName = Dictionary(uniqueKeysWithValues: previous.namespaces.map { ($0.name, $0) })
            let currByName = Dictionary(uniqueKeysWithValues: current.namespaces.map { ($0.name, $0) })

            let addedNs = current.namespaces.filter { prevByName[$0.name] == nil }
            let changedNs = current.namespaces.filter { ns in
                guard let prev = prevByName[ns.name] else { return false }
                return prev.description != ns.description
            }
            let removedNs = previous.namespaces.filter { currByName[$0.name] == nil }

            let restated = addedNs + changedNs
            let restatedNames = Set(restated.map(\.name))
            let unchanged = Set(current.namespaces.map(\.name).filter { !restatedNames.contains($0) })
            func kept(_ path: String) -> Bool {
                let nsName = String(path.split(separator: ".", maxSplits: 1).first ?? Substring(path))
                return unchanged.contains(nsName)
            }

            let beforeTools = Set(previous.namespaces.flatMap(\.tools))
            let afterTools = Set(current.namespaces.flatMap(\.tools))
            let added = current.namespaces.flatMap(\.tools).filter { kept($0) && !beforeTools.contains($0) }
            let removed = previous.namespaces.flatMap(\.tools).filter { kept($0) && !afterTools.contains($0) }
            let changed: [Catalog.Listing] = previous.namespaces.flatMap(\.entries).compactMap { entry in
                guard kept(entry.path), afterTools.contains(entry.path),
                      let latest = lookup(entry.path), latest.line != entry.line
                else { return nil }
                return latest
            }

            let denom = max(1, restated.count + (added.isEmpty ? 0 : 1))
            let budget = isComplete(current) ? Double.infinity : Double(updateBudget) / Double(denom)

            var parts = ["The Code Mode tool catalog has changed."]
            if !restated.isEmpty {
                var section = ["New tools are available:"]
                for ns in restated {
                    let shown = fit(ns.tools.compactMap(lookup), budget: budget)
                    let block = ([Catalog.namespaceLine(ns, shown: shown.count)] + shown.map(\.line)).joined(separator: "\n")
                    section.append(block)
                }
                parts.append(section.joined(separator: "\n"))
            }
            if !added.isEmpty {
                let shown = fit(added.compactMap(lookup), budget: budget)
                let rest = added.count - shown.count
                var section = ["New tools are available in addition to those previously listed:"]
                section.append(contentsOf: shown.map(\.line))
                if rest > 0 { section.append("  - \(rest) more; search for them") }
                parts.append(section.joined(separator: "\n"))
            }
            if isComplete(previous) && !isComplete(current) { parts.append(searchNote) }
            if !changed.isEmpty {
                parts.append((["Changed tool listings supersede the previously listed ones:"] + changed.map(\.line)).joined(separator: "\n"))
            }
            if !removed.isEmpty {
                let exprs = removed.map { CodemodeEngine.ToolRuntime.toolExpression($0) }.joined(separator: ", ")
                parts.append("The following tools are no longer available and must not be called: \(exprs).")
            }
            if !removedNs.isEmpty {
                let names = removedNs.map { "`\($0.name)`" }.joined(separator: ", ")
                parts.append("The following tool namespaces are no longer available and must not be used: \(names).")
            }
            if parts.count == 1 { return nil }
            let delta = parts.joined(separator: "\n\n")
            return delta.count < replacement.count ? delta : replacement
        }

        /// The `core/codemode` instruction source: the Code Mode catalog when `execute` is offered, removed otherwise.
        // parity: core/src/codemode/instructions.ts#make [status=implemented hash=bccc95c0eaac]
        public static func make(_ inventory: Catalog.Inventory? = nil) -> CoreInstruction.Instructions.List {
            let catalog: CoreInstruction.Instructions.Observation<Catalog.Summary> =
                inventory.map { .value(Catalog.summarize($0)) } ?? .removed
            // Rendered once, against the inventory that produced `current`, and stored with the update.
            let lookupFn: @Sendable (String) -> Catalog.Listing?
            if let inventory {
                lookupFn = Catalog.lookup(inventory)
            } else {
                lookupFn = { _ in nil }
            }
            return CoreInstruction.Instructions.make(CoreInstruction.Instructions.Source.Definition<Catalog.Summary>(
                key: CoreInstruction.Instructions.Key(rawValue: "core/codemode")!,
                read: { catalog },
                renderInitial: { render($0) },
                renderChanged: { previous, current in update(previous: previous, current: current, lookup: lookupFn) },
                renderRemoved: { _ in
                    "The `execute` tool is no longer available. Permitted tools are now available as direct tool calls."
                }
            ))
        }
    }

    // MARK: - Sandboxed Fetch Extension via HTTPTransport (core/src/codemode/fetch.ts)

    public enum Fetch {
        // parity: core/src/codemode/fetch.ts#MAX_REDIRECTS [status=implemented hash=633cbc259257]
        public static let MAX_REDIRECTS: Int = 20

        private static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]

        // parity: core/src/codemode/fetch.ts#display [status=implemented hash=fd7e1776f3c7]
        public static func display(_ args: [CodemodeLanguage.Value]) -> [String: JSONValue] {
            let inputStr = args.first.map { CodemodeLanguage.coerceToString($0).toHostString() } ?? ""
            var method = "GET"
            if args.count > 1, case .object(let initObj) = args[1] {
                if case .string(let m) = CodemodeLanguage.get(initObj, "method") {
                    method = m.toHostString().uppercased()
                }
            }
            return ["method": .string(method), "url": .string(inputStr)]
        }

        /// Builds the `fetch` sandbox extension strictly routing HTTP requests through `transport`
        /// and enforcing URL safety, permission hooks, and manual redirect hops up to `MAX_REDIRECTS`.
        public static func makeExtension(
            transport: any HTTPTransport,
            execution: Execution.Service
        ) -> CodemodeEngine.Extension.Definition {
            let fetchFn = CodemodeEngine.Extension.async { args, builtins in
                guard let first = args.first, !first.isUndefined else {
                    throw CodemodeLanguage.typeError("fetch requires a URL argument.")
                }
                let rawUrl = CodemodeLanguage.coerceToString(first).toHostString()
                let cleanUrl = String(rawUrl.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(rawUrl))
                guard let parsed = URL(string: cleanUrl), let scheme = parsed.scheme?.lowercased() else {
                    throw CodemodeLanguage.typeError("Invalid URL: \(cleanUrl)")
                }
                if scheme == "file" {
                    throw CodemodeLanguage.HostFailure(kind: "ExecutionFailure", message: "fetch cannot be used for filesystem access.")
                }
                if (parsed.user != nil && !(parsed.user?.isEmpty ?? true)) || (parsed.password != nil && !(parsed.password?.isEmpty ?? true)) {
                    throw CodemodeLanguage.typeError("fetch cannot be used with credentials in the URL.")
                }

                // Extract init options
                var method = "GET"
                var headers: [String: String] = [:]
                var bodyBytes: [UInt8]? = nil
                if args.count > 1, case .object(let initObj) = args[1] {
                    if case .string(let m) = CodemodeLanguage.get(initObj, "method") { method = m.toHostString().uppercased() }
                    let hVal = CodemodeLanguage.get(initObj, "headers")
                    if case .object(let hObj as CodemodeLanguage.HeadersObj) = hVal {
                        headers = hObj.asDictionary()
                    } else if case .object(let hArr as CodemodeLanguage.Arr) = hVal {
                        for pair in hArr.items {
                            if case .object(let pArr as CodemodeLanguage.Arr) = pair, pArr.count >= 2 {
                                headers[CodemodeLanguage.coerceToString(pArr.item(at: 0)).toHostString().lowercased()] = CodemodeLanguage.coerceToString(pArr.item(at: 1)).toHostString()
                            }
                        }
                    } else if case .object(let hObj) = hVal {
                        for (k, v) in CodemodeLanguage.entries(hObj) {
                            headers[k.toHostString().lowercased()] = CodemodeLanguage.coerceToString(v).toHostString()
                        }
                    }
                    let bVal = CodemodeLanguage.get(initObj, "body")
                    switch bVal {
                    case .string(let s): bodyBytes = s.utf8BytesReplacingSurrogates()
                    case .object(let b as CodemodeLanguage.Bytes): bodyBytes = b.data
                    case .object(let sp as CodemodeLanguage.URLSearchParamsObj):
                        bodyBytes = sp.jsToString().utf8BytesReplacingSurrogates()
                        if headers["content-type"] == nil { headers["content-type"] = "application/x-www-form-urlencoded;charset=UTF-8" }
                    default: break
                    }
                }

                // Initial webfetch permission check
                do {
                    try await execution.permission.assertAllowed(PermissionRequest(
                        action: "webfetch",
                        resources: [cleanUrl],
                        metadata: display(args),
                        sessionID: execution.context.sessionID,
                        agent: execution.context.agent,
                        messageID: execution.context.messageID,
                        callID: execution.context.id
                    ))
                } catch let rejected as PermissionRejectedError {
                    if let feedback = rejected.feedback {
                        throw CodemodeLanguage.HostFailure(kind: "ExecutionFailure", message: "The user rejected fetching \(cleanUrl): \(feedback)")
                    }
                    throw CodemodeLanguage.HostFailure(kind: "ExecutionFailure", message: rejected.message)
                }

                var target = cleanUrl
                var redirects = 0
                while true {
                    if execution.isCancelled {
                        throw CodemodeLanguage.Interruption("cancelled")
                    }
                    let req = HTTPRequest(method: method, url: target, headers: headers, body: bodyBytes)
                    let resp = try await transport.send(req)
                    let locationHeader = resp.head.headers.first { $0.key.lowercased() == "location" }?.value
                    if !redirectStatuses.contains(resp.head.statusCode) || locationHeader == nil {
                        return makeJSResponse(
                            builtins: builtins,
                            streaming: CodemodeLanguage.StreamingResponse(
                                url: target,
                                status: resp.head.statusCode,
                                statusText: httpStatusText(resp.head.statusCode),
                                headers: resp.head.headers,
                                bodyBytes: resp.body,
                                redirected: redirects > 0
                            )
                        )
                    }
                    if redirects >= MAX_REDIRECTS {
                        throw CodemodeLanguage.HostFailure(kind: "ExecutionFailure", message: "Too many redirects (more than \(MAX_REDIRECTS))")
                    }
                    guard let base = URL(string: target),
                          let nextURL = URL(string: locationHeader!, relativeTo: base)?.absoluteURL
                    else {
                        throw CodemodeLanguage.HostFailure(kind: "ExecutionFailure", message: "Invalid redirect location: \(locationHeader!)")
                    }
                    let nextScheme = (nextURL.scheme ?? "").lowercased()
                    if nextScheme != "http" && nextScheme != "https" {
                        throw CodemodeLanguage.HostFailure(kind: "ExecutionFailure", message: "fetch cannot follow a redirect to \(nextScheme): URLs.")
                    }
                    if (nextURL.user != nil && !(nextURL.user?.isEmpty ?? true)) || (nextURL.password != nil && !(nextURL.password?.isEmpty ?? true)) {
                        throw CodemodeLanguage.HostFailure(kind: "ExecutionFailure", message: "fetch cannot follow a redirect with credentials in the URL.")
                    }
                    let nextHref = String(nextURL.absoluteString.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(nextURL.absoluteString))
                    var hopMeta = display([.string(CodemodeLanguage.JSString(nextHref))])
                    hopMeta["redirectedFrom"] = .string(cleanUrl)
                    try await execution.permission.assertNotDenied(PermissionRequest(
                        action: "webfetch",
                        resources: [nextHref],
                        metadata: hopMeta,
                        sessionID: execution.context.sessionID,
                        agent: execution.context.agent,
                        messageID: execution.context.messageID,
                        callID: execution.context.id,
                        isRedirectCheck: true
                    ))

                    // Browser redirect method/header rewrite rules
                    let toGet = (resp.head.statusCode == 303 && method != "HEAD")
                        || ((resp.head.statusCode == 301 || resp.head.statusCode == 302) && method == "POST")
                    if toGet {
                        method = "GET"
                        bodyBytes = nil
                        for h in ["content-type", "content-length", "content-encoding", "content-language", "content-location"] {
                            headers.removeValue(forKey: h)
                        }
                    }
                    if originOf(base) != originOf(nextURL) {
                        for h in ["authorization", "cookie", "proxy-authorization"] {
                            headers.removeValue(forKey: h)
                        }
                    }
                    target = nextHref
                    redirects += 1
                }
            }
            return CodemodeEngine.Extension.make(name: "fetch", globals: ["fetch": .function(fetchFn)])
        }

        // parity: core/src/codemode/fetch.ts#extension [status=adapted hash=0a07d604d32a]
        public static let `extension`: CodemodeEngine.Extension.Definition = CodemodeEngine.Extension.make(
            name: "fetch",
            globals: [
                "fetch": .function(CodemodeEngine.Extension.async { _, _ in
                    throw CodemodeLanguage.HostFailure(
                        kind: "ExecutionFailure",
                        message: "fetch requires an injected HTTPTransport via CoreCodemode.Fetch.makeExtension(transport:execution:)."
                    )
                }),
            ]
        )

        private static func originOf(_ url: URL) -> String {
            let scheme = (url.scheme ?? "").lowercased()
            let host = (url.host ?? "").lowercased()
            let port = url.port.map { ":\($0)" } ?? ""
            return "\(scheme)://\(host)\(port)"
        }

        private static func httpStatusText(_ code: Int) -> String {
            switch code {
            case 200: return "OK"
            case 201: return "Created"
            case 204: return "No Content"
            case 301: return "Moved Permanently"
            case 302: return "Found"
            case 303: return "See Other"
            case 304: return "Not Modified"
            case 307: return "Temporary Redirect"
            case 308: return "Permanent Redirect"
            case 400: return "Bad Request"
            case 401: return "Unauthorized"
            case 403: return "Forbidden"
            case 404: return "Not Found"
            case 500: return "Internal Server Error"
            default: return ""
            }
        }

        private static func makeJSResponse(
            builtins: CodemodeLanguage.Builtins,
            streaming: CodemodeLanguage.StreamingResponse
        ) -> CodemodeLanguage.Value {
            let used = Mutex<Bool>(false)
            let respObj = CodemodeLanguage.Obj(proto: builtins.Object)
            let headersObj = CodemodeLanguage.HeadersObj(proto: builtins.Headers, initial: streaming.headers)
            CodemodeLanguage.define(respObj, "url", .string(CodemodeLanguage.JSString(streaming.url)))
            CodemodeLanguage.define(respObj, "status", .number(Double(streaming.status)))
            CodemodeLanguage.define(respObj, "statusText", .string(CodemodeLanguage.JSString(streaming.statusText)))
            CodemodeLanguage.define(respObj, "ok", .bool(streaming.ok))
            CodemodeLanguage.define(respObj, "redirected", .bool(streaming.redirected))
            CodemodeLanguage.define(respObj, "headers", .object(headersObj))
            CodemodeLanguage.defineAccessorHalf(
                respObj,
                .string("bodyUsed"),
                half: .get,
                fn: CodemodeLanguage.hostGetter(builtins, "bodyUsed") { used.withLock { $0 } },
                enumerable: false
            )

            @Sendable func consumeBody() throws -> [UInt8] {
                let already = used.withLock { u -> Bool in
                    if u { return true }
                    u = true
                    return false
                }
                if already {
                    throw CodemodeLanguage.typeError("Body has already been used.")
                }
                return streaming.bodyBytes
            }

            CodemodeLanguage.methods(builtins, respObj, [
                CodemodeLanguage.Method("text", 0) { _, _, _, _ in
                    let bytes = try consumeBody()
                    return .object(CodemodeLanguage.PromiseObj(
                        proto: builtins.Promise,
                        status: .fulfilled(.string(CodemodeLanguage.JSString(String(decoding: bytes, as: UTF8.self))))
                    ))
                },
                CodemodeLanguage.Method("json", 0) { _, _, _, _ in
                    let bytes = try consumeBody()
                    let text = String(decoding: bytes, as: UTF8.self)
                    guard let parsed = PureJSON.parse(text) else {
                        return .object(CodemodeLanguage.PromiseObj(
                            proto: builtins.Promise,
                            status: .rejected(CodemodeLanguage.materialize(builtins, CodemodeLanguage.syntaxError("Unexpected token in JSON")))
                        ))
                    }
                    return .object(CodemodeLanguage.PromiseObj(
                        proto: builtins.Promise,
                        status: .fulfilled(CodemodeLanguage.pureJsonToValue(builtins, parsed))
                    ))
                },
                CodemodeLanguage.Method("bytes", 0) { _, _, _, _ in
                    let bytes = try consumeBody()
                    return .object(CodemodeLanguage.PromiseObj(
                        proto: builtins.Promise,
                        status: .fulfilled(.object(CodemodeLanguage.finishBytes(builtins, bytes)))
                    ))
                },
                CodemodeLanguage.Method("arrayBuffer", 0) { _, _, _, _ in
                    let bytes = try consumeBody()
                    return .object(CodemodeLanguage.PromiseObj(
                        proto: builtins.Promise,
                        status: .fulfilled(.object(CodemodeLanguage.finishBytes(builtins, bytes)))
                    ))
                },
            ])
            return .object(respObj)
        }
    }

    // MARK: - Path Extension (core/src/codemode/path.ts)

    public enum Path {
        private static func normalizePosix(_ raw: String) -> String {
            if raw.isEmpty { return "." }
            let isAbs = raw.hasPrefix("/")
            var stack: [String] = []
            for part in raw.split(separator: "/") {
                if part == "." || part.isEmpty { continue }
                if part == ".." {
                    if !stack.isEmpty && stack.last != ".." { stack.removeLast() }
                    else if !isAbs { stack.append("..") }
                } else {
                    stack.append(String(part))
                }
            }
            let joined = stack.joined(separator: "/")
            if isAbs { return "/" + joined }
            return joined.isEmpty ? "." : joined
        }

        private static func resolvePath(base: String, parts: [String]) -> String {
            var current = base
            for part in parts where !part.isEmpty {
                if part.hasPrefix("/") { current = part }
                else { current = current.hasSuffix("/") ? "\(current)\(part)" : "\(current)/\(part)" }
            }
            return normalizePosix(current)
        }

        private static func flavorItems(baseDirectory: String, sep: String, delimiter: String) -> [String: CodemodeEngine.Extension.GlobalItem] {
            let joinFn = CodemodeEngine.Extension.MarkedFunction { args, _ in
                let raw = args.map { CodemodeLanguage.coerceToString($0).toHostString() }.filter { !$0.isEmpty }.joined(separator: "/")
                return .string(CodemodeLanguage.JSString(normalizePosix(raw)))
            }
            let resolveFn = CodemodeEngine.Extension.MarkedFunction { args, _ in
                let parts = args.map { CodemodeLanguage.coerceToString($0).toHostString() }
                return .string(CodemodeLanguage.JSString(resolvePath(base: baseDirectory, parts: parts)))
            }
            let relativeFn = CodemodeEngine.Extension.MarkedFunction { args, _ in
                let from = resolvePath(base: baseDirectory, parts: [args.first.map { CodemodeLanguage.coerceToString($0).toHostString() } ?? ""])
                let to = resolvePath(base: baseDirectory, parts: [args.count > 1 ? CodemodeLanguage.coerceToString(args[1]).toHostString() : ""])
                let fromParts = from.split(separator: "/").map(String.init)
                let toParts = to.split(separator: "/").map(String.init)
                var common = 0
                while common < fromParts.count && common < toParts.count && fromParts[common] == toParts[common] { common += 1 }
                let ups = Array(repeating: "..", count: fromParts.count - common)
                let downs = Array(toParts[common...])
                return .string(CodemodeLanguage.JSString((ups + downs).joined(separator: sep)))
            }
            let dirnameFn = CodemodeEngine.Extension.MarkedFunction { args, _ in
                let p = normalizePosix(args.first.map { CodemodeLanguage.coerceToString($0).toHostString() } ?? "")
                if p == "/" { return .string("/") }
                guard let slash = p.lastIndex(of: "/") else { return .string(".") }
                let head = String(p[..<slash])
                return .string(CodemodeLanguage.JSString(head.isEmpty ? "/" : head))
            }
            let basenameFn = CodemodeEngine.Extension.MarkedFunction { args, _ in
                let p = normalizePosix(args.first.map { CodemodeLanguage.coerceToString($0).toHostString() } ?? "")
                var base = p.split(separator: "/").last.map(String.init) ?? ""
                if args.count > 1, case .string(let ext) = args[1] {
                    let extStr = ext.toHostString()
                    if !extStr.isEmpty && base.hasSuffix(extStr) {
                        base = String(base.dropLast(extStr.count))
                    }
                }
                return .string(CodemodeLanguage.JSString(base))
            }
            let extnameFn = CodemodeEngine.Extension.MarkedFunction { args, _ in
                let base = normalizePosix(args.first.map { CodemodeLanguage.coerceToString($0).toHostString() } ?? "").split(separator: "/").last.map(String.init) ?? ""
                guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return .string("") }
                return .string(CodemodeLanguage.JSString(String(base[dot...])))
            }
            let isAbsFn = CodemodeEngine.Extension.MarkedFunction { args, _ in
                let p = args.first.map { CodemodeLanguage.coerceToString($0).toHostString() } ?? ""
                return .bool(p.hasPrefix("/") || (sep == "\\" && p.count >= 2 && p[p.index(after: p.startIndex)] == ":"))
            }
            let normFn = CodemodeEngine.Extension.MarkedFunction { args, _ in
                .string(CodemodeLanguage.JSString(normalizePosix(args.first.map { CodemodeLanguage.coerceToString($0).toHostString() } ?? "")))
            }
            return [
                "sep": .constant(.string(CodemodeLanguage.JSString(sep))),
                "delimiter": .constant(.string(CodemodeLanguage.JSString(delimiter))),
                "join": .function(joinFn),
                "resolve": .function(resolveFn),
                "relative": .function(relativeFn),
                "dirname": .function(dirnameFn),
                "basename": .function(basenameFn),
                "extname": .function(extnameFn),
                "isAbsolute": .function(isAbsFn),
                "normalize": .function(normFn),
            ]
        }

        public static func makeExtension(directory: String) -> CodemodeEngine.Extension.Definition {
            var host = flavorItems(baseDirectory: directory, sep: "/", delimiter: ":")
            host["posix"] = .object(flavorItems(baseDirectory: directory, sep: "/", delimiter: ":"))
            host["win32"] = .object(flavorItems(baseDirectory: "\\", sep: "\\", delimiter: ";"))
            return CodemodeEngine.Extension.make(
                name: "path",
                globals: ["path": .object(host)],
                modules: ["path": "path"]
            )
        }

        // parity: core/src/codemode/path.ts#extension [status=adapted hash=4920b46a70ab]
        public static let `extension`: CodemodeEngine.Extension.Definition = makeExtension(directory: "/")
    }

    // MARK: - Bun File & Glob Extension (core/src/codemode/bun.ts)

    public enum Bun {
        /// The session's file services that the `Bun` global reads and writes through. Each file is reached through its
        /// target's own environment (here the injected file system), so there is no separate environment service.
        // parity: core/src/codemode/bun.ts#Services [status=adapted hash=99c960df0b05]
        public struct Services: Sendable {
            public let directory: String
            public let fileSystem: any OpenCodeFileSystem
            public let permission: PermissionHook

            public init(
                directory: String,
                fileSystem: any OpenCodeFileSystem,
                permission: PermissionHook = .allowAll
            ) {
                self.directory = directory
                self.fileSystem = fileSystem
                self.permission = permission
            }
        }

        private static func resolveInDir(_ input: String, directory: String) -> String {
            if input.hasPrefix("/") { return input }
            let cleanBase = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
            return "\(cleanBase)/\(input)"
        }

        private static func mimeFor(_ name: String) -> String {
            let ext = name.split(separator: ".").last.map { String($0).lowercased() } ?? ""
            switch ext {
            case "txt", "log", "ini": return "text/plain;charset=utf-8"
            case "js", "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx": return "text/javascript;charset=utf-8"
            case "json", "map": return "application/json;charset=utf-8"
            case "html", "htm": return "text/html;charset=utf-8"
            case "css": return "text/css;charset=utf-8"
            case "md": return "text/markdown"
            case "csv": return "text/csv"
            case "yaml", "yml": return "text/yaml"
            case "png": return "image/png"
            case "jpg", "jpeg": return "image/jpeg"
            case "pdf": return "application/pdf"
            default: return "application/octet-stream"
            }
        }

        public static func makeExtension(services: Services, execution: Execution.Service) -> CodemodeEngine.Extension.Definition {
            let fileFn = CodemodeEngine.Extension.MarkedFunction { args, builtins in
                let name = args.first.map { CodemodeLanguage.coerceToString($0).toHostString() } ?? ""
                let absPath = resolveInDir(name, directory: services.directory)
                try await services.permission.assertAllowed(PermissionRequest(
                    action: "read",
                    resources: [absPath],
                    sessionID: execution.context.sessionID,
                    agent: execution.context.agent,
                    messageID: execution.context.messageID,
                    callID: execution.context.id
                ))
                let stat = try? await services.fileSystem.stat(at: absPath)
                let handle = CodemodeLanguage.Obj(proto: builtins.Object)
                CodemodeLanguage.define(handle, "name", .string(CodemodeLanguage.JSString(name)))
                CodemodeLanguage.define(handle, "type", .string(CodemodeLanguage.JSString(mimeFor(name))))
                CodemodeLanguage.define(handle, "size", .number(Double(stat?.size ?? 0)))
                CodemodeLanguage.define(handle, "lastModified", .number(Double(stat?.modifiedAtMs ?? 0)))
                CodemodeLanguage.methods(builtins, handle, [
                    CodemodeLanguage.Method("text", 0) { _, _, _, _ in
                        let data = try await services.fileSystem.readFile(at: absPath)
                        return .object(CodemodeLanguage.PromiseObj(proto: builtins.Promise, status: .fulfilled(.string(CodemodeLanguage.JSString(String(decoding: data, as: UTF8.self))))))
                    },
                    CodemodeLanguage.Method("bytes", 0) { _, _, _, _ in
                        let data = try await services.fileSystem.readFile(at: absPath)
                        return .object(CodemodeLanguage.PromiseObj(proto: builtins.Promise, status: .fulfilled(.object(CodemodeLanguage.finishBytes(builtins, data)))))
                    },
                    CodemodeLanguage.Method("json", 0) { _, _, _, _ in
                        let data = try await services.fileSystem.readFile(at: absPath)
                        let str = String(decoding: data, as: UTF8.self)
                        guard let parsed = PureJSON.parse(str) else {
                            throw CodemodeLanguage.syntaxError("Invalid JSON in \(name)")
                        }
                        return .object(CodemodeLanguage.PromiseObj(proto: builtins.Promise, status: .fulfilled(CodemodeLanguage.pureJsonToValue(builtins, parsed))))
                    },
                    CodemodeLanguage.Method("exists", 0) { _, _, _, _ in
                        let ex = await services.fileSystem.exists(at: absPath)
                        return .object(CodemodeLanguage.PromiseObj(proto: builtins.Promise, status: .fulfilled(.bool(ex))))
                    },
                    CodemodeLanguage.Method("delete", 0) { _, _, _, _ in
                        try await services.permission.assertAllowed(PermissionRequest(
                            action: "edit",
                            resources: [absPath],
                            sessionID: execution.context.sessionID,
                            agent: execution.context.agent,
                            messageID: execution.context.messageID,
                            callID: execution.context.id
                        ))
                        try await services.fileSystem.remove(at: absPath)
                        return .object(CodemodeLanguage.PromiseObj(proto: builtins.Promise, status: .fulfilled(.undefined)))
                    },
                ])
                return .object(handle)
            }

            let writeFn = CodemodeEngine.Extension.async { args, _ in
                let destName: String
                if case .object(let obj) = args.first, case .string(let n) = CodemodeLanguage.get(obj, "name") {
                    destName = n.toHostString()
                } else {
                    destName = args.first.map { CodemodeLanguage.coerceToString($0).toHostString() } ?? ""
                }
                let absPath = resolveInDir(destName, directory: services.directory)
                try await services.permission.assertAllowed(PermissionRequest(
                    action: "edit",
                    resources: [absPath],
                    sessionID: execution.context.sessionID,
                    agent: execution.context.agent,
                    messageID: execution.context.messageID,
                    callID: execution.context.id
                ))
                let dataArg = args.count > 1 ? args[1] : .undefined
                let bytes: [UInt8]
                switch dataArg {
                case .string(let s): bytes = s.utf8BytesReplacingSurrogates()
                case .number(let n): bytes = Array(CodemodeLanguage.formatJSNumber(n).utf8)
                case .bool(let b): bytes = Array((b ? "true" : "false").utf8)
                case .object(let b as CodemodeLanguage.Bytes): bytes = b.data
                default:
                    throw CodemodeLanguage.typeError("Bun.write expects a string, a Uint8Array, a BunFile, or a Response as the data to write.")
                }
                try await services.fileSystem.writeFile(bytes, to: absPath, createDirectories: true)
                return .number(Double(bytes.count))
            }

            let globCtor = CodemodeEngine.Extension.constructible { args, builtins in
                guard case .string(let patternJS) = args.first else {
                    throw CodemodeLanguage.typeError("Bun.Glob expects a pattern string.")
                }
                let pattern = patternJS.toHostString()
                let globObj = CodemodeLanguage.Obj(proto: builtins.Object)
                CodemodeLanguage.methods(builtins, globObj, [
                    CodemodeLanguage.Method("match", 1) { _, mArgs, _, _ in
                        let target = mArgs.first.map { CodemodeLanguage.coerceToString($0).toHostString() } ?? ""
                        return .bool(Glob.match(pattern, filepath: target, dot: true))
                    },
                    CodemodeLanguage.Method("scan", 1) { _, sArgs, _, _ in
                        var cwd = services.directory
                        var dot = false
                        if let opt = sArgs.first {
                            if case .string(let c) = opt { cwd = resolveInDir(c.toHostString(), directory: services.directory) }
                            else if case .object(let o) = opt {
                                if case .string(let c) = CodemodeLanguage.get(o, "cwd") { cwd = resolveInDir(c.toHostString(), directory: services.directory) }
                                dot = CodemodeLanguage.get(o, "dot").isTruthy
                            }
                        }
                        try await services.permission.assertAllowed(PermissionRequest(
                            action: "glob",
                            resources: [pattern],
                            sessionID: execution.context.sessionID,
                            agent: execution.context.agent,
                            messageID: execution.context.messageID,
                            callID: execution.context.id
                        ))
                        var matched: [CodemodeLanguage.Value] = []
                        let entries = (try? await services.fileSystem.readDirectory(at: cwd)) ?? []
                        for name in entries.sorted() {
                            if Glob.match(pattern, filepath: name, dot: dot) {
                                matched.append(.string(CodemodeLanguage.JSString(name)))
                            }
                        }
                        return .object(CodemodeLanguage.Arr(proto: builtins.Array, items: matched))
                    },
                ])
                return .object(globObj)
            }

            return CodemodeEngine.Extension.make(
                name: "bun",
                globals: ["Bun": .object(["file": .function(fileFn), "write": .function(writeFn), "Glob": .function(globCtor)])],
                modules: ["bun": "Bun"]
            )
        }

        /// Default Bun file & glob extension definition backed by the current host filesystem.
        // parity: core/src/codemode/bun.ts#extension [status=implemented hash=a9730b6420cb]
        public static let `extension`: CodemodeEngine.Extension.Definition = {
            let defaultContext = ToolSchema.Context(
                sessionID: SessionID.create(),
                agent: AgentSchema.ID(rawValue: "build"),
                messageID: "msg_default",
                id: ToolSchema.CallID(rawValue: "call_default"),
                progress: { _ in }
            )
            return makeExtension(
                services: Services(
                    directory: CorePlugin.Host.currentEnvironment.homeDirectory ?? "/",
                    fileSystem: CorePlugin.Host.currentFileSystem
                ),
                execution: Execution.Service(context: defaultContext)
            )
        }()

        private static func handleName(of value: CodemodeLanguage.Value?) -> String? {
            guard case .object(let obj) = value,
                  case .string(let name) = CodemodeLanguage.get(obj, "name")
            else {
                return nil
            }
            return name.toHostString()
        }

        /// Formats a Bun call for user display: method name, path/pattern, and optional `from` file handle for `Bun.write`.
        // parity: core/src/codemode/bun.ts#display [status=implemented hash=874e4d886fe8]
        public static func display(name: String, args: [CodemodeLanguage.Value]) -> [String: JSONValue] {
            let method: String
            if let dot = name.lastIndex(of: ".") {
                method = String(name[name.index(after: dot)...])
            } else {
                method = name
            }
            let firstArg = args.first
            let path = handleName(of: firstArg) ?? firstArg.map { CodemodeLanguage.coerceToString($0).toHostString() } ?? "undefined"
            var result: [String: JSONValue] = [
                "method": .string(method),
                "path": .string(path),
            ]
            if name == "Bun.write", args.count > 1, let from = handleName(of: args[1]) {
                result["from"] = .string(from)
            }
            return result
        }
    }

    // MARK: - Background Job Notice & Runner (core/src/codemode/job.ts)

    public enum Job {
        public struct Info: Equatable, Hashable, Sendable, Codable {
            public let id: String
            public let status: String
            public let output: String?
            public let error: String?

            public init(id: String, status: String, output: String? = nil, error: String? = nil) {
                self.id = id
                self.status = status
                self.output = output
                self.error = error
            }
        }

        public struct Notice: Equatable, Sendable {
            public let description: String
            public let text: String
            public let metadata: [String: JSONValue]

            public init(description: String, text: String, metadata: [String: JSONValue]) {
                self.description = description
                self.text = text
                self.metadata = metadata
            }
        }

        /// The session's background-completion wrapper (upstream `BackgroundResult.render`).
        static func backgroundResult(_ attributes: String, _ body: String) -> String {
            CoreSessionBackgroundResult.render(attributes, body)
        }

        // parity: core/src/codemode/job.ts#notice [status=implemented hash=643c21dfd255]
        public static func notice(_ job: Info) -> Notice {
            let state = job.status == "running" ? "cancelled" : job.status
            let body = job.status == "running" ? "Interrupted by server restart." : (job.output ?? job.error ?? state)
            return Notice(
                description: "Script",
                text: backgroundResult("kind=\"codemode\" id=\"\(job.id)\" state=\"\(state)\"", body),
                metadata: [
                    "source": .string("codemode"),
                    "jobID": .string(job.id),
                    "state": .string(state),
                ]
            )
        }

        /// How long a Code Mode script blocks its tool call before it moves to the background (upstream `BLOCK_TIMEOUT`).
        public static let blockTimeoutMs: Int = 2 * 60 * 1000

        public typealias RunFn = @Sendable (ToolSchema.Context, @escaping @Sendable (ToolSchema.Context) async throws -> ToolSchema.Result<JSONValue>) async throws -> ToolSchema.Result<JSONValue>

        // parity: core/src/codemode/job.ts#Current [status=adapted hash=6a45e9ab22b0]
        public enum Current {
            @TaskLocal public static var run: RunFn? = nil
        }

        private enum Settled: Sendable {
            case finished(Result<ToolSchema.Result<JSONValue>, any Error>)
            case timedOut
        }

        /// The script's outcome, shared by the blocking tool call and the background notice.
        private final class Outcome: Sendable {
            private struct State: Sendable {
                var result: Result<ToolSchema.Result<JSONValue>, any Error>?
                var waiters: [CheckedContinuation<Result<ToolSchema.Result<JSONValue>, any Error>, Never>] = []
                var detached = false
            }

            private let state = Mutex(State())

            var detached: Bool { state.withLock { $0.detached } }

            func detach() { state.withLock { $0.detached = true } }

            func finish(_ result: Result<ToolSchema.Result<JSONValue>, any Error>) {
                let waiters = state.withLock { s -> [CheckedContinuation<Result<ToolSchema.Result<JSONValue>, any Error>, Never>] in
                    s.result = result
                    defer { s.waiters.removeAll() }
                    return s.waiters
                }
                for waiter in waiters { waiter.resume(returning: result) }
            }

            func wait() async -> Result<ToolSchema.Result<JSONValue>, any Error> {
                await withCheckedContinuation { continuation in
                    let ready = state.withLock { s -> Result<ToolSchema.Result<JSONValue>, any Error>? in
                        if let result = s.result { return result }
                        s.waiters.append(continuation)
                        return nil
                    }
                    if let ready { continuation.resume(returning: ready) }
                }
            }
        }

        private static func text(of result: ToolSchema.Result<JSONValue>) -> String {
            switch result.content {
            case .text(let s): return s
            case .parts(let parts):
                return parts.compactMap { if case .text(let tc) = $0 { return tc.text } else { return nil } }.joined(separator: "\n")
            case nil: return ""
            }
        }

        /// With `full_codemode`, a script runs as a job: its tool call blocks for up to `blockTimeoutMs`, then moves to the
        /// background (the call returns at once) and its result arrives later as a session notice.
        // parity: core/src/codemode/job.ts#make [status=adapted hash=e5bdf2c79179]
        public static func make(
            fullCodemode: Bool,
            blockTimeoutMs: Int = Job.blockTimeoutMs,
            onBackgroundNotice: (@Sendable (Notice) async -> Void)? = nil
        ) -> RunFn {
            { context, execute in
                if !fullCodemode {
                    return try await execute(context)
                }
                let jobId = "cm_\(Identifier.ascending())"
                let outcome = Outcome()
                // The background flag tells clients this script can move to the background.
                await context.progress(["background": .bool(true)])
                let jobContext = ToolSchema.Context(
                    sessionID: context.sessionID,
                    agent: context.agent,
                    messageID: context.messageID,
                    id: context.id,
                    progress: { update in
                        if outcome.detached { return }
                        var flagged = update
                        flagged["background"] = .bool(true)
                        await context.progress(flagged)
                    },
                    cancel: context.cancel
                )
                let job = Task {
                    do {
                        outcome.finish(.success(try await execute(jobContext)))
                    } catch {
                        outcome.finish(.failure(error))
                    }
                }
                let settled = await withTaskCancellationHandler {
                    await withTaskGroup(of: Settled.self) { group -> Settled in
                        group.addTask { .finished(await outcome.wait()) }
                        group.addTask {
                            try? await Task.sleep(for: .milliseconds(blockTimeoutMs))
                            return .timedOut
                        }
                        let first = await group.next() ?? .timedOut
                        group.cancelAll()
                        return first
                    }
                } onCancel: {
                    job.cancel()
                }
                if case .finished(let result) = settled {
                    return try result.get()
                }
                // Drain the last progress publication before the tool row becomes terminal.
                outcome.detach()
                Task {
                    let info: Info
                    switch await outcome.wait() {
                    case .success(let result):
                        let body = text(of: result)
                        info = result.metadata?["error"] == .bool(true)
                            ? Info(id: jobId, status: "failed", error: body)
                            : Info(id: jobId, status: "completed", output: body)
                    case .failure(let error):
                        if error is CancellationError { return }
                        info = Info(id: jobId, status: "failed", error: String(describing: error))
                    }
                    await onBackgroundNotice?(notice(info))
                }
                let message = "Script \(jobId) is still running; its result will arrive in this session."
                return ToolSchema.Result(
                    output: .object([
                        "output": .string(message),
                        "toolCalls": .array([]),
                        "files": .array([]),
                    ]),
                    content: .text(message),
                    metadata: ["jobID": .string(jobId)]
                )
            }
        }
    }

    // MARK: - Core CodeMode Tool Integration (core/src/codemode/tool.ts)

    public enum Tool {
        public struct ExecuteFile: Equatable, Hashable, Sendable, Codable {
            public let data: String
            public let mime: String
            public let name: String?

            public init(data: String, mime: String, name: String? = nil) {
                self.data = data
                self.mime = mime
                self.name = name
            }
        }

        public struct ExecuteCall: Equatable, Hashable, Sendable, Codable {
            public let tool: String
            public let status: String
            public let input: [String: JSONValue]?

            public init(tool: String, status: String, input: [String: JSONValue]? = nil) {
                self.tool = tool
                self.status = status
                self.input = input
            }
        }

        public struct ExecuteOutput: Equatable, Hashable, Sendable, Codable {
            public let output: String
            public let toolCalls: [ExecuteCall]
            public let error: Bool?
            public let files: [ExecuteFile]

            public init(output: String, toolCalls: [ExecuteCall], error: Bool? = nil, files: [ExecuteFile] = []) {
                self.output = output
                self.toolCalls = toolCalls
                self.error = error
                self.files = files
            }
        }

        public struct ToolRegistration: Sendable {
            public let name: String
            public let description: String
            public let inputSchema: CodemodeEngine.Tool.JsonSchema
            public let outputSchema: CodemodeEngine.Tool.JsonSchema?
            public let freeform: ToolSchema.Freeform?
            public let options: ToolSchema.Options?
            public let execute: @Sendable (JSONValue, ToolSchema.Context) async throws(ToolSchema.ToolError) -> ToolSchema.Result<JSONValue>

            public init(
                name: String,
                description: String,
                inputSchema: CodemodeEngine.Tool.JsonSchema = ["type": .string("object")],
                outputSchema: CodemodeEngine.Tool.JsonSchema? = nil,
                freeform: ToolSchema.Freeform? = nil,
                options: ToolSchema.Options? = nil,
                execute: @escaping @Sendable (JSONValue, ToolSchema.Context) async throws(ToolSchema.ToolError) -> ToolSchema.Result<JSONValue>
            ) {
                self.name = name
                self.description = description
                self.inputSchema = inputSchema
                self.outputSchema = outputSchema
                self.freeform = freeform
                self.options = options
                self.execute = execute
            }
        }

        // parity: core/src/codemode/tool.ts#Services [status=adapted hash=8f6f3b675071]
        public struct Services: Sendable {
            public let location: OpenCodeLocation
            public let bun: Bun.Services

            public init(location: OpenCodeLocation, bun: Bun.Services) {
                self.location = location
                self.bun = bun
            }
        }

        /// Those services alone (location and the file services; no environment service, since each file target carries
        /// its environment), so a run they are given to keeps its own scope.
        // parity: core/src/codemode/tool.ts#services [status=adapted hash=c1a25f495fc3]
        public static func services(
            location: OpenCodeLocation,
            fileSystem: any OpenCodeFileSystem,
            permission: PermissionHook = .allowAll
        ) -> Services {
            Services(
                location: location,
                bun: Bun.Services(directory: location.directory, fileSystem: fileSystem, permission: permission)
            )
        }

        // parity: core/src/codemode/tool.ts#Inventory [status=implemented hash=e344e0eb4ea9]
        public struct Inventory: Sendable {
            public let tools: [String: ToolRegistration]
            public let namespaces: [String: ToolSchema.Namespace]

            public init(tools: [String: ToolRegistration], namespaces: [String: ToolSchema.Namespace] = [:]) {
                self.tools = tools
                self.namespaces = namespaces
            }
        }

        // parity: core/src/codemode/tool.ts#qualifiedName [status=implemented hash=a66f0a654727]
        public static func qualifiedName(_ registration: ToolRegistration) -> String {
            let normalized = registration.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let ns = registration.options?.namespace, !ns.isEmpty else { return normalized }
            return "\(ns).\(normalized)"
        }

        private static func description(full: Bool) -> String {
            [
                "Run JavaScript in a confined Code Mode runtime to script tool calls and HTTP requests and compose their results.",
                "Write plain JavaScript and send it exactly as written: no code fence, and no JSON or other wrapper around it.",
                full
                    ? "`fetch` is available for HTTP requests, and Bun's file APIs (`Bun.file`, `Bun.write`, `Bun.Glob`) for files, in place of Node's `fs`. Imports and timers are unavailable: there is no `setTimeout` or sleep. All other external access goes through `tools`."
                    : "`fetch` is available for HTTP requests. Imports, direct filesystem access, and timers are unavailable: there is no `setTimeout` or sleep. All other external access goes through `tools`.",
                "Inside `execute`, the only callable tools are those explicitly listed in the Code Mode catalog instructions or returned by the `search` function. Ignore tools shown outside the Code Mode catalog. They are not available in the Code Mode runtime.",
                #"Call tools through `tools` using only exact paths and signatures from the catalog. Do not infer or normalize tool names; preserve bracket notation such as `tools.<namespace>["tool-name"](input)`."#,
                "Prefer an explicit `return`; if omitted, the final top-level expression becomes the result.",
                "Await every call whose completion matters; pending calls are interrupted when execution ends. Run independent calls concurrently with `Promise.allSettled`.",
            ].joined(separator: "\n")
        }

        private static func resultValue(_ executed: ToolSchema.Result<JSONValue>) -> JSONValue {
            if let out = executed.output { return out }
            switch executed.content {
            case .text(let s): return s.isEmpty ? .null : .string(s)
            case .parts(let parts):
                let joined = parts.compactMap { if case .text(let tc) = $0 { return tc.text } else { return nil } }.joined(separator: "\n")
                return joined.isEmpty ? .null : .string(joined)
            case nil: return .null
            }
        }

        private static func outputFiles(_ executed: ToolSchema.Result<JSONValue>) -> [ExecuteFile] {
            guard case .parts(let parts) = executed.content else { return [] }
            return parts.compactMap { part in
                guard case .file(let fc) = part else { return nil }
                let prefix = "data:\(fc.mime);base64,"
                guard fc.uri.hasPrefix(prefix) else { return nil }
                return ExecuteFile(data: String(fc.uri.dropFirst(prefix.count)), mime: fc.mime, name: fc.name)
            }
        }

        /// A Code Mode setting's schema as JSON Schema (a named contract carries its schema when it has one).
        private static func jsonSchema(_ schema: ToolSchema.ValueSchema?) -> CodemodeEngine.Tool.JsonSchema? {
            switch schema {
            case .jsonSchema(let json)?: return json
            case .named(_, let json)?: return json
            case nil: return nil
            }
        }

        /// The tool as Code Mode presents it (`definition(registration, true)`): its `codemode` settings may override
        /// the direct tool's description and input/output schemas.
        static func codemodeDefinition(_ reg: ToolRegistration) -> (description: String, input: CodemodeEngine.Tool.JsonSchema, output: CodemodeEngine.Tool.JsonSchema?) {
            let overrides = reg.options?.codemodeOptions
            return (
                overrides?.description ?? reg.description,
                jsonSchema(overrides?.input) ?? reg.inputSchema,
                jsonSchema(overrides?.output) ?? reg.outputSchema
            )
        }

        private static func buildToolsTree(
            _ inventory: Inventory,
            executor: @escaping @Sendable (String, ToolRegistration, JSONValue) async throws -> JSONValue
        ) -> CodemodeEngine.Tools {
            var root: CodemodeEngine.Tools = [:]
            for name in inventory.tools.keys.sorted() {
                guard let reg = inventory.tools[name] else { continue }
                let qName = qualifiedName(reg)
                let definition = codemodeDefinition(reg)
                let def = CodemodeEngine.Tool.make(CodemodeEngine.Tool.Options(
                    description: definition.description,
                    input: definition.input,
                    freeform: reg.freeform != nil,
                    output: definition.output ?? ["type": .array([.string("string"), .string("null")])],
                    execute: { input, _ in
                        try await executor(name, reg, input)
                    }
                ))
                root[qName] = .tool(def)
            }
            for (nsName, ns) in inventory.namespaces {
                // Attach namespace metadata if children exist under this prefix
                let prefix = "\(nsName)."
                var nsChildren: CodemodeEngine.Tools = [:]
                for (k, v) in root where k.hasPrefix(prefix) {
                    nsChildren[String(k.dropFirst(prefix.count))] = v
                    root.removeValue(forKey: k)
                }
                root[nsName] = .namespace(CodemodeEngine.Namespace.make(.init(description: ns.description, tools: nsChildren)))
            }
            return root
        }

        /// Whether a tool is pinned in the catalog: `codemode.pinned`, or the deprecated top-level `pinned`
        /// (`ToolSchema.Options.pinned` resolves that fallback).
        static func isPinned(_ registration: ToolRegistration) -> Bool {
            registration.options?.pinned == true
        }

        // parity: core/src/codemode/tool.ts#catalog [status=implemented hash=d9123c90fa74]
        public static func catalog(_ inventory: Inventory) -> Catalog.Inventory {
            let pinnedSet = Set(inventory.tools.values.filter(isPinned).map(qualifiedName))
            let prepared = CodemodeEngine.ToolRuntime.prepare(buildToolsTree(inventory) { _, _, _ in .null })

            final class Node {
                var tool: Catalog.ToolEntry?
                var namespace: ToolSchema.Namespace?
                var children: [String: Node] = [:]
            }

            let root = Node()
            func getNode(_ path: String) -> Node {
                var cur = root
                for seg in path.split(separator: ".").map(String.init) {
                    if let existing = cur.children[seg] { cur = existing }
                    else { let n = Node(); cur.children[seg] = n; cur = n }
                }
                return cur
            }
            for ns in inventory.namespaces.values { getNode(ns.name).namespace = ns }
            for desc in prepared.catalog {
                let segName = desc.path.split(separator: ".").last.map(String.init) ?? desc.path
                getNode(desc.path).tool = Catalog.ToolEntry(
                    name: segName,
                    description: desc.description,
                    signature: desc.signature,
                    pinned: pinnedSet.contains(desc.path) ? true : nil
                )
            }

            func render(_ node: Node) -> [Catalog.Entry] {
                var out: [Catalog.Entry] = []
                for key in node.children.keys.sorted() {
                    guard let child = node.children[key] else { continue }
                    let nested = render(child)
                    let nsEntry: Catalog.NamespaceEntry? = (child.namespace != nil || !nested.isEmpty)
                        ? Catalog.NamespaceEntry(name: key, description: child.namespace?.description, tools: nested)
                        : nil
                    if let t = child.tool { out.append(.tool(t)) }
                    if let nsEntry { out.append(.namespace(nsEntry)) }
                }
                return out
            }
            return Catalog.Inventory(tools: render(root))
        }

        // parity: core/src/codemode/tool.ts#create [status=adapted hash=1ee5996bd6f5]
        public static func create(
            inventory: Inventory,
            transport: any HTTPTransport,
            permission: PermissionHook = .allowAll,
            services: Services? = nil,
            limits: CodemodeEngine.ExecutionLimits = CodemodeEngine.ExecutionLimits()
        ) -> ToolSchema.Info<CodemodeEngine.Input, ExecuteOutput> {
            ToolSchema.Info<CodemodeEngine.Input, ExecuteOutput>(
                name: "execute",
                input: .jsonSchema([
                    "type": .string("object"),
                    "properties": .object(["code": .object(["type": .string("string")])]),
                    "required": .array([.string("code")]),
                ]),
                freeform: .text,
                description: description(full: services != nil),
                execute: { input, context in
                    let callRows = Mutex<[ExecuteCall]>([])
                    let rowIndexByKey = Mutex<[String: Int]>([:])
                    let collectedFiles = Mutex<[(Int, [ExecuteFile])]>([])
                    let callCounter = Mutex<Int>(0)

                    @Sendable func displayInput(_ val: JSONValue) -> [String: JSONValue]? {
                        switch val {
                        case .null: return nil
                        case .object(let d): return d.isEmpty ? nil : d
                        default: return ["input": val]
                        }
                    }

                    let execSvc = Execution.Service(context: context, permission: permission, transport: transport)
                    var extensions: [CodemodeEngine.Extension.Definition] = [
                        Fetch.makeExtension(transport: transport, execution: execSvc),
                    ]
                    if let services {
                        extensions.append(Path.makeExtension(directory: services.location.directory))
                        extensions.append(Bun.makeExtension(services: services.bun, execution: execSvc))
                    }

                    let hooks = CodemodeEngine.ToolRuntime.Hooks(
                        toolBefore: { call in
                            let row = ExecuteCall(tool: call.name, status: "running", input: displayInput(call.input))
                            let idx = callRows.withLock { list -> Int in
                                let i = list.count
                                list.append(row)
                                return i
                            }
                            rowIndexByKey.withLock { $0[call.key] = idx }
                            let snapshot = callRows.withLock { $0 }
                            await context.progress(["toolCalls": .array(snapshot.map(encodeExecuteCall))])
                        },
                        toolAfter: { call, res in
                            if let idx = rowIndexByKey.withLock({ $0[call.key] }) {
                                callRows.withLock { list in
                                    let prev = list[idx]
                                    let status = if case .success = res { "completed" } else { "error" }
                                    list[idx] = ExecuteCall(tool: prev.tool, status: status, input: prev.input)
                                }
                                let snapshot = callRows.withLock { $0 }
                                await context.progress(["toolCalls": .array(snapshot.map(encodeExecuteCall))])
                            }
                        },
                        extensionBefore: { call in
                            let entry: ExecuteCall?
                            if call.name == "fetch" {
                                entry = ExecuteCall(tool: "fetch", status: "running", input: Fetch.display(call.args))
                            } else if call.extension == "bun" {
                                entry = ExecuteCall(tool: "Bun", status: "running", input: Bun.display(name: call.name, args: call.args))
                            } else {
                                entry = nil
                            }
                            if let entry {
                                callRows.withLock { $0.append(entry) }
                            }
                        },
                        extensionAfter: { call, res in
                            if call.name == "fetch" || call.extension == "bun" {
                                callRows.withLock { list in
                                    if let idx = list.lastIndex(where: { $0.status == "running" && ($0.tool == call.name || ($0.tool == "Bun" && call.extension == "bun")) }) {
                                        let prev = list[idx]
                                        let status = if case .success = res { "completed" } else { "error" }
                                        list[idx] = ExecuteCall(tool: prev.tool, status: status, input: prev.input)
                                    }
                                }
                            }
                        }
                    )

                    let toolsTree = buildToolsTree(inventory) { _, reg, toolInput in
                        let seq = callCounter.withLock { c -> Int in let cur = c; c += 1; return cur }
                        let nestedID = ToolSchema.CallID(rawValue: "call_\(Identifier.ascending())")
                        let nestedCtx = ToolSchema.Context(
                            sessionID: context.sessionID,
                            agent: context.agent,
                            messageID: context.messageID,
                            id: nestedID,
                            progress: { _ in },
                            cancel: nil,
                            // The tool runs inside Code Mode, so its `codemode` overrides apply.
                            codemode: true
                        )
                        do {
                            let executed = try await reg.execute(toolInput, nestedCtx)
                            let files = outputFiles(executed)
                            if !files.isEmpty {
                                collectedFiles.withLock { $0.append((seq, files)) }
                            }
                            return resultValue(executed)
                        } catch let toolErr as ToolSchema.ToolError {
                            throw CodemodeEngine.toolError(toolErr.message)
                        } catch {
                            throw CodemodeEngine.toolError(CodemodeLanguage.errorMessage(error))
                        }
                    }

                    let result: CodemodeEngine.ExecutionResult
                    do {
                        let rt = try CodemodeEngine.make(CodemodeEngine.Options(
                            tools: toolsTree,
                            hooks: hooks,
                            extensions: extensions,
                            limits: limits
                        ))
                        result = await rt.execute(input.code, nil, nil)
                    } catch {
                        result = .failure(CodemodeEngine.Failure(error: CodemodeLanguage.normalizeError(error)))
                    }

                    let finalCalls = callRows.withLock { $0 }
                    let finalFiles = collectedFiles.withLock { $0 }
                        .sorted { $0.0 < $1.0 }
                        .flatMap(\.1)
                    let formatted = result.formattedOutput()
                    let outputStruct = ExecuteOutput(
                        output: formatted,
                        toolCalls: finalCalls,
                        error: result.ok ? nil : true,
                        files: finalFiles
                    )
                    var contentParts: [ToolSchema.Content] = [.text(ToolSchema.TextContent(text: formatted))]
                    for f in finalFiles {
                        contentParts.append(.file(ToolSchema.FileContent(
                            uri: "data:\(f.mime);base64,\(f.data)",
                            mime: f.mime,
                            name: f.name
                        )))
                    }
                    var metadata: ToolSchema.Metadata = ["toolCalls": .array(finalCalls.map(encodeExecuteCall))]
                    if !result.ok { metadata["error"] = .bool(true) }
                    return ToolSchema.Result(output: outputStruct, content: .parts(contentParts), metadata: metadata)
                }
            )
        }

        private static func encodeExecuteCall(_ call: ExecuteCall) -> JSONValue {
            var dict: [String: JSONValue] = [
                "tool": .string(call.tool),
                "status": .string(call.status),
            ]
            if let input = call.input { dict["input"] = .object(input) }
            return .object(dict)
        }

        // parity: core/src/codemode/tool.ts#check [status=implemented hash=332d31757798]
        public static func check(
            inventory: Inventory,
            code: String,
            bindings: [String: CodemodeEngine.DataValue] = [:],
            limits: CodemodeEngine.ExecutionLimits = CodemodeEngine.ExecutionLimits(),
            executeTool: @escaping @Sendable (String, ToolRegistration, JSONValue) async throws -> ToolSchema.Result<JSONValue>
        ) async throws -> CodemodeEngine.ExecutionResult {
            let toolsTree = buildToolsTree(inventory) { name, reg, input in
                let res = try await executeTool(name, reg, input)
                return resultValue(res)
            }
            let rt = try CodemodeEngine.make(CodemodeEngine.Options(
                tools: toolsTree,
                hooks: CodemodeEngine.ToolRuntime.Hooks(),
                limits: limits
            ))
            return await rt.execute(code, bindings, nil)
        }
    }
}

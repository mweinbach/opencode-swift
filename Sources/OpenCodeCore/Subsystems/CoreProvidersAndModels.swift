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

// MARK: - CoreAgent (`core/src/agent.ts`)

public enum CoreAgent {
    public enum Agent {
        // parity: core/src/agent.ts#ID [status=implemented hash=706bcfe5348f]
        public typealias ID = AgentSchema.ID

        // parity: core/src/agent.ts#Name [status=implemented hash=53efd1f24699]
        public typealias Name = AgentSchema.Name

        // parity: core/src/agent.ts#defaultID [status=implemented hash=e20ea5875e13]
        public static let defaultID = ID(rawValue: "build")

        // parity: core/src/agent.ts#Color [status=implemented hash=0e644751222b]
        public typealias Color = AgentSchema.Color

        // parity: core/src/agent.ts#Info [status=implemented hash=fd734916140a]
        public typealias Info = AgentSchema.Info

        // parity: core/src/agent.ts#Selection [status=implemented hash=e7f7661123c2]
        public struct Selection: Equatable, Hashable, Sendable {
            public let id: ID
            public let info: Info?

            public init(id: ID, info: Info?) {
                self.id = id
                self.info = info
            }
        }

        public struct Data: Equatable, Sendable {
            public var agents: [ID: Info]
            public var defaultAgent: ID?

            public init(agents: [ID: Info] = [:], defaultAgent: ID? = nil) {
                self.agents = agents
                self.defaultAgent = defaultAgent
            }
        }

        // parity: core/src/agent.ts#Editor [status=implemented hash=442aa294882c]
        public final class Editor: @unchecked Sendable {
            internal var data: Data
            internal init(data: Data) { self.data = data }

            public func list() -> [Info] {
                Array(data.agents.values).sorted { $0.id.rawValue < $1.id.rawValue }
            }

            public func get(_ id: ID) -> Info? {
                data.agents[id]
            }

            public func setDefault(_ id: ID?) {
                data.defaultAgent = id
            }

            public func update(_ id: ID, _ fn: (Info) -> Info) {
                let current = data.agents[id] ?? Agent.defaultInfo(id: id)
                let next = fn(current)
                data.agents[id] = Info(
                    id: id,
                    name: next.name,
                    model: next.model,
                    request: next.request,
                    system: next.system,
                    description: next.description,
                    mode: next.mode,
                    hidden: next.hidden,
                    color: next.color,
                    steps: next.steps,
                    permissions: next.permissions
                )
            }

            public func remove(_ id: ID) {
                data.agents.removeValue(forKey: id)
            }
        }

        public static func defaultInfo(id: ID) -> Info {
            Info(
                id: id,
                name: Name(rawValue: id.rawValue),
                model: nil,
                request: ProviderSchema.Request(),
                system: nil,
                description: nil,
                mode: .all,
                hidden: false,
                color: nil,
                steps: nil,
                permissions: []
            )
        }

        // parity: core/src/agent.ts#Interface [status=implemented hash=86a9ba3394ed]
        public protocol Interface: CoreState.Transformable where Editor == Agent.Editor {
            func get(_ id: ID) async -> Info?
            func resolve(_ id: String?) async -> Info?
            func select(_ id: ID?) async -> Selection
            func list() async -> [Info]
        }

        // parity: core/src/agent.ts#Service [status=implemented hash=b05258c8f85a]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/Agent"
            private let state: CoreState.Store<Data, Editor>

            public init(onUpdated: (@Sendable () async -> Void)? = nil) {
                self.state = CoreState.create(CoreState.Options(
                    name: "agent",
                    initial: { Data() },
                    makeEditor: { Editor(data: $0) },
                    commitEditor: { $0.data },
                    notify: onUpdated.map { cb in
                        CoreState.changes(
                            project: { Self.orderedList(from: $0) },
                            notify: { _ in await cb() }
                        )
                    }
                ))
            }

            private static func selectable(_ agent: Info?) -> Info? {
                guard let agent, agent.mode != .subagent, !agent.hidden else { return nil }
                return agent
            }

            private static func selectedDefault(in data: Data) -> Info? {
                if let configuredID = data.defaultAgent, let chosen = selectable(data.agents[configuredID]) {
                    return chosen
                }
                if let build = selectable(data.agents[Agent.defaultID]) {
                    return build
                }
                for agent in data.agents.values.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
                    if let fallback = selectable(agent) { return fallback }
                }
                return nil
            }

            private static func orderedList(from data: Data) -> [Info] {
                let all = data.agents.values.sorted { $0.id.rawValue < $1.id.rawValue }
                guard let selected = selectedDefault(in: data) else { return all }
                return [selected] + all.filter { $0.id != selected.id }
            }

            @discardableResult
            public func transform(_ update: @escaping @Sendable (Editor) throws -> Void) async throws -> CoreState.Registration {
                try await state.transform(update)
            }

            public func reload() async { await state.reload() }

            public func get(_ id: ID) async -> Info? {
                state.get().agents[id]
            }

            public func resolve(_ id: String? = nil) async -> Info? {
                let data = state.get()
                if let id { return data.agents[ID(rawValue: id)] }
                return Self.selectedDefault(in: data)
            }

            public func select(_ id: ID? = nil) async -> Selection {
                let data = state.get()
                if let id { return Selection(id: id, info: data.agents[id]) }
                let info = Self.selectedDefault(in: data)
                return Selection(id: info?.id ?? Agent.defaultID, info: info)
            }

            public func list() async -> [Info] {
                Self.orderedList(from: state.get())
            }
        }

        // parity: core/src/agent.ts#node [status=implemented hash=557341d81bc8]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer { _, _ in LayerNode.Output([Service.serviceKey: Service()]) },
            []
        )
    }
}

// MARK: - CoreProvider (`account/sql.ts`, `credential*`, `console-access.ts`, `oauth/*`, `usage-limits.ts`, `aisdk*`, `provider.ts`)

public enum CoreProvider {
    // MARK: - core/src/account/sql.ts

    public enum AccountSQL {
        // parity: core/src/account/sql.ts#AccountTable [status=adapted hash=b0c2822752a9]
        public enum AccountTable {
            public static let tableName = "account"
            public static let createTableSQL = """
                CREATE TABLE IF NOT EXISTS account (
                    id TEXT PRIMARY KEY,
                    email TEXT NOT NULL,
                    url TEXT NOT NULL,
                    access_token TEXT NOT NULL,
                    refresh_token TEXT NOT NULL,
                    token_expiry INTEGER,
                    time_created INTEGER NOT NULL,
                    time_updated INTEGER NOT NULL
                );
                """
        }

        // parity: core/src/account/sql.ts#AccountStateTable [status=adapted hash=8fe23d7616fd]
        public enum AccountStateTable {
            public static let tableName = "account_state"
            public static let createTableSQL = """
                CREATE TABLE IF NOT EXISTS account_state (
                    id INTEGER PRIMARY KEY,
                    active_account_id TEXT REFERENCES account(id) ON DELETE SET NULL,
                    active_org_id TEXT
                );
                """
        }

        // parity: core/src/account/sql.ts#ControlAccountTable [status=adapted hash=8a5bd2a035b2]
        public enum ControlAccountTable {
            public static let tableName = "control_account"
            public static let createTableSQL = """
                CREATE TABLE IF NOT EXISTS control_account (
                    email TEXT NOT NULL,
                    url TEXT NOT NULL,
                    access_token TEXT NOT NULL,
                    refresh_token TEXT NOT NULL,
                    token_expiry INTEGER,
                    active INTEGER NOT NULL DEFAULT 0,
                    time_created INTEGER NOT NULL,
                    time_updated INTEGER NOT NULL,
                    PRIMARY KEY (email, url)
                );
                """
        }
    }

    // MARK: - core/src/credential/sql.ts & core/src/credential.ts

    public enum CredentialSQL {
        // parity: core/src/credential/sql.ts#CredentialTable [status=adapted hash=981858cf3cb8]
        public enum CredentialTable {
            public static let tableName = "credential"
            public static let createTableSQL = """
                CREATE TABLE IF NOT EXISTS credential (
                    id TEXT PRIMARY KEY,
                    integration_id TEXT,
                    label TEXT NOT NULL,
                    value TEXT NOT NULL,
                    connector_id TEXT,
                    method_id TEXT,
                    active INTEGER,
                    time_created INTEGER NOT NULL,
                    time_updated INTEGER NOT NULL
                );
                """
        }
    }

    public enum Credential {
        // parity: core/src/credential.ts#ID [status=implemented hash=fb6232c3214c]
        public typealias ID = CredentialSchema.ID

        // parity: core/src/credential.ts#OAuth [status=implemented hash=0ea15c70f983]
        public typealias OAuth = CredentialSchema.OAuth

        // parity: core/src/credential.ts#Key [status=implemented hash=38b3d1fd5489]
        public typealias Key = CredentialSchema.Key

        // parity: core/src/credential.ts#External [status=implemented hash=3322cccd31c0]
        public typealias External = CredentialSchema.External

        // parity: core/src/credential.ts#Value [status=implemented hash=8f09840353ba]
        public typealias Value = CredentialSchema.Value

        // parity: core/src/credential.ts#Event [status=implemented hash=f52610e8bb0b]
        public typealias Event = CredentialSchema.Event

        /// Whether an access token is due for a refresh. `expires == 0` means the issuer gave no lifetime.
        // parity: core/src/credential.ts#expiring [status=implemented hash=1a3a0c22858e]
        public static func expiring(_ value: OAuth, now: Int64, marginMs: Int64 = 5 * 60 * 1_000) -> Bool {
            let exp = Int64(value.expires.rawValue)
            return exp != 0 && exp <= now + marginMs
        }

        // parity: core/src/credential.ts#Info [status=implemented hash=5ff5aac9c405]
        public struct Info: Equatable, Hashable, Sendable, Codable {
            public let id: ID
            public let integrationID: IntegrationID
            public let label: String
            public let value: Value

            public init(id: ID, integrationID: IntegrationID, label: String, value: Value) {
                self.id = id
                self.integrationID = integrationID
                self.label = label
                self.value = value
            }
        }

        // parity: core/src/credential.ts#Interface [status=implemented hash=41dedf758f32]
        public protocol Interface: Sendable {
            func all() async throws -> [Info]
            func list(_ integrationID: IntegrationID) async throws -> [Info]
            func get(_ id: ID) async throws -> Info?
            func refresh(
                _ id: ID,
                stale: @escaping @Sendable (OAuth, Int64) -> Bool,
                refresh: @escaping @Sendable (OAuth) async throws -> OAuth
            ) async throws -> OAuth?
            func create(id: ID?, integrationID: IntegrationID, value: Value, label: String?, activate: Bool) async throws -> Info
            func activate(_ id: ID) async throws
            func update(_ id: ID, label: String?, value: Value?) async throws
            func remove(_ id: ID) async throws
        }

        // parity: core/src/credential.ts#Service [status=implemented hash=103075b59f47]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/Credential"
            private let db: any SQLiteDatabase
            private let refreshLocks = CoreSubsystems.Effect.KeyedMutex<ID>()

            public init(database: any SQLiteDatabase) throws {
                self.db = database
                try database.executeScript(CredentialSQL.CredentialTable.createTableSQL)
            }

            public static func inMemory() throws -> Service {
                try Service(database: SQLiteDatabaseFactory.open(path: ":memory:"))
            }

            private static func decodeRow(_ row: SQLiteRow) -> Info? {
                guard let idRaw = row.string("id"),
                      let integrationRaw = row.string("integration_id"),
                      let label = row.string("label"),
                      let valRaw = row.string("value"),
                      let value = try? JSONDecoder().decode(Value.self, from: Data(valRaw.utf8))
                else { return nil }
                return Info(
                    id: ID(rawValue: idRaw),
                    integrationID: IntegrationID(rawValue: integrationRaw),
                    label: label,
                    value: value
                )
            }

            public func all() async throws -> [Info] {
                let rows = try db.query("SELECT * FROM credential ORDER BY active ASC, time_created ASC, id ASC")
                return rows.compactMap(Self.decodeRow)
            }

            public func list(_ integrationID: IntegrationID) async throws -> [Info] {
                let rows = try db.query(
                    "SELECT * FROM credential WHERE integration_id = ? ORDER BY active ASC, time_created ASC, id ASC",
                    parameters: [.text(integrationID.rawValue)]
                )
                return rows.compactMap(Self.decodeRow)
            }

            public func get(_ id: ID) async throws -> Info? {
                guard let row = try db.queryOne("SELECT * FROM credential WHERE id = ?", parameters: [.text(id.rawValue)]) else {
                    return nil
                }
                return Self.decodeRow(row)
            }

            public func refresh(
                _ id: ID,
                stale: @escaping @Sendable (OAuth, Int64) -> Bool,
                refresh: @escaping @Sendable (OAuth) async throws -> OAuth
            ) async throws -> OAuth? {
                try await refreshLocks.withLock(id) { [self] in
                    guard let currentInfo = try await self.get(id), case .oauth(let current) = currentInfo.value else {
                        return nil
                    }
                    let now = Flock.currentEpochMs()
                    if !stale(current, now) { return current }
                    let refreshed = try await refresh(current)
                    guard let latestInfo = try await self.get(id), case .oauth(let latest) = latestInfo.value else {
                        return nil
                    }
                    if latest.access != current.access || latest.refresh != current.refresh {
                        return latest
                    }
                    try await self.update(id, label: nil, value: .oauth(refreshed))
                    return refreshed
                }
            }

            public func create(
                id: ID? = nil,
                integrationID: IntegrationID,
                value: Value,
                label: String? = nil,
                activate: Bool = true
            ) async throws -> Info {
                let info = Info(
                    id: id ?? ID.create(),
                    integrationID: integrationID,
                    label: label ?? "default",
                    value: value
                )
                let now = Flock.currentEpochMs()
                let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
                try db.transaction {
                    let existing = try db.queryOne(
                        "SELECT id, active FROM credential WHERE integration_id = ? ORDER BY active DESC, time_created DESC, id DESC",
                        parameters: [.text(integrationID.rawValue)]
                    )
                    let shouldActivate = activate || existing == nil
                    if shouldActivate {
                        _ = try db.execute(
                            "UPDATE credential SET active = 0 WHERE integration_id = ?",
                            parameters: [.text(integrationID.rawValue)]
                        )
                    }
                    _ = try db.execute(
                        """
                        INSERT INTO credential (id, integration_id, label, value, active, time_created, time_updated)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        parameters: [
                            .text(info.id.rawValue),
                            .text(info.integrationID.rawValue),
                            .text(info.label),
                            .text(encoded),
                            .integer(shouldActivate ? 1 : 0),
                            .integer(now),
                            .integer(now),
                        ]
                    )
                }
                return info
            }

            public func activate(_ id: ID) async throws {
                try db.transaction {
                    guard let row = try db.queryOne("SELECT integration_id FROM credential WHERE id = ?", parameters: [.text(id.rawValue)]),
                          let integrationID = row.string("integration_id")
                    else { return }
                    _ = try db.execute("UPDATE credential SET active = 0 WHERE integration_id = ?", parameters: [.text(integrationID)])
                    _ = try db.execute("UPDATE credential SET active = 1 WHERE id = ?", parameters: [.text(id.rawValue)])
                }
            }

            public func update(_ id: ID, label: String?, value: Value?) async throws {
                guard label != nil || value != nil else { return }
                let now = Flock.currentEpochMs()
                if let label, let value {
                    let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
                    _ = try db.execute(
                        "UPDATE credential SET label = ?, value = ?, time_updated = ? WHERE id = ?",
                        parameters: [.text(label), .text(encoded), .integer(now), .text(id.rawValue)]
                    )
                } else if let label {
                    _ = try db.execute(
                        "UPDATE credential SET label = ?, time_updated = ? WHERE id = ?",
                        parameters: [.text(label), .integer(now), .text(id.rawValue)]
                    )
                } else if let value {
                    let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
                    _ = try db.execute(
                        "UPDATE credential SET value = ?, time_updated = ? WHERE id = ?",
                        parameters: [.text(encoded), .integer(now), .text(id.rawValue)]
                    )
                }
            }

            public func remove(_ id: ID) async throws {
                try db.transaction {
                    guard let row = try db.queryOne("SELECT integration_id, active FROM credential WHERE id = ?", parameters: [.text(id.rawValue)]) else {
                        return
                    }
                    _ = try db.execute("DELETE FROM credential WHERE id = ?", parameters: [.text(id.rawValue)])
                    if let integrationID = row.string("integration_id"), row.int64("active") == 1 {
                        if let replacement = try db.queryOne(
                            "SELECT id FROM credential WHERE integration_id = ? ORDER BY time_created DESC, id DESC",
                            parameters: [.text(integrationID)]
                        ), let repID = replacement.string("id") {
                            _ = try db.execute("UPDATE credential SET active = 1 WHERE id = ?", parameters: [.text(repID)])
                        }
                    }
                }
            }
        }

        // parity: core/src/credential.ts#node [status=implemented hash=4c01331df1d9]
        public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer { _, _ in
                LayerNode.Output([Service.serviceKey: try Service.inMemory()])
            },
            []
        )
    }

    // MARK: - core/src/console-access.ts

    public enum ConsoleAccess {
        // parity: core/src/console-access.ts#defaultServer [status=implemented hash=fede4d49812d]
        public static let defaultServer = "https://opencode.ai/console"

        /// Resolves the Console server URL, rewriting legacy `https://console.opencode.ai` hosts.
        // parity: core/src/console-access.ts#server [status=implemented hash=2a94ab1553ac]
        public static func server(_ value: Credential.Value) -> String {
            let meta: [String: JSONValue]?
            switch value {
            case .key(let k): meta = k.metadata
            case .oauth(let o): meta = o.metadata
            case .external(let e): meta = e.metadata
            }
            let raw: String
            if case .string(let s) = meta?["server"] {
                raw = s
            } else {
                raw = defaultServer
            }
            if raw == "https://console.opencode.ai" {
                return defaultServer
            }
            if raw.hasPrefix("https://console.opencode.ai/") {
                return defaultServer + String(raw.dropFirst("https://console.opencode.ai".count))
            }
            return raw
        }

        // parity: core/src/console-access.ts#headers [status=implemented hash=173c4f1c5d3c]
        public static func headers(_ value: Credential.Value) -> [String: String] {
            var out: [String: String] = [:]
            let meta: [String: JSONValue]?
            switch value {
            case .oauth(let o):
                out["authorization"] = "Bearer \(o.access)"
                meta = o.metadata
            case .key(let k):
                out["authorization"] = "Bearer \(k.key)"
                meta = k.metadata
            case .external:
                return [:]
            }
            if case .string(let orgID) = meta?["orgID"] {
                out["x-org-id"] = orgID
            }
            return out
        }
    }

    // MARK: - core/src/oauth/page.ts & core/src/oauth/redirect.ts

    public enum OAuthPage {
        // parity: core/src/oauth/page.ts#CallbackPageOptions [status=implemented hash=44ea09599f73]
        public struct CallbackPageOptions: Equatable, Hashable, Sendable {
            public let provider: String?
            public let autoClose: Bool?

            public init(provider: String? = nil, autoClose: Bool? = nil) {
                self.provider = provider
                self.autoClose = autoClose
            }
        }

        // parity: core/src/oauth/page.ts#BootstrapOptions [status=implemented hash=aa8a7278df47]
        public struct BootstrapOptions: Equatable, Hashable, Sendable {
            public let tokenPath: String
            public let provider: String?

            public init(tokenPath: String, provider: String? = nil) {
                self.tokenPath = tokenPath
                self.provider = provider
            }
        }

        private static func escapeHTML(_ value: String) -> String {
            value
                .replacing("&", with: "&amp;")
                .replacing("<", with: "&lt;")
                .replacing(">", with: "&gt;")
                .replacing("\"", with: "&quot;")
                .replacing("'", with: "&#39;")
        }

        private static func renderDocument(title: String, status: String, headline: String, message: String, detail: String? = nil, footnote: String, script: String? = nil) -> String {
            let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hiddenAttr = trimmedDetail.isEmpty ? " hidden" : ""
            let scriptBlock = script.map { "\n    <script>\($0)</script>" } ?? ""
            return """
            <!doctype html>
            <html lang="en">
              <head>
                <meta charset="utf-8" />
                <meta name="viewport" content="width=device-width, initial-scale=1" />
                <meta name="robots" content="noindex" />
                <title>\(escapeHTML(title)) · OpenCode</title>
              </head>
              <body>
                <main class="card" id="oc-card" data-status="\(status)" role="status" aria-live="polite">
                  <h1 class="headline" id="oc-headline">\(escapeHTML(headline))</h1>
                  <p class="message" id="oc-message">\(message)</p>
                  <pre class="detail" id="oc-detail"\(hiddenAttr)>\(escapeHTML(trimmedDetail))</pre>
                  <p class="footnote" id="oc-footnote">\(escapeHTML(footnote))</p>
                </main>\(scriptBlock)
              </body>
            </html>
            """
        }

        // parity: core/src/oauth/page.ts#success [status=implemented hash=1fbd58a290a8]
        public static func success(_ options: CallbackPageOptions? = nil) -> String {
            let message = options?.provider.map { "OpenCode is now connected to \(escapeHTML($0))." } ?? "OpenCode is now authorized."
            let script = options?.autoClose == false ? nil : "setTimeout(function(){try{window.close()}catch(e){}},2500)"
            return renderDocument(
                title: "Authorization successful",
                status: "success",
                headline: "Authorization successful",
                message: message,
                footnote: "You can close this window.",
                script: script
            )
        }

        // parity: core/src/oauth/page.ts#error [status=implemented hash=e717350b55ea]
        public static func error(_ detail: String, options: CallbackPageOptions? = nil) -> String {
            let message = options?.provider.map { "OpenCode couldn't finish connecting to \(escapeHTML($0))." }
                ?? "OpenCode couldn't complete authorization."
            return renderDocument(
                title: "Authorization failed",
                status: "error",
                headline: "Authorization failed",
                message: message,
                detail: detail,
                footnote: "Close this window and try again from OpenCode."
            )
        }

        // parity: core/src/oauth/page.ts#bootstrap [status=implemented hash=cd67d89106ea]
        public static func bootstrap(_ options: BootstrapOptions) -> String {
            let message = options.provider.map { "Completing your \(escapeHTML($0)) authorization." } ?? "Completing authorization."
            let tokenPathJSON = CoreSubsystems.Util.encodeJSONString(options.tokenPath).replacing("<", with: "\\u003c")
            let script = "var TOKEN_URL=new URL(\(tokenPathJSON),window.location.origin).href;"
            return renderDocument(
                title: "Finishing sign-in",
                status: "pending",
                headline: "Finishing sign-in",
                message: message,
                footnote: "You can close this window once sign-in finishes.",
                script: script
            )
        }
    }

    public enum OAuthRedirect {
        public enum PastedResult: Equatable, Sendable {
            case code(code: String, params: [String: String])
            case error(message: String, params: [String: String])
        }

        // parity: core/src/oauth/redirect.ts#pasted [status=implemented hash=670fd81febb4]
        public static func pasted(text: String, state: String) throws -> PastedResult {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: value), url.scheme != nil,
                  let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else {
                throw PlatformError.ioFailure("Paste the full URL from the browser's address bar")
            }
            var params: [String: String] = [:]
            for item in comps.queryItems ?? [] {
                params[item.name] = item.value ?? ""
            }
            guard params["state"] == state else {
                throw PlatformError.ioFailure("This URL belongs to a different sign-in")
            }
            if let err = params["error_description"] ?? params["error"], !err.isEmpty {
                return .error(message: err, params: params)
            }
            guard let code = params["code"], !code.isEmpty else {
                throw PlatformError.ioFailure("The URL does not contain an authorization code")
            }
            return .code(code: code, params: params)
        }

        // parity: core/src/oauth/redirect.ts#submit [status=implemented hash=ecd92e0cd1b1]
        public static func submit<A: Sendable>(
            state: String,
            received: @escaping @Sendable (String, [String: String]) -> A,
            resolve: @escaping @Sendable (Result<A, any Error>) async -> Void
        ) -> @Sendable (String) async throws -> Void {
            { text in
                let parsed = try pasted(text: text, state: state)
                switch parsed {
                case .error(let msg, _):
                    await resolve(.failure(PlatformError.ioFailure(msg)))
                case .code(let code, let params):
                    await resolve(.success(received(code, params)))
                }
            }
        }
    }

    // MARK: - core/src/usage-limits.ts

    public enum UsageLimits {
        // parity: core/src/usage-limits.ts#Info [status=implemented hash=7c6362c48f5a]
        public typealias Info = UsageLimitsSchema.Info

        // parity: core/src/usage-limits.ts#UnavailableError [status=implemented hash=8dd989a7017f]
        public struct UnavailableError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "UsageLimits.UnavailableError"
            public let message: String
            public init(message: String) { self.message = message }
            public var description: String { message }
        }

        // parity: core/src/usage-limits.ts#Interface [status=implemented hash=dff1cf708b27]
        public protocol Interface: Sendable {
            func get() async throws -> Info?
        }

        // parity: core/src/usage-limits.ts#Service [status=implemented hash=8e7a1b69de0b]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/UsageLimits"
            private let integrations: any CoreIntegration.Integration.Interface
            private let http: any HTTPTransport

            public init(integrations: any CoreIntegration.Integration.Interface, http: any HTTPTransport) {
                self.integrations = integrations
                self.http = http
            }

            public func get() async throws -> Info? {
                guard let conn = try await integrations.activeConnection(IntegrationID(rawValue: "opencode")),
                      let cred = try await integrations.resolveConnection(conn)
                else {
                    return nil
                }
                if case .external = cred { return nil }
                let meta: [String: JSONValue]?
                switch cred {
                case .key(let k): meta = k.metadata
                case .oauth(let o): meta = o.metadata
                case .external: return nil
                }
                guard case .string(let workspaceID) = meta?["orgID"] else { return nil }
                let orgName: String? = { if case .string(let n) = meta?["orgName"] { return n } else { return nil } }()
                let server = ConsoleAccess.server(cred)
                var headers = ConsoleAccess.headers(cred)
                headers["accept"] = "application/json"
                let budgetResp = try await http.send(HTTPRequest(
                    method: "GET",
                    url: "\(server)/api/policies/current-budgets",
                    headers: headers
                ))
                if budgetResp.head.statusCode != 403 && !(200..<300).contains(budgetResp.head.statusCode) {
                    throw UnavailableError(message: "OpenCode Console budgets are unavailable (HTTP \(budgetResp.head.statusCode))")
                }
                let budgets: [UsageLimitsSchema.Budget] = (budgetResp.head.statusCode == 403)
                    ? []
                    : ((try? JSONDecoder().decode([UsageLimitsSchema.Budget].self, from: Data(budgetResp.body))) ?? [])
                return Info(
                    workspace: UsageLimitsSchema.WorkspaceRef(
                        id: workspaceID,
                        name: orgName,
                        usageURL: "\(server)/\(workspaceID)/activity/overview"
                    ),
                    go: nil,
                    budgets: budgets
                )
            }
        }

        // parity: core/src/usage-limits.ts#layer [status=implemented hash=0d75385f1944]
        public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { deps, _ in
            let integrations = try deps.get(CoreIntegration.Integration.Service.serviceKey, as: CoreIntegration.Integration.Service.self)
                ?? CoreIntegration.Integration.Service(credentials: Credential.Service.inMemory())
            let http = deps.get(LayerNodePlatform.httpClientKey, as: (any HTTPTransport).self)
                ?? LayerNodePlatform.FetchTransport { _ in
                    throw PlatformError.unsupportedOnPlatform(Platform.current, operation: "UsageLimits")
                }
            return LayerNode.Output([Service.serviceKey: Service(integrations: integrations, http: http)])
        }

        // parity: core/src/usage-limits.ts#node [status=implemented hash=3156ecc2e047]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            layer,
            [CoreIntegration.Integration.node, LayerNodePlatform.httpClient]
        )
    }

    // MARK: - core/src/aisdk-native.ts

    public enum AISDKNative {
        // parity: core/src/aisdk-native.ts#AISDK_PREFIX [status=implemented hash=8ce9640fd5b7]
        public static let AISDK_PREFIX = "aisdk:"

        // parity: core/src/aisdk-native.ts#isAISDK [status=implemented hash=0167446ea1ce]
        public static func isAISDK(_ value: String?) -> Bool {
            value?.hasPrefix(AISDK_PREFIX) ?? false
        }

        // parity: core/src/aisdk-native.ts#aisdk [status=implemented hash=b17669c46010]
        public static func aisdk(_ value: String) -> String {
            isAISDK(value) ? value : "\(AISDK_PREFIX)\(value)"
        }

        // parity: core/src/aisdk-native.ts#packageName [status=implemented hash=eeb4b3579612]
        public static func packageName(_ value: String?) -> String? {
            guard let value else { return nil }
            if value.hasPrefix("@opencode-ai/ai/") {
                return "@opencode/ai/" + value.dropFirst("@opencode-ai/ai/".count)
            }
            if isAISDK(value) {
                return String(value.dropFirst(AISDK_PREFIX.count))
            }
            return value
        }

        private static func mergeRecord(_ base: [String: JSONValue], _ overlay: [String: JSONValue]) -> [String: JSONValue] {
            var result = base
            for (k, right) in overlay {
                if case .object(let leftObj) = result[k], case .object(let rightObj) = right {
                    result[k] = .object(mergeRecord(leftObj, rightObj))
                } else {
                    result[k] = right
                }
            }
            return result
        }

        // parity: core/src/aisdk-native.ts#mergeOverlay [status=implemented hash=da9285bc84e2]
        public static func mergeOverlay(
            _ base: [String: JSONValue]?,
            _ overlay: [String: JSONValue]?
        ) -> [String: JSONValue]? {
            guard let base else { return overlay }
            guard let overlay else { return base }
            return mergeRecord(base, overlay)
        }

        /// Merges HTTP headers case-insensitively with `overlay` winning over `base`.
        // parity: core/src/aisdk-native.ts#mergeHeaders [status=implemented hash=cc87b9984509]
        public static func mergeHeaders(
            _ base: [String: String]?,
            _ overlay: [String: String]?
        ) -> [String: String]? {
            guard let base else { return overlay }
            guard let overlay else { return base }
            var map: [String: (String, String)] = [:]
            for (k, v) in base { map[k.lowercased()] = (k, v) }
            for (k, v) in overlay { map[k.lowercased()] = (k, v) }
            var out: [String: String] = [:]
            for (_, pair) in map { out[pair.0] = pair.1 }
            return out
        }

        private static let packages: [String: String] = [
            "@ai-sdk/amazon-bedrock": "@opencode/ai/providers/amazon-bedrock",
            "@ai-sdk/alibaba": "@opencode/ai/providers/alibaba/chat",
            "@ai-sdk/anthropic": "@opencode/ai/providers/anthropic",
            "@ai-sdk/azure": "@opencode/ai/providers/azure/responses",
            "@ai-sdk/cerebras": "@opencode/ai/providers/cerebras",
            "@ai-sdk/cohere": "@opencode/ai/providers/cohere",
            "@ai-sdk/deepinfra": "@opencode/ai/providers/deepinfra",
            "@ai-sdk/google": "@opencode/ai/providers/google",
            "@ai-sdk/google-vertex": "@opencode/ai/providers/google-vertex",
            "@ai-sdk/google-vertex/anthropic": "@opencode/ai/providers/google-vertex/messages",
            "@ai-sdk/groq": "@opencode/ai/providers/groq",
            "@ai-sdk/mistral": "@opencode/ai/providers/mistral",
            "@ai-sdk/openai": "@opencode/ai/providers/openai",
            "@ai-sdk/openai-compatible": "@opencode/ai/providers/openai-compatible",
            "@ai-sdk/togetherai": "@opencode/ai/providers/togetherai",
            "@ai-sdk/xai": "@opencode/ai/providers/xai",
            "@ai-sdk/gateway": "@opencode/ai/providers/vercel-ai-gateway",
            "@openrouter/ai-sdk-provider": "@opencode/ai/providers/openrouter",
            "ai-gateway-provider": "@opencode/ai/providers/cloudflare-ai-gateway",
            "venice-ai-sdk-provider": "@opencode/ai/providers/venice",
        ]

        private static func hostProtocols(_ name: String) -> [String: String] {
            [
                "@ai-sdk/openai-compatible": "@opencode/ai/providers/\(name)/chat",
                "@ai-sdk/anthropic": "@opencode/ai/providers/\(name)/messages",
                "@ai-sdk/openai": "@opencode/ai/providers/\(name)/responses",
            ]
        }

        private static let hosts: [String: [String: String]] = [
            "alibaba": hostProtocols("alibaba"),
            "alibaba-cn": hostProtocols("alibaba"),
            "alibaba-coding-plan": hostProtocols("alibaba"),
            "alibaba-coding-plan-cn": hostProtocols("alibaba"),
            "baseten": ["@ai-sdk/openai-compatible": "@opencode/ai/providers/baseten"],
            "cloudflare-ai-gateway": [
                "@ai-sdk/anthropic": "@opencode/ai/providers/cloudflare-ai-gateway",
                "@ai-sdk/openai": "@opencode/ai/providers/cloudflare-ai-gateway",
                "@ai-sdk/openai-compatible": "@opencode/ai/providers/cloudflare-ai-gateway",
                "ai-gateway-provider": "@opencode/ai/providers/cloudflare-ai-gateway",
            ],
            "cohere": ["@ai-sdk/openai-compatible": "@opencode/ai/providers/cohere/chat"],
            "cloudflare-workers-ai": ["@ai-sdk/openai-compatible": "@opencode/ai/providers/cloudflare-workers-ai"],
            "deepseek": ["@ai-sdk/openai-compatible": "@opencode/ai/providers/deepseek"],
            "digitalocean": ["@ai-sdk/openai-compatible": "@opencode/ai/providers/digitalocean"],
            "fireworks-ai": ["@ai-sdk/openai-compatible": "@opencode/ai/providers/fireworks"],
            "google-vertex": [
                "@ai-sdk/openai-compatible": "@opencode/ai/providers/google-vertex/chat",
                "@ai-sdk/mistral": "@opencode/ai/providers/google-vertex/mistral",
            ],
            "kimi-for-coding": hostProtocols("moonshot"),
            "meta": hostProtocols("meta"),
            "minimax": hostProtocols("minimax"),
            "minimax-cn": hostProtocols("minimax"),
            "moonshotai": hostProtocols("moonshot"),
            "moonshotai-cn": hostProtocols("moonshot"),
            "zai": ["@ai-sdk/openai-compatible": "@opencode/ai/providers/zai/chat"],
            "zai-coding-plan": hostProtocols("zai-coding-plan"),
            "zhipuai": ["@ai-sdk/openai-compatible": "@opencode/ai/providers/zai/chat"],
            "zhipuai-coding-plan": hostProtocols("zai-coding-plan"),
        ]

        private static let legacyVertex: [String: String] = [
            "@opencode/ai/providers/google-vertex-chat": "@opencode/ai/providers/google-vertex/chat",
            "@opencode/ai/providers/google-vertex-responses": "@opencode/ai/providers/google-vertex/responses",
            "@opencode/ai/providers/google-vertex-interactions": "@opencode/ai/providers/google-vertex/interactions",
            "@opencode/ai/providers/google-vertex-mistral": "@opencode/ai/providers/google-vertex/mistral",
        ]

        // parity: core/src/aisdk-native.ts#native [status=implemented hash=0d56986aba5b]
        public static func native(
            npm: String,
            providerID: String,
            modelID: String? = nil,
            shape: String? = nil,
            useCompletionUrls: Bool = false
        ) -> String? {
            if let host = hosts[providerID]?[npm] { return host }
            if npm == "@ai-sdk/amazon-bedrock/mantle" {
                guard let modelID else { return "@opencode/ai/providers/amazon-bedrock/mantle" }
                if modelID.contains("anthropic.") { return "@opencode/ai/providers/amazon-bedrock/mantle/messages" }
                return "@opencode/ai/providers/amazon-bedrock/mantle/\(modelID.contains("gpt-oss") ? "chat" : "responses")"
            }
            if npm == "@ai-sdk/azure" && (shape == "completions" || useCompletionUrls) {
                return "@opencode/ai/providers/azure/chat"
            }
            return packages[npm]
        }

        public struct RewriteResult: Equatable, Sendable {
            public let package: String?
            public let settings: [String: JSONValue]?
            public let headers: [String: String]?
            public let body: [String: JSONValue]?
        }

        // parity: core/src/aisdk-native.ts#rewrite [status=implemented hash=62aee618c306]
        public static func rewrite(
            specifier: String?,
            providerID: String,
            canonical: String? = nil,
            modelID: String? = nil,
            settings: [String: JSONValue]? = nil,
            headers: [String: String]? = nil,
            body: [String: JSONValue]? = nil,
            builtins: Set<String> = Provider.builtinPackages
        ) -> RewriteResult {
            guard let specifier, let npm = packageName(specifier) else {
                return RewriteResult(package: specifier, settings: settings, headers: headers, body: body)
            }
            let useCompletion: Bool = if case .bool(true) = settings?["useCompletionUrls"] { true } else { false }
            let replacement: String?
            if isAISDK(specifier) || packages[npm] != nil || hosts[providerID]?[npm] != nil {
                replacement = native(npm: npm, providerID: providerID, modelID: modelID, useCompletionUrls: useCompletion)
            } else if let legacy = legacyVertex[npm] {
                replacement = legacy
            } else if (npm == "@opencode/ai/providers/azure" || npm == "@opencode/ai/providers/azure/responses") && useCompletion {
                replacement = "@opencode/ai/providers/azure/chat"
            } else {
                replacement = builtins.contains(npm) ? npm : nil
            }
            guard let replacement else {
                return RewriteResult(package: specifier, settings: settings, headers: headers, body: body)
            }
            var nextSettings = settings
            if replacement == "@opencode/ai/providers/openai-compatible" && !builtins.contains(specifier) {
                var s = nextSettings ?? [:]
                s["provider"] = .string(canonical ?? providerID)
                nextSettings = s
            }
            return RewriteResult(package: replacement, settings: nextSettings, headers: headers, body: body)
        }
    }

    // MARK: - core/src/aisdk.ts

    public enum AISDK {
        // parity: core/src/aisdk.ts#SDKEvent [status=adapted hash=c3fa02705820]
        public struct SDKEvent: Sendable {
            public let model: CoreModel.Model.RuntimeInfo
            public let package: String
            public let options: [String: JSONValue]

            public init(model: CoreModel.Model.RuntimeInfo, package: String, options: [String: JSONValue] = [:]) {
                self.model = model
                self.package = package
                self.options = options
            }
        }

        // parity: core/src/aisdk.ts#LanguageEvent [status=adapted hash=3099fc0b8ea7]
        public struct LanguageEvent: Sendable {
            public let model: CoreModel.Model.RuntimeInfo
            public let options: [String: JSONValue]

            public init(model: CoreModel.Model.RuntimeInfo, options: [String: JSONValue] = [:]) {
                self.model = model
                self.options = options
            }
        }

        // parity: core/src/aisdk.ts#InitError [status=implemented hash=150c667a2ec2]
        public struct InitError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "AISDK.InitError"
            public let providerID: ProviderSchema.ID
            public let message: String

            public init(providerID: ProviderSchema.ID, message: String) {
                self.providerID = providerID
                self.message = message
            }

            public var description: String { "AISDK init failed for \(providerID.rawValue): \(message)" }
        }

        // parity: core/src/aisdk.ts#Interface [status=adapted hash=2b99a6805294]
        public protocol Interface: Sendable {
            func registerSDKHook(_ hook: @escaping @Sendable (SDKEvent) async -> Void) async -> CoreState.Registration
            func registerLanguageHook(_ hook: @escaping @Sendable (LanguageEvent) async -> Void) async -> CoreState.Registration
            func runSDK(_ event: SDKEvent) async -> SDKEvent
            func runLanguage(_ event: LanguageEvent) async -> LanguageEvent
        }

        // parity: core/src/aisdk.ts#Service [status=adapted hash=05b004040973]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/AISDK"

            private struct Hooks: Sendable {
                var nextID: UInt64 = 1
                var sdk: [(id: UInt64, fn: @Sendable (SDKEvent) async -> Void)] = []
                var language: [(id: UInt64, fn: @Sendable (LanguageEvent) async -> Void)] = []
            }

            private let hooks = Mutex(Hooks())

            public init() {}

            public func registerSDKHook(_ hook: @escaping @Sendable (SDKEvent) async -> Void) async -> CoreState.Registration {
                let id = hooks.withLock { h -> UInt64 in
                    let cur = h.nextID; h.nextID += 1; h.sdk.append((cur, hook)); return cur
                }
                return CoreState.Registration { [self] in self.hooks.withLock { $0.sdk.removeAll { $0.id == id } } }
            }

            public func registerLanguageHook(_ hook: @escaping @Sendable (LanguageEvent) async -> Void) async -> CoreState.Registration {
                let id = hooks.withLock { h -> UInt64 in
                    let cur = h.nextID; h.nextID += 1; h.language.append((cur, hook)); return cur
                }
                return CoreState.Registration { [self] in self.hooks.withLock { $0.language.removeAll { $0.id == id } } }
            }

            public func runSDK(_ event: SDKEvent) async -> SDKEvent {
                let list = hooks.withLock { $0.sdk.map(\.fn) }
                for fn in list { await fn(event) }
                return event
            }

            public func runLanguage(_ event: LanguageEvent) async -> LanguageEvent {
                let list = hooks.withLock { $0.language.map(\.fn) }
                for fn in list { await fn(event) }
                return event
            }
        }

        // parity: core/src/aisdk.ts#locationLayer [status=implemented hash=ca1ce48458cd]
        public static let locationLayer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { _, _ in
            LayerNode.Output([Service.serviceKey: Service()])
        }
    }

    // MARK: - core/src/provider.ts

    public enum Provider {
        // parity: core/src/provider.ts#ID [status=implemented hash=1626b0b12933]
        public typealias ID = ProviderSchema.ID

        // parity: core/src/provider.ts#Request [status=implemented hash=36d08aee6711]
        public typealias Request = ProviderSchema.Request

        // parity: core/src/provider.ts#Compaction [status=implemented hash=d6bf79b132b1]
        public typealias Compaction = ProviderSchema.Compaction

        // parity: core/src/provider.ts#Cache [status=implemented hash=d10dd40b0f33]
        public typealias Cache = ProviderSchema.Cache

        // parity: core/src/provider.ts#Transport [status=implemented hash=5d8d180a9539]
        public typealias Transport = ProviderSchema.Transport

        // parity: core/src/provider.ts#Settings [status=implemented hash=4664afef7bae]
        public typealias Settings = ProviderSchema.Settings

        // parity: core/src/provider.ts#Info [status=implemented hash=2df71e07fd12]
        public typealias Info = ProviderSchema.Info

        // parity: core/src/provider.ts#MutableInfo [status=adapted hash=ea40965711c4]
        public typealias MutableInfo = ProviderSchema.Info

        // parity: core/src/provider.ts#LoadError [status=implemented hash=697a5f957d85]
        public struct LoadError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Provider.LoadError"
            public let package: String
            public let message: String

            public init(package: String, message: String) {
                self.package = package
                self.message = message
            }

            public var description: String { "Failed to load provider package '\(package)': \(message)" }
        }

        /// All native `@opencode/ai/providers/*` entrypoints bundled with OpenCodeCore.
        // parity: core/src/provider.ts#builtinPackages [status=implemented hash=16df8dd416bf]
        public static let builtinPackages: Set<String> = [
            "@opencode/ai/providers/alibaba",
            "@opencode/ai/providers/alibaba/chat",
            "@opencode/ai/providers/alibaba/messages",
            "@opencode/ai/providers/alibaba/responses",
            "@opencode/ai/providers/alibaba/images",
            "@opencode/ai/providers/alibaba/embeddings",
            "@opencode/ai/providers/amazon-bedrock",
            "@opencode/ai/providers/amazon-bedrock/mantle",
            "@opencode/ai/providers/amazon-bedrock/mantle/chat",
            "@opencode/ai/providers/amazon-bedrock/mantle/messages",
            "@opencode/ai/providers/amazon-bedrock/mantle/responses",
            "@opencode/ai/providers/anthropic",
            "@opencode/ai/providers/anthropic-compatible",
            "@opencode/ai/providers/azure",
            "@opencode/ai/providers/azure/chat",
            "@opencode/ai/providers/azure/responses",
            "@opencode/ai/providers/azure/images",
            "@opencode/ai/providers/azure/embeddings",
            "@opencode/ai/providers/azure/messages",
            "@opencode/ai/providers/baseten",
            "@opencode/ai/providers/baseten/decisions",
            "@opencode/ai/providers/byteplus/videos",
            "@opencode/ai/providers/cerebras",
            "@opencode/ai/providers/cloudflare-ai-gateway",
            "@opencode/ai/providers/cloudflare-ai-gateway/decisions",
            "@opencode/ai/providers/cloudflare-workers-ai",
            "@opencode/ai/providers/cloudflare-workers-ai/decisions",
            "@opencode/ai/providers/cloudflare-workers-ai/images",
            "@opencode/ai/providers/cohere",
            "@opencode/ai/providers/cohere/chat",
            "@opencode/ai/providers/cohere/embeddings",
            "@opencode/ai/providers/deepinfra",
            "@opencode/ai/providers/deepinfra/embeddings",
            "@opencode/ai/providers/deepseek",
            "@opencode/ai/providers/digitalocean",
            "@opencode/ai/providers/digitalocean/decisions",
            "@opencode/ai/providers/digitalocean/embeddings",
            "@opencode/ai/providers/digitalocean/images",
            "@opencode/ai/providers/digitalocean/responses",
            "@opencode/ai/providers/fireworks",
            "@opencode/ai/providers/fireworks/embeddings",
            "@opencode/ai/providers/google",
            "@opencode/ai/providers/google/decisions",
            "@opencode/ai/providers/google/interactions",
            "@opencode/ai/providers/google/embeddings",
            "@opencode/ai/providers/google/images",
            "@opencode/ai/providers/google/videos",
            "@opencode/ai/providers/google-vertex",
            "@opencode/ai/providers/google-vertex/chat",
            "@opencode/ai/providers/google-vertex/gemini",
            "@opencode/ai/providers/google-vertex/interactions",
            "@opencode/ai/providers/google-vertex/messages",
            "@opencode/ai/providers/google-vertex/mistral",
            "@opencode/ai/providers/google-vertex/responses",
            "@opencode/ai/providers/google-vertex/embeddings",
            "@opencode/ai/providers/google-vertex/images",
            "@opencode/ai/providers/google-vertex-messages",
            "@opencode/ai/providers/groq",
            "@opencode/ai/providers/meta",
            "@opencode/ai/providers/meta/chat",
            "@opencode/ai/providers/meta/images",
            "@opencode/ai/providers/meta/messages",
            "@opencode/ai/providers/meta/responses",
            "@opencode/ai/providers/minimax",
            "@opencode/ai/providers/minimax/chat",
            "@opencode/ai/providers/minimax/images",
            "@opencode/ai/providers/minimax/messages",
            "@opencode/ai/providers/minimax/responses",
            "@opencode/ai/providers/minimax/videos",
            "@opencode/ai/providers/mistral",
            "@opencode/ai/providers/moonshot",
            "@opencode/ai/providers/moonshot/chat",
            "@opencode/ai/providers/moonshot/messages",
            "@opencode/ai/providers/moonshot/responses",
            "@opencode/ai/providers/openai",
            "@opencode/ai/providers/openai/chat",
            "@opencode/ai/providers/openai/responses",
            "@opencode/ai/providers/openai/images",
            "@opencode/ai/providers/openai/embeddings",
            "@opencode/ai/providers/openai-compatible",
            "@opencode/ai/providers/openai-compatible/responses",
            "@opencode/ai/providers/openai-compatible/images",
            "@opencode/ai/providers/openai-compatible/decisions",
            "@opencode/ai/providers/openai-compatible/embeddings",
            "@opencode/ai/providers/openai-compatible-responses",
            "@opencode/ai/providers/opencode/decisions",
            "@opencode/ai/providers/openrouter",
            "@opencode/ai/providers/openrouter/decisions",
            "@opencode/ai/providers/openrouter/embeddings",
            "@opencode/ai/providers/openrouter/images",
            "@opencode/ai/providers/openrouter/videos",
            "@opencode/ai/providers/openrouter/responses",
            "@opencode/ai/providers/togetherai",
            "@opencode/ai/providers/typesafe-ai/decisions",
            "@opencode/ai/providers/venice",
            "@opencode/ai/providers/venice/responses",
            "@opencode/ai/providers/volcengine/videos",
            "@opencode/ai/providers/vercel-ai-gateway",
            "@opencode/ai/providers/vercel-ai-gateway/chat",
            "@opencode/ai/providers/vercel-ai-gateway/messages",
            "@opencode/ai/providers/vercel-ai-gateway/responses",
            "@opencode/ai/providers/vercel-ai-gateway/decisions",
            "@opencode/ai/providers/vercel-ai-gateway/images",
            "@opencode/ai/providers/vercel-ai-gateway/embeddings",
            "@opencode/ai/providers/xai",
            "@opencode/ai/providers/xai/images",
            "@opencode/ai/providers/xai/videos",
            "@opencode/ai/providers/zai",
            "@opencode/ai/providers/zai/chat",
            "@opencode/ai/providers/zai/images",
            "@opencode/ai/providers/zai-coding-plan",
            "@opencode/ai/providers/zai-coding-plan/chat",
            "@opencode/ai/providers/zai-coding-plan/messages",
            "@opencode/ai/providers/zai-coding-plan/responses",
        ]

        // parity: core/src/provider.ts#loadPackage [status=adapted hash=49c1f8da07ea]
        public static func loadPackage(_ input: String) throws(LoadError) -> String {
            guard let specifier = AISDKNative.packageName(input) else {
                throw LoadError(package: input, message: "Empty package specifier")
            }
            guard builtinPackages.contains(specifier) else {
                throw LoadError(package: specifier, message: "Provider package \(specifier) is not installed")
            }
            return specifier
        }

        private static let settingsKeys: Set<String> = [
            "timeout", "headerTimeout", "chunkTimeout", "compaction", "cache", "transport", "encoding", "tls",
        ]
        private static let providerOnlyKeys: Set<String> = [
            "timeout", "headerTimeout", "chunkTimeout", "cache", "transport", "tls",
        ]

        // parity: core/src/provider.ts#nativeSettings [status=implemented hash=b39ff87dc49c]
        public static func nativeSettings(_ settings: [String: JSONValue]) -> [String: JSONValue] {
            settings.filter { !settingsKeys.contains($0.key) }
        }

        // parity: core/src/provider.ts#modelSettings [status=implemented hash=a64f3e3a7261]
        public static func modelSettings(_ settings: [String: JSONValue]?) -> [String: JSONValue]? {
            settings?.filter { !providerOnlyKeys.contains($0.key) }
        }

        // parity: core/src/provider.ts#DEFAULT_TIMEOUT_MS [status=implemented hash=d4b737a21685]
        public static let DEFAULT_TIMEOUT_MS: Int = 300_000

        // parity: core/src/provider.ts#DEFAULT_CHUNK_TIMEOUT_MS [status=implemented hash=ad58a6869793]
        public static let DEFAULT_CHUNK_TIMEOUT_MS: Int = 900_000

        // parity: core/src/provider.ts#timeout [status=implemented hash=fa11d86c66aa]
        public static func timeout(_ value: JSONValue?) -> ProviderSchema.TimeoutOption? {
            guard let value else { return nil }
            switch value {
            case .bool(false): return .disabled
            case .int(let i) where i > 0: return .milliseconds(Double(i))
            case .double(let d) where d.isFinite && d > 0: return .milliseconds(d)
            default: return nil
            }
        }

        public struct ResolvedTimeouts: Equatable, Hashable, Sendable {
            public let timeout: ProviderSchema.TimeoutOption?
            public let headerTimeout: ProviderSchema.TimeoutOption
            public let chunkTimeout: ProviderSchema.TimeoutOption
        }

        // parity: core/src/provider.ts#timeouts [status=implemented hash=54e19beacd34]
        public static func timeouts(_ settings: [String: JSONValue]) -> ResolvedTimeouts {
            ResolvedTimeouts(
                timeout: timeout(settings["timeout"]),
                headerTimeout: timeout(settings["headerTimeout"]) ?? .milliseconds(Double(DEFAULT_TIMEOUT_MS)),
                chunkTimeout: timeout(settings["chunkTimeout"]) ?? .milliseconds(Double(DEFAULT_CHUNK_TIMEOUT_MS))
            )
        }

        // parity: core/src/provider.ts#encoding [status=implemented hash=6425971628ad]
        public static func encoding(_ settings: [String: JSONValue]) -> ProviderSchema.Encoding? {
            guard case .string(let raw) = settings["encoding"] else { return nil }
            return ProviderSchema.Encoding(rawValue: raw)
        }

        // parity: core/src/provider.ts#tls [status=implemented hash=86da746d975c]
        public static func tls(_ settings: [String: JSONValue]) -> ProviderSchema.Tls? {
            guard case .object(let obj) = settings["tls"],
                  case .string(let cert) = obj["cert"], !cert.isEmpty,
                  case .string(let key) = obj["key"], !key.isEmpty
            else { return nil }
            let passphrase: String? = { if case .string(let p) = obj["passphrase"] { return p } else { return nil } }()
            return ProviderSchema.Tls(cert: cert, key: key, passphrase: passphrase)
        }

        // parity: core/src/provider.ts#Definition [status=implemented hash=5744e1eea014]
        public struct Definition: Equatable, Sendable {
            public var provider: Info
            public var models: [ModelSchema.ID: ModelSchema.Info]
            public var sourceConnection: CoreIntegration.Connection.Info?

            public init(
                provider: Info,
                models: [ModelSchema.ID: ModelSchema.Info] = [:],
                sourceConnection: CoreIntegration.Connection.Info? = nil
            ) {
                self.provider = provider
                self.models = models
                self.sourceConnection = sourceConnection
            }
        }

        // parity: core/src/provider.ts#Editor [status=implemented hash=609ad4965292]
        public final class Editor: @unchecked Sendable {
            internal var records: [ID: Definition]
            internal init(records: [ID: Definition]) { self.records = records }

            public func list() -> [Definition] {
                Array(records.values).sorted { $0.provider.id.rawValue < $1.provider.id.rawValue }
            }

            public func get(_ id: ID) -> Definition? { records[id] }

            public func add(info: Info, models: [ModelSchema.Info], sourceConnection: CoreIntegration.Connection.Info? = nil) {
                var indexed: [ModelSchema.ID: ModelSchema.Info] = [:]
                for m in models { indexed[m.id] = m }
                records[info.id] = Definition(provider: info, models: indexed, sourceConnection: sourceConnection)
            }

            public func update(_ id: ID, _ fn: (Info) -> Info) {
                let current = records[id]?.provider ?? Info.empty(id)
                let next = fn(current)
                var def = records[id] ?? Definition(provider: next)
                def.provider = next
                records[id] = def
            }

            public func remove(_ id: ID) { records.removeValue(forKey: id) }

            public func setModels(providerID: ID, models: [ModelSchema.Info]) {
                var def = records[providerID] ?? Definition(provider: Info.empty(providerID))
                var indexed: [ModelSchema.ID: ModelSchema.Info] = [:]
                for m in models { indexed[m.id] = m }
                def.models = indexed
                records[providerID] = def
            }

            public func removeModel(providerID: ID, modelID: ModelSchema.ID) {
                records[providerID]?.models.removeValue(forKey: modelID)
            }
        }

        // parity: core/src/provider.ts#Snapshot [status=implemented hash=5c60d78372d7]
        public struct Snapshot: Equatable, Sendable {
            public let records: [ID: Definition]
            public let available: [Definition]
            public let providers: [Info]

            public init(records: [ID: Definition], available: [Definition], providers: [Info]) {
                self.records = records
                self.available = available
                self.providers = providers
            }
        }

        // parity: core/src/provider.ts#Interface [status=implemented hash=f138fd3dc5a1]
        public protocol Interface: CoreState.Transformable where Editor == Provider.Editor {
            func get(_ providerID: ID) async -> Info?
            func all() async -> [Info]
            func available() async throws -> [Info]
            func snapshot() async throws -> Snapshot
        }

        // parity: core/src/provider.ts#Service [status=implemented hash=ca8b88561d70]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/Provider"
            private let integrations: (any CoreIntegration.Integration.Interface)?
            private let state: CoreState.Store<[ID: Definition], Editor>

            public init(integrations: (any CoreIntegration.Integration.Interface)? = nil) {
                self.integrations = integrations
                self.state = CoreState.create(CoreState.Options(
                    name: "provider",
                    initial: { [:] },
                    makeEditor: { Editor(records: $0) },
                    commitEditor: { $0.records }
                ))
            }

            @discardableResult
            public func transform(_ update: @escaping @Sendable (Editor) throws -> Void) async throws -> CoreState.Registration {
                try await state.transform(update)
            }

            public func reload() async { await state.reload() }

            public func get(_ providerID: ID) async -> Info? {
                state.get()[providerID]?.provider
            }

            public func all() async -> [Info] {
                state.get().values.map(\.provider).sorted { $0.id.rawValue < $1.id.rawValue }
            }

            public func available() async throws -> [Info] {
                try await snapshot().providers
            }

            public func snapshot() async throws -> Snapshot {
                let records = state.get()
                let integrationList = (try? await integrations?.list()) ?? []
                var byID: [IntegrationID: IntegrationSchema.Info] = [:]
                for item in integrationList { byID[item.id] = item }
                let avail = records.values.sorted { $0.provider.id.rawValue < $1.provider.id.rawValue }.filter { rec in
                    if rec.provider.activation == .disabled { return false }
                    let intID = rec.provider.integrationID ?? IntegrationID(rawValue: rec.provider.id.rawValue)
                    let integration = byID[intID]
                    if let sourceConn = rec.sourceConnection,
                       CoreIntegration.Connection.key(sourceConn) != CoreIntegration.Connection.key(integration?.connections.first) {
                        return false
                    }
                    if rec.provider.activation == .enabled { return true }
                    if !(integration?.connections.isEmpty ?? true) { return true }
                    return rec.provider.integrationID == nil && integration == nil
                }
                return Snapshot(records: records, available: avail, providers: avail.map(\.provider))
            }
        }

        // parity: core/src/provider.ts#node [status=implemented hash=4bdab79916d6]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer { deps, _ in
                let integrations = deps.get(CoreIntegration.Integration.Service.serviceKey, as: CoreIntegration.Integration.Service.self)
                return LayerNode.Output([Service.serviceKey: Service(integrations: integrations)])
            },
            [CoreIntegration.Integration.node]
        )
    }
}

// MARK: - CoreModel (`model.ts`, `variant.ts`, `model-retry.ts`, `model-resolver.ts`, `models-dev*`, `github-copilot/models.ts`)

public enum CoreModel {
    // MARK: - core/src/model.ts

    public enum Model {
        // parity: core/src/model.ts#ID [status=implemented hash=955c1a4a8db3]
        public typealias ID = ModelSchema.ID

        // parity: core/src/model.ts#VariantID [status=implemented hash=c5df48cb1423]
        public typealias VariantID = ModelSchema.VariantID

        // parity: core/src/model.ts#Family [status=implemented hash=08afa78ee4f9]
        public typealias Family = ModelSchema.Family

        // parity: core/src/model.ts#ReasoningField [status=implemented hash=babc2e47cbe6]
        public typealias ReasoningField = ModelCompatibilitySchema.ReasoningField

        // parity: core/src/model.ts#Compatibility [status=implemented hash=653f06ff7d0c]
        public typealias Compatibility = ModelCompatibilitySchema.Compatibility

        // parity: core/src/model.ts#Capabilities [status=implemented hash=bcd00b803b4e]
        public typealias Capabilities = ModelSchema.Capabilities

        // parity: core/src/model.ts#Cost [status=implemented hash=76f6a457759c]
        public typealias Cost = ModelSchema.Cost

        // parity: core/src/model.ts#Type [status=implemented hash=c7432aefdb22]
        public typealias ModelType = ModelSchema.ModelType

        // parity: core/src/model.ts#Ref [status=implemented hash=48b98a625089]
        public typealias Ref = ModelSchema.Ref

        // parity: core/src/model.ts#Info [status=implemented hash=fb57be7ef9a9]
        public typealias Info = ModelSchema.Info

        // parity: core/src/model.ts#RuntimeInfo [status=implemented hash=68673c52d892]
        public struct RuntimeInfo: Equatable, Sendable {
            public let info: Info
            public let settings: [String: JSONValue]?

            public init(info: Info, settings: [String: JSONValue]? = nil) {
                self.info = info
                self.settings = settings
            }
        }

        // parity: core/src/model.ts#MutableInfo [status=adapted hash=ea40965711c4]
        public typealias MutableInfo = Info

        // parity: core/src/model.ts#mergeCapabilities [status=implemented hash=ad0f35e0d357]
        public static func mergeCapabilities(
            tools: Bool? = nil,
            freeform: [ToolSchema.FreeformFormat]? = nil,
            input: [String]? = nil,
            output: [String]? = nil,
            temperature: Bool? = nil,
            base: Capabilities?
        ) -> Capabilities {
            let fallback = base ?? Capabilities.default()
            return Capabilities(
                tools: tools ?? fallback.tools,
                freeform: freeform ?? base?.freeform,
                input: input ?? fallback.input,
                output: output ?? fallback.output,
                temperature: temperature ?? base?.temperature
            )
        }

        // parity: core/src/model.ts#supportsText [status=implemented hash=0477c0186cfa]
        public static func supportsText(_ model: Info) -> Bool {
            let inText = model.capabilities.input.isEmpty || model.capabilities.input.contains { $0.hasPrefix("text") }
            let outText = model.capabilities.output.isEmpty || model.capabilities.output.contains { $0.hasPrefix("text") }
            return inText && outText
        }

        // parity: core/src/model.ts#compatibility [status=implemented hash=20df5eb5f641]
        public static func compatibility(_ input: JSONValue) -> Compatibility? {
            switch input {
            case .string(let s):
                return Compatibility(reasoningField: ReasoningField(rawValue: s))
            case .object(let obj):
                if case .string(let field) = obj["field"] {
                    return Compatibility(reasoningField: ReasoningField(rawValue: field))
                }
                return nil
            default:
                return nil
            }
        }

        // parity: core/src/model.ts#parse [status=implemented hash=04551609f85a]
        public static func parse(_ input: String) -> (providerID: ProviderSchema.ID, modelID: ID) {
            guard let slash = input.firstIndex(of: "/") else {
                return (ProviderSchema.ID(rawValue: input), ID(rawValue: ""))
            }
            return (
                ProviderSchema.ID(rawValue: String(input[..<slash])),
                ID(rawValue: String(input[input.index(after: slash)...]))
            )
        }

        public struct Data: Equatable, Sendable {
            public var models: [ProviderSchema.ID: [ID: Info]]
            public var defaultModel: (providerID: ProviderSchema.ID, modelID: ID)?

            public init(models: [ProviderSchema.ID: [ID: Info]] = [:], defaultModel: (ProviderSchema.ID, ID)? = nil) {
                self.models = models
                self.defaultModel = defaultModel
            }

            public static func == (lhs: Data, rhs: Data) -> Bool {
                lhs.models == rhs.models &&
                    lhs.defaultModel?.providerID == rhs.defaultModel?.providerID &&
                    lhs.defaultModel?.modelID == rhs.defaultModel?.modelID
            }
        }

        // parity: core/src/model.ts#Editor [status=implemented hash=ace414c851d0]
        public final class Editor: @unchecked Sendable {
            internal var data: Data
            private let providerRecords: [ProviderSchema.ID: CoreProvider.Provider.Definition]

            internal init(data: Data, providerRecords: [ProviderSchema.ID: CoreProvider.Provider.Definition]) {
                self.data = data
                self.providerRecords = providerRecords
            }

            public func list(providerID: ProviderSchema.ID? = nil) -> [Info] {
                if let pid = providerID {
                    return data.models[pid].map { Array($0.values) } ?? []
                }
                return data.models.values.flatMap(\.values)
            }

            public func get(providerID: ProviderSchema.ID, modelID: ID) -> Info? {
                data.models[providerID]?[modelID]
            }

            public func update(providerID: ProviderSchema.ID, modelID: ID, _ fn: (Info) -> Info) {
                guard data.models[providerID] != nil else { return }
                let base = data.models[providerID]?[modelID] ?? Info.default(providerID: providerID, id: modelID)
                data.models[providerID]?[modelID] = fn(base)
            }

            public func remove(providerID: ProviderSchema.ID, modelID: ID) {
                data.models[providerID]?.removeValue(forKey: modelID)
            }

            public func setDefault(providerID: ProviderSchema.ID, modelID: ID) {
                data.defaultModel = (providerID, modelID)
            }

            public func listProviders() -> [CoreProvider.Provider.Definition] {
                Array(providerRecords.values)
            }

            public func getProvider(_ providerID: ProviderSchema.ID) -> CoreProvider.Provider.Definition? {
                providerRecords[providerID]
            }
        }

        // parity: core/src/model.ts#Interface [status=implemented hash=5fc8d73f49ef]
        public protocol Interface: CoreState.Transformable where Editor == Model.Editor {
            func get(providerID: ProviderSchema.ID, modelID: ID) async throws -> Info?
            func all() async throws -> [Info]
            func available(types: [ModelType]?) async throws -> [Info]
            func defaultModel() async throws -> Info?
            func small(providerID: ProviderSchema.ID) async throws -> Info?
        }

        private static let preferredFree: [String] = [
            "big-pickle",
            "deepseek-v4.1-flash-free",
            "muse-spark-1.3-contributor-free",
        ]

        private static let smallFamilies: [String] = [
            "gpt-luna", "gemini-flash-lite", "gemini-flash", "claude-haiku",
        ]

        // parity: core/src/model.ts#Service [status=implemented hash=8d307b2f5cb6]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/Model"
            private final class SnapshotBox: Sendable {
                let value = Mutex<CoreProvider.Provider.Snapshot?>(nil)
            }

            private let providers: any CoreProvider.Provider.Interface
            private let latestSnapshot = SnapshotBox()
            private let state: CoreState.Store<Data, Editor>

            public init(providers: any CoreProvider.Provider.Interface) {
                self.providers = providers
                let snapBox = self.latestSnapshot
                self.state = CoreState.create(CoreState.Options(
                    name: "model",
                    initial: {
                        var seed: [ProviderSchema.ID: [ID: Info]] = [:]
                        if let snap = snapBox.value.withLock({ $0 }) {
                            for def in snap.available {
                                seed[def.provider.id] = def.models
                            }
                        }
                        return Data(models: seed)
                    },
                    makeEditor: { data in
                        Editor(data: data, providerRecords: snapBox.value.withLock { $0?.records ?? [:] })
                    },
                    commitEditor: { $0.data }
                ))
            }

            private func syncProviders() async throws -> CoreProvider.Provider.Snapshot {
                let snap = try await providers.snapshot()
                let changed = latestSnapshot.value.withLock { cur -> Bool in
                    if cur == snap { return false }
                    cur = snap
                    return true
                }
                if changed { state.invalidate() }
                return snap
            }

            @discardableResult
            public func transform(_ update: @escaping @Sendable (Editor) throws -> Void) async throws -> CoreState.Registration {
                _ = try await syncProviders()
                return try await state.transform(update)
            }

            public func reload() async {
                _ = try? await syncProviders()
                await state.reload()
            }

            private func materialized() async throws -> (data: Data, allChat: [Info], availableChat: [Info], other: [ModelType: [Info]], byProvider: [ProviderSchema.ID: [ID: Info]]) {
                let snap = try await syncProviders()
                let data = state.get()
                var byProvider: [ProviderSchema.ID: [ID: Info]] = [:]
                var other: [ModelType: [Info]] = [:]
                for (pid, models) in data.models {
                    let provider = snap.records[pid]?.provider
                    var chatMap: [ID: Info] = [:]
                    for (mid, m) in models {
                        let merged = Info(
                            id: m.id,
                            modelID: m.modelID,
                            providerID: m.providerID,
                            canonical: provider?.canonical ?? m.canonical,
                            type: m.type,
                            family: m.family,
                            name: m.name,
                            compatibility: ModelCompatibilitySchema.resolve(model: m.compatibility, provider: provider?.compatibility),
                            package: m.package ?? provider?.package,
                            settings: m.settings,
                            headers: CoreProvider.AISDKNative.mergeHeaders(provider?.headers, m.headers),
                            body: CoreProvider.AISDKNative.mergeOverlay(provider?.body, m.body),
                            capabilities: m.capabilities,
                            variants: m.variants,
                            time: m.time,
                            cost: m.cost,
                            status: m.status,
                            enabled: m.enabled,
                            limit: m.limit
                        )
                        let mType = merged.type ?? .chat
                        if mType == .chat {
                            chatMap[mid] = merged
                        } else if merged.enabled {
                            other[mType, default: []].append(merged)
                        }
                    }
                    byProvider[pid] = chatMap
                }
                let allChat = byProvider.values.flatMap(\.values).sorted { $0.time.released > $1.time.released }
                var availChat = allChat.filter(\.enabled)
                let freeOnly = !availChat.isEmpty && availChat.allSatisfy { m in
                    m.providerID == ProviderSchema.ID.opencode && !m.cost.contains { $0.input.rawValue > 0 }
                }
                if freeOnly {
                    let picks = Model.preferredFree.compactMap { pid in availChat.first { $0.id.rawValue == pid } }
                    let pickIDs = Set(picks.map(\.id))
                    availChat = picks + availChat.filter { !pickIDs.contains($0.id) }
                }
                for (k, v) in other { other[k] = v.sorted { $0.time.released > $1.time.released } }
                return (data, allChat, availChat, other, byProvider)
            }

            public func get(providerID: ProviderSchema.ID, modelID: ID) async throws -> Info? {
                try await materialized().byProvider[providerID]?[modelID]
            }

            public func all() async throws -> [Info] {
                try await materialized().allChat
            }

            public func available(types: [ModelType]? = nil) async throws -> [Info] {
                let mat = try await materialized()
                guard let types, !types.isEmpty else { return mat.availableChat }
                var seen: Set<ModelType> = []
                var out: [Info] = []
                for t in types where seen.insert(t).inserted {
                    if t == .chat {
                        out.append(contentsOf: mat.availableChat)
                    } else if let list = mat.other[t] {
                        out.append(contentsOf: list)
                    }
                }
                return out
            }

            public func defaultModel() async throws -> Info? {
                let mat = try await materialized()
                if let req = mat.data.defaultModel, let found = mat.byProvider[req.providerID]?[req.modelID], found.enabled {
                    return found
                }
                return mat.availableChat.first(where: Model.supportsText)
            }

            public func small(providerID: ProviderSchema.ID) async throws -> Info? {
                let mat = try await materialized()
                let candidates = mat.availableChat.filter {
                    $0.providerID == providerID && $0.status == .active && Model.supportsText($0)
                }
                for fam in Model.smallFamilies {
                    if let hit = candidates.first(where: { $0.family?.rawValue == fam }) { return hit }
                }
                return nil
            }
        }

        // parity: core/src/model.ts#node [status=implemented hash=dd2ba709da98]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer { deps, _ in
                let prov = deps.get(CoreProvider.Provider.Service.serviceKey, as: CoreProvider.Provider.Service.self)
                    ?? CoreProvider.Provider.Service()
                return LayerNode.Output([Service.serviceKey: Service(providers: prov)])
            },
            [CoreProvider.Provider.node]
        )
    }

    // MARK: - core/src/variant.ts

    public enum Variant {
        // parity: core/src/variant.ts#Support [status=implemented hash=219be3c06c96]
        public enum Support: Equatable, Hashable, Sendable {
            case effort(values: [String]?)
            case toggle
            case budgetTokens(min: Int?, max: Int?)
        }

        // parity: core/src/variant.ts#supports [status=implemented hash=d29085ba467b]
        public static func supports(_ reasoning: ConfigProviderSchema.Reasoning) -> [Support] {
            switch reasoning {
            case .unsupported:
                return []
            case .supported(let toggle, let effort, let budget):
                var out: [Support] = []
                if toggle == true { out.append(.toggle) }
                if let effort {
                    out.append(.effort(values: effort.filter { $0 != "default" }))
                }
                if let budget {
                    out.append(.budgetTokens(min: budget.min, max: budget.max))
                }
                return out
            }
        }

        private static let defaultEfforts = ["low", "medium", "high"]
        private static let anthropicOutputMax = 32_000
        private static let alibabaBudgetMax = 64_000

        private static func makeVariant(
            _ id: String,
            settings: [String: JSONValue]? = nil,
            body: [String: JSONValue]? = nil
        ) -> ModelSchema.Variant {
            ModelSchema.Variant(
                id: ModelSchema.VariantID(rawValue: id),
                settings: settings.map { ModelSchema.VariantSettings(extra: $0) },
                headers: nil,
                body: body
            )
        }

        private static func makeBudgets(
            model: ModelSchema.Info,
            minVal: Int?,
            maxVal: Int?,
            ceiling: Int,
            build: (Int) -> (settings: [String: JSONValue]?, body: [String: JSONValue]?)
        ) -> [ModelSchema.Variant] {
            let maxLimit = min(maxVal ?? (ceiling - 1), model.limit.output - 1, ceiling - 1)
            guard maxLimit > 0 else { return [] }
            let high = min(max(minVal ?? 0, (maxLimit + 1) / 2), maxLimit)
            let h = build(high)
            let m = build(maxLimit)
            return [
                makeVariant("high", settings: h.settings, body: h.body),
                makeVariant("max", settings: m.settings, body: m.body),
            ]
        }

        private static func resolveProtocol(
            package: String,
            model: ModelSchema.Info,
            support: Support
        ) -> [ModelSchema.Variant] {
            let responsesPackages: Set<String> = [
                "@opencode/ai/providers/openai", "@opencode/ai/providers/openai/responses",
                "@opencode/ai/providers/azure", "@opencode/ai/providers/azure/responses",
                "@opencode/ai/providers/amazon-bedrock/mantle", "@opencode/ai/providers/amazon-bedrock/mantle/responses",
                "@opencode/ai/providers/alibaba/responses", "@opencode/ai/providers/meta",
                "@opencode/ai/providers/meta/responses", "@opencode/ai/providers/minimax/responses",
                "@opencode/ai/providers/moonshot/responses", "@opencode/ai/providers/zai-coding-plan/responses",
            ]
            let openResponsesPackages: Set<String> = [
                "@opencode/ai/providers/openai-compatible/responses", "@opencode/ai/providers/openai-compatible-responses",
                "@opencode/ai/providers/google-vertex/responses", "@opencode/ai/providers/xai",
                "@opencode/ai/providers/digitalocean/responses", "@opencode/ai/providers/openrouter/responses",
                "@opencode/ai/providers/venice/responses",
            ]
            let anthropicPackages: Set<String> = [
                "@opencode/ai/providers/anthropic", "@opencode/ai/providers/anthropic-compatible",
                "@opencode/ai/providers/amazon-bedrock/mantle/messages", "@opencode/ai/providers/azure/messages",
                "@opencode/ai/providers/google-vertex/messages", "@opencode/ai/providers/google-vertex-messages",
                "@opencode/ai/providers/meta/messages",
            ]
            let geminiPackages: Set<String> = [
                "@opencode/ai/providers/google", "@opencode/ai/providers/google-vertex",
                "@opencode/ai/providers/google-vertex/gemini", "@opencode/ai/providers/google/images",
                "@opencode/ai/providers/google-vertex/images",
            ]
            let googleInteractionsPackages: Set<String> = [
                "@opencode/ai/providers/google/interactions", "@opencode/ai/providers/google-vertex/interactions",
            ]

            if responsesPackages.contains(package) || openResponsesPackages.contains(package) {
                guard case .effort(let vals) = support else { return [] }
                let list = vals ?? (responsesPackages.contains(package) ? ["none", "minimal", "low", "medium", "high", "xhigh"] : defaultEfforts)
                return list.map { effort in
                    makeVariant(effort, settings: [
                        "reasoningEffort": .string(effort),
                        "reasoningSummary": .string("auto"),
                        "include": .array([.string("reasoning.encrypted_content")]),
                    ])
                }
            }
            if anthropicPackages.contains(package) {
                let adaptive: JSONValue = .object(["type": .string("adaptive"), "display": .string("summarized")])
                switch support {
                case .effort(let vals):
                    let list = vals ?? ["low", "medium", "high", "max"]
                    return list.map { effort in
                        if effort == "none" {
                            return makeVariant(effort, settings: ["thinking": .object(["type": .string("disabled")])])
                        }
                        return makeVariant(effort, settings: ["thinking": adaptive, "effort": .string(effort)])
                    }
                case .toggle:
                    return [
                        makeVariant("none", settings: ["thinking": .object(["type": .string("disabled")])]),
                        makeVariant("thinking", settings: ["thinking": adaptive]),
                    ]
                case .budgetTokens(let minV, let maxV):
                    return makeBudgets(model: model, minVal: minV, maxVal: maxV, ceiling: anthropicOutputMax) { tokens in
                        (["thinking": .object(["type": .string("enabled"), "budgetTokens": .int(Int64(tokens))])], nil)
                    }
                }
            }
            if geminiPackages.contains(package) {
                switch support {
                case .effort(let vals):
                    return (vals ?? defaultEfforts).map { effort in
                        makeVariant(effort, settings: ["thinkingConfig": .object(["includeThoughts": .bool(true), "thinkingLevel": .string(effort)])])
                    }
                case .toggle:
                    return [
                        makeVariant("none", settings: ["thinkingConfig": .object(["includeThoughts": .bool(false), "thinkingBudget": .int(0)])]),
                        makeVariant("thinking", settings: ["thinkingConfig": .object(["includeThoughts": .bool(true), "thinkingBudget": .int(-1)])]),
                    ]
                case .budgetTokens(let minV, let maxV):
                    return makeBudgets(model: model, minVal: minV, maxVal: maxV, ceiling: model.limit.output) { tokens in
                        (["thinkingConfig": .object(["includeThoughts": .bool(true), "thinkingBudget": .int(Int64(tokens))])], nil)
                    }
                }
            }
            if googleInteractionsPackages.contains(package) {
                guard case .effort(let vals) = support else { return [] }
                return (vals ?? defaultEfforts).map { effort in
                    makeVariant(effort, settings: ["thinkingLevel": .string(effort), "thinkingSummaries": .string("auto")])
                }
            }
            if package == "@opencode/ai/providers/deepseek" {
                switch support {
                case .effort(let vals):
                    return (vals ?? ["low", "high", "max"]).map { effort in
                        if effort == "none" {
                            return makeVariant(effort, body: ["thinking": .object(["type": .string("disabled")])])
                        }
                        return makeVariant(effort, settings: ["reasoningEffort": .string(effort)], body: ["thinking": .object(["type": .string("enabled")])])
                    }
                case .toggle:
                    return [
                        makeVariant("none", body: ["thinking": .object(["type": .string("disabled")])]),
                        makeVariant("thinking", body: ["thinking": .object(["type": .string("enabled")])]),
                    ]
                case .budgetTokens:
                    return []
                }
            }
            if package == "@opencode/ai/providers/openrouter" {
                switch support {
                case .effort(let vals):
                    return (vals ?? defaultEfforts).map { effort in
                        makeVariant(effort, settings: ["reasoning": .object(["effort": .string(effort)])])
                    }
                case .toggle:
                    return [
                        makeVariant("none", settings: ["reasoning": .object(["enabled": .bool(false)])]),
                        makeVariant("thinking", settings: ["reasoning": .object(["enabled": .bool(true)])]),
                    ]
                case .budgetTokens(let minV, let maxV):
                    return makeBudgets(model: model, minVal: minV, maxVal: maxV, ceiling: model.limit.output) { tokens in
                        (["reasoning": .object(["max_tokens": .int(Int64(tokens))])], nil)
                    }
                }
            }
            if package == "@opencode/ai/providers/alibaba" || package == "@opencode/ai/providers/alibaba/chat" {
                switch support {
                case .effort(let vals):
                    return (vals ?? ["low", "medium", "xhigh"]).map { effort in
                        if effort == "none" {
                            return makeVariant(effort, settings: ["enableThinking": .bool(false)])
                        }
                        return makeVariant(effort, settings: ["enableThinking": .bool(true), "reasoningEffort": .string(effort)])
                    }
                case .toggle:
                    return [
                        makeVariant("none", settings: ["enableThinking": .bool(false)]),
                        makeVariant("thinking", settings: ["enableThinking": .bool(true)]),
                    ]
                case .budgetTokens(let minV, let maxV):
                    return makeBudgets(model: model, minVal: minV, maxVal: maxV, ceiling: alibabaBudgetMax) { tokens in
                        (["enableThinking": .bool(true), "thinkingBudget": .int(Int64(tokens))], nil)
                    }
                }
            }
            if package == "@opencode/ai/providers/amazon-bedrock" {
                let isClaude = model.modelID.rawValue.contains("anthropic")
                switch support {
                case .effort(let vals):
                    return (vals ?? defaultEfforts).map { effort in
                        if isClaude {
                            return makeVariant(effort, body: ["additionalModelRequestFields": .object(["output_config": .object(["effort": .string(effort)])])])
                        }
                        return makeVariant(effort, body: ["additionalModelRequestFields": .object(["reasoningConfig": .object(["type": .string("enabled"), "maxReasoningEffort": .string(effort)])])])
                    }
                case .toggle:
                    return [
                        makeVariant("none", body: ["additionalModelRequestFields": .object([isClaude ? "thinking" : "reasoningConfig": .object(["type": .string("disabled")])])]),
                        makeVariant("thinking", body: ["additionalModelRequestFields": .object([isClaude ? "thinking" : "reasoningConfig": .object(["type": .string(isClaude ? "adaptive" : "enabled")])])]),
                    ]
                case .budgetTokens(let minV, let maxV):
                    return makeBudgets(model: model, minVal: minV, maxVal: maxV, ceiling: isClaude ? anthropicOutputMax : model.limit.output) { tokens in
                        if isClaude {
                            return (["thinking": .object(["type": .string("enabled"), "budgetTokens": .int(Int64(tokens))])], nil)
                        }
                        return (nil, ["additionalModelRequestFields": .object(["reasoningConfig": .object(["type": .string("enabled"), "budgetTokens": .int(Int64(tokens))])])])
                    }
                }
            }
            // Default OpenAI Chat compatible protocols
            if CoreProvider.Provider.builtinPackages.contains(package) {
                guard case .effort(let vals) = support else { return [] }
                return (vals ?? defaultEfforts).map { effort in
                    makeVariant(effort, settings: ["reasoningEffort": .string(effort)])
                }
            }
            return []
        }

        // parity: core/src/variant.ts#resolve [status=implemented hash=fc31a0f341b3]
        public static func resolve(
            _ model: ModelSchema.Info,
            supports: [Support] = [.effort(values: nil)]
        ) -> [ModelSchema.Variant] {
            guard let pkg = model.package else { return [] }
            let toggleVariants: [ModelSchema.Variant] = supports.contains(.toggle)
                ? resolveProtocol(package: pkg, model: model, support: .toggle)
                : []
            let effortSupport = supports.first { if case .effort = $0 { return true } else { return false } }
            let budgetSupport = supports.first { if case .budgetTokens = $0 { return true } else { return false } }
            let main: [ModelSchema.Variant]
            if let effortSupport {
                main = resolveProtocol(package: pkg, model: model, support: effortSupport)
            } else if let budgetSupport {
                main = resolveProtocol(package: pkg, model: model, support: budgetSupport)
            } else {
                main = toggleVariants
            }
            let combined = toggleVariants.filter { $0.id.rawValue == "none" } + main
            var seen: Set<ModelSchema.VariantID> = []
            return combined.filter { seen.insert($0.id).inserted }
        }
    }

    // MARK: - core/src/model-retry.ts

    public enum Retry {
        private static let retryAfterMaxMs: Int = 15 * 60 * 1_000
        private static let unreachableCodes: Set<String> = ["ENOTFOUND", "EAI_AGAIN", "ENETUNREACH", "EHOSTUNREACH", "ENETDOWN"]
        private static let unreachableGapMaxMs: Int = 30_000
        private static let maxTimeoutRetries: Int = 3
        private static let oneShotRetries: Int = 3
        private static let notSentCodes: Set<String> = ["ECONNREFUSED", "ENOTFOUND", "EAI_AGAIN"]

        // parity: core/src/model-retry.ts#UNREACHABLE_WINDOW [status=implemented hash=40c262342216]
        public static let UNREACHABLE_WINDOW_MS: Int64 = 60 * 60 * 1_000

        // parity: core/src/model-retry.ts#isUnreachable [status=implemented hash=d1f36797a1f9]
        public static func isUnreachable(_ error: AISchema.AIError) -> Bool {
            if case .transport(let t) = error.reason, let code = t.code {
                return unreachableCodes.contains(code)
            }
            return false
        }

        public struct Decision: Equatable, Hashable, Sendable {
            public let attempt: Int
            public let delayMs: Int
            public let retry: Bool

            public init(attempt: Int, delayMs: Int, retry: Bool) {
                self.attempt = attempt
                self.delayMs = delayMs
                self.retry = retry
            }
        }

        public final class Policy: Sendable {
            private struct State: Sendable {
                var attempt: Int = 1
                var generalStep: Int = 0
                var unreachableStep: Int = 0
                var unreachableStartedAtMs: Int64?
                var timeouts: Int = 0
            }

            private let state = Mutex(State())
            private let clock: @Sendable () -> Int64
            private let jitter: @Sendable () -> Double

            public init(
                clock: @escaping @Sendable () -> Int64 = { Flock.currentEpochMs() },
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.8...1.2) }
            ) {
                self.clock = clock
                self.jitter = jitter
            }

            public func next(cause: AISchema.AIError, retry: Bool) -> Decision? {
                let now = clock()
                let jitterFactor = jitter()
                return state.withLock { s -> Decision? in
                    let isUnreach = retry && Retry.isUnreachable(cause)
                    let baseDelayMs: Int
                    if isUnreach {
                        let started = s.unreachableStartedAtMs ?? now
                        s.unreachableStartedAtMs = started
                        if now - started >= Retry.UNREACHABLE_WINDOW_MS { return nil }
                        let exp = min(2_000 * (1 << min(s.unreachableStep, 4)), Retry.unreachableGapMaxMs)
                        s.unreachableStep += 1
                        baseDelayMs = min(Int((Double(exp) * jitterFactor).rounded(.up)), Retry.unreachableGapMaxMs)
                    } else {
                        if s.generalStep >= 10 { return nil }
                        let exp = min(2_000 * (1 << min(s.generalStep, 4)), 10_000)
                        s.generalStep += 1
                        let jittered = Int((Double(exp) * jitterFactor).rounded(.up))
                        let headerMin: Int?
                        switch cause.reason {
                        case .rateLimit(let r):
                            headerMin = (r.retryAfterMs ?? r.rateLimit?.retryAfterMs).map { min($0, Retry.retryAfterMaxMs) }
                        case .providerInternal(let p):
                            headerMin = p.retryAfterMs.map { min($0, Retry.retryAfterMaxMs) }
                        default:
                            headerMin = nil
                        }
                        baseDelayMs = max(jittered, headerMin ?? 0)
                    }
                    s.attempt += 1
                    if case .transport(let t) = cause.reason, t.code == "Timeout" {
                        s.timeouts += 1
                    }
                    return Decision(
                        attempt: s.attempt,
                        delayMs: baseDelayMs,
                        retry: retry && s.timeouts <= Retry.maxTimeoutRetries
                    )
                }
            }
        }

        // parity: core/src/model-retry.ts#policy [status=implemented hash=03a13cd21f8d]
        public static func policy(
            clock: @escaping @Sendable () -> Int64 = { Flock.currentEpochMs() },
            jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.8...1.2) }
        ) -> Policy {
            Policy(clock: clock, jitter: jitter)
        }

        // parity: core/src/model-retry.ts#retry [status=implemented hash=471f475196b2]
        public static func retry<A: Sendable>(
            policy: Policy = Retry.policy(),
            sleep: (@Sendable (Int) async throws -> Void)? = nil,
            operation: @Sendable () async throws -> A
        ) async throws -> A {
            while true {
                do {
                    return try await operation()
                } catch let error as AISchema.AIError {
                    guard let decision = policy.next(cause: error, retry: AIErrorClassifier.isRetryable(error)),
                          decision.retry
                    else {
                        throw error
                    }
                    if let sleep {
                        try await sleep(decision.delayMs)
                    } else {
                        try await Task.sleep(for: .milliseconds(max(0, decision.delayMs)))
                    }
                }
            }
        }

        private static func notRun(_ error: AISchema.AIError) -> Bool {
            if let override = error.reason.http?.headers["x-should-retry"] {
                if override == "true" { return true }
                if override == "false" { return false }
            }
            switch error.reason {
            case .rateLimit: return true
            case .providerInternal(let p):
                return p.http?.status == 503 || p.http?.status == 529
            case .transport(let t):
                return t.delivery == .notSent || (t.code.map { notSentCodes.contains($0) } ?? false)
            default:
                return false
            }
        }

        // parity: core/src/model-retry.ts#retryOneShot [status=implemented hash=6fbe6b03d746]
        public static func retryOneShot<A: Sendable>(
            policy: Policy = Retry.policy(),
            sleep: (@Sendable (Int) async throws -> Void)? = nil,
            operation: @Sendable () async throws -> A
        ) async throws -> A {
            var retries = 0
            while true {
                do {
                    return try await operation()
                } catch let error as AISchema.AIError {
                    guard let decision = policy.next(cause: error, retry: notRun(error)),
                          decision.retry,
                          retries < oneShotRetries
                    else {
                        throw error
                    }
                    retries += 1
                    if let sleep {
                        try await sleep(decision.delayMs)
                    } else {
                        try await Task.sleep(for: .milliseconds(max(0, decision.delayMs)))
                    }
                }
            }
        }
    }

    // MARK: - core/src/model-resolver.ts

    public enum Resolver {
        // parity: core/src/model-resolver.ts#VariantUnavailableError [status=implemented hash=fc2d64e053ee]
        public struct VariantUnavailableError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "SessionRunnerModel.VariantUnavailableError"
            public let providerID: ProviderSchema.ID
            public let modelID: ModelSchema.ID
            public let variant: ModelSchema.VariantID

            public init(providerID: ProviderSchema.ID, modelID: ModelSchema.ID, variant: ModelSchema.VariantID) {
                self.providerID = providerID; self.modelID = modelID; self.variant = variant
            }

            public var message: String { "Variant unavailable for \(providerID.rawValue)/\(modelID.rawValue): \(variant.rawValue)" }
            public var description: String { message }
        }

        // parity: core/src/model-resolver.ts#UnsupportedPackageError [status=implemented hash=24328a576b3f]
        public struct UnsupportedPackageError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "SessionRunnerModel.UnsupportedPackageError"
            public let providerID: ProviderSchema.ID
            public let modelID: ModelSchema.ID
            public let package: String

            public init(providerID: ProviderSchema.ID, modelID: ModelSchema.ID, package: String) {
                self.providerID = providerID; self.modelID = modelID; self.package = package
            }

            public var message: String { "Unsupported package for \(providerID.rawValue)/\(modelID.rawValue): \(package)" }
            public var description: String { message }
        }

        // parity: core/src/model-resolver.ts#InitializationPhase [status=implemented hash=b2521c72d8a6]
        public enum InitializationPhase: String, Equatable, Hashable, Sendable, Codable {
            case load, `init`, construct
        }

        // parity: core/src/model-resolver.ts#ModelConfigurationError [status=implemented hash=a14999f712b6]
        public struct ModelConfigurationError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "SessionRunnerModel.ModelConfigurationError"
            public let providerID: ProviderSchema.ID
            public let modelID: ModelSchema.ID
            public let package: String
            public let detail: String

            public init(providerID: ProviderSchema.ID, modelID: ModelSchema.ID, package: String, detail: String) {
                self.providerID = providerID; self.modelID = modelID; self.package = package; self.detail = detail
            }

            public var message: String { "Cannot initialize \(providerID.rawValue)/\(modelID.rawValue): \(detail)" }
            public var description: String { message }
        }

        // parity: core/src/model-resolver.ts#ModelInitializationError [status=implemented hash=a028e7f5eefa]
        public struct ModelInitializationError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "SessionRunnerModel.ModelInitializationError"
            public let providerID: ProviderSchema.ID
            public let modelID: ModelSchema.ID
            public let package: String
            public let phase: InitializationPhase
            public let detail: String

            public init(providerID: ProviderSchema.ID, modelID: ModelSchema.ID, package: String, phase: InitializationPhase, detail: String) {
                self.providerID = providerID; self.modelID = modelID; self.package = package; self.phase = phase; self.detail = detail
            }

            public var message: String { "Cannot initialize \(providerID.rawValue)/\(modelID.rawValue): \(detail)" }
            public var description: String { message }
        }

        // parity: core/src/model-resolver.ts#UnresolvedProviderVariablesError [status=implemented hash=76c9a275e686]
        public struct UnresolvedProviderVariablesError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "SessionRunnerModel.UnresolvedProviderVariablesError"
            public let providerID: ProviderSchema.ID
            public let modelID: ModelSchema.ID
            public let variables: [String]

            public init(providerID: ProviderSchema.ID, modelID: ModelSchema.ID, variables: [String]) {
                self.providerID = providerID; self.modelID = modelID; self.variables = variables
            }

            public var message: String {
                let verb = variables.count == 1 ? "is" : "are"
                return "Cannot initialize \(providerID.rawValue)/\(modelID.rawValue): \(variables.joined(separator: ", ")) \(verb) required to resolve the provider endpoint"
            }

            public var description: String { message }
        }

        // parity: core/src/model-resolver.ts#UnsupportedCompactionError [status=implemented hash=2a52f2180e37]
        public struct UnsupportedCompactionError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "SessionRunnerModel.UnsupportedCompactionError"
            public let providerID: ProviderSchema.ID
            public let modelID: ModelSchema.ID
            public let route: String

            public init(providerID: ProviderSchema.ID, modelID: ModelSchema.ID, route: String) {
                self.providerID = providerID; self.modelID = modelID; self.route = route
            }

            public var message: String { "Provider compaction is not supported by \(providerID.rawValue)/\(modelID.rawValue) (\(route))" }
            public var description: String { message }
        }

        // parity: core/src/model-resolver.ts#Error [status=implemented hash=066909e749b1]
        public enum ResolverError: Swift.Error, Equatable, Hashable, Sendable {
            case variantUnavailable(VariantUnavailableError)
            case unsupportedPackage(UnsupportedPackageError)
            case configuration(ModelConfigurationError)
            case initialization(ModelInitializationError)
            case unresolvedVariables(UnresolvedProviderVariablesError)
            case unsupportedCompaction(UnsupportedCompactionError)
            case authorization(CoreIntegration.Integration.AuthorizationError)
        }

        // parity: core/src/model-resolver.ts#MediaError [status=implemented hash=5caad911504f]
        public enum MediaError: Swift.Error, Equatable, Hashable, Sendable {
            case variantUnavailable(VariantUnavailableError)
            case unsupportedPackage(UnsupportedPackageError)
            case configuration(ModelConfigurationError)
            case initialization(ModelInitializationError)
            case unresolvedVariables(UnresolvedProviderVariablesError)
            case authorization(CoreIntegration.Integration.AuthorizationError)
        }

        public struct ResolvedModelDescriptor: Equatable, Sendable {
            public let id: String
            public let provider: String
            public let package: String
            public let baseURL: String?
            public let headers: [String: String]
            public let body: [String: JSONValue]
            public let settings: [String: JSONValue]

            public init(
                id: String,
                provider: String,
                package: String,
                baseURL: String? = nil,
                headers: [String: String] = [:],
                body: [String: JSONValue] = [:],
                settings: [String: JSONValue] = [:]
            ) {
                self.id = id; self.provider = provider; self.package = package; self.baseURL = baseURL
                self.headers = headers; self.body = body; self.settings = settings
            }
        }

        // parity: core/src/model-resolver.ts#Resolved [status=implemented hash=30d2b97aa48e]
        public struct Resolved: Equatable, Sendable {
            public let model: ResolvedModelDescriptor
            public let ref: ModelSchema.Ref
            public let capabilities: ModelSchema.Capabilities
            public let cost: [ModelSchema.Cost]
            public let limit: ModelSchema.Info.Limit
            public let compaction: ProviderSchema.Compaction?
            public let cache: ProviderSchema.Cache?
            public let transport: ProviderSchema.Transport?
            public let chunkTimeout: ProviderSchema.TimeoutOption?

            public init(
                model: ResolvedModelDescriptor,
                ref: ModelSchema.Ref,
                capabilities: ModelSchema.Capabilities,
                cost: [ModelSchema.Cost],
                limit: ModelSchema.Info.Limit,
                compaction: ProviderSchema.Compaction? = nil,
                cache: ProviderSchema.Cache? = nil,
                transport: ProviderSchema.Transport? = nil,
                chunkTimeout: ProviderSchema.TimeoutOption? = nil
            ) {
                self.model = model; self.ref = ref; self.capabilities = capabilities; self.cost = cost
                self.limit = limit; self.compaction = compaction; self.cache = cache
                self.transport = transport; self.chunkTimeout = chunkTimeout
            }
        }

        // parity: core/src/model-resolver.ts#Dependencies [status=adapted hash=05f4bacf6674]
        public struct Dependencies: Sendable {
            public let loadPackage: (@Sendable (String) throws -> String)?
            public let environment: any EnvironmentProviding

            public init(
                loadPackage: (@Sendable (String) throws -> String)? = nil,
                environment: any EnvironmentProviding = SystemEnvironment.shared
            ) {
                self.loadPackage = loadPackage
                self.environment = environment
            }
        }

        // parity: core/src/model-resolver.ts#withVariant [status=implemented hash=55e47521b362]
        public static func withVariant(
            _ model: ModelSchema.Info,
            variantID: ModelSchema.VariantID?
        ) throws(VariantUnavailableError) -> ModelSchema.Info {
            let effectiveID = (variantID?.rawValue == "default") ? nil : variantID
            let variant = effectiveID.flatMap { id in model.variants.first { $0.id == id } }
            if let effectiveID, variant == nil {
                throw VariantUnavailableError(providerID: model.providerID, modelID: model.id, variant: effectiveID)
            }
            guard let variant else { return model }
            var mergedExtra = model.settings?.extra ?? [:]
            if let varExtra = variant.settings?.extra {
                for (k, v) in varExtra where k != "cache" {
                    mergedExtra[k] = v
                }
            }
            let mergedSettings = ModelSchema.Settings(
                compaction: variant.settings?.compaction ?? model.settings?.compaction,
                encoding: variant.settings?.encoding ?? model.settings?.encoding,
                extra: mergedExtra
            )
            return ModelSchema.Info(
                id: model.id,
                modelID: model.modelID,
                providerID: model.providerID,
                canonical: model.canonical,
                type: model.type,
                family: model.family,
                name: model.name,
                compatibility: model.compatibility,
                package: model.package,
                settings: mergedSettings,
                headers: CoreProvider.AISDKNative.mergeHeaders(model.headers, variant.headers),
                body: CoreProvider.AISDKNative.mergeOverlay(model.body, variant.body),
                capabilities: model.capabilities,
                variants: model.variants,
                time: model.time,
                cost: model.cost,
                status: model.status,
                enabled: model.enabled,
                limit: model.limit
            )
        }

        // parity: core/src/model-resolver.ts#hasPackage [status=implemented hash=9ba72dcdd1a5]
        public static func hasPackage(_ model: ModelSchema.Info) -> Bool {
            guard let pkg = model.package else { return false }
            return !pkg.isEmpty
        }

        // parity: core/src/model-resolver.ts#fromCatalogModel [status=implemented hash=fdbf31f4c355]
        public static func fromCatalogModel(
            _ runtime: Model.RuntimeInfo,
            credential: CredentialSchema.Value? = nil,
            dependencies: Dependencies = Dependencies()
        ) throws -> ResolvedModelDescriptor {
            let info = runtime.info
            guard let specifier = CoreProvider.AISDKNative.packageName(info.package), !specifier.isEmpty else {
                throw UnsupportedPackageError(providerID: info.providerID, modelID: info.id, package: info.package ?? "unknown")
            }
            let resolvedPkg: String
            do {
                resolvedPkg = try (dependencies.loadPackage ?? { try CoreProvider.Provider.loadPackage($0) })(specifier)
            } catch {
                throw ModelInitializationError(
                    providerID: info.providerID,
                    modelID: info.id,
                    package: specifier,
                    phase: .load,
                    detail: String(describing: error)
                )
            }

            var effectiveSettings = CoreProvider.Provider.nativeSettings(runtime.settings ?? info.settings?.extra ?? [:])
            if case .string("") = effectiveSettings["apiKey"] {
                effectiveSettings.removeValue(forKey: "apiKey")
            }

            var resolvedBaseURL: String? = nil
            if case .string(let rawBaseURL) = effectiveSettings["baseURL"] {
                var prepared = rawBaseURL
                if let regex = try? Regex("\\$\\{([^}]+)\\}") {
                    for match in rawBaseURL.matches(of: regex).reversed() {
                        let full = String(rawBaseURL[match.range])
                        let varName = String(full.dropFirst(2).dropLast())
                        let replacement: String?
                        if varName == "AWS_REGION", case .string(let r) = effectiveSettings["region"] {
                            replacement = r
                        } else {
                            replacement = dependencies.environment.variable(varName)
                        }
                        if let replacement {
                            prepared.replaceSubrange(match.range, with: replacement)
                        }
                    }
                    var unresolved: [String] = []
                    for match in prepared.matches(of: regex) {
                        let full = String(prepared[match.range])
                        let varName = String(full.dropFirst(2).dropLast())
                        if !unresolved.contains(varName) { unresolved.append(varName) }
                    }
                    if !unresolved.isEmpty {
                        throw UnresolvedProviderVariablesError(providerID: info.providerID, modelID: info.id, variables: unresolved)
                    }
                }
                effectiveSettings["baseURL"] = .string(prepared)
                resolvedBaseURL = prepared
            }

            if let credential {
                effectiveSettings.removeValue(forKey: "accessToken")
                effectiveSettings.removeValue(forKey: "apiKey")
                effectiveSettings.removeValue(forKey: "authToken")
                switch credential {
                case .key(let k):
                    effectiveSettings["apiKey"] = .string(k.key)
                case .oauth(let o):
                    if resolvedPkg == "@opencode/ai/providers/anthropic" || resolvedPkg == "@opencode/ai/providers/anthropic-compatible" {
                        effectiveSettings["authToken"] = .string(o.access)
                    } else if resolvedPkg.hasPrefix("@opencode/ai/providers/google-vertex") {
                        effectiveSettings["accessToken"] = .string(o.access)
                    } else {
                        effectiveSettings["apiKey"] = .string(o.access)
                    }
                case .external:
                    if resolvedPkg.hasPrefix("@opencode/ai/providers/amazon-bedrock") {
                        effectiveSettings["auth"] = .string("sigv4")
                    }
                }
            }

            return ResolvedModelDescriptor(
                id: info.modelID.rawValue,
                provider: (info.canonical ?? info.providerID).rawValue,
                package: resolvedPkg,
                baseURL: resolvedBaseURL,
                headers: info.headers ?? [:],
                body: info.body ?? [:],
                settings: effectiveSettings
            )
        }

        // parity: core/src/model-resolver.ts#resolveModel [status=implemented hash=0421736bcd52]
        public static func resolveModel(
            _ model: ModelSchema.Info,
            variant: ModelSchema.VariantID? = nil,
            credential: CredentialSchema.Value? = nil,
            dependencies: Dependencies = Dependencies()
        ) throws -> ResolvedModelDescriptor {
            let withVar = try withVariant(model, variantID: variant)
            return try fromCatalogModel(Model.RuntimeInfo(info: withVar, settings: withVar.settings?.extra), credential: credential, dependencies: dependencies)
        }

        // parity: core/src/model-resolver.ts#Interface [status=implemented hash=fdd67dbd4c62]
        public protocol Interface: Sendable {
            func resolve(_ requested: ModelSchema.Ref?) async throws -> Resolved?
            func fallback() async throws -> ModelSchema.Info?
            func resolveModel(_ model: ModelSchema.Info, variant: ModelSchema.VariantID?) async throws -> Resolved
            func resolveImage(_ ref: ModelSchema.Ref) async throws -> ResolvedModelDescriptor?
            func resolveVideo(_ ref: ModelSchema.Ref) async throws -> ResolvedModelDescriptor?
            func resolveDecision(_ ref: ModelSchema.Ref) async throws -> ResolvedModelDescriptor?
        }

        // parity: core/src/model-resolver.ts#Service [status=implemented hash=00caf0f492a9]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/ModelResolver"
            private let providers: any CoreProvider.Provider.Interface
            private let models: any Model.Interface
            private let integrations: (any CoreIntegration.Integration.Interface)?
            private let dependencies: Dependencies

            public init(
                providers: any CoreProvider.Provider.Interface,
                models: any Model.Interface,
                integrations: (any CoreIntegration.Integration.Interface)? = nil,
                dependencies: Dependencies = Dependencies()
            ) {
                self.providers = providers
                self.models = models
                self.integrations = integrations
                self.dependencies = dependencies
            }

            public func fallback() async throws -> ModelSchema.Info? {
                if let def = try await models.defaultModel(), Resolver.hasPackage(def) {
                    return def
                }
                let avail = try await models.available(types: nil)
                return avail.first { Resolver.hasPackage($0) && Model.supportsText($0) }
            }

            public func resolve(_ requested: ModelSchema.Ref? = nil) async throws -> Resolved? {
                let selected: ModelSchema.Info?
                if let requested {
                    selected = try await models.get(providerID: requested.providerID, modelID: requested.id)
                } else {
                    selected = try await fallback()
                }
                guard let selected else { return nil }
                return try await resolveModel(selected, variant: requested?.variant)
            }

            public func resolveModel(_ model: ModelSchema.Info, variant: ModelSchema.VariantID? = nil) async throws -> Resolved {
                let provider = await providers.get(model.providerID)
                let intID = provider?.integrationID ?? IntegrationID(rawValue: model.providerID.rawValue)
                let activeConn = try? await integrations?.activeConnection(intID)
                let credential = activeConn != nil ? (try? await integrations?.resolveConnection(activeConn!)) : nil
                let withVar = try Resolver.withVariant(model, variantID: variant)
                let mergedSettings = CoreProvider.AISDKNative.mergeOverlay(
                    provider?.settings?.extra,
                    CoreProvider.Provider.modelSettings(withVar.settings?.extra)
                )
                let runtime = Model.RuntimeInfo(info: withVar, settings: mergedSettings)
                let descriptor = try Resolver.fromCatalogModel(runtime, credential: credential, dependencies: dependencies)
                let transport: ProviderSchema.Transport? = provider?.settings?.tls != nil ? .http : provider?.settings?.transport
                return Resolved(
                    model: descriptor,
                    ref: ModelSchema.Ref(id: model.id, providerID: model.providerID, variant: variant),
                    capabilities: model.capabilities,
                    cost: model.cost,
                    limit: model.limit,
                    compaction: withVar.settings?.compaction ?? provider?.settings?.compaction,
                    cache: provider?.settings?.cache,
                    transport: transport,
                    chunkTimeout: provider?.settings?.chunkTimeout
                )
            }

            private func resolveMedia(_ ref: ModelSchema.Ref, type: ModelSchema.ModelType) async throws -> ResolvedModelDescriptor? {
                let candidates = try await models.available(types: [type])
                guard let info = candidates.first(where: { $0.providerID == ref.providerID && $0.id == ref.id }) else {
                    return nil
                }
                let resolved = try await resolveModel(info, variant: ref.variant)
                return resolved.model
            }

            public func resolveImage(_ ref: ModelSchema.Ref) async throws -> ResolvedModelDescriptor? {
                try await resolveMedia(ref, type: .image)
            }

            public func resolveVideo(_ ref: ModelSchema.Ref) async throws -> ResolvedModelDescriptor? {
                try await resolveMedia(ref, type: .video)
            }

            public func resolveDecision(_ ref: ModelSchema.Ref) async throws -> ResolvedModelDescriptor? {
                try await resolveMedia(ref, type: .decision)
            }
        }

        // parity: core/src/model-resolver.ts#layer [status=implemented hash=49efdcbaf5c1]
        public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { deps, _ in
            let providers = deps.get(CoreProvider.Provider.Service.serviceKey, as: CoreProvider.Provider.Service.self)
                ?? CoreProvider.Provider.Service()
            let models = deps.get(Model.Service.serviceKey, as: Model.Service.self)
                ?? Model.Service(providers: providers)
            let integrations = deps.get(CoreIntegration.Integration.Service.serviceKey, as: CoreIntegration.Integration.Service.self)
            return LayerNode.Output([Service.serviceKey: Service(providers: providers, models: models, integrations: integrations)])
        }

        // parity: core/src/model-resolver.ts#node [status=implemented hash=f361994733ce]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            layer,
            [CoreProvider.Provider.node, Model.node, CoreIntegration.Integration.node]
        )
    }

    // MARK: - core/src/models-dev/v1.ts & core/src/models-dev.ts

    public enum ModelsDev {
        public enum V1 {
            private static let responsesByDefault: Set<String> = [
                "@ai-sdk/openai", "@ai-sdk/azure", "@ai-sdk/xai",
            ]

            /// v1 providers always declare an `npm` string; v2 providers never do.
            // parity: core/src/models-dev/v1.ts#isV1 [status=implemented hash=0b9ebded7697]
            public static func isV1(_ catalog: [String: JSONValue]) -> Bool {
                catalog.values.contains { val in
                    if case .object(let obj) = val, case .string = obj["npm"] { return true }
                    return false
                }
            }

            /// Converts a models.dev v1 catalog dictionary into the v2 shape.
            // parity: core/src/models-dev/v1.ts#toV2 [status=implemented hash=cf5eb404eb08]
            public static func toV2(_ catalog: [String: JSONValue]) -> [String: JSONValue] {
                var out: [String: JSONValue] = [:]
                for (key, value) in catalog {
                    guard case .object(let prov) = value,
                          case .string(let pid) = prov["id"],
                          case .string(let pname) = prov["name"],
                          case .string(let npm) = prov["npm"],
                          case .object(let rawModels) = prov["models"]
                    else { continue }
                    let envArr = prov["env"] ?? .array([])
                    let provApi: String = { if case .string(let a) = prov["api"] { return a } else { return "" } }()
                    var convertedModels: [String: JSONValue] = [:]
                    for (mid, mVal) in rawModels {
                        guard case .object(let m) = mVal,
                              case .string(let id) = m["id"],
                              case .string(let name) = m["name"]
                        else { continue }
                        var modelProv: [String: JSONValue]? = nil
                        if case .object(let p) = m["provider"] { modelProv = p }
                        var mNpm = npm
                        if case .string(let n) = modelProv?["npm"] { mNpm = n }
                        var mApi = provApi
                        if case .string(let a) = modelProv?["api"] { mApi = a }
                        var shape: String? = nil
                        if case .string(let s) = modelProv?["shape"] { shape = s }
                        let proto = (shape == "responses" || (shape == nil && responsesByDefault.contains(mNpm))) ? "responses" : "chat-completions"
                        let toolCall: Bool = { if case .bool(let b) = m["tool_call"] { return b } else { return false } }()
                        let reasoningSupported: Bool = { if case .bool(let b) = m["reasoning"] { return b } else { return false } }()
                        let mType = m["type"] ?? .string("chat")
                        let modalities = m["modalities"] ?? .object(["input": .array([.string("text")]), "output": .array([.string("text")])])
                        var converted: [String: JSONValue] = [
                            "id": .string(id),
                            "type": mType,
                            "name": .string(name),
                            "release_date": m["release_date"] ?? .string(""),
                            "modalities": modalities,
                            "capabilities": .object([
                                "tools": .object(["supported": .bool(toolCall)]),
                                "reasoning": .object(["supported": .bool(reasoningSupported)]),
                            ]),
                            "api": .object([
                                proto: .object([
                                    "base_url": .string(mApi),
                                    "sdk": .object(["aisdk": .string(mNpm)]),
                                ]),
                            ]),
                        ]
                        if let fam = m["family"] { converted["family"] = fam }
                        if let lim = m["limit"] { converted["limit"] = lim }
                        if let st = m["status"] { converted["status"] = st }
                        convertedModels[mid] = .object(converted)
                    }
                    out[key] = .object([
                        "id": .string(pid),
                        "name": .string(pname),
                        "env": envArr,
                        "models": .object(convertedModels),
                    ])
                }
                return out
            }
        }

        // parity: core/src/models-dev.ts#Snapshot [status=implemented hash=6b5ddd97a912]
        public struct Snapshot: Equatable, Sendable {
            public let info: ProviderSchema.Info
            public let models: [ModelSchema.Info]
            public let environment: [String]

            public init(info: ProviderSchema.Info, models: [ModelSchema.Info], environment: [String]) {
                self.info = info
                self.models = models
                self.environment = environment
            }
        }

        // parity: core/src/models-dev.ts#Options [status=implemented hash=4f4c4f6a24cb]
        public struct Options: Equatable, Hashable, Sendable, Codable {
            public let url: String?
            public let file: String?
            public let fetch: Bool?
            public let snapshot: Bool?

            public init(url: String? = nil, file: String? = nil, fetch: Bool? = nil, snapshot: Bool? = nil) {
                self.url = url; self.file = file; self.fetch = fetch; self.snapshot = snapshot
            }
        }

        // parity: core/src/models-dev.ts#catalogPath [status=implemented hash=e92527d3d949]
        public static let catalogPath = "/experimental/v2.0/api.json?type=chat,decision,image,video"

        // parity: core/src/models-dev.ts#bodyDigest [status=implemented hash=4278a18c1470]
        public static func bodyDigest(_ text: String) -> String {
            Hash.sha256(text)
        }

        // parity: core/src/models-dev.ts#decodeSnapshot [status=implemented hash=3365142ba603]
        public static func decodeSnapshot(_ text: String) throws -> [Snapshot] {
            let raw = try JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8))
            let v2 = V1.isV1(raw) ? V1.toV2(raw) : raw
            var snapshots: [Snapshot] = []
            for (_, value) in v2.sorted(by: { $0.key < $1.key }) {
                guard case .object(let prov) = value,
                      case .string(let pidStr) = prov["id"],
                      case .string(let pname) = prov["name"],
                      case .object(let rawModels) = prov["models"]
                else { continue }
                let pid = ProviderSchema.ID(rawValue: pidStr)
                let env: [String] = {
                    guard case .array(let arr) = prov["env"] else { return [] }
                    return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
                }()
                var builtModels: [ModelSchema.Info] = []
                var pkgCounts: [String: Int] = [:]
                for (_, mVal) in rawModels {
                    guard case .object(let m) = mVal,
                          case .string(let mid) = m["id"],
                          case .string(let mname) = m["name"]
                    else { continue }
                    var chosenPkg: String?
                    if case .object(let apiMap) = m["api"] {
                        for (_, apiVal) in apiMap {
                            if case .object(let apiObj) = apiVal, case .object(let sdk) = apiObj["sdk"] {
                                if case .string(let oc) = sdk["opencodeai"], CoreProvider.Provider.builtinPackages.contains(oc) {
                                    chosenPkg = oc; break
                                }
                                if case .string(let ai) = sdk["aisdk"] {
                                    chosenPkg = CoreProvider.AISDKNative.native(npm: ai, providerID: pidStr, modelID: mid)
                                        ?? CoreProvider.AISDKNative.aisdk(ai)
                                    break
                                }
                            }
                        }
                    }
                    guard let pkg = chosenPkg else { continue }
                    pkgCounts[pkg, default: 0] += 1
                    let ctx: Int = { if case .object(let lim) = m["limit"], case .int(let c) = lim["context"] { return Int(c) } else { return 0 } }()
                    let out: Int = { if case .object(let lim) = m["limit"], case .int(let o) = lim["output"] { return Int(o) } else { return 0 } }()
                    let fam: ModelSchema.Family? = { if case .string(let f) = m["family"] { return ModelSchema.Family(rawValue: f) } else { return nil } }()
                    let toolsSupported: Bool = {
                        if case .object(let caps) = m["capabilities"],
                           case .object(let tools) = caps["tools"],
                           case .bool(let b) = tools["supported"] { return b }
                        return false
                    }()
                    builtModels.append(ModelSchema.Info(
                        id: ModelSchema.ID(rawValue: mid),
                        modelID: ModelSchema.ID(rawValue: mid),
                        providerID: pid,
                        type: { if case .string(let t) = m["type"] { return ModelSchema.ModelType(rawValue: t) } else { return .chat } }(),
                        family: fam,
                        name: mname,
                        package: pkg,
                        capabilities: ModelSchema.Capabilities(tools: toolsSupported, input: ["text"], output: ["text"]),
                        variants: [],
                        time: ModelSchema.Info.Time(released: 0),
                        cost: [ModelSchema.Cost(input: .zero, output: .zero, cache: ModelSchema.Cost.Cache(read: .zero, write: .zero))],
                        status: .active,
                        enabled: true,
                        limit: ModelSchema.Info.Limit(context: ctx, input: nil, output: out)
                    ))
                }
                guard !builtModels.isEmpty,
                      let defaultPkg = pkgCounts.max(by: { $0.value < $1.value })?.key
                else { continue }
                snapshots.append(Snapshot(
                    info: ProviderSchema.Info(id: pid, name: pname, activation: .auto, package: defaultPkg),
                    models: builtModels,
                    environment: env
                ))
            }
            return snapshots
        }

        // parity: core/src/models-dev.ts#Interface [status=implemented hash=08a58c77c944]
        public protocol Interface: Sendable {
            func get() async throws -> [Snapshot]
            func refresh(force: Bool) async
        }

        // parity: core/src/models-dev.ts#Service [status=implemented hash=e6f82121971f]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/ModelsDev"
            private let options: Options
            private let http: any HTTPTransport
            private let fileSystem: any OpenCodeFileSystem
            private let kv: any CoreKV.Interface
            private let cachedSnapshots = Mutex<[Snapshot]?>(nil)

            public init(
                options: Options = Options(),
                http: any HTTPTransport,
                fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
                kv: any CoreKV.Interface
            ) {
                self.options = options
                self.http = http
                self.fileSystem = fileSystem
                self.kv = kv
            }

            public func get() async throws -> [Snapshot] {
                if let cached = cachedSnapshots.withLock({ $0 }) { return cached }
                if let file = options.file, let bytes = try? await fileSystem.readFile(at: file) {
                    let parsed = try ModelsDev.decodeSnapshot(String(decoding: bytes, as: UTF8.self))
                    cachedSnapshots.withLock { $0 = parsed }
                    return parsed
                }
                if options.fetch == false { return [] }
                await refresh(force: true)
                return cachedSnapshots.withLock { $0 ?? [] }
            }

            public func refresh(force: Bool = false) async {
                _ = force
                let source = options.url ?? "https://models.opencode.ai"
                let url = "\(source)\(ModelsDev.catalogPath)"
                guard let resp = try? await http.send(HTTPRequest(method: "GET", url: url, headers: ["accept": "application/json"])),
                      (200..<300).contains(resp.head.statusCode)
                else { return }
                let text = String(decoding: resp.body, as: UTF8.self)
                guard let parsed = try? ModelsDev.decodeSnapshot(text) else { return }
                cachedSnapshots.withLock { $0 = parsed }
                try? await kv.set("models-dev:v2:catalog:meta", value: .object([
                    "updatedAt": .int(Flock.currentEpochMs()),
                    "digest": .string(ModelsDev.bodyDigest(text)),
                ]))
            }
        }

        // parity: core/src/models-dev.ts#layer [status=implemented hash=eb1de6460b85]
        public static func layer(_ options: Options = Options()) -> LayerNode.ExecutableLayer {
            LayerNode.ExecutableLayer { deps, _ in
                let http = deps.get(LayerNodePlatform.httpClientKey, as: (any HTTPTransport).self)
                    ?? LayerNodePlatform.FetchTransport { _ in
                        throw PlatformError.unsupportedOnPlatform(Platform.current, operation: "ModelsDev")
                    }
                let fs = deps.get(LayerNodePlatform.fileSystemKey, as: (any OpenCodeFileSystem).self) ?? LocalFileSystem.shared
                let kv = try deps.get(CoreKV.Service.serviceKey, as: CoreKV.Service.self) ?? CoreKV.Service.inMemory()
                return LayerNode.Output([Service.serviceKey: Service(options: options, http: http, fileSystem: fs, kv: kv)])
            }
        }

        // parity: core/src/models-dev.ts#configured [status=implemented hash=db51bec50564]
        public static func configured(_ options: Options = Options()) -> LayerNode.Provider {
            AppNode.makeGlobalNode(
                Service.serviceKey,
                layer(options),
                [LayerNodePlatform.httpClient, LayerNodePlatform.filesystem, CoreKV.node]
            )
        }

        // parity: core/src/models-dev.ts#node [status=implemented hash=aea3814ebc3b]
        public static let node: LayerNode.Provider = configured()
    }

    // MARK: - core/src/github-copilot/models.ts

    public enum CopilotModels {
        public enum Endpoint: String, Equatable, Hashable, Sendable, Codable {
            case messages, responses, chat
        }

        public struct RouteInfo: Equatable, Hashable, Sendable {
            public let endpoint: Endpoint
            public let package: String
            public let baseURL: String
        }

        public struct RemoteModel: Equatable, Hashable, Sendable, Codable {
            public struct Limits: Equatable, Hashable, Sendable, Codable {
                public let maxContextWindowTokens: Int?
                public let maxOutputTokens: Int?
                public let maxPromptTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case maxContextWindowTokens = "max_context_window_tokens"
                    case maxOutputTokens = "max_output_tokens"
                    case maxPromptTokens = "max_prompt_tokens"
                }

                public init(maxContextWindowTokens: Int? = nil, maxOutputTokens: Int? = nil, maxPromptTokens: Int? = nil) {
                    self.maxContextWindowTokens = maxContextWindowTokens
                    self.maxOutputTokens = maxOutputTokens
                    self.maxPromptTokens = maxPromptTokens
                }
            }

            public struct Supports: Equatable, Hashable, Sendable, Codable {
                public let adaptiveThinking: Bool?
                public let maxThinkingBudget: Int?
                public let reasoningEffort: [String]?
                public let toolCalls: Bool?
                public let vision: Bool?

                enum CodingKeys: String, CodingKey {
                    case adaptiveThinking = "adaptive_thinking"
                    case maxThinkingBudget = "max_thinking_budget"
                    case reasoningEffort = "reasoning_effort"
                    case toolCalls = "tool_calls"
                    case vision
                }

                public init(
                    adaptiveThinking: Bool? = nil,
                    maxThinkingBudget: Int? = nil,
                    reasoningEffort: [String]? = nil,
                    toolCalls: Bool? = nil,
                    vision: Bool? = nil
                ) {
                    self.adaptiveThinking = adaptiveThinking
                    self.maxThinkingBudget = maxThinkingBudget
                    self.reasoningEffort = reasoningEffort
                    self.toolCalls = toolCalls
                    self.vision = vision
                }
            }

            public struct Capabilities: Equatable, Hashable, Sendable, Codable {
                public let family: String
                public let limits: Limits?
                public let supports: Supports

                public init(family: String, limits: Limits? = nil, supports: Supports) {
                    self.family = family; self.limits = limits; self.supports = supports
                }
            }

            public struct Policy: Equatable, Hashable, Sendable, Codable {
                public let state: String?
                public init(state: String? = nil) { self.state = state }
            }

            public struct Billing: Equatable, Hashable, Sendable, Codable {
                public let autoDiscount: Double?
                enum CodingKeys: String, CodingKey { case autoDiscount = "auto_discount" }
                public init(autoDiscount: Double? = nil) { self.autoDiscount = autoDiscount }
            }

            public let modelPickerEnabled: Bool
            public let id: String
            public let name: String
            public let version: String
            public let supportedEndpoints: [String]?
            public let policy: Policy?
            public let billing: Billing?
            public let capabilities: Capabilities

            enum CodingKeys: String, CodingKey {
                case modelPickerEnabled = "model_picker_enabled"
                case id, name, version, policy, billing, capabilities
                case supportedEndpoints = "supported_endpoints"
            }

            public init(
                modelPickerEnabled: Bool,
                id: String,
                name: String,
                version: String,
                supportedEndpoints: [String]? = nil,
                policy: Policy? = nil,
                billing: Billing? = nil,
                capabilities: Capabilities
            ) {
                self.modelPickerEnabled = modelPickerEnabled; self.id = id; self.name = name; self.version = version
                self.supportedEndpoints = supportedEndpoints; self.policy = policy; self.billing = billing; self.capabilities = capabilities
            }
        }

        // parity: core/src/github-copilot/models.ts#Snapshot [status=implemented hash=efbefea97692]
        public typealias Snapshot = [String: RemoteModel]

        // parity: core/src/github-copilot/models.ts#auto [status=implemented hash=35eed04163c5]
        public static let auto = ModelSchema.ID(rawValue: "auto")

        // parity: core/src/github-copilot/models.ts#routeFor [status=implemented hash=44a06e3dcbc4]
        public static func routeFor(modelID: String, advertised: Endpoint?, root: String) -> RouteInfo {
            let selected: Endpoint
            if let advertised {
                selected = advertised
            } else {
                var fallback: Endpoint = .chat
                if modelID.hasPrefix("gpt-"),
                   let rest = modelID.dropFirst(4).split(whereSeparator: { !$0.isNumber }).first,
                   let major = Int(rest), major >= 5, !modelID.hasPrefix("gpt-5-mini") {
                    fallback = .responses
                } else if modelID.hasPrefix("grok-") || modelID.hasPrefix("mai-code-") {
                    fallback = .responses
                }
                selected = fallback
            }
            let pkg: String
            switch selected {
            case .messages: pkg = "@opencode/ai/providers/anthropic"
            case .responses: pkg = "@opencode/ai/providers/openai-compatible-responses"
            case .chat: pkg = "@opencode/ai/providers/openai-compatible"
            }
            return RouteInfo(
                endpoint: selected,
                package: pkg,
                baseURL: selected == .messages ? "\(root)/v1" : root
            )
        }

        private static func advertisedEndpoint(_ endpoints: [String]?) -> Endpoint? {
            guard let endpoints else { return nil }
            if endpoints.contains("/v1/messages") { return .messages }
            if endpoints.contains("/responses") { return .responses }
            if endpoints.contains("/chat/completions") { return .chat }
            return nil
        }

        private static func isUsable(_ m: RemoteModel) -> Bool {
            m.policy?.state != "disabled" &&
                m.capabilities.limits?.maxOutputTokens != nil &&
                m.capabilities.limits?.maxPromptTokens != nil &&
                m.capabilities.supports.toolCalls != nil
        }

        // parity: core/src/github-copilot/models.ts#load [status=implemented hash=d8e759a7dad2]
        public static func load(
            http: any HTTPTransport,
            baseURL: String,
            headers: [String: String]
        ) async throws -> Snapshot {
            let resp = try await http.send(HTTPRequest(method: "GET", url: "\(baseURL)/models", headers: headers))
            guard (200..<300).contains(resp.head.statusCode) else {
                throw PlatformError.ioFailure("Copilot models fetch failed (HTTP \(resp.head.statusCode))")
            }
            struct Envelope: Decodable { let data: [JSONValue] }
            let env = try JSONDecoder().decode(Envelope.self, from: Data(resp.body))
            let enc = JSONEncoder()
            let dec = JSONDecoder()
            var map: Snapshot = [:]
            for raw in env.data {
                guard let d = try? enc.encode(raw),
                      let model = try? dec.decode(RemoteModel.self, from: d),
                      isUsable(model)
                else { continue }
                map[model.id] = model
            }
            return map
        }

        private static func buildModel(
            id: ModelSchema.ID,
            remote: RemoteModel,
            baseURL: String,
            previous: ModelSchema.Info? = nil
        ) -> ModelSchema.Info {
            let route = routeFor(modelID: remote.id, advertised: advertisedEndpoint(remote.supportedEndpoints), root: baseURL)
            var inputMods = ["text"]
            if remote.capabilities.supports.vision == true { inputMods.append("image") }
            return ModelSchema.Info(
                id: id,
                modelID: ModelSchema.ID(rawValue: remote.id),
                providerID: ProviderSchema.ID.githubCopilot,
                family: previous?.family ?? ModelSchema.Family(rawValue: remote.capabilities.family),
                name: previous?.name ?? remote.name,
                package: route.package,
                settings: ModelSchema.Settings(extra: ["baseURL": .string(route.baseURL)]),
                headers: previous?.headers,
                body: previous?.body,
                capabilities: ModelSchema.Capabilities(
                    tools: remote.capabilities.supports.toolCalls ?? false,
                    input: inputMods,
                    output: ["text"]
                ),
                variants: [],
                time: previous?.time ?? ModelSchema.Info.Time(released: 0),
                cost: [ModelSchema.Cost(input: .zero, output: .zero, cache: ModelSchema.Cost.Cache(read: .zero, write: .zero))],
                status: .active,
                enabled: remote.modelPickerEnabled,
                limit: ModelSchema.Info.Limit(
                    context: remote.capabilities.limits?.maxContextWindowTokens ?? remote.capabilities.limits?.maxPromptTokens ?? 0,
                    input: remote.capabilities.limits?.maxPromptTokens,
                    output: remote.capabilities.limits?.maxOutputTokens ?? 0
                )
            )
        }

        // parity: core/src/github-copilot/models.ts#derive [status=implemented hash=40fccfba7064]
        public static func derive(
            baseURL: String,
            remote: Snapshot,
            existing: [ModelSchema.Info]
        ) -> [ModelSchema.ID: ModelSchema.Info] {
            var result: [ModelSchema.ID: ModelSchema.Info] = [:]
            for m in existing {
                if let cur = remote[m.modelID.rawValue] {
                    result[m.id] = buildModel(id: m.id, remote: cur, baseURL: baseURL, previous: m)
                }
            }
            for (idStr, cur) in remote {
                let key = ModelSchema.ID(rawValue: idStr)
                if result[key] == nil {
                    result[key] = buildModel(id: key, remote: cur, baseURL: baseURL)
                }
            }
            return result
        }

        // parity: core/src/github-copilot/models.ts#autoModel [status=implemented hash=62ab99c3021d]
        public static func autoModel(baseURL: String, remote: Snapshot) -> ModelSchema.Info? {
            let pool = remote.values.filter { $0.billing?.autoDiscount != nil }
            guard !pool.isEmpty else { return nil }
            let route = routeFor(modelID: auto.rawValue, advertised: .chat, root: baseURL)
            let minContext = pool.compactMap { $0.capabilities.limits?.maxContextWindowTokens ?? $0.capabilities.limits?.maxPromptTokens }.min() ?? 0
            let minInput = pool.compactMap { $0.capabilities.limits?.maxPromptTokens }.min() ?? 0
            let minOutput = pool.compactMap { $0.capabilities.limits?.maxOutputTokens }.min() ?? 0
            return ModelSchema.Info(
                id: auto,
                modelID: auto,
                providerID: ProviderSchema.ID.githubCopilot,
                name: "Auto",
                package: route.package,
                settings: ModelSchema.Settings(extra: ["baseURL": .string(route.baseURL)]),
                capabilities: ModelSchema.Capabilities(tools: true, input: ["text", "image"], output: ["text"]),
                variants: [],
                time: ModelSchema.Info.Time(released: 0),
                cost: [ModelSchema.Cost(input: .zero, output: .zero, cache: ModelSchema.Cost.Cache(read: .zero, write: .zero))],
                status: .active,
                enabled: true,
                limit: ModelSchema.Info.Limit(context: minContext, input: minInput, output: minOutput)
            )
        }

        // parity: core/src/github-copilot/models.ts#get [status=implemented hash=e7e2845fec96]
        public static func get(
            http: any HTTPTransport,
            baseURL: String,
            headers: [String: String],
            existing: [ModelSchema.Info]
        ) async throws -> [ModelSchema.ID: ModelSchema.Info] {
            let snap = try await load(http: http, baseURL: baseURL, headers: headers)
            return derive(baseURL: baseURL, remote: snap, existing: existing)
        }
    }
}

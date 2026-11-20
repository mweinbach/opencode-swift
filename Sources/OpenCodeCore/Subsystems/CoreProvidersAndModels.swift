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

        // parity: core/src/credential.ts#Interface [status=implemented hash=85560a5f7c2d]
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

            /// Decodes a stored SQLite credential `value` JSON blob cleanly, supporting both integer
            /// and floating-point OAuth `expires` timestamps as well as legacy pre-v2.1 `configuration`
            /// objects on key credentials (matching `credential-legacy.ts`).
            public static func decodeStoredValue(_ rawJSON: String, fallbackMethodID: String? = nil) -> Value? {
                guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(rawJSON.utf8)),
                      case .object(let obj) = parsed,
                      case .string(let typeStr) = obj["type"]
                else { return nil }

                let metadata: [String: JSONValue]?
                if let rawMeta = obj["metadata"], rawMeta != .null {
                    guard case .object(let dict) = rawMeta else { return nil }
                    metadata = dict
                } else {
                    metadata = nil
                }

                switch typeStr {
                case "oauth":
                    let methodRaw: String?
                    if case .string(let s) = obj["methodID"], !s.isEmpty {
                        methodRaw = s
                    } else if let fallback = fallbackMethodID, !fallback.isEmpty {
                        methodRaw = fallback
                    } else {
                        methodRaw = nil
                    }
                    guard let methodRaw,
                          case .string(let refresh) = obj["refresh"],
                          case .string(let access) = obj["access"]
                    else { return nil }

                    let expiresInt: Int?
                    switch obj["expires"] {
                    case .int(let i) where i >= 0:
                        expiresInt = Int(i)
                    case .double(let d) where d.isFinite && d >= 0 && d < Double(Int.max):
                        expiresInt = Int(d)
                    default:
                        expiresInt = nil
                    }
                    guard let expiresInt,
                          let expires = SchemaPrimitive.NonNegativeInt(rawValue: expiresInt)
                    else { return nil }

                    return .oauth(OAuth(
                        methodID: IntegrationMethodID(rawValue: methodRaw),
                        refresh: refresh,
                        access: access,
                        expires: expires,
                        metadata: metadata
                    ))

                case "key":
                    guard case .string(let key) = obj["key"] else { return nil }
                    let effectiveMetadata: [String: JSONValue]?
                    if case .object(let config) = obj["configuration"] {
                        var merged = metadata ?? [:]
                        for (k, v) in config {
                            merged[k] = v
                        }
                        effectiveMetadata = merged
                    } else {
                        effectiveMetadata = metadata
                    }
                    return .key(Key(key: key, metadata: effectiveMetadata))

                case "external":
                    let methodRaw: String?
                    if case .string(let s) = obj["methodID"], !s.isEmpty {
                        methodRaw = s
                    } else if let fallback = fallbackMethodID, !fallback.isEmpty {
                        methodRaw = fallback
                    } else {
                        methodRaw = nil
                    }
                    guard let methodRaw else { return nil }
                    return .external(External(
                        methodID: IntegrationMethodID(rawValue: methodRaw),
                        metadata: metadata
                    ))

                default:
                    return nil
                }
            }

            private static func decodeRow(_ row: SQLiteRow) -> Info? {
                guard let idRaw = row.string("id"),
                      let integrationRaw = row.string("integration_id"),
                      !integrationRaw.isEmpty,
                      let label = row.string("label"),
                      let valRaw = row.string("value"),
                      let value = Self.decodeStoredValue(valRaw, fallbackMethodID: row.string("method_id"))
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

        // parity: core/src/aisdk.ts#locationLayer [status=implemented hash=4d2e179515a2]
        public static let locationLayer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { _, _ in
            LayerNode.Output([Service.serviceKey: Service()])
        }

        // parity: core/src/aisdk.ts#node [status=adapted hash=3231454d6c02]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            locationLayer,
            []
        )
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

        // parity: core/src/model-retry.ts#policy [status=implemented hash=82338bc34ebe]
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

            // parity: core/src/model-resolver.ts#VariantUnavailableError.message [status=implemented hash=f1332e6907af]
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

            // parity: core/src/model-resolver.ts#UnsupportedPackageError.message [status=implemented hash=babeff35a9c4]
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

            // parity: core/src/model-resolver.ts#ModelConfigurationError.message [status=implemented hash=8fa7eedb07c5]
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

            // parity: core/src/model-resolver.ts#ModelInitializationError.message [status=implemented hash=8fa7eedb07c5]
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

            // parity: core/src/model-resolver.ts#UnresolvedProviderVariablesError.message [status=implemented hash=8fa7eedb07c5]
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

            // parity: core/src/model-resolver.ts#UnsupportedCompactionError.message [status=implemented hash=9513faef6aa3]
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

            /// Instantiates a live runnable `AISchema.LanguageModel` from this resolved catalog descriptor.
            public func makeLanguageModel(
                transport: (any HTTPTransport)? = nil,
                environment: any EnvironmentProviding = SystemEnvironment.shared,
                clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
            ) throws -> AISchema.LanguageModel {
                var effectiveSettings = model.settings
                if let baseURL = model.baseURL, effectiveSettings["baseURL"] == nil {
                    effectiveSettings["baseURL"] = .string(baseURL)
                }
                let timeout: AISchema.RequestTimeout? = chunkTimeout.map { opt in
                    let chunk: AISchema.HttpTimeout = switch opt {
                    case .disabled: .disabled
                    case .milliseconds(let ms): .milliseconds(ms)
                    }
                    return .phases(AISchema.TimeoutConfig(chunk: chunk))
                }
                return try AIProviders.makeLanguageModel(
                    package: model.package,
                    modelID: model.id,
                    settings: effectiveSettings,
                    headers: model.headers.isEmpty ? nil : model.headers,
                    body: model.body.isEmpty ? nil : model.body,
                    timeout: timeout,
                    environment: environment,
                    transport: transport,
                    clock: clock
                )
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

        // parity: core/src/model-resolver.ts#withVariant [status=implemented hash=cc7a8984e83a]
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

            /// Resolves a model reference from the live catalog and returns a runnable `AISchema.LanguageModel`
            /// wired to the appropriate `AIProviders` protocol route and `OpenCodePlatform.HTTPTransport`.
            public func resolveLanguageModel(
                _ requested: ModelSchema.Ref? = nil,
                transport: (any HTTPTransport)? = nil,
                clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
            ) async throws -> AISchema.LanguageModel? {
                guard let resolved = try await resolve(requested) else { return nil }
                return try resolved.makeLanguageModel(
                    transport: transport,
                    environment: dependencies.environment,
                    clock: clock
                )
            }

            /// Resolves a specific catalog `ModelSchema.Info` (with optional variant) into a runnable `AISchema.LanguageModel`.
            public func resolveLanguageModel(
                _ model: ModelSchema.Info,
                variant: ModelSchema.VariantID? = nil,
                transport: (any HTTPTransport)? = nil,
                clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
            ) async throws -> AISchema.LanguageModel {
                let resolved = try await resolveModel(model, variant: variant)
                return try resolved.makeLanguageModel(
                    transport: transport,
                    environment: dependencies.environment,
                    clock: clock
                )
            }
        }

        // parity: core/src/model-resolver.ts#layer [status=implemented hash=9a12d882bc0e]
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
        public enum DecodeError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
            case invalidJSON(String)
            case expectedObject

            public var description: String {
                switch self {
                case .invalidJSON(let detail):
                    return "Invalid ModelsDev catalog JSON: \(detail)"
                case .expectedObject:
                    return "Expected top-level JSON object for ModelsDev catalog"
                }
            }
        }

        public enum Event {
            public static let refreshed = EventSchema.ephemeral(
                type: ModelsDevSchema.Event.refreshed.type,
                identifier: "ModelsDev.Refreshed",
                data: EventSchema.EmptyData.self
            )
            public static let Refreshed = refreshed
            public static let definitions: [SchemaPrimitive.EventDescriptor] = ModelsDevSchema.Event.definitions
        }

        private static func int64Value(_ value: JSONValue?) -> Int64? {
            switch value {
            case .int(let i): return i
            case .double(let d) where d.isFinite && d >= Double(Int64.min) && d < Double(Int64.max):
                return Int64(d)
            default: return nil
            }
        }

        /// Lightweight RFC 8259 JSON AST preserving exact object key insertion order.
        /// Required because models.dev v2 `api`, `cache.write`, and multiplier objects are order-sensitive
        /// (the first API entry is the model's default route).
        private indirect enum OrderedJSON: Sendable {
            case null
            case bool(Bool)
            case int(Int64)
            case double(Double)
            case string(String)
            case array([OrderedJSON])
            case object([(String, OrderedJSON)])

            var doubleValue: Double? {
                switch self {
                case .double(let d) where d.isFinite: return d
                case .int(let i): return Double(i)
                default: return nil
                }
            }

            var intValue: Int? {
                switch self {
                case .int(let i): return Int(i)
                case .double(let d) where d.isFinite: return Int(d)
                default: return nil
                }
            }

            var stringValue: String? {
                if case .string(let s) = self { return s }
                return nil
            }

            var boolValue: Bool? {
                if case .bool(let b) = self { return b }
                return nil
            }

            var arrayValue: [OrderedJSON]? {
                if case .array(let arr) = self { return arr }
                return nil
            }

            var objectValue: [(String, OrderedJSON)]? {
                if case .object(let pairs) = self { return pairs }
                return nil
            }

            func toJSONValue() -> JSONValue {
                switch self {
                case .null: return .null
                case .bool(let b): return .bool(b)
                case .int(let i): return .int(i)
                case .double(let d): return .double(d)
                case .string(let s): return .string(s)
                case .array(let arr): return .array(arr.map { $0.toJSONValue() })
                case .object(let pairs):
                    var dict: [String: JSONValue] = [:]
                    dict.reserveCapacity(pairs.count)
                    for (k, v) in pairs {
                        dict[k] = v.toJSONValue()
                    }
                    return .object(dict)
                }
            }

            static func fromJSONValue(_ value: JSONValue) -> OrderedJSON {
                switch value {
                case .null: return .null
                case .bool(let b): return .bool(b)
                case .int(let i): return .int(i)
                case .double(let d): return .double(d)
                case .string(let s): return .string(s)
                case .array(let arr): return .array(arr.map(fromJSONValue))
                case .object(let dict):
                    return .object(dict.sorted(by: { $0.key < $1.key }).map { ($0.key, fromJSONValue($0.value)) })
                }
            }

            static func parse(_ text: String) throws -> OrderedJSON {
                let bytes = Array(text.utf8)
                var parser = Parser(bytes: bytes)
                let root = try parser.parseRoot()
                return root
            }

            private struct Parser {
                let bytes: [UInt8]
                let count: Int
                var pos: Int = 0

                init(bytes: [UInt8]) {
                    self.bytes = bytes
                    self.count = bytes.count
                    // Strip UTF-8 BOM if present
                    if count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
                        self.pos = 3
                    }
                }

                mutating func parseRoot() throws -> OrderedJSON {
                    skipWhitespace()
                    guard pos < count else {
                        throw DecodeError.invalidJSON("Empty input")
                    }
                    let val = try parseValue(depth: 0)
                    skipWhitespace()
                    guard pos == count else {
                        throw DecodeError.invalidJSON("Unexpected trailing data at byte \(pos)")
                    }
                    return val
                }

                mutating func skipWhitespace() {
                    while pos < count {
                        let b = bytes[pos]
                        if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                            pos += 1
                        } else {
                            break
                        }
                    }
                }

                mutating func parseValue(depth: Int) throws -> OrderedJSON {
                    guard depth < 256 else {
                        throw DecodeError.invalidJSON("Maximum nesting depth exceeded")
                    }
                    skipWhitespace()
                    guard pos < count else {
                        throw DecodeError.invalidJSON("Unexpected end of input")
                    }
                    switch bytes[pos] {
                    case 0x7B: // {
                        return try parseObject(depth: depth + 1)
                    case 0x5B: // [
                        return try parseArray(depth: depth + 1)
                    case 0x22: // "
                        return .string(try parseString())
                    case 0x74: // t
                        try expectLiteral([0x74, 0x72, 0x75, 0x65]) // true
                        return .bool(true)
                    case 0x66: // f
                        try expectLiteral([0x66, 0x61, 0x6C, 0x73, 0x65]) // false
                        return .bool(false)
                    case 0x6E: // n
                        try expectLiteral([0x6E, 0x75, 0x6C, 0x6C]) // null
                        return .null
                    case 0x2D, 0x30...0x39: // - or 0-9
                        return try parseNumber()
                    default:
                        throw DecodeError.invalidJSON("Unexpected byte \(bytes[pos]) at offset \(pos)")
                    }
                }

                mutating func expectLiteral(_ expected: [UInt8]) throws {
                    guard pos + expected.count <= count else {
                        throw DecodeError.invalidJSON("Unexpected end of input")
                    }
                    for i in 0..<expected.count {
                        if bytes[pos + i] != expected[i] {
                            throw DecodeError.invalidJSON("Invalid literal at offset \(pos)")
                        }
                    }
                    pos += expected.count
                }

                mutating func parseObject(depth: Int) throws -> OrderedJSON {
                    pos += 1 // skip '{'
                    skipWhitespace()
                    var pairs: [(String, OrderedJSON)] = []
                    if pos < count && bytes[pos] == 0x7D { // '}'
                        pos += 1
                        return .object(pairs)
                    }
                    while true {
                        skipWhitespace()
                        guard pos < count && bytes[pos] == 0x22 else {
                            throw DecodeError.invalidJSON("Expected string key at offset \(pos)")
                        }
                        let key = try parseString()
                        skipWhitespace()
                        guard pos < count && bytes[pos] == 0x3A else { // ':'
                            throw DecodeError.invalidJSON("Expected ':' at offset \(pos)")
                        }
                        pos += 1
                        let value = try parseValue(depth: depth)
                        pairs.append((key, value))
                        skipWhitespace()
                        guard pos < count else {
                            throw DecodeError.invalidJSON("Unterminated object")
                        }
                        let next = bytes[pos]
                        if next == 0x2C { // ','
                            pos += 1
                        } else if next == 0x7D { // '}'
                            pos += 1
                            return .object(pairs)
                        } else {
                            throw DecodeError.invalidJSON("Expected ',' or '}' at offset \(pos)")
                        }
                    }
                }

                mutating func parseArray(depth: Int) throws -> OrderedJSON {
                    pos += 1 // skip '['
                    skipWhitespace()
                    var items: [OrderedJSON] = []
                    if pos < count && bytes[pos] == 0x5D { // ']'
                        pos += 1
                        return .array(items)
                    }
                    while true {
                        let item = try parseValue(depth: depth)
                        items.append(item)
                        skipWhitespace()
                        guard pos < count else {
                            throw DecodeError.invalidJSON("Unterminated array")
                        }
                        let next = bytes[pos]
                        if next == 0x2C { // ','
                            pos += 1
                        } else if next == 0x5D { // ']'
                            pos += 1
                            return .array(items)
                        } else {
                            throw DecodeError.invalidJSON("Expected ',' or ']' at offset \(pos)")
                        }
                    }
                }

                mutating func parseString() throws -> String {
                    pos += 1 // skip opening '"'
                    let start = pos
                    while pos < count {
                        let b = bytes[pos]
                        if b == 0x22 { // '"'
                            let end = pos
                            pos += 1
                            return String(decoding: bytes[start..<end], as: UTF8.self)
                        }
                        if b == 0x5C { // '\\'
                            return try parseEscapedString(prefixStart: start)
                        }
                        if b < 0x20 {
                            throw DecodeError.invalidJSON("Unescaped control character at offset \(pos)")
                        }
                        pos += 1
                    }
                    throw DecodeError.invalidJSON("Unterminated string")
                }

                mutating func parseEscapedString(prefixStart: Int) throws -> String {
                    var out: [UInt8] = Array(bytes[prefixStart..<pos])
                    while pos < count {
                        let b = bytes[pos]
                        if b == 0x22 { // '"'
                            pos += 1
                            return String(decoding: out, as: UTF8.self)
                        }
                        if b == 0x5C { // '\\'
                            pos += 1
                            guard pos < count else {
                                throw DecodeError.invalidJSON("Unterminated escape sequence")
                            }
                            let esc = bytes[pos]
                            pos += 1
                            switch esc {
                            case 0x22: out.append(0x22) // "
                            case 0x5C: out.append(0x5C) // \
                            case 0x2F: out.append(0x2F) // /
                            case 0x62: out.append(0x08) // \b
                            case 0x66: out.append(0x0C) // \f
                            case 0x6E: out.append(0x0A) // \n
                            case 0x72: out.append(0x0D) // \r
                            case 0x74: out.append(0x09) // \t
                            case 0x75: // \uXXXX
                                let unit = try parseHex4()
                                let scalar: Unicode.Scalar
                                if (0xD800...0xDBFF).contains(unit) {
                                    guard pos + 6 <= count && bytes[pos] == 0x5C && bytes[pos + 1] == 0x75 else {
                                        throw DecodeError.invalidJSON("Unpaired high surrogate at offset \(pos)")
                                    }
                                    pos += 2
                                    let low = try parseHex4()
                                    guard (0xDC00...0xDFFF).contains(low) else {
                                        throw DecodeError.invalidJSON("Invalid low surrogate at offset \(pos)")
                                    }
                                    let combined = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                                    guard let s = Unicode.Scalar(combined) else {
                                        throw DecodeError.invalidJSON("Invalid Unicode scalar")
                                    }
                                    scalar = s
                                } else if (0xDC00...0xDFFF).contains(unit) {
                                    throw DecodeError.invalidJSON("Unpaired low surrogate at offset \(pos)")
                                } else {
                                    guard let s = Unicode.Scalar(unit) else {
                                        throw DecodeError.invalidJSON("Invalid Unicode scalar")
                                    }
                                    scalar = s
                                }
                                for u8 in scalar.utf8 {
                                    out.append(u8)
                                }
                            default:
                                throw DecodeError.invalidJSON("Invalid escape character at offset \(pos - 1)")
                            }
                        } else if b < 0x20 {
                            throw DecodeError.invalidJSON("Unescaped control character at offset \(pos)")
                        } else {
                            out.append(b)
                            pos += 1
                        }
                    }
                    throw DecodeError.invalidJSON("Unterminated string")
                }

                mutating func parseHex4() throws -> UInt32 {
                    guard pos + 4 <= count else {
                        throw DecodeError.invalidJSON("Incomplete unicode escape")
                    }
                    var value: UInt32 = 0
                    for _ in 0..<4 {
                        let b = bytes[pos]
                        pos += 1
                        let digit: UInt32
                        if b >= 0x30 && b <= 0x39 {
                            digit = UInt32(b - 0x30)
                        } else if b >= 0x41 && b <= 0x46 {
                            digit = UInt32(b - 0x41 + 10)
                        } else if b >= 0x61 && b <= 0x66 {
                            digit = UInt32(b - 0x61 + 10)
                        } else {
                            throw DecodeError.invalidJSON("Invalid hex digit in unicode escape")
                        }
                        value = (value << 4) | digit
                    }
                    return value
                }

                mutating func parseNumber() throws -> OrderedJSON {
                    let start = pos
                    var isNegative = false
                    if bytes[pos] == 0x2D { // '-'
                        isNegative = true
                        pos += 1
                    }
                    guard pos < count else {
                        throw DecodeError.invalidJSON("Incomplete number")
                    }
                    var intAccum: UInt64 = 0
                    var intOverflow = false
                    if bytes[pos] == 0x30 { // '0'
                        pos += 1
                        if pos < count && bytes[pos] >= 0x30 && bytes[pos] <= 0x39 {
                            throw DecodeError.invalidJSON("Leading zero in number at offset \(start)")
                        }
                    } else if bytes[pos] >= 0x31 && bytes[pos] <= 0x39 {
                        while pos < count && bytes[pos] >= 0x30 && bytes[pos] <= 0x39 {
                            let d = UInt64(bytes[pos] - 0x30)
                            if !intOverflow {
                                let (mul, o1) = intAccum.multipliedReportingOverflow(by: 10)
                                let (add, o2) = mul.addingReportingOverflow(d)
                                if o1 || o2 {
                                    intOverflow = true
                                } else {
                                    intAccum = add
                                }
                            }
                            pos += 1
                        }
                    } else {
                        throw DecodeError.invalidJSON("Invalid number at offset \(start)")
                    }

                    var isFloat = false
                    if pos < count && bytes[pos] == 0x2E { // '.'
                        isFloat = true
                        pos += 1
                        let fracStart = pos
                        while pos < count && bytes[pos] >= 0x30 && bytes[pos] <= 0x39 {
                            pos += 1
                        }
                        guard pos > fracStart else {
                            throw DecodeError.invalidJSON("Missing fraction digits at offset \(start)")
                        }
                    }
                    if pos < count && (bytes[pos] == 0x65 || bytes[pos] == 0x45) { // 'e' or 'E'
                        isFloat = true
                        pos += 1
                        if pos < count && (bytes[pos] == 0x2B || bytes[pos] == 0x2D) {
                            pos += 1
                        }
                        let expStart = pos
                        while pos < count && bytes[pos] >= 0x30 && bytes[pos] <= 0x39 {
                            pos += 1
                        }
                        guard pos > expStart else {
                            throw DecodeError.invalidJSON("Missing exponent digits at offset \(start)")
                        }
                    }

                    if !isFloat && !intOverflow {
                        if isNegative {
                            if intAccum == 0 {
                                return .int(0)
                            }
                            if intAccum == UInt64(Int64.max) + 1 {
                                return .int(Int64.min)
                            }
                            if intAccum <= UInt64(Int64.max) {
                                return .int(-Int64(intAccum))
                            }
                        } else if intAccum <= UInt64(Int64.max) {
                            return .int(Int64(intAccum))
                        }
                    }

                    let slice = String(decoding: bytes[start..<pos], as: UTF8.self)
                    guard let doubleVal = Double(slice), doubleVal.isFinite else {
                        throw DecodeError.invalidJSON("Invalid floating-point number '\(slice)'")
                    }
                    return .double(doubleVal)
                }
            }
        }

        private static func field(_ pairs: [(String, OrderedJSON)]?, _ key: String) -> OrderedJSON? {
            guard let pairs else { return nil }
            for (k, v) in pairs.reversed() {
                if k == key { return v }
            }
            return nil
        }

        private static func stringField(_ pairs: [(String, OrderedJSON)]?, _ key: String) -> String? {
            field(pairs, key)?.stringValue
        }

        private static func boolField(_ pairs: [(String, OrderedJSON)]?, _ key: String) -> Bool? {
            field(pairs, key)?.boolValue
        }

        private static func objectField(_ pairs: [(String, OrderedJSON)]?, _ key: String) -> [(String, OrderedJSON)]? {
            field(pairs, key)?.objectValue
        }

        private static func arrayField(_ pairs: [(String, OrderedJSON)]?, _ key: String) -> [OrderedJSON]? {
            field(pairs, key)?.arrayValue
        }

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

            private static func convertReasoning(_ model: [String: JSONValue]) -> JSONValue {
                guard case .bool(true) = model["reasoning"] else {
                    return .object(["supported": .bool(false)])
                }
                var out: [String: JSONValue] = ["supported": .bool(true)]
                if case .array(let options) = model["reasoning_options"] {
                    for optVal in options {
                        guard case .object(let opt) = optVal,
                              case .string(let optType) = opt["type"] else { continue }
                        switch optType {
                        case "toggle":
                            out["toggle"] = .bool(true)
                        case "effort":
                            if case .array(let vals) = opt["values"] {
                                let filtered: [JSONValue] = vals.compactMap { v in
                                    if case .string(let s) = v, s != "null" { return .string(s) }
                                    return nil
                                }
                                out["effort"] = .array(filtered)
                            }
                        case "budget_tokens":
                            var budget: [String: JSONValue] = [:]
                            if let minV = opt["min"], minV != .null { budget["min"] = minV }
                            if let maxV = opt["max"], maxV != .null { budget["max"] = maxV }
                            out["budget"] = .object(budget)
                        default:
                            break
                        }
                    }
                }
                return .object(out)
            }

            private static func convertCost(_ raw: JSONValue?) -> JSONValue? {
                guard case .object(let c) = raw else { return nil }
                var inputCache: [String: JSONValue] = [:]
                if let cr = c["cache_read"], cr != .null { inputCache["read"] = cr }
                if let cw = c["cache_write"], cw != .null { inputCache["write"] = cw }

                var inputOverrides: [JSONValue] = []
                var outputOverrides: [JSONValue] = []
                if case .array(let tiers) = c["tiers"] {
                    for tierVal in tiers {
                        guard case .object(let t) = tierVal,
                              case .object(let tierMeta) = t["tier"],
                              let sizeVal = tierMeta["size"], sizeVal != .null
                        else { continue }
                        let whenObj: JSONValue = .object(["context": .object(["gt": sizeVal])])
                        var inOv: [String: JSONValue] = ["when": whenObj]
                        if let ip = t["input"], ip != .null { inOv["price"] = ip }
                        var ovCache: [String: JSONValue] = [:]
                        if let cr = t["cache_read"], cr != .null { ovCache["read"] = cr }
                        if let cw = t["cache_write"], cw != .null { ovCache["write"] = cw }
                        if !ovCache.isEmpty { inOv["cache"] = .object(ovCache) }
                        inputOverrides.append(.object(inOv))

                        var outOv: [String: JSONValue] = ["when": whenObj]
                        if let op = t["output"], op != .null { outOv["price"] = op }
                        outputOverrides.append(.object(outOv))
                    }
                }

                var inputObj: [String: JSONValue] = [
                    "price": c["input"] ?? .int(0),
                ]
                if !inputCache.isEmpty { inputObj["cache"] = .object(inputCache) }
                if !inputOverrides.isEmpty { inputObj["overrides"] = .array(inputOverrides) }

                var outputObj: [String: JSONValue] = [
                    "price": c["output"] ?? .int(0),
                ]
                if !outputOverrides.isEmpty { outputObj["overrides"] = .array(outputOverrides) }

                return .object([
                    "text": .object([
                        "input": .object(inputObj),
                        "output": .object(outputObj),
                    ]),
                ])
            }

            /// Converts a models.dev v1 catalog dictionary into the v2 shape.
            // parity: core/src/models-dev/v1.ts#toV2 [status=implemented hash=cf5eb404eb08]
            public static func toV2(_ catalog: [String: JSONValue]) -> [String: JSONValue] {
                var out: [String: JSONValue] = [:]
                for (key, value) in catalog {
                    guard case .object(let prov) = value,
                          case .string(let pid) = prov["id"],
                          case .string(let pname) = prov["name"],
                          case .object(let rawModels) = prov["models"]
                    else { continue }
                    let npm: String = if case .string(let n) = prov["npm"] { n } else { "" }
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
                        if case .string(let n) = modelProv?["npm"], !n.isEmpty { mNpm = n }
                        guard !mNpm.isEmpty else { continue }
                        var mApi = provApi
                        if case .string(let a) = modelProv?["api"] { mApi = a }
                        var shape: String? = nil
                        if case .string(let s) = modelProv?["shape"] { shape = s }
                        let proto = (shape == "responses" || (shape == nil && responsesByDefault.contains(mNpm))) ? "responses" : "chat-completions"
                        let toolCall: Bool = { if case .bool(let b) = m["tool_call"] { return b } else { return false } }()
                        let mType = m["type"] ?? .string("chat")
                        let modalities = m["modalities"] ?? .object(["input": .array([.string("text")]), "output": .array([.string("text")])])

                        var caps: [String: JSONValue] = [
                            "tools": .object(["supported": .bool(toolCall)]),
                            "reasoning": convertReasoning(m),
                        ]
                        if case .bool(let temp) = m["temperature"] {
                            caps["temperature"] = .bool(temp)
                        }

                        var apiEntry: [String: JSONValue] = [
                            "base_url": .string(mApi),
                            "sdk": .object(["aisdk": .string(mNpm)]),
                        ]
                        let reasoningField: String? = {
                            if case .string(let s) = m["interleaved"] { return s }
                            if case .object(let obj) = m["interleaved"], case .string(let f) = obj["field"] { return f }
                            return nil
                        }()
                        if let reasoningField {
                            apiEntry["compatibility"] = .object(["reasoning_field": .string(reasoningField)])
                        }

                        var converted: [String: JSONValue] = [
                            "id": .string(id),
                            "type": mType,
                            "name": .string(name),
                            "release_date": m["release_date"] ?? .string(""),
                            "modalities": modalities,
                            "capabilities": .object(caps),
                            "api": .object([proto: .object(apiEntry)]),
                        ]
                        if let fam = m["family"] { converted["family"] = fam }
                        if let lim = m["limit"] { converted["limit"] = lim }
                        if let st = m["status"] { converted["status"] = st }
                        if let costVal = convertCost(m["cost"]) { converted["cost"] = costVal }
                        if case .object(let exp) = m["experimental"], case .object(let modes) = exp["modes"] {
                            var convertedModes: [String: JSONValue] = [:]
                            for (modeName, modeVal) in modes {
                                guard case .object(let modeObj) = modeVal else { continue }
                                var nextMode: [String: JSONValue] = [:]
                                if let mc = convertCost(modeObj["cost"]) { nextMode["cost"] = mc }
                                if case .object(let mp) = modeObj["provider"] {
                                    if let b = mp["body"] { nextMode["body"] = b }
                                    if let h = mp["headers"] { nextMode["headers"] = h }
                                }
                                convertedModes[modeName] = .object(nextMode)
                            }
                            converted["experimental"] = .object(["modes": .object(convertedModes)])
                        }
                        convertedModels[mid] = .object(converted)
                    }
                    guard !convertedModels.isEmpty else { continue }
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

        /// Amazon Bedrock catalog IDs that require cross-region inference profiles and cannot be called directly.
        public static let bedrockProfileOnlyIDs: Set<String> = [
            "amazon.nova-2-lite-v1:0",
            "anthropic.claude-fable-5",
            "anthropic.claude-fable-5-1",
            "anthropic.claude-haiku-4-5-20251001-v1:0",
            "anthropic.claude-haiku-5-5",
            "anthropic.claude-opus-4-1-20250805-v1:0",
            "anthropic.claude-opus-4-5-20251101-v1:0",
            "anthropic.claude-opus-4-7",
            "anthropic.claude-opus-4-8",
            "anthropic.claude-opus-5",
            "anthropic.claude-sonnet-4-5-20250929-v1:0",
            "anthropic.claude-sonnet-5",
            "anthropic.claude-sonnet-5-5",
            "deepseek.r1-v1:0",
            "meta.llama4-maverick-17b-instruct-v1:0",
            "meta.llama4-scout-17b-instruct-v1:0",
            "mistral.pixtral-large-2502-v1:0",
            "writer.palmyra-x4-v1:0",
            "writer.palmyra-x5-v1:0",
        ]

        /// Filters decoded snapshots matching upstream `plugin/models-dev.ts`:
        /// removes deprecated provider aliases (`azure-cognitive-services`, `google-vertex-anthropic`),
        /// deprecated models, non-text chat models, Amazon Bedrock profile-only models, and empty providers.
        public static func filterSnapshots(_ data: [Snapshot]) -> [Snapshot] {
            data
                .filter { snap in
                    snap.info.id.rawValue != "azure-cognitive-services"
                        && snap.info.id.rawValue != "google-vertex-anthropic"
                }
                .compactMap { snap -> Snapshot? in
                    let filteredModels = snap.models.filter { model in
                        let effectiveID = model.modelID.rawValue.isEmpty ? model.id.rawValue : model.modelID.rawValue
                        return model.status != .deprecated
                            && ((model.type ?? .chat) != .chat || Model.supportsText(model))
                            && !(snap.info.id == .amazonBedrock && bedrockProfileOnlyIDs.contains(effectiveID))
                    }
                    guard !filteredModels.isEmpty else { return nil }
                    return Snapshot(info: snap.info, models: filteredModels, environment: snap.environment)
                }
        }

        private static let supportedModelTypes: Set<String> = ["chat", "decision", "image", "video"]

        private static let compatiblePackages: Set<String> = [
            "@opencode/ai/providers/openai-compatible",
            "@opencode/ai/providers/anthropic-compatible",
        ]

        private static let buildsOwnURL: Set<String> = [
            "@opencode/ai/providers/amazon-bedrock",
            "@opencode/ai/providers/azure/chat",
            "@opencode/ai/providers/azure/images",
            "@opencode/ai/providers/azure/messages",
            "@opencode/ai/providers/azure/responses",
            "@opencode/ai/providers/cloudflare-ai-gateway",
            "@opencode/ai/providers/cloudflare-ai-gateway/decisions",
            "@opencode/ai/providers/cloudflare-workers-ai",
            "@opencode/ai/providers/cloudflare-workers-ai/decisions",
            "@opencode/ai/providers/cloudflare-workers-ai/images",
            "@opencode/ai/providers/google-vertex/gemini",
            "@opencode/ai/providers/google-vertex/images",
            "@opencode/ai/providers/google-vertex/messages",
            "aisdk:@jerome-benoit/sap-ai-provider-v2",
            "aisdk:watsonx-ai-provider",
        ]

        private static func normalizeModality(_ raw: String) -> String {
            if raw == "application/pdf" { return "pdf" }
            let kind = raw.split(separator: "/", maxSplits: 1).first.map(String.init) ?? raw
            if kind == "text" || kind == "image" || kind == "audio" || kind == "video" {
                return kind
            }
            return raw
        }

        private static func decodeModalities(_ value: OrderedJSON?) -> [String] {
            guard let items = value?.arrayValue else { return ["text"] }
            var seen: Set<String> = []
            var out: [String] = []
            for item in items {
                guard let s = item.stringValue, !s.isEmpty else { continue }
                let norm = normalizeModality(s)
                if seen.insert(norm).inserted {
                    out.append(norm)
                }
            }
            return out.isEmpty ? ["text"] : out
        }

        private static func decodeReasoning(_ value: OrderedJSON?) -> ConfigProviderSchema.Reasoning {
            guard let obj = value?.objectValue,
                  boolField(obj, "supported") == true
            else {
                return .unsupported
            }
            let toggle = boolField(obj, "toggle")
            let effort: [String]? = arrayField(obj, "effort").map { arr in
                arr.compactMap(\.stringValue)
            }
            let budget: ConfigProviderSchema.ReasoningBudget? = objectField(obj, "budget").map { bObj in
                ConfigProviderSchema.ReasoningBudget(
                    min: field(bObj, "min")?.intValue,
                    max: field(bObj, "max")?.intValue
                )
            }
            return .supported(toggle: toggle, effort: effort, budget: budget)
        }

        /// Pure portable ISO-8601 date parser matching JS `Date.parse(release_date)` (returns epoch ms or `0`).
        public static func parseReleaseDateMs(_ raw: String) -> Double {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return 0 }
            let dateAndTime = trimmed.split(separator: "T", maxSplits: 1)
            let dateParts = dateAndTime[0].split(separator: "-")
            guard !dateParts.isEmpty, let year = Int(dateParts[0]) else { return 0 }
            let month = dateParts.count >= 2 ? (Int(dateParts[1]) ?? 0) : 1
            let day = dateParts.count >= 3 ? (Int(dateParts[2]) ?? 0) : 1
            guard (1...12).contains(month), (1...31).contains(day) else { return 0 }

            var hour = 0
            var minute = 0
            var second = 0
            var millis = 0
            var tzOffsetSeconds = 0

            if dateAndTime.count == 2 {
                var timeStr = String(dateAndTime[1])
                if timeStr.hasSuffix("Z") || timeStr.hasSuffix("z") {
                    timeStr.removeLast()
                } else if let plusIdx = timeStr.lastIndex(of: "+") {
                    let tz = String(timeStr[timeStr.index(after: plusIdx)...])
                    timeStr = String(timeStr[..<plusIdx])
                    let tzParts = tz.split(separator: ":").compactMap { Int($0) }
                    if tzParts.count >= 2 { tzOffsetSeconds = tzParts[0] * 3600 + tzParts[1] * 60 }
                } else if let minusIdx = timeStr.lastIndex(of: "-"), minusIdx > timeStr.startIndex {
                    let tz = String(timeStr[timeStr.index(after: minusIdx)...])
                    timeStr = String(timeStr[..<minusIdx])
                    let tzParts = tz.split(separator: ":").compactMap { Int($0) }
                    if tzParts.count >= 2 { tzOffsetSeconds = -(tzParts[0] * 3600 + tzParts[1] * 60) }
                }
                let hms = timeStr.split(separator: ":")
                if hms.count >= 2, let h = Int(hms[0]), let m = Int(hms[1]) {
                    hour = h
                    minute = m
                    if hms.count >= 3 {
                        let secParts = hms[2].split(separator: ".", maxSplits: 1)
                        second = Int(secParts[0]) ?? 0
                        if secParts.count == 2 {
                            let frac = String(secParts[1].prefix(3))
                            let padded = frac + String(repeating: "0", count: max(0, 3 - frac.count))
                            millis = Int(padded) ?? 0
                        }
                    }
                }
            }

            // Howard Hinnant civil-to-days algorithm (pure arithmetic, zero Calendar/Locale dependencies).
            let adjY = month <= 2 ? year - 1 : year
            let era = (adjY >= 0 ? adjY : adjY - 399) / 400
            let yoe = adjY - era * 400
            let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            let daysSinceEpoch = era * 146_097 + doe - 719_468
            let totalSeconds = Int64(daysSinceEpoch) * 86_400
                + Int64(hour * 3600 + minute * 60 + second)
                - Int64(tzOffsetSeconds)
            return Double(totalSeconds) * 1000.0 + Double(millis)
        }

        private static func makeUSD(_ value: Double?) -> MoneySchema.USDPerMillionTokens {
            guard let value, let money = MoneySchema.USDPerMillionTokens(rawValue: value) else {
                return .zero
            }
            return money
        }

        private static func extractCacheWrite(_ cacheVal: OrderedJSON?) -> Double? {
            guard let cache = cacheVal?.objectValue else { return nil }
            func firstWrite(_ raw: OrderedJSON?) -> Double? {
                guard let raw else { return nil }
                if let n = raw.doubleValue { return n }
                if let pairs = raw.objectValue {
                    // Preserves JSON insertion order (matching JS `Object.values(write)[0]`).
                    for (_, val) in pairs {
                        if let n = val.doubleValue { return n }
                    }
                }
                return nil
            }
            if let direct = firstWrite(field(cache, "write")) { return direct }
            if let explicit = objectField(cache, "explicit") {
                return firstWrite(field(explicit, "write"))
            }
            return nil
        }

        private static func decodeCost(_ raw: OrderedJSON?) -> [ModelSchema.Cost] {
            let zeroCost = [ModelSchema.Cost(input: .zero, output: .zero, cache: ModelSchema.Cost.Cache(read: .zero, write: .zero))]
            guard let obj = raw?.objectValue else { return zeroCost }

            // Direct v2 shape: `cost.text.{input, output}`
            if let text = objectField(obj, "text"),
               let textIn = objectField(text, "input"),
               let textOut = objectField(text, "output") {
                let inUnit = stringField(textIn, "unit")
                let outUnit = stringField(textOut, "unit")
                guard (inUnit == nil || inUnit == "token"), (outUnit == nil || outUnit == "token") else {
                    return zeroCost
                }
                let baseIn = makeUSD(field(textIn, "price")?.doubleValue)
                let baseOut = makeUSD(field(textOut, "price")?.doubleValue)
                let baseCacheRead: MoneySchema.USDPerMillionTokens = {
                    if let c = objectField(textIn, "cache") { return makeUSD(field(c, "read")?.doubleValue) }
                    return .zero
                }()
                let baseCacheWrite = makeUSD(extractCacheWrite(field(textIn, "cache")))
                let base = ModelSchema.Cost(
                    tier: nil,
                    input: baseIn,
                    output: baseOut,
                    cache: ModelSchema.Cost.Cache(read: baseCacheRead, write: baseCacheWrite)
                )

                var tierOrder: [Int] = []
                var tiers: [Int: ModelSchema.Cost] = [:]

                func contextTierSize(_ whenVal: OrderedJSON?) -> Int? {
                    guard let when = whenVal?.objectValue, when.count == 1,
                          let ctx = objectField(when, "context")
                    else { return nil }
                    return field(ctx, "gt")?.intValue ?? field(ctx, "gte")?.intValue
                }

                if let inOverrides = arrayField(textIn, "overrides") {
                    for ovVal in inOverrides {
                        guard let ov = ovVal.objectValue,
                              let size = contextTierSize(field(ov, "when"))
                        else { continue }
                        let existing = tiers[size] ?? ModelSchema.Cost(
                            tier: ModelSchema.Cost.Tier(size: size),
                            input: base.input,
                            output: base.output,
                            cache: base.cache
                        )
                        if tiers[size] == nil { tierOrder.append(size) }
                        let ovPrice = field(ov, "price")?.doubleValue.flatMap(MoneySchema.USDPerMillionTokens.init(rawValue:)) ?? existing.input
                        let ovCacheRead: MoneySchema.USDPerMillionTokens = {
                            if let c = objectField(ov, "cache"),
                               let r = field(c, "read")?.doubleValue,
                               let m = MoneySchema.USDPerMillionTokens(rawValue: r) { return m }
                            return existing.cache.read
                        }()
                        let ovCacheWrite = extractCacheWrite(field(ov, "cache")).flatMap(MoneySchema.USDPerMillionTokens.init(rawValue:)) ?? existing.cache.write
                        tiers[size] = ModelSchema.Cost(
                            tier: ModelSchema.Cost.Tier(size: size),
                            input: ovPrice,
                            output: existing.output,
                            cache: ModelSchema.Cost.Cache(read: ovCacheRead, write: ovCacheWrite)
                        )
                    }
                }

                if let outOverrides = arrayField(textOut, "overrides") {
                    for ovVal in outOverrides {
                        guard let ov = ovVal.objectValue,
                              let size = contextTierSize(field(ov, "when"))
                        else { continue }
                        let existing = tiers[size] ?? ModelSchema.Cost(
                            tier: ModelSchema.Cost.Tier(size: size),
                            input: base.input,
                            output: base.output,
                            cache: base.cache
                        )
                        if tiers[size] == nil { tierOrder.append(size) }
                        let ovPrice = field(ov, "price")?.doubleValue.flatMap(MoneySchema.USDPerMillionTokens.init(rawValue:)) ?? existing.output
                        tiers[size] = ModelSchema.Cost(
                            tier: ModelSchema.Cost.Tier(size: size),
                            input: existing.input,
                            output: ovPrice,
                            cache: existing.cache
                        )
                    }
                }

                return [base] + tierOrder.compactMap { tiers[$0] }
            }

            // Flat cost fallback (`{ input, output, cache_read, cache_write }`)
            if field(obj, "input")?.doubleValue != nil || field(obj, "output")?.doubleValue != nil {
                return [ModelSchema.Cost(
                    input: makeUSD(field(obj, "input")?.doubleValue),
                    output: makeUSD(field(obj, "output")?.doubleValue),
                    cache: ModelSchema.Cost.Cache(
                        read: makeUSD(field(obj, "cache_read")?.doubleValue),
                        write: makeUSD(field(obj, "cache_write")?.doubleValue)
                    )
                )]
            }

            return zeroCost
        }

        private static func factorAt(_ factor: OrderedJSON, path: [String]) -> Double {
            var node: OrderedJSON? = factor
            for key in path {
                guard let current = node else { return 1 }
                if let n = current.doubleValue { return n }
                if let pairs = current.objectValue {
                    node = field(pairs, key)
                } else {
                    return 1
                }
            }
            guard let leaf = node else { return 1 }
            if let n = leaf.doubleValue { return n }
            if let pairs = leaf.objectValue {
                for (_, val) in pairs {
                    if let n = val.doubleValue { return n }
                }
            }
            return 1
        }

        private static func modeCost(
            modelCostRaw: OrderedJSON?,
            baseCost: [ModelSchema.Cost],
            modeName: String,
            modeObj: [(String, OrderedJSON)]
        ) -> [ModelSchema.Cost] {
            guard let baseDefault = baseCost.first else { return baseCost }
            let baseTiers = Array(baseCost.dropFirst())
            if let explicitModeCost = field(modeObj, "cost"), case .object = explicitModeCost {
                let decoded = decodeCost(explicitModeCost)
                if let first = decoded.first { return [first] + baseTiers }
            }
            let tierName = stringField(modeObj, "service_tier") ?? modeName
            guard let rawCostObj = modelCostRaw?.objectValue,
                  let multipliers = arrayField(rawCostObj, "multipliers")
            else { return baseCost }
            var matchedFactor: OrderedJSON? = nil
            for mVal in multipliers {
                guard let mObj = mVal.objectValue,
                      let when = objectField(mObj, "when"), when.count == 1,
                      let st = objectField(when, "service_tier"),
                      let eq = stringField(st, "equals"), eq == tierName,
                      let factor = field(mObj, "factor")
                else { continue }
                matchedFactor = factor
                break
            }
            guard let factor = matchedFactor else { return baseCost }
            func scale(_ price: MoneySchema.USDPerMillionTokens, _ path: [String]) -> MoneySchema.USDPerMillionTokens {
                let scaled = (price.rawValue * factorAt(factor, path: path) * 1e10).rounded() / 1e10
                return makeUSD(scaled)
            }
            let scaledDefault = ModelSchema.Cost(
                tier: nil,
                input: scale(baseDefault.input, ["text", "input", "price"]),
                output: scale(baseDefault.output, ["text", "output", "price"]),
                cache: ModelSchema.Cost.Cache(
                    read: scale(baseDefault.cache.read, ["text", "input", "cache", "read"]),
                    write: scale(baseDefault.cache.write, ["text", "input", "cache", "write"])
                )
            )
            return [scaledDefault] + baseTiers
        }

        private static func mostCommon(order: [String], counts: [String: Int]) -> String? {
            var bestKey: String?
            var bestCount = 0
            for key in order {
                let count = counts[key] ?? 0
                if bestKey == nil || count > bestCount {
                    bestKey = key
                    bestCount = count
                }
            }
            return bestKey
        }

        private static func loadableOpencodeAI(_ raw: String?) -> String? {
            guard let raw, !raw.isEmpty,
                  let name = CoreProvider.AISDKNative.packageName(raw)
            else { return nil }
            if !name.hasPrefix("@opencode/ai/") || CoreProvider.Provider.builtinPackages.contains(name) {
                return raw
            }
            return nil
        }

        /// Heuristic priority used ONLY when decoding an already-parsed unordered `[String: JSONValue]` dictionary
        /// (e.g. a KV cache row whose `body` was stored as a JSON object rather than raw JSON text).
        private static func unorderedAPIRank(protoKey: String, apiObj: [(String, OrderedJSON)]) -> Int {
            let sdk = objectField(apiObj, "sdk")
            let oc = loadableOpencodeAI(stringField(sdk, "opencodeai"))
            if let oc {
                let isGeneric = compatiblePackages.contains(oc)
                if !isGeneric {
                    // Prefer provider-native responses over chat for OpenAI / Azure / Cloudflare.
                    if protoKey == "responses" && (oc.contains("/openai/") || oc.contains("/azure/")) {
                        return 0
                    }
                    // Prefer root provider packages (e.g. `/anthropic`, `/google`, `/openrouter`, `/amazon-bedrock`).
                    let components = oc.split(separator: "/")
                    if components.count == 4 { // @opencode / ai / providers / <name>
                        return 1
                    }
                    if protoKey == "messages" || protoKey == "generate-content" || protoKey == "converse" || protoKey == "cohere-chat" {
                        return 2
                    }
                    if protoKey == "responses" {
                        return 3
                    }
                    if protoKey == "chat-completions" {
                        return 4
                    }
                    return 5
                }
                return 6
            }
            if stringField(sdk, "aisdk") != nil {
                return 7
            }
            return 8
        }

        private struct RoutedSource {
            let modelObj: [(String, OrderedJSON)]
            let id: String
            let name: String
            let typeStr: String
            let package: String
            let baseURL: String?
            let apiObj: [(String, OrderedJSON)]
        }

        private static func decodeV2Pairs(
            _ v2Pairs: [(String, OrderedJSON)],
            preserveAPIOrder: Bool,
            recommended: Bool = false
        ) -> [Snapshot] {
            var snapshots: [Snapshot] = []
            snapshots.reserveCapacity(v2Pairs.count)

            for (_, value) in v2Pairs {
                guard let prov = value.objectValue,
                      let pidStr = stringField(prov, "id"), !pidStr.isEmpty,
                      let pname = stringField(prov, "name"),
                      let rawModels = objectField(prov, "models")
                else { continue }
                let pid = ProviderSchema.ID(rawValue: pidStr)
                let env: [String] = arrayField(prov, "env")?.compactMap(\.stringValue) ?? []
                // Vertex needs separate handling for location and Express Mode.
                let prefer = recommended && pid != .googleVertex

                // Pass 1: route every model in source order and compute provider-level defaults.
                var routed: [RoutedSource] = []
                routed.reserveCapacity(rawModels.count)
                var pkgCounts: [String: Int] = [:]
                var pkgOrder: [String] = []
                var urlCounts: [String: Int] = [:]
                var urlOrder: [String] = []
                var allHaveBaseURL = true

                for (_, mVal) in rawModels {
                    guard let m = mVal.objectValue,
                          let mid = stringField(m, "id"), !mid.isEmpty,
                          let mname = stringField(m, "name")
                    else { continue }
                    let modelTypeStr = stringField(m, "type") ?? "chat"
                    guard supportedModelTypes.contains(modelTypeStr) else { continue }

                    var apiEntries: [(protoKey: String, apiObj: [(String, OrderedJSON)])] = []
                    switch field(m, "api") {
                    case .object(let apiPairs):
                        for (protoKey, apiVal) in apiPairs {
                            if let apiObj = apiVal.objectValue {
                                apiEntries.append((protoKey, apiObj))
                            }
                        }
                    case .array(let apiList):
                        for item in apiList {
                            if let apiObj = item.objectValue {
                                let protoKey = stringField(apiObj, "protocol")
                                    ?? stringField(apiObj, "id")
                                    ?? stringField(apiObj, "type")
                                    ?? ""
                                apiEntries.append((protoKey, apiObj))
                            }
                        }
                    default:
                        break
                    }

                    if !preserveAPIOrder && apiEntries.count > 1 {
                        apiEntries.sort { lhs, rhs in
                            let lRank = unorderedAPIRank(protoKey: lhs.protoKey, apiObj: lhs.apiObj)
                            let rRank = unorderedAPIRank(protoKey: rhs.protoKey, apiObj: rhs.apiObj)
                            if lRank != rRank { return lRank < rRank }
                            return lhs.protoKey < rhs.protoKey
                        }
                    }

                    var chosenProto: String?
                    var chosenApiObj: [(String, OrderedJSON)]?
                    var chosenOpencodeAI: String?
                    // A chat model uses an API with a package; other types only their own `/<type>s` entrypoint.
                    func eligible(_ apiObj: [(String, OrderedJSON)]) -> (ok: Bool, opencodeAI: String?) {
                        guard let sdk = objectField(apiObj, "sdk") else { return (false, nil) }
                        let opencodeAI = loadableOpencodeAI(stringField(sdk, "opencodeai"))
                        let aisdk = stringField(sdk, "aisdk")
                        if modelTypeStr == "chat" {
                            return (opencodeAI != nil || (aisdk != nil && !aisdk!.isEmpty), opencodeAI)
                        }
                        if let oc = opencodeAI, oc.hasSuffix("/\(modelTypeStr)s") { return (true, oc) }
                        return (false, nil)
                    }
                    // With `recommended_api`, the model's recommended API wins when it is eligible.
                    if prefer, let wanted = stringField(m, "recommended_api"),
                       let match = apiEntries.first(where: { $0.protoKey == wanted && eligible($0.apiObj).ok })
                    {
                        chosenProto = match.protoKey
                        chosenApiObj = match.apiObj
                        chosenOpencodeAI = eligible(match.apiObj).opencodeAI
                    }
                    if chosenProto == nil {
                        for (protoKey, apiObj) in apiEntries {
                            let check = eligible(apiObj)
                            if check.ok {
                                chosenProto = protoKey
                                chosenApiObj = apiObj
                                chosenOpencodeAI = check.opencodeAI
                                break
                            }
                        }
                    }

                    guard let protoKey = chosenProto, let apiObj = chosenApiObj else { continue }
                    let chosenPkg: String?
                    if let oc = chosenOpencodeAI {
                        chosenPkg = oc
                    } else if let sdk = objectField(apiObj, "sdk"),
                              let ai = stringField(sdk, "aisdk"), !ai.isEmpty {
                        let shape: String? = protoKey == "responses" ? "responses" : (protoKey == "chat-completions" ? "completions" : nil)
                        chosenPkg = CoreProvider.AISDKNative.native(npm: ai, providerID: pidStr, modelID: mid, shape: shape)
                            ?? CoreProvider.AISDKNative.aisdk(ai)
                    } else {
                        chosenPkg = nil
                    }
                    guard let pkg = chosenPkg, !pkg.isEmpty else { continue }

                    if pkgCounts[pkg] == nil { pkgOrder.append(pkg) }
                    pkgCounts[pkg, default: 0] += 1

                    let routeBaseURL: String? = {
                        guard !buildsOwnURL.contains(pkg),
                              let u = stringField(apiObj, "base_url"),
                              !u.isEmpty
                        else { return nil }
                        return u
                    }()
                    if let routeBaseURL {
                        if urlCounts[routeBaseURL] == nil { urlOrder.append(routeBaseURL) }
                        urlCounts[routeBaseURL, default: 0] += 1
                    } else {
                        allHaveBaseURL = false
                    }

                    routed.append(RoutedSource(
                        modelObj: m,
                        id: mid,
                        name: mname,
                        typeStr: modelTypeStr,
                        package: pkg,
                        baseURL: routeBaseURL,
                        apiObj: apiObj
                    ))
                }

                guard !routed.isEmpty,
                      let defaultPkg = mostCommon(order: pkgOrder, counts: pkgCounts)
                else { continue }
                let defaultBaseURL: String? = allHaveBaseURL ? mostCommon(order: urlOrder, counts: urlCounts) : nil

                // Pass 2: materialize models using provider defaults (only storing model-level package/baseURL overrides).
                var builtModels: [ModelSchema.Info] = []
                builtModels.reserveCapacity(routed.count)

                for src in routed {
                    let m = src.modelObj
                    let mid = src.id
                    let mname = src.name
                    let modelType = ModelSchema.ModelType(rawValue: src.typeStr)
                    let limitObj = objectField(m, "limit")
                    let ctx = field(limitObj, "context")?.intValue ?? 0
                    let inputLimit = field(limitObj, "input")?.intValue
                    let out = field(limitObj, "output")?.intValue ?? 0
                    let fam: ModelSchema.Family? = {
                        if let f = stringField(m, "family"), !f.isEmpty { return ModelSchema.Family(rawValue: f) }
                        return nil
                    }()

                    let capsObj = objectField(m, "capabilities")
                    let toolsSupported: Bool = {
                        if let tools = objectField(capsObj, "tools"),
                           let b = boolField(tools, "supported") { return b }
                        return false
                    }()
                    let temperatureSupported = boolField(capsObj, "temperature")
                    let freeformFormats: [ToolSchema.FreeformFormat]? = {
                        guard let apiCaps = objectField(src.apiObj, "capabilities"),
                              let apiTools = objectField(apiCaps, "tools"),
                              let arr = arrayField(apiTools, "freeform")
                        else { return nil }
                        let parsed = arr.compactMap { item -> ToolSchema.FreeformFormat? in
                            item.stringValue.flatMap(ToolSchema.FreeformFormat.init(rawValue:))
                        }
                        return parsed.isEmpty ? nil : parsed
                    }()

                    let modalitiesObj = objectField(m, "modalities")
                    let inputModalities = decodeModalities(field(modalitiesObj, "input"))
                    let outputModalities = decodeModalities(field(modalitiesObj, "output"))
                    let capabilities = ModelSchema.Capabilities(
                        tools: toolsSupported,
                        freeform: freeformFormats,
                        input: inputModalities,
                        output: outputModalities,
                        temperature: temperatureSupported
                    )

                    let compatibility: ModelCompatibilitySchema.Compatibility? = {
                        guard let comp = objectField(src.apiObj, "compatibility") else { return nil }
                        let rf: ModelCompatibilitySchema.ReasoningField? = {
                            if let s = stringField(comp, "reasoning_field"), !s.isEmpty {
                                return ModelCompatibilitySchema.ReasoningField(rawValue: s)
                            }
                            return nil
                        }()
                        let mtf = stringField(comp, "max_tokens_field").flatMap(ModelCompatibilitySchema.MaxTokensField.init(rawValue:))
                        let mi = stringField(comp, "media_input").flatMap(ModelCompatibilitySchema.MediaInput.init(rawValue:))
                        if rf == nil && mtf == nil && mi == nil { return nil }
                        return ModelCompatibilitySchema.Compatibility(reasoningField: rf, maxTokensField: mtf, mediaInput: mi)
                    }()

                    let releaseDateStr = stringField(m, "release_date") ?? ""
                    let releasedMs = parseReleaseDateMs(releaseDateStr)
                    let rawCost = field(m, "cost")
                    let baseCost = decodeCost(rawCost)
                    let status: ModelSchema.Info.Status = {
                        if let s = stringField(m, "status"),
                           let parsed = ModelSchema.Info.Status(rawValue: s),
                           parsed == .alpha || parsed == .beta || parsed == .deprecated {
                            return parsed
                        }
                        return .active
                    }()

                    let modelPackage: String? = src.package != defaultPkg ? src.package : nil
                    let modelSettings: ModelSchema.Settings? = {
                        var extra: [String: JSONValue] = [:]
                        if let routeBaseURL = src.baseURL, routeBaseURL != defaultBaseURL {
                            extra["baseURL"] = .string(routeBaseURL)
                        }
                        if compatiblePackages.contains(src.package) {
                            extra["provider"] = .string(pidStr)
                        }
                        return extra.isEmpty ? nil : ModelSchema.Settings(extra: extra)
                    }()

                    let baseModelForVariants = ModelSchema.Info(
                        id: ModelSchema.ID(rawValue: mid),
                        modelID: ModelSchema.ID(rawValue: mid),
                        providerID: pid,
                        type: modelType,
                        family: fam,
                        name: mname,
                        compatibility: compatibility,
                        package: src.package,
                        settings: modelSettings,
                        capabilities: capabilities,
                        variants: [],
                        time: ModelSchema.Info.Time(released: releasedMs),
                        cost: baseCost,
                        status: status,
                        enabled: true,
                        limit: ModelSchema.Info.Limit(context: ctx, input: inputLimit, output: out)
                    )
                    let reasoning = decodeReasoning(field(capsObj, "reasoning"))
                    let variants = CoreModel.Variant.resolve(baseModelForVariants, supports: CoreModel.Variant.supports(reasoning))
                    let fullModel = ModelSchema.Info(
                        id: baseModelForVariants.id,
                        modelID: baseModelForVariants.modelID,
                        providerID: baseModelForVariants.providerID,
                        type: baseModelForVariants.type,
                        family: baseModelForVariants.family,
                        name: baseModelForVariants.name,
                        compatibility: baseModelForVariants.compatibility,
                        package: modelPackage,
                        settings: baseModelForVariants.settings,
                        capabilities: baseModelForVariants.capabilities,
                        variants: variants,
                        time: baseModelForVariants.time,
                        cost: baseModelForVariants.cost,
                        status: baseModelForVariants.status,
                        enabled: baseModelForVariants.enabled,
                        limit: baseModelForVariants.limit
                    )
                    builtModels.append(fullModel)

                    if let exp = objectField(m, "experimental"), let modes = objectField(exp, "modes") {
                        for (modeName, modeVal) in modes {
                            guard let modeObj = modeVal.objectValue else { continue }
                            let titleMode = modeName.prefix(1).uppercased() + modeName.dropFirst()
                            let mCost = modeCost(modelCostRaw: rawCost, baseCost: baseCost, modeName: modeName, modeObj: modeObj)
                            let mHeaders: [String: String]? = {
                                guard let h = objectField(modeObj, "headers") else { return nil }
                                var dict: [String: String] = [:]
                                for (k, v) in h {
                                    if let s = v.stringValue { dict[k] = s }
                                }
                                return dict.isEmpty ? nil : dict
                            }()
                            let mBody: [String: JSONValue]? = {
                                guard let b = field(modeObj, "body"),
                                      case .object(let dict) = b.toJSONValue()
                                else { return nil }
                                return dict
                            }()
                            builtModels.append(ModelSchema.Info(
                                id: ModelSchema.ID(rawValue: "\(mid)-\(modeName)"),
                                modelID: fullModel.modelID,
                                providerID: pid,
                                type: fullModel.type,
                                family: fullModel.family,
                                name: "\(mname) \(titleMode)",
                                compatibility: fullModel.compatibility,
                                package: fullModel.package,
                                settings: fullModel.settings,
                                headers: mHeaders,
                                body: mBody,
                                capabilities: fullModel.capabilities,
                                variants: variants,
                                time: fullModel.time,
                                cost: mCost,
                                status: fullModel.status,
                                enabled: fullModel.enabled,
                                limit: fullModel.limit
                            ))
                        }
                    }
                }

                let providerSettings: ProviderSchema.Settings? = defaultBaseURL.map {
                    ProviderSchema.Settings(extra: ["baseURL": .string($0)])
                }
                snapshots.append(Snapshot(
                    info: ProviderSchema.Info(id: pid, name: pname, activation: .auto, package: defaultPkg, settings: providerSettings),
                    models: builtModels,
                    environment: env
                ))
            }
            return snapshots
        }

        private static func decodeSnapshot(catalogObject: [String: JSONValue], recommended: Bool = false) -> [Snapshot] {
            let v2 = V1.isV1(catalogObject) ? V1.toV2(catalogObject) : catalogObject
            let orderedPairs: [(String, OrderedJSON)] = v2
                .sorted(by: { $0.key < $1.key })
                .map { ($0.key, OrderedJSON.fromJSONValue($0.value)) }
            return decodeV2Pairs(orderedPairs, preserveAPIOrder: false, recommended: recommended)
        }

        /// `recommended` routes each model through its models.dev `recommended_api` when that API is usable, instead
        /// of the first usable API it lists (the `recommended_api` flag).
        // parity: core/src/models-dev.ts#decodeSnapshot [status=implemented hash=ef394d67ecaf]
        public static func decodeSnapshot(_ text: String, recommended: Bool = false) throws -> [Snapshot] {
            let root = try OrderedJSON.parse(text)
            guard case .object(let rootPairs) = root else {
                throw DecodeError.expectedObject
            }
            let isV1Catalog = rootPairs.contains { _, val in
                if let prov = val.objectValue, stringField(prov, "npm") != nil { return true }
                return false
            }
            if isV1Catalog {
                guard case .object(let rawDict) = root.toJSONValue() else {
                    throw DecodeError.expectedObject
                }
                let converted = V1.toV2(rawDict)
                let v2Pairs: [(String, OrderedJSON)] = converted
                    .sorted(by: { $0.key < $1.key })
                    .map { ($0.key, OrderedJSON.fromJSONValue($0.value)) }
                return decodeV2Pairs(v2Pairs, preserveAPIOrder: true, recommended: recommended)
            }
            return decodeV2Pairs(rootPairs, preserveAPIOrder: true, recommended: recommended)
        }

        // parity: core/src/models-dev.ts#Interface [status=implemented hash=4f5d4ac52127]
        public protocol Interface: Sendable {
            /// The catalog, routed through each model's recommended API when `recommended` is set.
            func get(recommended: Bool) async throws -> [Snapshot]
            func refresh(force: Bool) async
        }

        // parity: core/src/models-dev.ts#Service [status=implemented hash=e6f82121971f]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/ModelsDev"
            public static let defaultSource = "https://models.opencode.ai"
            public static let fallbackV1URL = "https://models.dev/api.json"
            public static let defaultTTLMs: Int64 = 5 * 60 * 1_000
            public static let defaultTimeoutMs: Int64 = 10_000
            public static let defaultUserAgent = "opencode/2.3.2"

            /// The catalog the cached snapshots were decoded from, kept so the other routing can be decoded from it.
            private enum CatalogSource: Sendable {
                case text(String)
                case object([String: JSONValue])

                func decode(recommended: Bool) -> [Snapshot]? {
                    switch self {
                    case .text(let text): return try? ModelsDev.decodeSnapshot(text, recommended: recommended)
                    case .object(let object): return ModelsDev.decodeSnapshot(catalogObject: object, recommended: recommended)
                    }
                }
            }

            private struct CacheState: Sendable {
                var source: CatalogSource?
                /// Decoded once per flag value from `source`; cleared whenever the catalog changes.
                var recommendedSnapshots: [Snapshot]?
                var snapshots: [Snapshot]?
                var updatedAt: Int64?
                var digest: String?
                var etag: String?
                var backgroundRefreshRunning: Bool = false
            }

            private struct CacheMeta: Sendable {
                let updatedAt: Int64
                let digest: String?
                let etag: String?
            }

            private struct KVHit: Sendable {
                let source: CatalogSource
                let snapshots: [Snapshot]
                let updatedAt: Int64
                let digest: String?
            }

            private struct DiskHit: Sendable {
                let text: String
                let snapshots: [Snapshot]
                let updatedAt: Int64?
                let digest: String
            }

            private enum FetchOutcome: Sendable {
                case notModified(etag: String?)
                case fetched(text: String, snapshots: [Snapshot], etag: String?)
                case failed
            }

            private actor RefreshLock {
                private var inFlight: Task<Void, Never>?

                func run(_ operation: @escaping @Sendable () async -> Void) async {
                    while let existing = inFlight {
                        await existing.value
                    }
                    let task = Task { await operation() }
                    inFlight = task
                    await task.value
                    inFlight = nil
                }
            }

            private let options: Options
            private let http: any HTTPTransport
            private let fileSystem: any OpenCodeFileSystem
            private let kv: any CoreKV.Interface
            private let bus: CoreBus.Service?
            private let cacheFilePath: String?
            private let userAgent: String
            private let ttlMs: Int64
            private let requestTimeoutMs: Int64
            private let nowMs: @Sendable () -> Int64
            private let cacheState = Mutex(CacheState())
            private let refreshLock = RefreshLock()

            public init(
                options: Options = Options(),
                http: any HTTPTransport,
                fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
                kv: any CoreKV.Interface,
                bus: CoreBus.Service? = nil,
                cacheFilePath: String? = nil,
                userAgent: String = Service.defaultUserAgent,
                ttlMs: Int64 = Service.defaultTTLMs,
                requestTimeoutMs: Int64 = Service.defaultTimeoutMs,
                nowMs: @escaping @Sendable () -> Int64 = { Flock.currentEpochMs() }
            ) {
                self.options = options
                self.http = http
                self.fileSystem = fileSystem
                self.kv = kv
                self.bus = bus
                self.cacheFilePath = cacheFilePath
                self.userAgent = userAgent
                self.ttlMs = max(0, ttlMs)
                self.requestTimeoutMs = max(1, requestTimeoutMs)
                self.nowMs = nowMs
            }

            private var source: String {
                if let url = options.url, !url.isEmpty { return url }
                return Self.defaultSource
            }

            private var shouldFetch: Bool {
                options.fetch ?? true
            }

            private var catalogKVKey: String {
                if source == Self.defaultSource { return "models-dev:v2:catalog" }
                return "models-dev:v2:catalog:\(Hash.fast(source))"
            }

            private var metaKVKey: String {
                "\(catalogKVKey):meta"
            }

            private func isStale(updatedAt: Int64?) -> Bool {
                guard let updatedAt, updatedAt > 0 else { return true }
                return nowMs() - updatedAt >= ttlMs
            }

            private func loadMetaFromKV() async -> CacheMeta? {
                let raw: JSONValue?
                if let metaVal = try? await kv.get(metaKVKey) {
                    raw = metaVal
                } else if let catVal = try? await kv.get(catalogKVKey) {
                    raw = catVal
                } else {
                    raw = nil
                }
                guard case .object(let obj) = raw,
                      let updatedAt = ModelsDev.int64Value(obj["updatedAt"])
                else { return nil }
                let digest: String? = if case .string(let d) = obj["digest"], !d.isEmpty { d } else { nil }
                let etag: String? = if case .string(let e) = obj["etag"], !e.isEmpty { e } else { nil }
                return CacheMeta(updatedAt: updatedAt, digest: digest, etag: etag)
            }

            private func loadFromKV() async -> KVHit? {
                guard let raw = try? await kv.get(catalogKVKey) else { return nil }
                guard case .object(let obj) = raw,
                      let updatedAt = ModelsDev.int64Value(obj["updatedAt"]),
                      let bodyVal = obj["body"]
                else {
                    try? await kv.remove(catalogKVKey)
                    try? await kv.remove(metaKVKey)
                    return nil
                }
                let digest: String? = if case .string(let d) = obj["digest"], !d.isEmpty { d } else { nil }
                switch bodyVal {
                case .string(let rawText):
                    guard let snapshots = try? ModelsDev.decodeSnapshot(rawText) else {
                        try? await kv.remove(catalogKVKey)
                        try? await kv.remove(metaKVKey)
                        return nil
                    }
                    return KVHit(
                        source: .text(rawText),
                        snapshots: snapshots,
                        updatedAt: updatedAt,
                        digest: digest ?? ModelsDev.bodyDigest(rawText)
                    )
                case .object(let catalogDict):
                    let snapshots = ModelsDev.decodeSnapshot(catalogObject: catalogDict)
                    return KVHit(source: .object(catalogDict), snapshots: snapshots, updatedAt: updatedAt, digest: digest)
                default:
                    try? await kv.remove(catalogKVKey)
                    try? await kv.remove(metaKVKey)
                    return nil
                }
            }

            private func loadFromDiskCache() async -> DiskHit? {
                guard let path = cacheFilePath, !path.isEmpty,
                      await fileSystem.exists(at: path),
                      let bytes = try? await fileSystem.readFile(at: path)
                else { return nil }
                let text = String(decoding: bytes, as: UTF8.self)
                guard let snapshots = try? ModelsDev.decodeSnapshot(text) else { return nil }
                let mtime = (try? await fileSystem.stat(at: path))?.modifiedAtMs
                let updatedAt: Int64? = (mtime ?? 0) > 0 ? mtime : nil
                return DiskHit(text: text, snapshots: snapshots, updatedAt: updatedAt, digest: ModelsDev.bodyDigest(text))
            }

            private func writeMeta(updatedAt: Int64, digest: String?, etag: String?) async {
                var metaObj: [String: JSONValue] = ["updatedAt": .int(updatedAt)]
                if let digest, !digest.isEmpty { metaObj["digest"] = .string(digest) }
                if let etag, !etag.isEmpty { metaObj["etag"] = .string(etag) }
                try? await kv.set(metaKVKey, value: .object(metaObj))
            }

            private func writeCache(text: String, updatedAt: Int64, digest: String, etag: String?) async {
                // Best-effort KV write (matching upstream's exact `models-dev:v2:catalog` + `:meta` schema).
                try? await kv.set(catalogKVKey, value: .object([
                    "updatedAt": .int(updatedAt),
                    "digest": .string(digest),
                    "body": .string(text),
                ]))
                await writeMeta(updatedAt: updatedAt, digest: digest, etag: etag)

                // Best-effort disk cache write when configured.
                if let path = cacheFilePath, !path.isEmpty {
                    try? await fileSystem.writeFile(Array(text.utf8), to: path, createDirectories: true)
                }
            }

            private func sendWithTimeout(_ request: HTTPRequest) async throws -> HTTPResponse {
                let timeoutMs = requestTimeoutMs
                let transport = http
                return try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
                    group.addTask {
                        try await transport.send(request)
                    }
                    group.addTask {
                        try await Task.sleep(for: .milliseconds(timeoutMs))
                        throw PlatformError.ioFailure("ModelsDev HTTP request timed out after \(timeoutMs)ms")
                    }
                    defer { group.cancelAll() }
                    guard let first = try await group.next() else {
                        throw PlatformError.ioFailure("ModelsDev HTTP request cancelled")
                    }
                    return first
                }
            }

            private func fetchSingle(url: String, etag: String?) async -> FetchOutcome {
                var headers: [String: String] = [
                    "user-agent": userAgent,
                    "accept": "application/json",
                ]
                if let etag, !etag.isEmpty {
                    headers["if-none-match"] = etag
                }
                let request = HTTPRequest(method: "GET", url: url, headers: headers)
                guard let resp = try? await sendWithTimeout(request) else {
                    return .failed
                }
                let responseEtag = resp.head.headers.first(where: { $0.key.lowercased() == "etag" })?.value
                if etag != nil && resp.head.statusCode == 304 {
                    return .notModified(etag: responseEtag)
                }
                guard (200..<300).contains(resp.head.statusCode) else {
                    return .failed
                }
                let text = String(decoding: resp.body, as: UTF8.self)
                guard let parsed = try? ModelsDev.decodeSnapshot(text) else {
                    return .failed
                }
                return .fetched(text: text, snapshots: parsed, etag: responseEtag)
            }

            private func fetchCatalogWithFallback(etag: String?) async -> FetchOutcome {
                let base = source.hasSuffix("/") ? String(source.dropLast()) : source
                let primaryURL = "\(base)\(ModelsDev.catalogPath)"
                let primary = await fetchSingle(url: primaryURL, etag: etag)
                switch primary {
                case .notModified, .fetched:
                    return primary
                case .failed:
                    let fallbackURL = source == Self.defaultSource
                        ? Self.fallbackV1URL
                        : "\(base)/api.json"
                    return await fetchSingle(url: fallbackURL, etag: etag)
                }
            }

            private func scheduleBackgroundRefresh() {
                let shouldStart = cacheState.withLock { s -> Bool in
                    guard !s.backgroundRefreshRunning else { return false }
                    s.backgroundRefreshRunning = true
                    return true
                }
                guard shouldStart else { return }
                Task { [self] in
                    defer {
                        self.cacheState.withLock { $0.backgroundRefreshRunning = false }
                    }
                    await self.refresh(force: false)
                }
            }

            public func get(recommended: Bool) async throws -> [Snapshot] {
                let snapshots = try await getDefault()
                guard recommended else { return snapshots }
                if let cached = cacheState.withLock({ $0.recommendedSnapshots }) { return cached }
                guard let source = cacheState.withLock({ $0.source }), let decoded = source.decode(recommended: true) else {
                    return snapshots
                }
                cacheState.withLock { s in
                    if s.recommendedSnapshots == nil { s.recommendedSnapshots = decoded }
                }
                return decoded
            }

            private func getDefault() async throws -> [Snapshot] {
                // Explicit `options.file` takes precedence over KV/disk cache and network.
                if let file = options.file {
                    if let cached = cacheState.withLock({ $0.snapshots }) {
                        return cached
                    }
                    if let bytes = try? await fileSystem.readFile(at: file) {
                        let text = String(decoding: bytes, as: UTF8.self)
                        let parsed = try ModelsDev.decodeSnapshot(text)
                        cacheState.withLock { s in
                            s.snapshots = parsed
                            s.source = .text(text)
                            s.recommendedSnapshots = nil
                            s.updatedAt = nowMs()
                            s.digest = ModelsDev.bodyDigest(text)
                        }
                        return parsed
                    }
                    if !shouldFetch { return [] }
                }

                // 1. Fast path: in-memory cache with non-blocking stale-while-revalidate.
                let mem = cacheState.withLock { ($0.snapshots, $0.updatedAt) }
                if let snapshots = mem.0 {
                    if shouldFetch && isStale(updatedAt: mem.1) {
                        scheduleBackgroundRefresh()
                    }
                    return snapshots
                }

                // 2. SQLite KV cache (`models-dev:v2:catalog` + `:meta`) with SWR.
                if let kvHit = await loadFromKV() {
                    let meta = await loadMetaFromKV()
                    let effectiveUpdatedAt = max(kvHit.updatedAt, meta?.updatedAt ?? 0)
                    let effectiveDigest = kvHit.digest ?? meta?.digest
                    let effectiveEtag = meta?.etag
                    cacheState.withLock { s in
                        if s.snapshots == nil {
                            s.snapshots = kvHit.snapshots
                            s.source = kvHit.source
                            s.recommendedSnapshots = nil
                            s.updatedAt = effectiveUpdatedAt
                            s.digest = effectiveDigest
                            s.etag = effectiveEtag
                        }
                    }
                    if shouldFetch && isStale(updatedAt: effectiveUpdatedAt) {
                        scheduleBackgroundRefresh()
                    }
                    return kvHit.snapshots
                }

                // 3. Disk cache (`cacheFilePath`, e.g. `~/.cache/opencode/models.json`) with SWR.
                if let diskHit = await loadFromDiskCache() {
                    let meta = await loadMetaFromKV()
                    let maxTs = max(diskHit.updatedAt ?? 0, meta?.updatedAt ?? 0)
                    let effectiveUpdatedAt: Int64? = maxTs > 0 ? maxTs : nil
                    let effectiveEtag = meta?.etag
                    cacheState.withLock { s in
                        if s.snapshots == nil {
                            s.snapshots = diskHit.snapshots
                            s.source = .text(diskHit.text)
                            s.recommendedSnapshots = nil
                            s.updatedAt = effectiveUpdatedAt
                            s.digest = diskHit.digest
                            s.etag = effectiveEtag
                        }
                    }
                    if shouldFetch && isStale(updatedAt: effectiveUpdatedAt) {
                        scheduleBackgroundRefresh()
                    }
                    return diskHit.snapshots
                }

                // 4. Cold start: no cached catalog available.
                guard shouldFetch else { return [] }
                await refresh(force: true)
                return cacheState.withLock { $0.snapshots ?? [] }
            }

            public func refresh(force: Bool = false) async {
                await refreshLock.run { [self] in
                    await self.performRefresh(force: force)
                }
            }

            private func performRefresh(force: Bool) async {
                let kvMeta = await loadMetaFromKV()
                let mem = cacheState.withLock { ($0.updatedAt, $0.digest, $0.etag) }
                let storedUpdatedAt: Int64? = {
                    switch (kvMeta?.updatedAt, mem.0) {
                    case let (a?, b?): return max(a, b)
                    case let (a?, nil): return a
                    case let (nil, b?): return b
                    case (nil, nil): return nil
                    }
                }()
                let previousDigest = kvMeta?.digest ?? mem.1
                let storedEtag = kvMeta?.etag ?? mem.2

                if !force, let updatedAt = storedUpdatedAt, !isStale(updatedAt: updatedAt) {
                    return
                }

                let etagToSend = force ? nil : storedEtag
                let outcome = await fetchCatalogWithFallback(etag: etagToSend)
                let now = nowMs()

                switch outcome {
                case .notModified(let responseEtag):
                    let nextEtag = responseEtag ?? storedEtag
                    cacheState.withLock { s in
                        s.updatedAt = now
                        s.etag = nextEtag
                    }
                    await writeMeta(updatedAt: now, digest: previousDigest, etag: nextEtag)

                case .fetched(let text, let parsed, let responseEtag):
                    let digest = ModelsDev.bodyDigest(text)
                    let nextEtag = responseEtag ?? storedEtag
                    let digestChanged = previousDigest != digest

                    if !force && !digestChanged && previousDigest != nil {
                        cacheState.withLock { s in
                            if s.snapshots == nil {
                                s.snapshots = parsed
                                s.source = .text(text)
                                s.recommendedSnapshots = nil
                            }
                            s.updatedAt = now
                            s.digest = digest
                            s.etag = nextEtag
                        }
                        await writeMeta(updatedAt: now, digest: digest, etag: nextEtag)
                        return
                    }

                    cacheState.withLock { s in
                        s.snapshots = parsed
                        s.source = .text(text)
                        s.recommendedSnapshots = nil
                        s.updatedAt = now
                        s.digest = digest
                        s.etag = nextEtag
                    }
                    await writeCache(text: text, updatedAt: now, digest: digest, etag: nextEtag)

                    if digestChanged, let bus {
                        await bus.emit(
                            ModelsDev.Event.refreshed,
                            data: EventSchema.EmptyData(),
                            options: CoreBus.PublishOptions(global: true)
                        )
                    }

                case .failed:
                    break
                }
            }
        }

        // parity: core/src/models-dev.ts#layer [status=implemented hash=b6bce9765788]
        public static func layer(_ options: Options = Options()) -> LayerNode.ExecutableLayer {
            LayerNode.ExecutableLayer { deps, _ in
                let http = deps.get(LayerNodePlatform.httpClientKey, as: (any HTTPTransport).self)
                    ?? LayerNodePlatform.FetchTransport { _ in
                        throw PlatformError.unsupportedOnPlatform(Platform.current, operation: "ModelsDev")
                    }
                let fs = deps.get(LayerNodePlatform.fileSystemKey, as: (any OpenCodeFileSystem).self) ?? LocalFileSystem.shared
                let kv = try deps.get(CoreKV.Service.serviceKey, as: CoreKV.Service.self) ?? CoreKV.Service.inMemory()
                let bus = deps.get(CoreBus.Service.serviceKey, as: CoreBus.Service.self)
                return LayerNode.Output([
                    Service.serviceKey: Service(
                        options: options,
                        http: http,
                        fileSystem: fs,
                        kv: kv,
                        bus: bus
                    ),
                ])
            }
        }

        // parity: core/src/models-dev.ts#configured [status=implemented hash=db51bec50564]
        public static func configured(_ options: Options = Options()) -> LayerNode.Provider {
            AppNode.makeGlobalNode(
                Service.serviceKey,
                layer(options),
                [LayerNodePlatform.httpClient, LayerNodePlatform.filesystem, CoreKV.node, CoreBus.node]
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

extension CoreModel.Resolver.Interface {
    /// Resolves a model reference and instantiates a runnable `AISchema.LanguageModel`.
    public func resolveLanguageModel(
        _ requested: ModelSchema.Ref? = nil,
        transport: (any HTTPTransport)? = nil,
        environment: any EnvironmentProviding = SystemEnvironment.shared,
        clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) async throws -> AISchema.LanguageModel? {
        guard let resolved = try await resolve(requested) else { return nil }
        return try resolved.makeLanguageModel(transport: transport, environment: environment, clock: clock)
    }

    /// Resolves a specific catalog model and instantiates a runnable `AISchema.LanguageModel`.
    public func resolveLanguageModel(
        _ model: ModelSchema.Info,
        variant: ModelSchema.VariantID? = nil,
        transport: (any HTTPTransport)? = nil,
        environment: any EnvironmentProviding = SystemEnvironment.shared,
        clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) async throws -> AISchema.LanguageModel {
        let resolved = try await resolveModel(model, variant: variant)
        return try resolved.makeLanguageModel(transport: transport, environment: environment, clock: clock)
    }
}

extension CoreModel.ModelsDev.Interface {
    /// The catalog with each model on the first usable API it lists.
    public func get() async throws -> [CoreModel.ModelsDev.Snapshot] {
        try await get(recommended: false)
    }
}

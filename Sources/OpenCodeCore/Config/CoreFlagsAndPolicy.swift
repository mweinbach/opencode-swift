import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Feature Flags (`core/src/flag.ts`)

public enum CoreFlag {
    // parity: core/src/flag.ts#Key [status=implemented hash=6423dea34cf1]
    public typealias Key = ConfigFlagSchema.Key

    // parity: core/src/flag.ts#State [status=implemented hash=76568226cd8d]
    public struct State: Equatable, Hashable, Sendable, Codable {
        public enum Source: String, Equatable, Hashable, Sendable, Codable {
            case env
            case config
            case `default`
        }

        public let enabled: Bool
        public let source: Source

        public init(enabled: Bool, source: Source) {
            self.enabled = enabled
            self.source = source
        }
    }

    // parity: core/src/flag.ts#Interface [status=adapted hash=90a82d2b0ae9]
    public protocol Interface: Sendable {
        func resolve(_ entries: [CoreConfigEntry]) -> [Key: State]
        func all() async -> [Key: State]
        func enabled(_ key: Key) async -> Bool
    }

    /// Context reference for `OPENCODE_FLAGS` override strings (e.g. `"automations,-media_blob"` or `"all,-media_blob"`).
    // parity: core/src/flag.ts#Overrides [status=adapted hash=4a9e8375ed88]
    public enum Overrides {
        public static let key = "@opencode/Flag/Overrides"
        @TaskLocal public static var current: String? = nil

        public static func fromEnvironment(_ environment: any EnvironmentProviding = SystemEnvironment.shared) -> String? {
            current ?? environment.variable("OPENCODE_FLAGS")
        }
    }

    public struct ResolveInput: Equatable, Sendable {
        public let entries: [CoreConfigEntry]
        public let channel: String
        public let overrides: String?

        public init(entries: [CoreConfigEntry], channel: String, overrides: String? = nil) {
            self.entries = entries
            self.channel = channel
            self.overrides = overrides
        }
    }

    private static func onByDefault(channel: String) -> Bool {
        channel == "local" || channel == "dev"
    }

    /// Resolves every feature flag using exact precedence:
    /// `OPENCODE_FLAGS` (`key` / `-key` / alias / `all`) -> `experimental.<key>` (latest `experimental` doc)
    /// -> `experimental.all_flags: true` (latest doc setting `all_flags`) -> channel default (`local`/`dev`).
    /// Opt-in-only flags (`todo`, `sqlite_fts`) skip both `all` wildcards and default to `false` on every channel.
    // parity: core/src/flag.ts#resolve [status=implemented hash=a825939df6d4]
    public static func resolve(_ input: ResolveInput) -> [Key: State] {
        var envMap: [String: Bool] = [:]
        if let rawOverrides = input.overrides {
            for part in rawOverrides.split(separator: ",") {
                let item = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if item.isEmpty { continue }
                if item.hasPrefix("-") {
                    let name = String(item.dropFirst())
                    if !name.isEmpty { envMap[name] = false }
                } else {
                    envMap[item] = true
                }
            }
        }
        let allEnv = envMap[ConfigFlagSchema.wildcard] == true
        let experimental = CoreConfig.latest(input.entries, \.experimental)
        let allFlags: Bool = {
            for entry in input.entries.reversed() {
                if let val = entry.info?.experimental?.allFlags {
                    return val
                }
            }
            return false
        }()

        var result: [Key: State] = [:]
        for key in Key.allCases {
            let optInOnly = ConfigFlagSchema.optInOnly.contains(key)
            let aliasName = ConfigFlagSchema.aliases.first(where: { $0.value == key })?.key

            let envOverride: Bool? =
                envMap[key.rawValue]
                ?? aliasName.flatMap { envMap[$0] }
                ?? (allEnv && !optInOnly ? true : nil)

            let aliasConfigValue: Bool? = aliasName == "schedules" ? experimental?.schedules : nil
            // A flag that takes settings is on when given them (`flagValue` reads a settings object as `true`).
            let configured: Bool? =
                experimental?.flagValue(for: key)
                ?? aliasConfigValue
                ?? (allFlags && !optInOnly ? true : nil)

            if let envOverride {
                result[key] = State(enabled: envOverride, source: .env)
            } else if let configured {
                result[key] = State(enabled: configured, source: .config)
            } else {
                result[key] = State(enabled: !optInOnly && onByDefault(channel: input.channel), source: .default)
            }
        }
        return result
    }

    // parity: core/src/flag.ts#Service [status=adapted hash=ece99ea74cd2]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/Flag"

        private let config: any CoreConfig.Interface
        private let channel: String
        private let overrides: String?

        public init(
            config: any CoreConfig.Interface,
            channel: String = "local",
            overrides: String? = nil
        ) {
            self.config = config
            self.channel = channel
            self.overrides = overrides
        }

        public func resolve(_ entries: [CoreConfigEntry]) -> [Key: State] {
            CoreFlag.resolve(ResolveInput(entries: entries, channel: channel, overrides: overrides))
        }

        public func all() async -> [Key: State] {
            let entries = await config.entries()
            return resolve(entries)
        }

        public func enabled(_ key: Key) async -> Bool {
            let flags = await all()
            return flags[key]?.enabled ?? false
        }
    }

    // parity: core/src/flag.ts#layer [status=adapted hash=3a14f6c38d67]
    public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { deps, _ in
        let config = deps.get(CoreConfig.Service.serviceKey, as: (any CoreConfig.Interface).self)
            ?? CoreConfig.Test()
        let channel = deps.get("@opencode/App.channel", as: String.self) ?? "local"
        let overrides = deps.get(Overrides.key, as: String.self) ?? Overrides.fromEnvironment()
        let service = Service(config: config, channel: channel, overrides: overrides)
        return LayerNode.Output([Service.serviceKey: service as any Interface])
    }

    // parity: core/src/flag.ts#testLayer [status=adapted hash=096233449609]
    public static func testLayer(
        entries: [CoreConfigEntry] = [],
        channel: String = "local",
        overrides: String? = nil
    ) -> LayerNode.ExecutableLayer {
        LayerNode.ExecutableLayer { _, _ in
            let config = CoreConfig.Test(initial: entries)
            let service = Service(config: config, channel: channel, overrides: overrides)
            return LayerNode.Output([
                CoreConfig.Service.serviceKey: config as any CoreConfig.Interface,
                CoreConfig.Test.serviceKey: config as any CoreConfig.TestInterface,
                Service.serviceKey: service as any Interface,
            ])
        }
    }

    // parity: core/src/flag.ts#node [status=adapted hash=d8081ff752cc]
    public static let node: LayerNode.Provider = AppNode.makeLocationNode(
        Service.serviceKey,
        layer,
        [CoreConfig.node]
    )

    /// Reads every flag state from `service`.
    // parity: core/src/flag.ts#all [status=adapted hash=d002317de7f3]
    public static func all(using service: any Interface) async -> [Key: State] {
        await service.all()
    }

    /// Reads whether a single flag is enabled from `service`.
    // parity: core/src/flag.ts#enabled [status=adapted hash=3b1c3f1d55e6]
    public static func enabled(_ key: Key, using service: any Interface) async -> Bool {
        await service.enabled(key)
    }
}

// MARK: - Managed Policy Engine (`core/src/managed-policy.ts`)

public enum CoreManagedPolicy {
    public struct Statement: Equatable, Hashable, Sendable, Codable {
        public let action: ConfigPolicySchema.Action
        public let resource: String
        public let effect: ConfigPolicySchema.Effect
        public let message: String

        public init(
            action: ConfigPolicySchema.Action,
            resource: String,
            effect: ConfigPolicySchema.Effect,
            message: String
        ) {
            self.action = action
            self.resource = resource
            self.effect = effect
            self.message = message
        }

        public var policyInfo: ConfigPolicySchema.Info {
            ConfigPolicySchema.Info(action: action, resource: resource, effect: effect)
        }
    }

    /// Every policy statement across config entries, reversed so earliest-loaded policy comes last and wins.
    // parity: core/src/managed-policy.ts#statements [status=implemented hash=6d2e5a14ad41]
    public static func statements(_ entries: [CoreConfigEntry]) -> [Statement] {
        var result: [Statement] = []
        for entry in entries.reversed() {
            guard entry.isDocument, let policies = entry.info?.policies else { continue }
            let message: String
            if case .integration(let integrationDoc) = entry {
                message = blockedMessage(organization: integrationDoc.organization)
            } else {
                message = "Blocked by configuration policy"
            }
            for policy in policies {
                result.append(Statement(
                    action: policy.action,
                    resource: policy.resource,
                    effect: policy.effect,
                    message: message
                ))
            }
        }
        return result
    }

    private static func blockedMessage(organization: String?) -> String {
        if let organization, !organization.isEmpty {
            return "Blocked by \(organization)'s policy"
        }
        return "Blocked by your organization's policy"
    }

    /// Returns the last matching statement for `(action, resource)` using wildcard matching.
    // parity: core/src/managed-policy.ts#match [status=implemented hash=4a92c3e17c61]
    public static func match(
        _ policies: [Statement],
        action: ConfigPolicySchema.Action,
        resource: String
    ) -> Statement? {
        for policy in policies.reversed() {
            if policy.action == action && CorePermissionWildcard.match(resource, pattern: policy.resource) {
                return policy
            }
        }
        return nil
    }

    public static func match(
        _ policies: [ConfigPolicySchema.Info],
        action: ConfigPolicySchema.Action,
        resource: String
    ) -> ConfigPolicySchema.Info? {
        for policy in policies.reversed() {
            if policy.action == action && CorePermissionWildcard.match(resource, pattern: policy.resource) {
                return policy
            }
        }
        return nil
    }

    /// Evaluates policy decision for `(action, resource)`, defaulting to `.allow`.
    // parity: core/src/managed-policy.ts#decision [status=implemented hash=91de095b7e2f]
    public static func decision(
        _ policies: [ConfigPolicySchema.Info],
        action: ConfigPolicySchema.Action,
        resource: String
    ) -> ConfigPolicySchema.Effect {
        match(policies, action: action, resource: resource)?.effect ?? .allow
    }

    public static func decision(
        _ policies: [Statement],
        action: ConfigPolicySchema.Action,
        resource: String
    ) -> ConfigPolicySchema.Effect {
        match(policies, action: action, resource: resource)?.effect ?? .allow
    }

    /// Builds `<integration>#<account>` when an account is present, else bare `<integration>`.
    // parity: core/src/managed-policy.ts#integrationResource [status=implemented hash=0007cf0d9222]
    public static func integrationResource(_ integrationID: String, account: String? = nil) -> String {
        if let account, !account.isEmpty {
            return "\(integrationID)#\(account)"
        }
        return integrationID
    }

    /// Extracts the organization (`orgID`) or account (`accountID`) identifier from a stored credential value.
    // parity: core/src/managed-policy.ts#account [status=implemented hash=ed7610821eb3]
    public static func account(_ value: CredentialSchema.Value) -> String? {
        let metadata: [String: JSONValue]?
        switch value {
        case .oauth(let v): metadata = v.metadata
        case .key(let v): metadata = v.metadata
        case .external(let v): metadata = v.metadata
        }
        if case .string(let orgID) = metadata?["orgID"], !orgID.isEmpty {
            return orgID
        }
        if case .string(let accountID) = metadata?["accountID"], !accountID.isEmpty {
            return accountID
        }
        return nil
    }

    /// Maps each integration ID to the account behind its active (last-listed) stored credential.
    // parity: core/src/managed-policy.ts#accounts [status=implemented hash=6cf6f8253668]
    public static func accounts(_ credentials: [CredentialSchema.Entry]) -> [String: String?] {
        var map: [String: String?] = [:]
        for cred in credentials {
            map[cred.integrationID.rawValue] = account(cred.value)
        }
        return map
    }
}

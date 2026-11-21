import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Feature Flag Resolution (`core/src/flag/resolve.ts`)

/// Pure feature-flag resolution separated from `CoreFlag` so `CoreConfig` can resolve `project_overlay`
/// without creating a dependency cycle with `CoreFlag.Service`.
public enum CoreFlagResolve {
    // parity: core/src/flag/resolve.ts#State [status=implemented hash=76568226cd8d]
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

    /// `OPENCODE_FLAGS`, a comma-separated list such as `artifacts,-media_blob`; a leading `-` turns a flag off, and
    /// `all` enables all flags except opt-in-only flags and any disabled in the same list, as in `all,-media_blob`.
    // parity: core/src/flag/resolve.ts#Overrides [status=adapted hash=4a9e8375ed88]
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

    // Any other channel, such as a release or a branch preview build, keeps flags off so none turns on by accident.
    private static func onByDefault(channel: String) -> Bool {
        channel == "local" || channel == "dev"
    }

    /// Resolves every flag: `OPENCODE_FLAGS` (`key` or `-key`, then `all`), then `experimental.<key>` from the
    /// highest-priority document that sets `experimental` (the same document every other `experimental` setting reads),
    /// then `all_flags: true` from the highest-priority document that sets `all_flags`, so a global switch survives a
    /// project's own `experimental` block, then on for local and dev builds. `all_flags: false` falls through rather
    /// than turning flags off. Opt-in-only flags skip both wildcards and default to off on every channel.
    // parity: core/src/flag/resolve.ts#resolve [status=implemented hash=62bef60e4a02]
    public static func resolve(_ input: ResolveInput) -> [ConfigFlagSchema.Key: State] {
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
        let experimental: ConfigExperimentalSchema.Info? = {
            for entry in input.entries.reversed() where entry.isDocument {
                if let exp = entry.info?.experimental {
                    return exp
                }
            }
            return nil
        }()
        let allFlags: Bool = {
            for entry in input.entries.reversed() where entry.isDocument {
                if let val = entry.info?.experimental?.allFlags {
                    return val
                }
            }
            return false
        }()

        var result: [ConfigFlagSchema.Key: State] = [:]
        for key in ConfigFlagSchema.Key.allCases {
            let optInOnly = ConfigFlagSchema.optInOnly.contains(key)
            let override: Bool? = envMap[key.rawValue] ?? (allEnv && !optInOnly ? true : nil)
            // A flag that takes settings is on when given them (`flagValue` reads a settings object as `true`).
            let configured: Bool? =
                experimental?.flagValue(for: key)
                ?? (allFlags && !optInOnly ? true : nil)

            if let override {
                result[key] = State(enabled: override, source: .env)
            } else if let configured {
                result[key] = State(enabled: configured, source: .config)
            } else {
                result[key] = State(enabled: !optInOnly && onByDefault(channel: input.channel), source: .default)
            }
        }
        return result
    }
}

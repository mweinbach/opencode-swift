/// Pure-Swift environment variable registration, typed parsing, caching, and documentation
/// generation matching `packages/core/src/lib/env.ts`.
///
/// Accepts an injectable `[String: String]` environment map so `OpenTUICore` remains 100% pure
/// and testable on every Swift platform without OS environment dependencies.

// MARK: - Types

/// Value type supported by `EnvVarConfig`.
public enum EnvVarType: String, Equatable, Hashable, Sendable, Codable {
    case string
    case boolean
    case number
}

/// Typed value stored as a default or resolved from an environment variable.
public enum EnvVarValue: Equatable, Hashable, Sendable, Codable,
    ExpressibleByStringLiteral,
    ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral
{
    case string(String)
    case boolean(Bool)
    case number(Double)

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(booleanLiteral value: Bool) {
        self = .boolean(value)
    }

    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }

    public init(floatLiteral value: Double) {
        self = .number(value)
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self, value.isFinite {
            return Int(value)
        }
        return nil
    }

    internal var formattedDefault: String {
        switch self {
        case .string(let s):
            return "\"\(s)\""
        case .boolean(let b):
            return b ? "true" : "false"
        case .number(let n):
            if n.isFinite && n.rounded(.towardZero) == n && n >= Double(Int64.min) && n <= Double(Int64.max) {
                return String(Int64(n))
            }
            return String(n)
        }
    }
}

/// Declarative registration record for an environment variable.
// parity: core/src/lib/env.ts#EnvVarConfig [status=implemented hash=1fdf4cdc98ad]
public struct EnvVarConfig: Equatable, Hashable, Sendable, Codable {
    public var name: String
    public var description: String
    public var defaultValue: EnvVarValue?
    public var required: Bool?
    public var type: EnvVarType?

    public init(
        name: String,
        description: String,
        default defaultValue: EnvVarValue? = nil,
        required: Bool? = nil,
        type: EnvVarType? = nil
    ) {
        self.name = name
        self.description = description
        self.defaultValue = defaultValue
        self.required = required
        self.type = type
    }
}

/// Errors raised during environment variable registration or lookup.
public enum EnvRegistryError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case alreadyRegisteredWithDifferentConfig(name: String)
    case notRegistered(name: String)
    case requiredVariableNotSet(name: String, description: String)
    case invalidNumber(name: String, rawValue: String)

    public var description: String {
        switch self {
        case .alreadyRegisteredWithDifferentConfig(let name):
            return "Environment variable \"\(name)\" is already registered with different configuration."
        case .notRegistered(let name):
            return "Environment variable \(name) is not registered."
        case .requiredVariableNotSet(let name, let description):
            return "Required environment variable \(name) is not set. \(description)"
        case .invalidNumber(let name, let rawValue):
            return "Environment variable \(name) must be a valid number, got: \(rawValue)"
        }
    }
}

// MARK: - Boolean & Number Parsing

/// Parses an environment variable boolean string (`"true"`, `"1"`, `"on"`, `"yes"`, case-insensitive).
public func parseEnvBoolean(_ value: String) -> Bool {
    switch value.lowercased() {
    case "true", "1", "on", "yes":
        return true
    default:
        return false
    }
}

private func parseEnvNumber(_ raw: String) -> Double? {
    var trimmed = raw
    while let first = trimmed.first, first == " " || first == "\t" || first == "\n" || first == "\r" {
        trimmed.removeFirst()
    }
    while let last = trimmed.last, last == " " || last == "\t" || last == "\n" || last == "\r" {
        trimmed.removeLast()
    }
    if trimmed.isEmpty {
        // Matches JavaScript `Number("") === 0`.
        return 0
    }
    guard let value = Double(trimmed), !value.isNaN else {
        return nil
    }
    return value
}

// MARK: - EnvRegistry

/// Pure, injectable environment variable registry with typed parsing, value caching, and doc generation.
// parity: core/src/lib/env.ts#envRegistry [status=implemented hash=7497fb56181f]
public final class EnvRegistry: @unchecked Sendable {
    /// Default process-wide registry (starts with an empty injectable environment map).
    // parity: core/src/lib/env.ts#env [status=implemented hash=e963c7f59903]
    public static let shared = EnvRegistry()

    private var environment: [String: String]
    private var configs: [String: EnvVarConfig] = [:]
    private var registrationOrder: [String] = []
    private var parsedCache: [String: EnvVarValue?] = [:]

    public init(environment: [String: String] = [:]) {
        self.environment = environment
    }

    /// Replaces the backing environment dictionary and clears cached parsed values.
    public func setEnvironment(_ environment: [String: String]) {
        self.environment = environment
        parsedCache.removeAll(keepingCapacity: true)
    }

    /// Sets or unsets a single raw environment variable and invalidates its cache entry.
    public func setRawValue(_ value: String?, forKey key: String) {
        environment[key] = value
        parsedCache.removeValue(forKey: key)
    }

    /// Returns a snapshot of all registered configurations in registration order.
    public var registeredConfigs: [EnvVarConfig] {
        registrationOrder.compactMap { configs[$0] }
    }

    /// Returns all registered environment variable names in registration order.
    public var registeredNames: [String] {
        registrationOrder
    }

    /// Registers an environment variable specification.
    /// Re-registering an identical configuration is a no-op; conflicting definitions throw.
    public func register(_ config: EnvVarConfig) throws(EnvRegistryError) {
        if let existing = configs[config.name] {
            if existing != config {
                throw .alreadyRegisteredWithDifferentConfig(name: config.name)
            }
            return
        }
        configs[config.name] = config
        registrationOrder.append(config.name)
    }

    /// Reports whether `key` has been registered.
    public func has(_ key: String) -> Bool {
        configs[key] != nil
    }

    /// Resolves and caches the parsed value for a registered environment variable.
    public func get(_ key: String) throws(EnvRegistryError) -> EnvVarValue? {
        if let cached = parsedCache[key] {
            return cached
        }

        guard let config = configs[key] else {
            throw .notRegistered(name: key)
        }

        let value = try parseValue(for: config)
        parsedCache[key] = value
        return value
    }

    public func getString(_ key: String) throws(EnvRegistryError) -> String? {
        try get(key)?.stringValue
    }

    public func getBool(_ key: String) throws(EnvRegistryError) -> Bool? {
        try get(key)?.boolValue
    }

    public func getNumber(_ key: String) throws(EnvRegistryError) -> Double? {
        try get(key)?.numberValue
    }

    /// Clears all cached parsed values without unregistering configs.
    public func clearCache() {
        parsedCache.removeAll(keepingCapacity: true)
    }

    /// Clears both registrations and cache (useful for isolated tests).
    public func reset(environment: [String: String]? = nil) {
        configs.removeAll()
        registrationOrder.removeAll()
        parsedCache.removeAll()
        if let environment {
            self.environment = environment
        }
    }

    private func parseValue(for config: EnvVarConfig) throws(EnvRegistryError) -> EnvVarValue? {
        let rawValue = environment[config.name]

        if rawValue == nil, let defaultValue = config.defaultValue {
            return defaultValue
        }

        if rawValue == nil, config.required == false {
            return nil
        }

        guard let envValue = rawValue else {
            throw .requiredVariableNotSet(name: config.name, description: config.description)
        }

        switch config.type ?? .string {
        case .boolean:
            return .boolean(parseEnvBoolean(envValue))
        case .number:
            guard let num = parseEnvNumber(envValue) else {
                throw .invalidNumber(name: config.name, rawValue: envValue)
            }
            return .number(num)
        case .string:
            return .string(envValue)
        }
    }

    /// Generates Markdown documentation for all registered variables.
    public func generateMarkdown() -> String {
        let list = registeredConfigs
        if list.isEmpty {
            return "# Environment Variables\n\nNo environment variables registered.\n"
        }

        var markdown = "# Environment Variables\n\n"
        for config in list {
            markdown += "## \(config.name)\n\n"
            markdown += "\(config.description)\n\n"
            markdown += "**Type:** `\(config.type?.rawValue ?? "string")`  \n"

            if let defaultValue = config.defaultValue {
                markdown += "**Default:** `\(defaultValue.formattedDefault)`\n"
            } else if config.required == false {
                markdown += "**Default:** *unset*\n"
            } else {
                markdown += "**Default:** *Required*\n"
            }

            markdown += "\n"
        }
        return markdown
    }

    /// Generates ANSI-colored terminal documentation for all registered variables.
    public func generateColored() -> String {
        let list = registeredConfigs
        if list.isEmpty {
            return "\u{1B}[1;36mEnvironment Variables\u{1B}[0m\n\nNo environment variables registered.\n"
        }

        var output = "\u{1B}[1;36mEnvironment Variables\u{1B}[0m\n\n"
        for config in list {
            output += "\u{1B}[1;33m\(config.name)\u{1B}[0m\n"
            output += "\(config.description)\n"
            output += "\u{1B}[32mType:\u{1B}[0m \u{1B}[36m\(config.type?.rawValue ?? "string")\u{1B}[0m\n"

            if let defaultValue = config.defaultValue {
                output += "\u{1B}[32mDefault:\u{1B}[0m \u{1B}[35m\(defaultValue.formattedDefault)\u{1B}[0m\n"
            } else if config.required == false {
                output += "\u{1B}[32mDefault:\u{1B}[0m \u{1B}[35munset\u{1B}[0m\n"
            } else {
                output += "\u{1B}[32mDefault:\u{1B}[0m \u{1B}[31mRequired\u{1B}[0m\n"
            }

            output += "\n"
        }
        return output
    }

    /// Generates environment documentation in either Markdown or ANSI-colored format.
    public func generateDocs(colored: Bool = false) -> String {
        colored ? generateColored() : generateMarkdown()
    }
}

// MARK: - Top-Level Helpers

/// Registers an environment variable in `registry` (defaults to `EnvRegistry.shared`).
// parity: core/src/lib/env.ts#registerEnvVar [status=implemented hash=a024e3c7ba0d]
public func registerEnvVar(_ config: EnvVarConfig, in registry: EnvRegistry = .shared) throws(EnvRegistryError) {
    try registry.register(config)
}

/// Clears cached parsed environment values in `registry` (defaults to `EnvRegistry.shared`).
// parity: core/src/lib/env.ts#clearEnvCache [status=implemented hash=c6f2d96e4eac]
public func clearEnvCache(in registry: EnvRegistry = .shared) {
    registry.clearCache()
}

/// Generates Markdown documentation for registered environment variables.
// parity: core/src/lib/env.ts#generateEnvMarkdown [status=implemented hash=5a4b3d898de5]
public func generateEnvMarkdown(from registry: EnvRegistry = .shared) -> String {
    registry.generateMarkdown()
}

/// Generates ANSI-colored documentation for registered environment variables.
// parity: core/src/lib/env.ts#generateEnvColored [status=implemented hash=459a59be8f99]
public func generateEnvColored(from registry: EnvRegistry = .shared) -> String {
    registry.generateColored()
}

/// Generates environment variable documentation in Markdown or ANSI-colored format.
public func generateEnvDocs(from registry: EnvRegistry = .shared, colored: Bool = false) -> String {
    registry.generateDocs(colored: colored)
}

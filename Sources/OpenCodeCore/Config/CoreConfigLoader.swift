#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - JSONC Stripping & Parsing Utility

public enum CoreConfigJSONC {
    public struct ParseError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }

        public var description: String { message }
    }

    /// Strips `//` line comments, `/* ... */` block comments, and trailing commas before `}` or `]`
    /// while preserving all string literals verbatim.
    public static func stripCommentsAndTrailingCommas(_ text: String) throws -> String {
        let bytes = Array(text.utf8)
        var withoutComments: [UInt8] = []
        withoutComments.reserveCapacity(bytes.count)

        var i = 0
        var inString = false
        while i < bytes.count {
            let b = bytes[i]
            if inString {
                withoutComments.append(b)
                if b == 0x5C { // '\'
                    i += 1
                    if i < bytes.count {
                        withoutComments.append(bytes[i])
                    }
                } else if b == 0x22 { // '"'
                    inString = false
                }
                i += 1
                continue
            }

            if b == 0x22 { // '"'
                inString = true
                withoutComments.append(b)
                i += 1
                continue
            }

            if b == 0x2F, i + 1 < bytes.count { // '/'
                let next = bytes[i + 1]
                if next == 0x2F { // '//'
                    i += 2
                    while i < bytes.count && bytes[i] != 0x0A && bytes[i] != 0x0D {
                        i += 1
                    }
                    continue
                }
                if next == 0x2A { // '/*'
                    i += 2
                    var closed = false
                    while i + 1 < bytes.count {
                        if bytes[i] == 0x2A && bytes[i + 1] == 0x2F {
                            i += 2
                            closed = true
                            break
                        }
                        if bytes[i] == 0x0A {
                            withoutComments.append(0x0A)
                        }
                        i += 1
                    }
                    if !closed {
                        throw ParseError("Unterminated block comment in JSONC")
                    }
                    continue
                }
            }

            withoutComments.append(b)
            i += 1
        }

        // Strip trailing commas before '}' or ']' outside string literals.
        var out: [UInt8] = []
        out.reserveCapacity(withoutComments.count)
        i = 0
        inString = false
        while i < withoutComments.count {
            let b = withoutComments[i]
            if inString {
                out.append(b)
                if b == 0x5C {
                    i += 1
                    if i < withoutComments.count {
                        out.append(withoutComments[i])
                    }
                } else if b == 0x22 {
                    inString = false
                }
                i += 1
                continue
            }
            if b == 0x22 {
                inString = true
                out.append(b)
                i += 1
                continue
            }
            if b == 0x2C { // ','
                var look = i + 1
                while look < withoutComments.count && isASCIIWhitespace(withoutComments[look]) {
                    look += 1
                }
                if look < withoutComments.count && (withoutComments[look] == 0x7D || withoutComments[look] == 0x5D) {
                    i += 1
                    continue
                }
            }
            out.append(b)
            i += 1
        }

        return String(decoding: out, as: UTF8.self)
    }

    public static func parse(_ text: String) throws -> JSONValue {
        let stripped = try stripCommentsAndTrailingCommas(text)
        guard let data = stripped.data(using: .utf8) else {
            throw ParseError("Invalid UTF-8 in JSONC")
        }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ParseError("Malformed JSON/JSONC: \(error)")
        }
    }

    public static func parseInfo(_ text: String) throws -> (info: ConfigSchema.Info, diagnostics: [CoreConfigNormalize.Diagnostic]) {
        let raw = try parse(text)
        let normalized = CoreConfigNormalize.normalize(raw)
        switch normalized {
        case .rejected(let diagnostics):
            throw ParseError(diagnostics.first?.message ?? "Rejected configuration document")
        case .normalized(let encoded, let diagnostics):
            let data = try JSONEncoder().encode(JSONValue.object(encoded))
            let info = try JSONDecoder().decode(ConfigSchema.Info.self, from: data)
            return (info, diagnostics)
        }
    }

    public static func encodeJSONStringContents(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: out.append("\\\"")
            case 0x5C: out.append("\\\\")
            case 0x08: out.append("\\b")
            case 0x0C: out.append("\\f")
            case 0x0A: out.append("\\n")
            case 0x0D: out.append("\\r")
            case 0x09: out.append("\\t")
            case 0x00..<0x20:
                let hex = String(scalar.value, radix: 16, uppercase: false)
                out.append("\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func isASCIIWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }
}

// MARK: - Rich Entry Envelope Supporting Managed, Integration & WellKnown Documents

public enum CoreConfigEntry: Equatable, Hashable, Sendable {
    case document(ConfigSchema.Document)
    case directory(ConfigSchema.Directory)
    case managed(CoreConfigManaged.Document)
    case integration(CoreConfigIntegration.Document)
    case wellKnown(CoreConfigIntegration.WellKnownDocument)

    public var isDocument: Bool {
        if case .directory = self { return false }
        return true
    }

    public var info: ConfigSchema.Info? {
        switch self {
        case .document(let d): return d.info
        case .managed(let d): return d.info
        case .integration(let d): return d.info
        case .wellKnown(let d): return d.info
        case .directory: return nil
        }
    }

    public var path: SchemaPrimitive.AbsolutePath? {
        switch self {
        case .document(let d): return d.path
        case .managed(let d): return d.path
        case .integration(let d): return d.path
        case .wellKnown(let d): return d.path
        case .directory(let d): return d.path
        }
    }

    public var schemaEntry: ConfigSchema.Entry {
        switch self {
        case .document(let d): return .document(d)
        case .directory(let d): return .directory(d)
        case .managed(let d): return .document(ConfigSchema.Document(path: d.path, info: d.info))
        case .integration(let d): return .document(ConfigSchema.Document(path: d.path, info: d.info))
        case .wellKnown(let d): return .document(ConfigSchema.Document(path: d.path, info: d.info))
        }
    }

    public static func from(_ entry: ConfigSchema.Entry) -> CoreConfigEntry {
        switch entry {
        case .document(let d): return .document(d)
        case .directory(let d): return .directory(d)
        }
    }
}

// MARK: - Managed Config Document (`core/src/config/managed.ts`)

public enum CoreConfigManaged {
    /// A document from managed configuration: the system config directory or MDM managed preferences.
    // parity: core/src/config/managed.ts#Document [status=implemented hash=3d4536ba0fd7]
    public struct Document: Equatable, Hashable, Sendable, Codable {
        public let path: SchemaPrimitive.AbsolutePath?
        public let info: ConfigSchema.Info

        public init(path: SchemaPrimitive.AbsolutePath? = nil, info: ConfigSchema.Info) {
            self.path = path
            self.info = info
        }
    }
}

// MARK: - Integration & Well-Known Config (`core/src/config/integration.ts`)

public enum CoreConfigIntegration {
    /// Decodes a policy array while silently dropping statements whose `action` or `effect` is
    /// unrecognized by this version (forward compatibility with newer remote sources).
    // parity: core/src/config/integration.ts#Policies [status=implemented hash=3d016bf4bbed]
    public struct Policies: Equatable, Hashable, Sendable, Codable {
        public let items: [ConfigPolicySchema.Info]

        public init(items: [ConfigPolicySchema.Info] = []) {
            self.items = items
        }

        public static func decode(_ raw: [JSONValue]) throws -> [ConfigPolicySchema.Info] {
            var result: [ConfigPolicySchema.Info] = []
            for element in raw {
                if case .object(let dict) = element {
                    if case .string(let actionStr) = dict["action"],
                       ConfigPolicySchema.Action(rawValue: actionStr) == nil
                    {
                        continue
                    }
                    if case .string(let effectStr) = dict["effect"],
                       ConfigPolicySchema.Effect(rawValue: effectStr) == nil
                    {
                        continue
                    }
                }
                let data = try JSONEncoder().encode(element)
                let decoded = try JSONDecoder().decode(ConfigPolicySchema.Info.self, from: data)
                result.append(decoded)
            }
            return result
        }

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            let raw = try single.decode([JSONValue].self)
            self.items = try Self.decode(raw)
        }

        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            try single.encode(items)
        }
    }

    /// Allow-listed keys of a remote config (`providers`, `mcp`, `policies`, `websearch`).
    // parity: core/src/config/integration.ts#Remote [status=implemented hash=9c0bd2356687]
    public struct Remote: Equatable, Hashable, Sendable, Codable {
        public let providers: [String: ConfigProviderSchema.Info]?
        public let mcp: ConfigMCPSchema.Info?
        public let policies: [ConfigPolicySchema.Info]?
        public let websearch: ConfigWebSearchSchema.Selection?

        public init(
            providers: [String: ConfigProviderSchema.Info]? = nil,
            mcp: ConfigMCPSchema.Info? = nil,
            policies: [ConfigPolicySchema.Info]? = nil,
            websearch: ConfigWebSearchSchema.Selection? = nil
        ) {
            self.providers = providers
            self.mcp = mcp
            self.policies = policies
            self.websearch = websearch
        }

        enum CodingKeys: String, CodingKey {
            case providers
            case mcp
            case policies
            case websearch
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.providers = try container.decodeIfPresent([String: ConfigProviderSchema.Info].self, forKey: .providers)
            self.mcp = try container.decodeIfPresent(ConfigMCPSchema.Info.self, forKey: .mcp)
            self.policies = try container.decodeIfPresent(Policies.self, forKey: .policies)?.items
            self.websearch = try container.decodeIfPresent(ConfigWebSearchSchema.Selection.self, forKey: .websearch)
        }
    }

    /// A config document delivered by an integration connection (e.g. OpenCode Console).
    // parity: core/src/config/integration.ts#Document [status=implemented hash=0a9cb5e001b3]
    public struct Document: Equatable, Hashable, Sendable, Codable {
        public let path: SchemaPrimitive.AbsolutePath?
        public let info: ConfigSchema.Info
        public let integrationID: IntegrationID
        public let connection: ConnectionSchema.Info
        public let organization: String?

        public init(
            path: SchemaPrimitive.AbsolutePath? = nil,
            info: ConfigSchema.Info,
            integrationID: IntegrationID,
            connection: ConnectionSchema.Info,
            organization: String? = nil
        ) {
            self.path = path
            self.info = info
            self.integrationID = integrationID
            self.connection = connection
            self.organization = organization
        }
    }

    /// A config document delivered by a well-known origin.
    // parity: core/src/config/integration.ts#WellKnownDocument [status=implemented hash=98533906c4a6]
    public struct WellKnownDocument: Equatable, Hashable, Sendable, Codable {
        public let path: SchemaPrimitive.AbsolutePath?
        public let info: ConfigSchema.Info
        public let integrationID: IntegrationID

        public init(
            path: SchemaPrimitive.AbsolutePath? = nil,
            info: ConfigSchema.Info,
            integrationID: IntegrationID
        ) {
            self.path = path
            self.info = info
            self.integrationID = integrationID
        }
    }

    /// The integration whose delivered well-known document last defines each provider.
    // parity: core/src/config/integration.ts#suppliers [status=implemented hash=e50ec9bdcf0d]
    public static func suppliers(_ entries: [CoreConfigEntry]) -> [String: IntegrationID] {
        var result: [String: IntegrationID] = [:]
        for entry in entries {
            guard case .wellKnown(let doc) = entry else { continue }
            for providerID in (doc.info.providers ?? [:]).keys {
                result[providerID] = doc.integrationID
            }
        }
        return result
    }

    public struct MakeInput: Equatable, Hashable, Sendable {
        public let integrationID: IntegrationID
        public let connection: ConnectionSchema.Info
        public let organization: String?
        public let info: Remote

        public init(
            integrationID: IntegrationID,
            connection: ConnectionSchema.Info,
            organization: String? = nil,
            info: Remote
        ) {
            self.integrationID = integrationID
            self.connection = connection
            self.organization = organization
            self.info = info
        }
    }

    /// Builds a sanitized integration document from remote config (strips local `env`, credential keys, and local MCP servers).
    // parity: core/src/config/integration.ts#make [status=implemented hash=5dc0482476a4]
    public static func make(_ input: MakeInput) -> Document {
        let sanitizedProviders: [String: ConfigProviderSchema.Info]? = input.info.providers.map { map in
            var out: [String: ConfigProviderSchema.Info] = [:]
            for (id, provider) in map {
                let sanitizedModels: [String: ConfigProviderSchema.ModelConfig]? = provider.models.map { mMap in
                    var mOut: [String: ConfigProviderSchema.ModelConfig] = [:]
                    for (modelID, model) in mMap {
                        let sanitizedVariants = model.variants?.map { variant in
                            ConfigProviderSchema.VariantConfig(
                                id: variant.id,
                                settings: stripModelVariantCredentials(variant.settings),
                                headers: variant.headers,
                                body: variant.body
                            )
                        }
                        mOut[modelID] = ConfigProviderSchema.ModelConfig(
                            modelID: model.modelID,
                            type: model.type,
                            family: model.family,
                            name: model.name,
                            releaseDate: model.releaseDate,
                            compatibility: model.compatibility,
                            package: model.package,
                            settings: stripModelCredentials(model.settings),
                            headers: model.headers,
                            body: model.body,
                            capabilities: model.capabilities,
                            variants: sanitizedVariants,
                            cost: model.cost,
                            disabled: model.disabled,
                            limit: model.limit
                        )
                    }
                    return mOut
                }
                out[id] = ConfigProviderSchema.Info(
                    canonical: provider.canonical,
                    name: provider.name,
                    env: nil,
                    package: provider.package,
                    compatibility: provider.compatibility,
                    settings: stripProviderCredentials(provider.settings),
                    headers: provider.headers,
                    body: provider.body,
                    models: sanitizedModels
                )
            }
            return out
        }

        let sanitizedMcp: ConfigMCPSchema.Info? = input.info.mcp?.servers.map { servers in
            var remoteOnly: [String: McpSchema.ServerConfig] = [:]
            for (name, server) in servers {
                if case .remote = server {
                    remoteOnly[name] = server
                }
            }
            return ConfigMCPSchema.Info(timeout: nil, servers: remoteOnly)
        }

        return Document(
            path: nil,
            info: ConfigSchema.Info(
                policies: input.info.policies,
                mcp: sanitizedMcp,
                websearch: input.info.websearch,
                providers: sanitizedProviders
            ),
            integrationID: input.integrationID,
            connection: input.connection,
            organization: input.organization
        )
    }

    private static let credentialKeys: Set<String> = ["apiKey", "authToken", "accessToken"]

    private static func stripExtra(_ extra: [String: JSONValue]) -> [String: JSONValue] {
        extra.filter { !credentialKeys.contains($0.key) }
    }

    private static func stripProviderCredentials(_ settings: ProviderSchema.Settings?) -> ProviderSchema.Settings? {
        guard let settings else { return nil }
        return ProviderSchema.Settings(
            timeout: settings.timeout,
            headerTimeout: settings.headerTimeout,
            chunkTimeout: settings.chunkTimeout,
            compaction: settings.compaction,
            cache: settings.cache,
            transport: settings.transport,
            encoding: settings.encoding,
            tls: settings.tls,
            extra: stripExtra(settings.extra)
        )
    }

    private static func stripModelCredentials(_ settings: ModelSchema.Settings?) -> ModelSchema.Settings? {
        guard let settings else { return nil }
        return ModelSchema.Settings(
            compaction: settings.compaction,
            cache: settings.cache,
            encoding: settings.encoding,
            extra: stripExtra(settings.extra)
        )
    }

    private static func stripModelVariantCredentials(_ settings: ModelSchema.VariantSettings?) -> ModelSchema.VariantSettings? {
        guard let settings else { return nil }
        return ModelSchema.VariantSettings(
            compaction: settings.compaction,
            encoding: settings.encoding,
            extra: stripExtra(settings.extra)
        )
    }
}

// MARK: - Markdown Frontmatter Parser (`core/src/config/markdown.ts`)

public enum CoreConfigMarkdown {
    public struct Parsed: Equatable, Hashable, Sendable {
        public let data: [String: JSONValue]
        public let content: String

        public init(data: [String: JSONValue], content: String) {
            self.data = data
            self.content = content
        }
    }

    public struct ParseError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }

        public var description: String { message }
    }

    /// Parses YAML frontmatter (`--- ... ---`) and markdown body, retrying after `sanitize` on parse error.
    // parity: core/src/config/markdown.ts#parse [status=implemented hash=939fe3b434fa]
    public static func parse(_ content: String) throws -> Parsed {
        do {
            return try parseStrict(content)
        } catch {
            return try parseStrict(sanitize(content))
        }
    }

    /// Parses YAML frontmatter returning `nil` when parsing fails.
    // parity: core/src/config/markdown.ts#parseOption [status=implemented hash=ee8f2216ff4f]
    public static func parseOption(_ content: String) -> Parsed? {
        try? parse(content)
    }

    /// Joins a legacy separate `variant` into a string `model` so it survives native decoding. Embedded and
    /// structured native selections, and a variant without a model, stay unchanged.
    // parity: core/src/config/markdown.ts#joinLegacyVariant [status=implemented hash=ea60bed331cc]
    public static func joinLegacyVariant(_ data: [String: JSONValue]) -> [String: JSONValue] {
        guard case .string(let model) = data["model"], !model.contains("#") else { return data }
        guard case .string(let variant) = data["variant"], !variant.isEmpty, !variant.contains("#") else { return data }
        var joined = data
        joined["model"] = .string("\(model)#\(variant)")
        return joined
    }

    /// Converts unquoted YAML frontmatter values containing colons or leading `[Tag] text` into block scalars (`|-`),
    /// so config files written for other coding agents keep working, without rewriting valid YAML flow collections.
    // parity: core/src/config/markdown.ts#sanitize [status=implemented hash=153f9350af00]
    public static func sanitize(_ content: String) -> String {
        guard let (frontmatter, range) = extractFrontmatterBody(content) else {
            return content
        }
        let lines = splitLinesPreservingEmpty(frontmatter)
        var out: [String] = []
        var flow: FlowState?
        for line in lines {
            if let open = flow {
                flow = scanFlow(line, open).state
                out.append(line)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty || line.first?.isWhitespace == true {
                out.append(line)
                continue
            }
            guard let (key, rawVal) = splitTopLevelKeyValue(line) else {
                out.append(line)
                continue
            }
            let value = rawVal.trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value.hasPrefix("\"") || value.hasPrefix("'") {
                out.append(line)
                continue
            }
            if value.hasPrefix("[") || value.hasPrefix("{") {
                let scan = scanFlow(value, FlowState())
                if scan.status == .open { flow = scan.state }
                if scan.status != .trailing {
                    out.append(line)
                    continue
                }
                out.append("\(key): |-")
                out.append("  \(value)")
                continue
            }
            if !value.contains(":") || isValidYaml(line) {
                out.append(line)
                continue
            }
            out.append("\(key): |-")
            out.append("  \(value)")
        }
        let replacement = out.joined(separator: "\n")
        return content.replacingCharacters(in: range, with: replacement)
    }

    private static func isValidYaml(_ line: String) -> Bool {
        (try? parseSimpleYAMLMapping(line)) != nil
    }

    struct FlowState: Equatable, Sendable {
        var stack: [Character] = []
        var quote: Character?
    }

    enum FlowStatus: Equatable, Sendable {
        case open
        case closed
        case trailing
        case invalid
    }

    /// Tracks an unfinished YAML flow collection (`[...]` / `{...}`) across lines, quote-aware, stopping at a
    /// comment. `trailing` means text follows the closing bracket, as in `[Tag] text`.
    static func scanFlow(_ text: String, _ state: FlowState) -> (status: FlowStatus, state: FlowState?) {
        var stack = state.stack
        var quote = state.quote
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if quote == "\"" {
                if ch == "\\" {
                    i += 2
                    continue
                }
                if ch == "\"" { quote = nil }
                i += 1
                continue
            }
            if quote == "'" {
                if ch == "'" {
                    if i + 1 < chars.count, chars[i + 1] == "'" {
                        i += 2
                        continue
                    }
                    quote = nil
                }
                i += 1
                continue
            }
            if ch == "\"" || ch == "'" {
                if i == 0 || chars[i - 1].isWhitespace || "[{,:".contains(chars[i - 1]) {
                    quote = ch
                    i += 1
                    continue
                }
            }
            if ch == "#", i == 0 || chars[i - 1].isWhitespace { break }
            if ch == "[" {
                stack.append("]")
                i += 1
                continue
            }
            if ch == "{" {
                stack.append("}")
                i += 1
                continue
            }
            if ch == "]" || ch == "}" {
                guard stack.last == ch else { return (.invalid, nil) }
                stack.removeLast()
                if stack.isEmpty {
                    let rest = String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces)
                    if rest.isEmpty || rest.hasPrefix("#") { return (.closed, nil) }
                    return (.trailing, nil)
                }
            }
            i += 1
        }
        return (.open, FlowState(stack: stack, quote: quote))
    }

    private static func parseStrict(_ content: String) throws -> Parsed {
        guard let (frontmatter, bodyStart) = extractFrontmatterAndBody(content) else {
            return Parsed(data: [:], content: content)
        }
        let data = try parseSimpleYAMLMapping(frontmatter)
        return Parsed(data: data, content: String(content[bodyStart...]))
    }

    private static func extractFrontmatterBody(_ content: String) -> (String, Range<String.Index>)? {
        let utf8 = content.utf8
        let startByteOffset: Int
        if content.hasPrefix("---\r\n") {
            startByteOffset = 5
        } else if content.hasPrefix("---\n") {
            startByteOffset = 4
        } else {
            return nil
        }
        let bodyStart = utf8.index(utf8.startIndex, offsetBy: startByteOffset)
        var searchIdx = bodyStart
        while searchIdx < utf8.endIndex {
            let lineEnd = utf8[searchIdx...].firstIndex(of: 0x0A) ?? utf8.endIndex
            let lineBytes = utf8[searchIdx..<lineEnd]
            let trimmedCR = lineBytes.last == 0x0D ? lineBytes.dropLast() : lineBytes
            if String(decoding: trimmedCR, as: UTF8.self) == "---" {
                let fmEnd: String.Index
                if searchIdx > bodyStart {
                    let prev = utf8.index(before: searchIdx)
                    if utf8[prev] == 0x0A {
                        let beforeLF = prev > bodyStart ? utf8.index(before: prev) : prev
                        if beforeLF >= bodyStart && utf8[beforeLF] == 0x0D {
                            fmEnd = beforeLF
                        } else {
                            fmEnd = prev
                        }
                    } else {
                        fmEnd = searchIdx
                    }
                } else {
                    fmEnd = bodyStart
                }
                return (String(content[bodyStart..<fmEnd]), bodyStart..<fmEnd)
            }
            if lineEnd == utf8.endIndex { break }
            searchIdx = utf8.index(after: lineEnd)
        }
        return nil
    }

    private static func extractFrontmatterAndBody(_ content: String) -> (String, String.Index)? {
        let utf8 = content.utf8
        let startByteOffset: Int
        if content.hasPrefix("---\r\n") {
            startByteOffset = 5
        } else if content.hasPrefix("---\n") {
            startByteOffset = 4
        } else {
            return nil
        }
        let fmStart = utf8.index(utf8.startIndex, offsetBy: startByteOffset)
        var searchIdx = fmStart
        while searchIdx < utf8.endIndex {
            let lineEnd = utf8[searchIdx...].firstIndex(of: 0x0A) ?? utf8.endIndex
            let lineBytes = utf8[searchIdx..<lineEnd]
            let trimmedCR = lineBytes.last == 0x0D ? lineBytes.dropLast() : lineBytes
            if String(decoding: trimmedCR, as: UTF8.self) == "---" {
                let fmEnd: String.Index
                if searchIdx > fmStart {
                    let prev = utf8.index(before: searchIdx)
                    if utf8[prev] == 0x0A {
                        let beforeLF = prev > fmStart ? utf8.index(before: prev) : prev
                        if beforeLF >= fmStart && utf8[beforeLF] == 0x0D {
                            fmEnd = beforeLF
                        } else {
                            fmEnd = prev
                        }
                    } else {
                        fmEnd = searchIdx
                    }
                } else {
                    fmEnd = fmStart
                }
                let cleanFm = String(content[fmStart..<fmEnd]).replacing("\r\n", with: "\n")
                let afterFence = lineEnd < utf8.endIndex ? utf8.index(after: lineEnd) : utf8.endIndex
                return (cleanFm, afterFence)
            }
            if lineEnd == utf8.endIndex { break }
            searchIdx = utf8.index(after: lineEnd)
        }
        return nil
    }

    private static func parseSimpleYAMLMapping(_ yaml: String) throws -> [String: JSONValue] {
        let lines = splitLinesPreservingEmpty(yaml)
        var result: [String: JSONValue] = [:]
        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }
            guard let colon = raw.firstIndex(of: ":") else {
                throw ParseError("Invalid YAML frontmatter line: \(raw)")
            }
            let key = String(raw[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                throw ParseError("Empty YAML key in frontmatter")
            }
            let afterColon = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if afterColon == "|" || afterColon == "|-" || afterColon == ">" || afterColon == ">-" {
                let folded = afterColon.hasPrefix(">")
                let stripTrail = afterColon.hasSuffix("-")
                i += 1
                var blockLines: [String] = []
                var blockIndent: Int? = nil
                while i < lines.count {
                    let bLine = lines[i]
                    if bLine.trimmingCharacters(in: .whitespaces).isEmpty {
                        blockLines.append("")
                        i += 1
                        continue
                    }
                    let indent = bLine.prefix(while: { $0 == " " || $0 == "\t" }).count
                    if indent == 0 { break }
                    if blockIndent == nil { blockIndent = indent }
                    let drop = min(indent, blockIndent ?? indent)
                    blockLines.append(String(bLine.dropFirst(drop)))
                    i += 1
                }
                while blockLines.last == "" { blockLines.removeLast() }
                var joined = folded ? blockLines.joined(separator: " ") : blockLines.joined(separator: "\n")
                if !stripTrail && !joined.isEmpty { joined += "\n" }
                result[key] = .string(joined)
                continue
            }
            if afterColon.isEmpty {
                // Nested mapping or sequence
                i += 1
                var childLines: [String] = []
                var childIndent: Int? = nil
                while i < lines.count {
                    let cLine = lines[i]
                    if cLine.trimmingCharacters(in: .whitespaces).isEmpty || cLine.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                        i += 1
                        continue
                    }
                    let indent = cLine.prefix(while: { $0 == " " || $0 == "\t" }).count
                    if indent == 0 { break }
                    if childIndent == nil { childIndent = indent }
                    let drop = min(indent, childIndent ?? indent)
                    childLines.append(String(cLine.dropFirst(drop)))
                    i += 1
                }
                if childLines.isEmpty {
                    result[key] = .null
                } else if childLines[0].hasPrefix("- ") {
                    let items = try childLines.map { line -> JSONValue in
                        let itemText = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
                        return try parseYAMLScalar(itemText.trimmingCharacters(in: .whitespaces))
                    }
                    result[key] = .array(items)
                } else {
                    let nested = try parseSimpleYAMLMapping(childLines.joined(separator: "\n"))
                    result[key] = .object(nested)
                }
                continue
            }
            result[key] = try parseYAMLScalar(afterColon)
            i += 1
        }
        return result
    }

    private static func parseYAMLScalar(_ value: String) throws -> JSONValue {
        if value == "true" { return .bool(true) }
        if value == "false" { return .bool(false) }
        if value == "null" || value == "~" { return .null }
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            if let data = value.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(String.self, from: data)
            {
                return .string(decoded)
            }
            return .string(String(value.dropFirst().dropLast()))
        }
        if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
            let inner = String(value.dropFirst().dropLast()).replacing("''", with: "'")
            return .string(inner)
        }
        if value.hasPrefix("[") && value.hasSuffix("]") {
            if let parsed = try? CoreConfigJSONC.parse(value) {
                return parsed
            }
            let inner = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return .array([]) }
            let parts = inner.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            return .array(try parts.map(parseYAMLScalar))
        }
        if value.hasPrefix("{") && value.hasSuffix("}") {
            if let parsed = try? CoreConfigJSONC.parse(value) {
                return parsed
            }
        }
        // Reject unquoted value containing ": " or leading "[tag] text" in strict pass so `sanitize` triggers!
        if value.contains(": ") || value.hasSuffix(":") || matchesLeadingBracketTag(value) {
            throw ParseError("Unquoted colon or leading bracket tag in YAML scalar: \(value)")
        }
        if let intVal = Int64(value) { return .int(intVal) }
        if let dblVal = Double(value), dblVal.isFinite { return .double(dblVal) }
        return .string(value)
    }

    private static func splitLinesPreservingEmpty(_ text: String) -> [String] {
        text.replacing("\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func splitTopLevelKeyValue(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        guard let first = key.unicodeScalars.first,
              (first.value >= 0x41 && first.value <= 0x5A) || (first.value >= 0x61 && first.value <= 0x7A) || first == "_",
              key.unicodeScalars.allSatisfy({
                  ($0.value >= 0x41 && $0.value <= 0x5A)
                      || ($0.value >= 0x61 && $0.value <= 0x7A)
                      || ($0.value >= 0x30 && $0.value <= 0x39)
                      || $0 == "_"
              })
        else { return nil }
        return (key, String(line[line.index(after: colon)...]))
    }

    private static func matchesLeadingBracketTag(_ value: String) -> Bool {
        guard value.hasPrefix("[") || value.hasPrefix("{") else { return false }
        let close: Character = value.hasPrefix("[") ? "]" : "}"
        guard let closeIdx = value.firstIndex(of: close) else { return false }
        let after = value[value.index(after: closeIdx)...].trimmingCharacters(in: .whitespaces)
        return !after.isEmpty
    }
}

// MARK: - Config Variable Substitution (`core/src/config/variable.ts`)

public enum CoreConfigVariable {
    public enum Source: Equatable, Hashable, Sendable {
        case path(String)
        case virtual(source: String, dir: String)

        public var directory: String {
            switch self {
            case .path(let p): return CoreConfigDiscovery.dirname(p)
            case .virtual(_, let dir): return dir
            }
        }
    }

    public struct SubstituteInput: Sendable {
        public let source: Source
        public let text: String
        public let env: [String: String]?
        public let home: String
        public let environment: any EnvironmentProviding

        public init(
            source: Source,
            text: String,
            env: [String: String]? = nil,
            home: String? = nil,
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) {
            self.source = source
            self.text = text
            self.env = env
            self.home = home ?? environment.homeDirectory ?? Global.make(environment: environment).home
            self.environment = environment
        }
    }

    public struct SubstituteOutput: Equatable, Sendable {
        public let text: String
        public let references: Set<String>

        public init(text: String, references: Set<String>) {
            self.text = text
            self.references = references
        }
    }

    /// Applies `{env:VAR}` and `{file:path}` substitutions to config text.
    // parity: core/src/config/variable.ts#substitute [status=implemented hash=db54f5797490]
    public static func substitute(
        _ input: SubstituteInput,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
    ) async -> SubstituteOutput {
        func expandEnv(escape: Bool) -> String {
            replacePattern(in: input.text, prefix: "{env:") { name in
                let raw = input.env?[name] ?? input.environment.variable(name) ?? ""
                return escape ? CoreConfigJSONC.encodeJSONStringContents(raw) : raw
            }
        }

        var refs: Set<String> = []
        let raw = await substituteFiles(input: input, text: expandEnv(escape: false), fileSystem: fileSystem, references: &refs)
        if input.text.contains("{env:") {
            if (try? CoreConfigJSONC.parse(raw)) == nil {
                var escapedRefs: Set<String> = []
                let escaped = await substituteFiles(input: input, text: expandEnv(escape: true), fileSystem: fileSystem, references: &escapedRefs)
                return SubstituteOutput(text: escaped, references: escapedRefs)
            }
        }
        return SubstituteOutput(text: raw, references: refs)
    }

    private static func substituteFiles(
        input: SubstituteInput,
        text: String,
        fileSystem: any OpenCodeFileSystem,
        references: inout Set<String>
    ) async -> String {
        let configDir = input.source.directory
        let bytes = Array(text.utf8)
        let prefixBytes = Array("{file:".utf8)
        var out = ""
        var cursor = 0

        var i = 0
        while i < bytes.count {
            if i + prefixBytes.count < bytes.count && matchesAt(bytes, index: i, pattern: prefixBytes) {
                if let closeIdx = findByte(0x7D, in: bytes, from: i + prefixBytes.count) {
                    out += String(decoding: bytes[cursor..<i], as: UTF8.self)
                    let token = String(decoding: bytes[i...closeIdx], as: UTF8.self)

                    // Check if on a `//` comment line
                    var lineStart = i
                    while lineStart > 0 && bytes[lineStart - 1] != 0x0A {
                        lineStart -= 1
                    }
                    let prefix = String(decoding: bytes[lineStart..<i], as: UTF8.self)
                        .drop(while: { $0 == " " || $0 == "\t" })
                    if prefix.hasPrefix("//") {
                        out += token
                        cursor = closeIdx + 1
                        i = cursor
                        continue
                    }

                    let filePath = String(decoding: bytes[(i + prefixBytes.count)..<closeIdx], as: UTF8.self)
                    let expandedPath = filePath.hasPrefix("~/")
                        ? CoreConfigDiscovery.joinPath(input.home, String(filePath.dropFirst(2)))
                        : filePath
                    let resolvedPath = CoreConfigDiscovery.resolvePath(base: configDir, relative: expandedPath)
                    references.insert(resolvedPath)

                    let fileContent: String
                    if let fileBytes = try? await fileSystem.readFile(at: resolvedPath) {
                        fileContent = String(decoding: fileBytes, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        fileContent = ""
                    }
                    out += CoreConfigJSONC.encodeJSONStringContents(fileContent)
                    cursor = closeIdx + 1
                    i = cursor
                    continue
                }
            }
            i += 1
        }
        if cursor < bytes.count {
            out += String(decoding: bytes[cursor..<bytes.count], as: UTF8.self)
        }
        return out
    }

    private static func replacePattern(in text: String, prefix: String, transform: (String) -> String) -> String {
        let bytes = Array(text.utf8)
        let prefixBytes = Array(prefix.utf8)
        var out = ""
        var cursor = 0
        var i = 0
        while i < bytes.count {
            if i + prefixBytes.count < bytes.count && matchesAt(bytes, index: i, pattern: prefixBytes) {
                if let closeIdx = findByte(0x7D, in: bytes, from: i + prefixBytes.count) {
                    out += String(decoding: bytes[cursor..<i], as: UTF8.self)
                    let name = String(decoding: bytes[(i + prefixBytes.count)..<closeIdx], as: UTF8.self)
                    out += transform(name)
                    cursor = closeIdx + 1
                    i = cursor
                    continue
                }
            }
            i += 1
        }
        if cursor < bytes.count {
            out += String(decoding: bytes[cursor..<bytes.count], as: UTF8.self)
        }
        return out
    }

    private static func matchesAt(_ bytes: [UInt8], index: Int, pattern: [UInt8]) -> Bool {
        for j in 0..<pattern.count where bytes[index + j] != pattern[j] {
            return false
        }
        return true
    }

    private static func findByte(_ target: UInt8, in bytes: [UInt8], from start: Int) -> Int? {
        for idx in start..<bytes.count where bytes[idx] == target {
            return idx
        }
        return nil
    }
}

// MARK: - Config Normalization & V1 -> V2 Migration (`core/src/config/normalize.ts`)

public enum CoreConfigNormalize {
    // parity: core/src/config/normalize.ts#Diagnostic [status=implemented hash=57e190f9a686]
    public struct Diagnostic: Equatable, Hashable, Sendable, Codable {
        public enum Kind: String, Equatable, Hashable, Sendable, Codable {
            case conflict
            case invalid
            case unsupported
        }

        public let kind: Kind
        public let path: [String]
        public let message: String

        public init(kind: Kind, path: [String], message: String) {
            self.kind = kind
            self.path = path
            self.message = message
        }
    }

    // parity: core/src/config/normalize.ts#Result [status=implemented hash=da67c6408d96]
    public enum Result: Equatable, Hashable, Sendable {
        case normalized(encoded: [String: JSONValue], diagnostics: [Diagnostic])
        case rejected(diagnostics: [Diagnostic])
    }

    private static let unsupportedTopLevel: [String] = ["logLevel", "server", "subagent_depth", "layout"]
    private static let unsupportedExperimental: [String] = [
        "disable_paste_summary",
        "batch_tool",
        "openTelemetry",
        "primary_tools",
        "continue_loop_on_deny",
    ]
    private static let nativeAtomicKeys: [String] = [
        "$schema",
        "shell",
        "default_agent",
        "share",
        "enterprise",
        "username",
        "timezone",
        "snapshots",
        "media",
        "tool_output",
        "websearch",
        "worktree",
        "warming",
    ]

    /// Normalizes raw parsed JSON/JSONC configuration, migrating V1 keys into canonical V2 shape
    /// and collecting conflict/invalid/unsupported diagnostics.
    // parity: core/src/config/normalize.ts#normalize [status=implemented hash=0627772edd35]
    public static func normalize(_ input: JSONValue) -> Result {
        guard case .object(let obj) = input else {
            return .rejected(diagnostics: [
                Diagnostic(
                    kind: .invalid,
                    path: ["$"],
                    message: "rejected configuration because its root is not an object"
                ),
            ])
        }

        var diagnostics: [Diagnostic] = []
        var encoded: [String: JSONValue] = [:]

        for key in unsupportedTopLevel where obj[key] != nil {
            diagnostics.append(Diagnostic(kind: .unsupported, path: [key], message: "omitted unsupported legacy setting"))
        }

        // Legacy scalar migrations
        if let snap = obj["snapshot"] {
            if case .bool = snap {
                encoded["snapshots"] = snap
            } else {
                diagnostics.append(Diagnostic(kind: .invalid, path: ["snapshot"], message: "skipped malformed recognized value"))
            }
        }

        var migratedUpdate: JSONValue? = nil
        if let auto = obj["autoupdate"] {
            switch auto {
            case .bool(false): migratedUpdate = .string("disable")
            case .bool(true): migratedUpdate = .string("auto")
            case .string("notify"): migratedUpdate = .string("notify")
            default:
                diagnostics.append(Diagnostic(kind: .invalid, path: ["autoupdate"], message: "skipped malformed recognized value"))
            }
        }
        let nativeUpdate = obj["update"]
        if let native = nativeUpdate {
            if let migrated = migratedUpdate, migrated != native {
                diagnostics.append(Diagnostic(kind: .conflict, path: ["update"], message: "retained native value over legacy value"))
            }
            encoded["update"] = native
        } else if let migrated = migratedUpdate {
            encoded["update"] = migrated
        }

        if let autoshare = obj["autoshare"] {
            if case .bool(true) = autoshare {
                encoded["share"] = .string("auto")
            } else if case .bool(false) = autoshare {
                // false means unset
            } else {
                diagnostics.append(Diagnostic(kind: .invalid, path: ["autoshare"], message: "skipped malformed recognized value"))
            }
        }

        if let attachment = obj["attachment"] {
            encoded["media"] = attachment
        }

        // References (`reference` -> `references`)
        mergeRecordField(input: obj, legacyKey: "reference", nativeKey: "references", encoded: &encoded, diagnostics: &diagnostics)

        // Commands (`command` -> `commands`)
        mergeRecordField(input: obj, legacyKey: "command", nativeKey: "commands", encoded: &encoded, diagnostics: &diagnostics)

        // Agents (`agent` + `mode` + `small_model` -> `agents`)
        var mergedAgents: [String: JSONValue] = [:]
        var hasAgents = false
        if case .object(let legacyAgentMap) = obj["agent"] {
            hasAgents = true
            for (k, v) in legacyAgentMap { mergedAgents[k] = v }
        }
        if case .string(let smallModel) = obj["small_model"], smallModel.contains("/") {
            hasAgents = true
            if case .object(var titleObj) = mergedAgents["title"] {
                if titleObj["model"] == nil { titleObj["model"] = .string(smallModel) }
                mergedAgents["title"] = .object(titleObj)
            } else {
                mergedAgents["title"] = .object(["model": .string(smallModel)])
            }
        }
        if case .object(let modeMap) = obj["mode"] {
            hasAgents = true
            for (k, v) in modeMap {
                if case .object(var mObj) = v {
                    mObj["mode"] = .string("primary")
                    mergedAgents[k] = .object(mObj)
                }
            }
        }
        if case .object(let nativeAgentMap) = obj["agents"] {
            hasAgents = true
            for (k, v) in nativeAgentMap {
                if let existing = mergedAgents[k], existing != v {
                    diagnostics.append(Diagnostic(kind: .conflict, path: ["agents", k], message: "retained native value over legacy value"))
                }
                mergedAgents[k] = v
            }
        }
        if hasAgents {
            encoded["agents"] = .object(mergedAgents)
        }

        // Providers (`provider` -> `providers`)
        mergeRecordField(input: obj, legacyKey: "provider", nativeKey: "providers", encoded: &encoded, diagnostics: &diagnostics)

        // Permissions (`tools` + `permission` + `permissions` -> `permissions`)
        var permissions: [JSONValue] = []
        var hasPermissions = false
        if let rawTools = obj["tools"] {
            if case .object(let toolsMap) = rawTools {
                for (action, rawVal) in toolsMap.sorted(by: { $0.key < $1.key }) {
                    if case .bool(let enabled) = rawVal {
                        permissions.append(.object([
                            "action": .string(normalizeLegacyAction(action)),
                            "resource": .string("*"),
                            "effect": .string(enabled ? "allow" : "deny"),
                        ]))
                    } else {
                        diagnostics.append(Diagnostic(kind: .invalid, path: ["tools", action], message: "skipped malformed recognized value"))
                    }
                }
            } else {
                diagnostics.append(Diagnostic(kind: .invalid, path: ["tools"], message: "skipped malformed recognized value"))
            }
        }
        if let rawPerm = obj["permission"] {
            switch rawPerm {
            case .string(let eff) where eff == "allow" || eff == "deny" || eff == "ask":
                permissions.append(.object([
                    "action": .string("*"),
                    "resource": .string("*"),
                    "effect": .string(eff),
                ]))
            case .object(let permMap):
                for (action, rawVal) in permMap.sorted(by: { $0.key < $1.key }) {
                    let normAction = normalizeLegacyAction(action)
                    switch rawVal {
                    case .string(let eff) where eff == "allow" || eff == "deny" || eff == "ask":
                        permissions.append(.object([
                            "action": .string(normAction),
                            "resource": .string("*"),
                            "effect": .string(eff),
                        ]))
                    case .object(let resourceMap):
                        for (res, resEff) in resourceMap.sorted(by: { $0.key < $1.key }) {
                            if case .string(let eff) = resEff, eff == "allow" || eff == "deny" || eff == "ask" {
                                permissions.append(.object([
                                    "action": .string(normAction),
                                    "resource": .string(res),
                                    "effect": .string(eff),
                                ]))
                            } else {
                                diagnostics.append(Diagnostic(kind: .invalid, path: ["permission", action, res], message: "skipped malformed recognized value"))
                            }
                        }
                    default:
                        diagnostics.append(Diagnostic(kind: .invalid, path: ["permission", action], message: "skipped malformed recognized value"))
                    }
                }
            default:
                diagnostics.append(Diagnostic(kind: .invalid, path: ["permission"], message: "skipped malformed recognized value"))
            }
        }
        if let rawNativePerms = obj["permissions"] {
            if case .array(let arr) = rawNativePerms {
                hasPermissions = true
                permissions.append(contentsOf: arr)
            } else {
                diagnostics.append(Diagnostic(kind: .invalid, path: ["permissions"], message: "skipped malformed recognized value"))
            }
        }
        if !permissions.isEmpty || hasPermissions {
            encoded["permissions"] = .array(permissions)
        }

        // Plugins (`plugin` + `plugins` -> `plugins`)
        var plugins: [JSONValue] = []
        var hasPlugins = false
        if case .array(let legacyPlugs) = obj["plugin"] {
            hasPlugins = true
            for item in legacyPlugs {
                if case .string = item {
                    plugins.append(item)
                } else if case .array(let tuple) = item, tuple.count == 2, case .string(let pkg) = tuple[0] {
                    plugins.append(.object(["package": .string(pkg), "options": tuple[1]]))
                }
            }
        }
        if case .array(let nativePlugs) = obj["plugins"] {
            hasPlugins = true
            plugins.append(contentsOf: nativePlugs)
        }
        if !plugins.isEmpty || hasPlugins {
            encoded["plugins"] = .array(plugins)
        }

        // Skills
        if let rawSkills = obj["skills"] {
            switch rawSkills {
            case .array(let arr):
                encoded["skills"] = .array(arr)
            case .object(let skillObj):
                var combined: [JSONValue] = []
                if case .array(let paths) = skillObj["paths"] { combined.append(contentsOf: paths) }
                if case .array(let urls) = skillObj["urls"] { combined.append(contentsOf: urls) }
                encoded["skills"] = .array(combined)
            default:
                diagnostics.append(Diagnostic(kind: .invalid, path: ["skills"], message: "skipped malformed recognized value"))
            }
        }

        // MCP
        if let rawMcp = obj["mcp"] {
            if case .object(let mcpObj) = rawMcp {
                encoded["mcp"] = .object(mcpObj)
            } else {
                diagnostics.append(Diagnostic(kind: .invalid, path: ["mcp"], message: "skipped malformed recognized value"))
            }
        }

        // Compaction
        if let rawComp = obj["compaction"] {
            if case .object(let compObj) = rawComp {
                var compOut: [String: JSONValue] = [:]
                if let auto = compObj["auto"] { compOut["auto"] = auto }
                if let bg = compObj["background"] { compOut["background"] = bg }
                if let keep = compObj["keep"] {
                    compOut["keep"] = keep
                } else if let preserve = compObj["preserve_recent_tokens"] {
                    compOut["keep"] = .object(["tokens": preserve])
                }
                if let buffer = compObj["buffer"] {
                    compOut["buffer"] = buffer
                } else if let reserved = compObj["reserved"] {
                    compOut["buffer"] = reserved
                }
                encoded["compaction"] = .object(compOut)
            } else {
                diagnostics.append(Diagnostic(kind: .invalid, path: ["compaction"], message: "skipped malformed recognized value"))
            }
        }

        // Policies (`enabled_providers` + `disabled_providers` + `experimental.policies` + `policies`)
        var policies: [JSONValue] = []
        var hasPolicies = false
        if case .array(let enabledProviders) = obj["enabled_providers"] {
            policies.append(.object([
                "action": .string("provider.use"),
                "resource": .string("*"),
                "effect": .string("deny"),
            ]))
            for item in enabledProviders {
                if case .string(let name) = item {
                    policies.append(.object([
                        "action": .string("provider.use"),
                        "resource": .string(name),
                        "effect": .string("allow"),
                    ]))
                }
            }
        }
        if case .array(let disabledProviders) = obj["disabled_providers"] {
            for item in disabledProviders {
                if case .string(let name) = item {
                    policies.append(.object([
                        "action": .string("provider.use"),
                        "resource": .string(name),
                        "effect": .string("deny"),
                    ]))
                }
            }
        }
        if case .object(let expObj) = obj["experimental"], case .array(let expPol) = expObj["policies"] {
            hasPolicies = true
            policies.append(contentsOf: expPol)
        }
        if case .array(let nativePol) = obj["policies"] {
            hasPolicies = true
            policies.append(contentsOf: nativePol)
        }
        if !policies.isEmpty || hasPolicies {
            encoded["policies"] = .array(policies)
        }

        // Experimental
        if let rawExp = obj["experimental"] {
            if case .object(let expObj) = rawExp {
                var expOut: [String: JSONValue] = [:]
                for key in unsupportedExperimental where expObj[key] != nil {
                    diagnostics.append(Diagnostic(kind: .unsupported, path: ["experimental", key], message: "omitted unsupported legacy setting"))
                }
                for (k, v) in expObj where k != "policies" && !unsupportedExperimental.contains(k) {
                    expOut[k] = v
                }
                encoded["experimental"] = .object(expOut)
            } else {
                diagnostics.append(Diagnostic(kind: .invalid, path: ["experimental"], message: "skipped malformed recognized value"))
            }
        }

        // Watcher, Formatter, LSP
        if let w = obj["watcher"] { encoded["watcher"] = w }
        if let f = obj["formatter"] { encoded["formatter"] = f }
        if let l = obj["lsp"] { encoded["lsp"] = l }

        // Model
        if let model = obj["model"] {
            encoded["model"] = model
        }

        // Native atomic keys
        for key in nativeAtomicKeys {
            guard let val = obj[key] else { continue }
            if let existing = encoded[key], existing != val {
                diagnostics.append(Diagnostic(kind: .conflict, path: [key], message: "retained native value over legacy value"))
            }
            encoded[key] = val
        }

        // Instructions
        if case .array(let instr) = obj["instructions"] {
            encoded["instructions"] = .array(instr)
        }

        return .normalized(encoded: encoded, diagnostics: diagnostics)
    }

    private static func normalizeLegacyAction(_ action: String) -> String {
        switch action {
        case "bash": return "shell"
        case "write", "apply_patch", "patch", "multiedit": return "edit"
        default: return action
        }
    }

    private static func mergeRecordField(
        input: [String: JSONValue],
        legacyKey: String,
        nativeKey: String,
        encoded: inout [String: JSONValue],
        diagnostics: inout [Diagnostic]
    ) {
        var merged: [String: JSONValue] = [:]
        var present = false
        if case .object(let legacy) = input[legacyKey] {
            present = true
            for (k, v) in legacy { merged[k] = v }
        } else if input[legacyKey] != nil {
            diagnostics.append(Diagnostic(kind: .invalid, path: [legacyKey], message: "skipped malformed recognized value"))
        }
        if case .object(let native) = input[nativeKey] {
            present = true
            for (k, v) in native {
                if let existing = merged[k], existing != v {
                    diagnostics.append(Diagnostic(kind: .conflict, path: [nativeKey, k], message: "retained native value over legacy value"))
                }
                merged[k] = v
            }
        } else if input[nativeKey] != nil {
            diagnostics.append(Diagnostic(kind: .invalid, path: [nativeKey], message: "skipped malformed recognized value"))
        }
        if present {
            encoded[nativeKey] = .object(merged)
        }
    }
}

// MARK: - Hierarchical Config Discovery (`core/src/config/discovery.ts`)

public enum CoreConfigDiscovery {
    // parity: core/src/config/discovery.ts#names [status=implemented hash=b22b89185eb7]
    public static let names: [String] = ["opencode.json", "opencode.jsonc"]

    public struct DirectoryCandidate: Equatable, Hashable, Sendable, Codable {
        public let path: SchemaPrimitive.AbsolutePath
        public let present: Bool

        public init(path: SchemaPrimitive.AbsolutePath, present: Bool) {
            self.path = path
            self.present = present
        }
    }

    /// Eligible configuration sources in priority order, including paths that may appear later.
    // parity: core/src/config/discovery.ts#Sources [status=implemented hash=aa34b8894ddd]
    public struct Sources: Equatable, Hashable, Sendable, Codable {
        public let system: DirectoryCandidate?
        public let preferences: SchemaPrimitive.AbsolutePath?
        public let global: SchemaPrimitive.AbsolutePath?
        public let explicit: SchemaPrimitive.AbsolutePath?
        public let direct: [SchemaPrimitive.AbsolutePath]
        public let project: [DirectoryCandidate]
        public let claude: [SchemaPrimitive.AbsolutePath]
        public let agents: [SchemaPrimitive.AbsolutePath]

        public init(
            system: DirectoryCandidate? = nil,
            preferences: SchemaPrimitive.AbsolutePath? = nil,
            global: SchemaPrimitive.AbsolutePath? = nil,
            explicit: SchemaPrimitive.AbsolutePath? = nil,
            direct: [SchemaPrimitive.AbsolutePath] = [],
            project: [DirectoryCandidate] = [],
            claude: [SchemaPrimitive.AbsolutePath] = [],
            agents: [SchemaPrimitive.AbsolutePath] = []
        ) {
            self.system = system
            self.preferences = preferences
            self.global = global
            self.explicit = explicit
            self.direct = direct
            self.project = project
            self.claude = claude
            self.agents = agents
        }
    }

    /// Platform system configuration directory (`/Library/Application Support/opencode`, `/etc/opencode`, `%ProgramData%\opencode`).
    // parity: core/src/config/discovery.ts#systemDirectory [status=implemented hash=c250e39e7b6b]
    public static func systemDirectory(
        platform: PlatformOS = Platform.current,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) -> SchemaPrimitive.AbsolutePath {
        switch platform {
        case .macOS:
            return SchemaPrimitive.AbsolutePath(rawValue: "/Library/Application Support/opencode")
        case .windows:
            let base = environment.variable("ProgramData") ?? "C:\\ProgramData"
            return SchemaPrimitive.AbsolutePath(rawValue: "\(base)\\opencode")
        default:
            return SchemaPrimitive.AbsolutePath(rawValue: "/etc/opencode")
        }
    }

    /// macOS MDM managed preferences plists, most specific first; the first one present wins.
    // parity: core/src/config/discovery.ts#preferencePaths [status=implemented hash=3bc2532981cc]
    public static func preferencePaths(user: String) -> [SchemaPrimitive.AbsolutePath] {
        [
            SchemaPrimitive.AbsolutePath(rawValue: "/Library/Managed Preferences/\(user)/ai.opencode.managed.plist"),
            SchemaPrimitive.AbsolutePath(rawValue: "/Library/Managed Preferences/ai.opencode.managed.plist"),
        ]
    }

    private static let preferenceMetadataKeys: Set<String> = [
        "PayloadDisplayName",
        "PayloadIdentifier",
        "PayloadType",
        "PayloadUUID",
        "PayloadVersion",
        "_manualProfile",
    ]

    /// Removes macOS/MDM payload metadata keys from `plutil -convert json` output.
    // parity: core/src/config/discovery.ts#stripPreferenceMetadata [status=implemented hash=c32c6cb99d3f]
    public static func stripPreferenceMetadata(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let obj) = parsed
        else {
            return json
        }
        let filtered = obj.filter { !preferenceMetadataKeys.contains($0.key) }
        guard let encoded = try? JSONEncoder().encode(JSONValue.object(filtered)) else {
            return json
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    /// Discovers all eligible config sources across system, global, explicit, and ancestor project directories.
    // parity: core/src/config/discovery.ts#discover [status=implemented hash=814ca7c0a28d]
    public static func discover(
        directory: String,
        options: CoreConfig.Options? = nil,
        global: Global.Interface? = nil,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        environment: any EnvironmentProviding = SystemEnvironment.shared,
        platform: PlatformOS = Platform.current
    ) async -> Sources {
        let fsUtil = FSUtil.Service(fileSystem: fileSystem)
        let globalPaths = global ?? Global.make(environment: environment, os: platform)

        let systemDir: SchemaPrimitive.AbsolutePath?
        switch options?.system {
        case .disabled:
            systemDir = nil
        case .custom(let customPath):
            systemDir = SchemaPrimitive.AbsolutePath(rawValue: resolvePath(base: directory, relative: customPath))
        case .enabled, .none:
            systemDir = systemDirectory(platform: platform, environment: environment)
        }

        let globalDir = SchemaPrimitive.AbsolutePath(rawValue: globalPaths.config)
        let globalAgentsDir = SchemaPrimitive.AbsolutePath(rawValue: joinPath(globalPaths.home, ".agents"))
        let globalClaudeDir = SchemaPrimitive.AbsolutePath(rawValue: joinPath(globalPaths.home, ".claude"))

        let configDirs = (systemDir.map { [$0.rawValue] } ?? []) + [globalDir.rawValue]
        var globalRoots: [String] = []
        for root in configDirs + [globalClaudeDir.rawValue, globalAgentsDir.rawValue] {
            globalRoots.append(await fsUtil.resolve(root))
        }
        let currentResolved = await fsUtil.resolve(directory)
        let configRoots = Array(globalRoots.prefix(configDirs.count))

        let directories: [String]
        if configRoots.contains(currentResolved) || options?.project == false {
            directories = []
        } else {
            directories = ancestorDirectories(startingAt: directory)
        }

        let candidates = [".claude", ".agents", ".opencode"] + names.reversed()
        var discovered: [(item: SchemaPrimitive.AbsolutePath, resolved: String, missing: Bool)] = []
        for dir in directories {
            let parent = dir == directory ? currentResolved : await fsUtil.resolve(dir)
            let listing = (try? await fileSystem.readDirectory(at: parent)).map { Set($0.map { $0.lowercased() }) }
            for name in candidates {
                let item = SchemaPrimitive.AbsolutePath(rawValue: joinPath(dir, name))
                if let listing, !listing.contains(name.lowercased()) {
                    discovered.append((item, resolvePath(base: parent, relative: name), true))
                } else {
                    let resolved = await fsUtil.resolve(joinPath(parent, name))
                    discovered.append((item, resolved, false))
                }
            }
        }

        let globalEnabled = options?.global != false
        var globalFiles: [String] = []
        for dir in configDirs {
            for name in names {
                globalFiles.append(await fsUtil.resolve(joinPath(dir, name)))
            }
        }

        let visibleEntries = discovered.filter { entry in
            if globalEnabled {
                return !globalRoots.contains(entry.resolved) && !globalFiles.contains(entry.resolved)
            }
            return !globalRoots.contains { root in
                entry.resolved == root || entry.resolved.hasPrefix(root + "/")
            }
        }

        let direct = visibleEntries
            .filter { ![".agents", ".claude", ".opencode"].contains(basename($0.item.rawValue)) }
            .map(\.item)
            .reversed()

        var projectEntries: [DirectoryCandidate] = []
        for entry in visibleEntries.filter({ basename($0.item.rawValue) == ".opencode" }).reversed() {
            let present = entry.missing ? false : await fsUtil.isDir(entry.item.rawValue)
            projectEntries.append(DirectoryCandidate(path: entry.item, present: present))
        }

        var claudeList: [SchemaPrimitive.AbsolutePath] = []
        if options?.claude != false {
            var seen: Set<String> = []
            if globalEnabled, seen.insert(globalClaudeDir.rawValue).inserted {
                claudeList.append(globalClaudeDir)
            }
            for item in visibleEntries.filter({ basename($0.item.rawValue) == ".claude" }).map(\.item).reversed() {
                if seen.insert(item.rawValue).inserted { claudeList.append(item) }
            }
        }

        var agentsList: [SchemaPrimitive.AbsolutePath] = []
        do {
            var seen: Set<String> = []
            if globalEnabled, seen.insert(globalAgentsDir.rawValue).inserted {
                agentsList.append(globalAgentsDir)
            }
            for item in visibleEntries.filter({ basename($0.item.rawValue) == ".agents" }).map(\.item).reversed() {
                if seen.insert(item.rawValue).inserted { agentsList.append(item) }
            }
        }

        let isDefaultSystem: Bool = switch options?.system {
        case .enabled, .none: true
        case .disabled, .custom: false
        }
        var preferencesPath: SchemaPrimitive.AbsolutePath? = nil
        if globalEnabled && isDefaultSystem && platform == .macOS {
            let user = environment.variable("USER") ?? "user"
            for candidate in preferencePaths(user: user) {
                if await fsUtil.isFile(candidate.rawValue) {
                    preferencesPath = candidate
                    break
                }
            }
        }

        let systemCandidate: DirectoryCandidate?
        if globalEnabled, let systemDir {
            systemCandidate = DirectoryCandidate(path: systemDir, present: await fsUtil.isDir(systemDir.rawValue))
        } else {
            systemCandidate = nil
        }

        let explicitPath = options?.file.map { SchemaPrimitive.AbsolutePath(rawValue: resolvePath(base: directory, relative: $0)) }

        return Sources(
            system: systemCandidate,
            preferences: preferencesPath,
            global: globalEnabled ? globalDir : nil,
            explicit: explicitPath,
            direct: Array(direct),
            project: projectEntries,
            claude: claudeList,
            agents: agentsList
        )
    }

    internal static func joinPath(_ a: String, _ b: String) -> String {
        if a == "/" { return "/\(b)" }
        if a.hasSuffix("/") { return a + b }
        return "\(a)/\(b)"
    }

    internal static func dirname(_ path: String) -> String {
        var p = path.replacing("\\", with: "/")
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        guard let slash = p.lastIndex(of: "/") else { return "." }
        if slash == p.startIndex { return "/" }
        return String(p[..<slash])
    }

    internal static func basename(_ path: String) -> String {
        var p = path.replacing("\\", with: "/")
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        guard let slash = p.lastIndex(of: "/") else { return p }
        return String(p[p.index(after: slash)...])
    }

    internal static func resolvePath(base: String, relative: String) -> String {
        let cleanRel = relative.replacing("\\", with: "/")
        let combined = cleanRel.hasPrefix("/") ? cleanRel : joinPath(base.replacing("\\", with: "/"), cleanRel)
        var parts: [String] = []
        for seg in combined.split(separator: "/") {
            if seg.isEmpty || seg == "." { continue }
            if seg == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(String(seg))
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func ancestorDirectories(startingAt start: String) -> [String] {
        var dirs: [String] = []
        var current = resolvePath(base: "/", relative: start)
        while true {
            dirs.append(current)
            let parent = dirname(current)
            if parent == current { break }
            current = parent
        }
        return dirs
    }
}

// MARK: - Config Watch Planning (`core/src/config/watch.ts`)

public enum CoreConfigWatch {
    public enum Target: Equatable, Hashable, Sendable {
        case directory(path: String, ignore: [String])
        case entries(path: String, names: [String])

        public var path: String {
            switch self {
            case .directory(let p, _): return p
            case .entries(let p, _): return p
            }
        }

        public var key: String {
            switch self {
            case .directory(let p, let ignore):
                return "directory:\(p):\(ignore.joined(separator: ","))"
            case .entries(let p, let names):
                return "entries:\(p):\(names.joined(separator: ","))"
            }
        }

        /// Converts this watch plan target into a shared `CoreFilesystem.Watcher.WatchInput`.
        public var watchInput: CoreFilesystem.Watcher.WatchInput {
            switch self {
            case .directory(let p, let ignore):
                return .directory(path: p, ignore: ignore)
            case .entries(let p, let names):
                return .entries(path: p, names: names)
            }
        }
    }

    private static func normalizeKey(_ file: String) -> String {
        CoreConfigDiscovery.resolvePath(base: "/", relative: file).lowercased()
    }

    /// Returns a predicate identifying paths whose content or presence feeds the loaded config.
    // parity: core/src/config/watch.ts#inputs [status=implemented hash=4f9fdc12982b]
    public static func inputs(
        sources: CoreConfigDiscovery.Sources,
        references: Set<String>,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
    ) async -> @Sendable (String) -> Bool {
        var realRefs: [String] = []
        for ref in references {
            let real = (try? await fileSystem.realPath(at: ref)) ?? ref
            realRefs.append(real)
        }

        var roots: [String] = []
        if let sys = sources.system { roots.append(sys.path.rawValue) }
        if let glob = sources.global { roots.append(glob.rawValue) }
        roots.append(contentsOf: sources.project.map { $0.path.rawValue })

        var allPaths: Set<String> = []
        for r in roots {
            allPaths.insert(normalizeKey(r))
            for name in CoreConfigDiscovery.names {
                allPaths.insert(normalizeKey(CoreConfigDiscovery.joinPath(r, name)))
            }
        }
        for d in sources.direct { allPaths.insert(normalizeKey(d.rawValue)) }
        for c in sources.claude { allPaths.insert(normalizeKey(c.rawValue)) }
        for a in sources.agents { allPaths.insert(normalizeKey(a.rawValue)) }
        if let explicit = sources.explicit { allPaths.insert(normalizeKey(explicit.rawValue)) }
        for r in references { allPaths.insert(normalizeKey(r)) }
        for r in realRefs { allPaths.insert(normalizeKey(r)) }

        let snapshot = allPaths
        return { file in snapshot.contains(normalizeKey(file)) }
    }

    /// Computes watch targets covering all discovered directories and parent entry watches for missing/recreatable roots.
    // parity: core/src/config/watch.ts#plan [status=implemented hash=d8b8dba25a09]
    public static func plan(_ sources: CoreConfigDiscovery.Sources) -> [String: Target] {
        var directories: [String] = []
        if let sys = sources.system, sys.present { directories.append(sys.path.rawValue) }
        if let glob = sources.global { directories.append(glob.rawValue) }
        directories.append(contentsOf: sources.project.filter(\.present).map { $0.path.rawValue })

        var files: [String] = []
        if let sys = sources.system { files.append(sys.path.rawValue) }
        files.append(contentsOf: sources.direct.map(\.rawValue))
        files.append(contentsOf: sources.project.map { $0.path.rawValue })
        files.append(contentsOf: sources.claude.map(\.rawValue))
        files.append(contentsOf: sources.agents.map(\.rawValue))
        if let explicit = sources.explicit { files.append(explicit.rawValue) }

        var parents: [String: Set<String>] = [:]
        for file in files {
            let insideWatchedDir = directories.contains { dir in
                file != dir && FSPathUtil.contains(parent: dir, child: file)
            }
            if insideWatchedDir { continue }
            let parent = CoreConfigDiscovery.dirname(file)
            parents[parent, default: []].insert(CoreConfigDiscovery.basename(file))
        }

        var result: [String: Target] = [:]
        for dir in directories {
            let target = Target.directory(path: dir, ignore: FSPathUtil.ignoreGlobs)
            result[target.key] = target
        }
        for (parent, names) in parents {
            let target = Target.entries(path: parent, names: names.sorted())
            result[target.key] = target
        }
        return result
    }
}

// MARK: - Hierarchical Config Service (`core/src/config.ts`)

public enum CoreConfig {
    public struct CompatibilityRoots: Equatable, Hashable, Sendable, Codable {
        public let claude: [SchemaPrimitive.AbsolutePath]
        public let agents: [SchemaPrimitive.AbsolutePath]

        public init(
            claude: [SchemaPrimitive.AbsolutePath] = [],
            agents: [SchemaPrimitive.AbsolutePath] = []
        ) {
            self.claude = claude
            self.agents = agents
        }
    }

    public struct WatchUpdate: Equatable, Hashable, Sendable, Codable {
        public enum Kind: String, Equatable, Hashable, Sendable, Codable {
            case create
            case update
            case delete
        }

        public let path: String
        public let type: Kind

        public init(path: String, type: Kind) {
            self.path = path
            self.type = type
        }
    }

    public enum SystemOption: Equatable, Hashable, Sendable {
        case enabled
        case disabled
        case custom(String)
    }

    // parity: core/src/config.ts#Options [status=implemented hash=f06cfb36b814]
    public struct Options: Equatable, Hashable, Sendable {
        public let project: Bool?
        public let global: Bool?
        public let system: SystemOption?
        public let claude: Bool?
        public let file: String?
        public let content: String?

        public init(
            project: Bool? = nil,
            global: Bool? = nil,
            system: SystemOption? = nil,
            claude: Bool? = nil,
            file: String? = nil,
            content: String? = nil
        ) {
            self.project = project
            self.global = global
            self.system = system
            self.claude = claude
            self.file = file
            self.content = content
        }
    }

    /// Returns the value of `keyPath` from the highest-priority (last) document entry that defines it.
    // parity: core/src/config.ts#latest [status=implemented hash=bc751e3dbd9b]
    public static func latest<Value>(
        _ entries: [CoreConfigEntry],
        _ keyPath: KeyPath<ConfigSchema.Info, Value?>
    ) -> Value? {
        for entry in entries.reversed() {
            if let info = entry.info, let value = info[keyPath: keyPath] {
                return value
            }
        }
        return nil
    }

    public static func latest<Value>(
        _ entries: [ConfigSchema.Entry],
        _ keyPath: KeyPath<ConfigSchema.Info, Value?>
    ) -> Value? {
        for entry in entries.reversed() {
            if case .document(let doc) = entry, let value = doc.info[keyPath: keyPath] {
                return value
            }
        }
        return nil
    }

    // parity: core/src/config.ts#Interface [status=adapted hash=55e4af7f03b4]
    public protocol Interface: Sendable {
        func entries() async -> [CoreConfigEntry]
        func compatibility() async -> CompatibilityRoots
        func changes() -> AsyncStream<WatchUpdate>
        func update(_ patch: ConfigSchema.Patch) async throws
        func integration(
            _ integrationID: IntegrationID,
            document: CoreConfigIntegration.Document?
        ) async
    }

    // parity: core/src/config.ts#TestInterface [status=adapted hash=c6b136a69386]
    public protocol TestInterface: Interface {
        func setEntries(_ entries: [CoreConfigEntry]) async
        func emitChange(_ update: WatchUpdate) async
    }

    // parity: core/src/config.ts#Service [status=adapted hash=ea89ce8a8b6d]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/Config"

        /// Trailing-edge debounce window for config reload bursts (upstream: `Stream.debounce("100 millis")`).
        public static let defaultDebounce: Duration = .milliseconds(100)

        private struct WatchEntry: Sendable {
            let generation: UInt64
            let task: Task<Void, Never>
        }

        private struct State: Sendable {
            var sources: CoreConfigDiscovery.Sources
            var entries: [CoreConfigEntry]
            var isInput: @Sendable (String) -> Bool
            var integrations: [IntegrationID: CoreConfigIntegration.Document] = [:]
            var integrationOrder: [IntegrationID] = []
            var subscribers: [UInt64: AsyncStream<WatchUpdate>.Continuation] = [:]
            var nextSubscriberID: UInt64 = 1
            var watched: [String: WatchEntry] = [:]
            var nextWatchGeneration: UInt64 = 1
            var debounceTask: Task<Void, Never>?
            var debounceGeneration: UInt64 = 0
            var reloadInProgress: Bool = false
            var pendingReloadAfterCurrent: Bool = false
            var reloadCount: Int = 0
            var closed: Bool = false
        }

        private actor SerialGate {
            private var locked = false
            private var waiters: [CheckedContinuation<Void, Never>] = []

            func acquire() async {
                if !locked {
                    locked = true
                    return
                }
                await withCheckedContinuation { continuation in
                    waiters.append(continuation)
                }
            }

            func release() {
                if !waiters.isEmpty {
                    let next = waiters.removeFirst()
                    next.resume()
                } else {
                    locked = false
                }
            }
        }

        private static let configUpdatedDef = EventSchema.EphemeralDefinition<JSONValue>(
            type: ConfigSchema.Event.updated.type
        ).descriptor

        private let directory: String
        private let options: Options?
        private let globalPaths: Global.Interface
        private let fileSystem: any OpenCodeFileSystem
        private let environment: any EnvironmentProviding
        private let platform: PlatformOS
        private let watcher: (any CoreFilesystem.Watcher.Interface)?
        private let bus: (any CoreBus.Interface)?
        private let location: OpenCodeLocation?
        private let debounce: Duration
        private let onUpdated: (@Sendable () async -> Void)?
        private let state: Mutex<State>
        private let reloadLock = SerialGate()
        private let updateLock = SerialGate()

        public init(
            directory: String,
            options: Options? = nil,
            globalPaths: Global.Interface? = nil,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            environment: any EnvironmentProviding = SystemEnvironment.shared,
            platform: PlatformOS = Platform.current,
            watcher: (any CoreFilesystem.Watcher.Interface)? = nil,
            bus: (any CoreBus.Interface)? = nil,
            location: OpenCodeLocation? = nil,
            debounce: Duration = CoreConfig.Service.defaultDebounce,
            onUpdated: (@Sendable () async -> Void)? = nil
        ) async {
            let resolvedGlobal = globalPaths ?? Global.make(environment: environment, os: platform)
            self.directory = directory
            self.options = options
            self.globalPaths = resolvedGlobal
            self.fileSystem = fileSystem
            self.environment = environment
            self.platform = platform
            self.watcher = watcher
            self.bus = bus
            self.location = location ?? OpenCodeLocation(directory: directory)
            self.debounce = debounce
            self.onUpdated = onUpdated

            let discovered = await CoreConfigDiscovery.discover(
                directory: directory,
                options: options,
                global: resolvedGlobal,
                fileSystem: fileSystem,
                environment: environment,
                platform: platform
            )
            let loaded = await Self.loadAll(
                sources: discovered,
                directory: directory,
                options: options,
                globalPaths: resolvedGlobal,
                integrations: [],
                fileSystem: fileSystem,
                environment: environment
            )
            self.state = Mutex(State(sources: discovered, entries: loaded.entries, isInput: loaded.isInput))

            if watcher != nil {
                state.withLock { $0.reloadInProgress = true }
                await reloadLock.acquire()
                await reconcileWatchesLocked(discovered)
                let needsReload = state.withLock { s -> Bool in
                    s.reloadInProgress = false
                    let pending = s.pendingReloadAfterCurrent && !s.closed
                    s.pendingReloadAfterCurrent = false
                    return pending
                }
                await reloadLock.release()
                if needsReload {
                    requestReload()
                }
            }
        }

        deinit {
            let (debounceTask, watchTasks, subs): (
                Task<Void, Never>?,
                [Task<Void, Never>],
                [AsyncStream<WatchUpdate>.Continuation]
            ) = state.withLock { s in
                s.closed = true
                s.pendingReloadAfterCurrent = false
                let d = s.debounceTask
                s.debounceTask = nil
                let tasks = s.watched.values.map(\.task)
                s.watched.removeAll()
                let continuations = Array(s.subscribers.values)
                s.subscribers.removeAll()
                return (d, tasks, continuations)
            }
            debounceTask?.cancel()
            for task in watchTasks { task.cancel() }
            for sub in subs { sub.finish() }
        }

        /// Number of completed `reload()` executions after initial construction (for diagnostics and tests).
        public var reloadCount: Int {
            state.withLock { $0.reloadCount }
        }

        /// Number of currently attached config filesystem watch tasks.
        public var activeWatchCount: Int {
            state.withLock { $0.watched.count }
        }

        public func entries() async -> [CoreConfigEntry] {
            state.withLock { $0.entries }
        }

        public func compatibility() async -> CompatibilityRoots {
            let current = state.withLock { $0.sources }
            let fsUtil = FSUtil.Service(fileSystem: fileSystem)
            var claude: [SchemaPrimitive.AbsolutePath] = []
            for p in current.claude where await fsUtil.isDir(p.rawValue) {
                claude.append(p)
            }
            var agents: [SchemaPrimitive.AbsolutePath] = []
            for p in current.agents where await fsUtil.isDir(p.rawValue) {
                agents.append(p)
            }
            return CompatibilityRoots(claude: claude, agents: agents)
        }

        public func changes() -> AsyncStream<WatchUpdate> {
            AsyncStream { continuation in
                let registeredID: UInt64? = state.withLock { s in
                    guard !s.closed else { return nil }
                    let id = s.nextSubscriberID
                    s.nextSubscriberID &+= 1
                    s.subscribers[id] = continuation
                    return id
                }
                guard let id = registeredID else {
                    continuation.finish()
                    return
                }
                continuation.onTermination = { [weak self] _ in
                    self?.state.withLock { s in
                        _ = s.subscribers.removeValue(forKey: id)
                    }
                }
            }
        }

        /// Stops all config watches, pending debounce timers, and raw change streams for this Location.
        public func close() async {
            let (debounceTask, watchTasks, subs): (
                Task<Void, Never>?,
                [Task<Void, Never>],
                [AsyncStream<WatchUpdate>.Continuation]
            ) = state.withLock { s in
                s.closed = true
                s.pendingReloadAfterCurrent = false
                let d = s.debounceTask
                s.debounceTask = nil
                let tasks = s.watched.values.map(\.task)
                s.watched.removeAll()
                let continuations = Array(s.subscribers.values)
                s.subscribers.removeAll()
                return (d, tasks, continuations)
            }
            debounceTask?.cancel()
            for task in watchTasks { task.cancel() }
            for sub in subs { sub.finish() }
        }

        public func reload() async {
            await reloadLock.acquire()
            let (shouldRun, cancelledTimer): (Bool, Task<Void, Never>?) = state.withLock { s in
                guard !s.closed else { return (false, nil) }
                s.reloadInProgress = true
                s.pendingReloadAfterCurrent = false
                let timer = s.debounceTask
                s.debounceTask = nil
                s.debounceGeneration &+= 1
                return (true, timer)
            }
            cancelledTimer?.cancel()
            await finishReloadLocked(shouldRun: shouldRun)
        }

        private func finishReloadLocked(shouldRun: Bool) async {
            if shouldRun {
                await performReloadLocked()
            }
            let needsReschedule = state.withLock { s -> Bool in
                s.reloadInProgress = false
                let pending = s.pendingReloadAfterCurrent && !s.closed
                s.pendingReloadAfterCurrent = false
                return pending
            }
            await reloadLock.release()
            if needsReschedule {
                requestReload()
            }
        }

        public func update(_ patch: ConfigSchema.Patch) async throws {
            await updateLock.acquire()
            do {
                let globalDir = state.withLock { $0.sources.global?.rawValue } ?? globalPaths.config
                let fsUtil = FSUtil.Service(fileSystem: fileSystem)
                var chosenPath: String? = nil
                for name in CoreConfigDiscovery.names {
                    let candidate = CoreConfigDiscovery.joinPath(globalDir, name)
                    if await fsUtil.isFile(candidate) {
                        chosenPath = candidate
                    }
                }
                let filepath = chosenPath ?? CoreConfigDiscovery.joinPath(globalDir, "opencode.jsonc")
                let existingText = (try? await fsUtil.readFileStringSafe(filepath)) ?? "{}\n"
                var rootObj: [String: JSONValue]
                if let parsed = try? CoreConfigJSONC.parse(existingText), case .object(let obj) = parsed {
                    rootObj = obj
                } else {
                    rootObj = [:]
                }
                if let shell = patch.shell {
                    rootObj["shell"] = .string(shell)
                } else {
                    rootObj.removeValue(forKey: "shell")
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(JSONValue.object(rootObj))
                var outputText = String(decoding: data, as: UTF8.self)
                if !outputText.hasSuffix("\n") { outputText += "\n" }
                try await fileSystem.writeFile(Array(outputText.utf8), to: filepath, createDirectories: true)
                await reload()
                await updateLock.release()
            } catch {
                await updateLock.release()
                throw error
            }
        }

        public func integration(
            _ integrationID: IntegrationID,
            document: CoreConfigIntegration.Document?
        ) async {
            let changed: Bool = state.withLock { s in
                if s.integrations[integrationID] == document { return false }
                s.integrations.removeValue(forKey: integrationID)
                s.integrationOrder.removeAll { $0 == integrationID }
                if let document {
                    s.integrations[integrationID] = document
                    s.integrationOrder.append(integrationID)
                }
                return true
            }
            if changed {
                await reload()
            }
        }

        // MARK: - Live Self-Watching & Coalesced Reloads

        private func performReloadLocked() async {
            guard !state.withLock({ $0.closed }) else { return }
            let discovered = await CoreConfigDiscovery.discover(
                directory: directory,
                options: options,
                global: globalPaths,
                fileSystem: fileSystem,
                environment: environment,
                platform: platform
            )
            let orderedIntegrations: [CoreConfigIntegration.Document] = state.withLock { s in
                s.integrationOrder.compactMap { s.integrations[$0] }
            }
            let next = await Self.loadAll(
                sources: discovered,
                directory: directory,
                options: options,
                globalPaths: globalPaths,
                integrations: orderedIntegrations,
                fileSystem: fileSystem,
                environment: environment
            )
            state.withLock { s in
                s.isInput = next.isInput
                s.reloadCount += 1
            }
            await reconcileWatchesLocked(discovered)

            let changed: Bool = state.withLock { s in
                guard !s.closed else { return false }
                let compatibilityChanged = s.sources.claude != discovered.claude || s.sources.agents != discovered.agents
                let diff = s.entries != next.entries || compatibilityChanged
                if diff {
                    s.sources = discovered
                    s.entries = next.entries
                }
                return diff
            }
            if changed {
                await emitUpdated()
            }
        }

        private func emitUpdated() async {
            if let onUpdated {
                await onUpdated()
                return
            }
            guard let bus else { return }
            _ = try? await bus.publishRaw(
                definition: Self.configUpdatedDef,
                data: .object([:]),
                options: CoreBus.PublishOptions(location: location)
            )
        }

        private func reconcileWatchesLocked(_ sources: CoreConfigDiscovery.Sources) async {
            guard let watcher, !state.withLock({ $0.closed }) else { return }
            let plan = CoreConfigWatch.plan(sources)

            let removedTasks: [Task<Void, Never>] = state.withLock { s in
                var tasks: [Task<Void, Never>] = []
                for key in Array(s.watched.keys) where plan[key] == nil {
                    if let removed = s.watched.removeValue(forKey: key) {
                        tasks.append(removed.task)
                    }
                }
                return tasks
            }
            for task in removedTasks { task.cancel() }

            let fsUtil = FSUtil.Service(fileSystem: fileSystem)
            for key in plan.keys.sorted() {
                guard let target = plan[key] else { continue }
                let skip = state.withLock { s in
                    s.closed || s.watched[key] != nil
                }
                if skip || Task.isCancelled { continue }

                let targetPath = target.path
                let realBox = Mutex(targetPath)
                let updates = await watcher.subscribe(target.watchInput) { [weak self] in
                    let resolved = await fsUtil.resolve(targetPath)
                    realBox.withLock { $0 = resolved }
                    // Readiness rescans recover writes made before a watch attached.
                    self?.requestReload()
                }

                if state.withLock({ $0.closed }) || Task.isCancelled {
                    break
                }

                let generation = state.withLock { s -> UInt64 in
                    let gen = s.nextWatchGeneration
                    s.nextWatchGeneration &+= 1
                    return gen
                }

                let task = Task { [weak self] in
                    for await update in updates {
                        if Task.isCancelled { break }
                        guard let self else { break }
                        self.publishRawChange(update)
                        if self.matchesInput(update.path, targetPath: targetPath, realPath: realBox.withLock { $0 }) {
                            self.requestReload()
                        }
                    }
                    self?.removeWatchIfMatching(key: key, generation: generation)
                }

                let cancelNow: Task<Void, Never>? = state.withLock { s in
                    if s.closed || s.watched[key] != nil {
                        return task
                    }
                    s.watched[key] = WatchEntry(generation: generation, task: task)
                    return nil
                }
                cancelNow?.cancel()
            }
        }

        private func publishRawChange(_ update: WatchUpdate) {
            let subs = state.withLock { s -> [AsyncStream<WatchUpdate>.Continuation] in
                guard !s.closed else { return [] }
                return Array(s.subscribers.values)
            }
            for sub in subs {
                sub.yield(update)
            }
        }

        private func matchesInput(_ updatePath: String, targetPath: String, realPath: String) -> Bool {
            let predicate = state.withLock { $0.isInput }
            if predicate(updatePath) { return true }
            // Native watches can report the canonical path even after the root was deleted.
            if realPath == targetPath || !FSPathUtil.contains(parent: realPath, child: updatePath) {
                return false
            }
            let rel = FSPathUtil.posixRelative(from: realPath, to: updatePath)
            let mapped = rel.isEmpty ? targetPath : CoreConfigDiscovery.joinPath(targetPath, rel)
            return predicate(mapped)
        }

        private func requestReload() {
            let delay = self.debounce
            let previousTask: Task<Void, Never>? = state.withLock { s in
                guard !s.closed else { return nil }
                if s.reloadInProgress {
                    s.pendingReloadAfterCurrent = true
                    return nil
                }
                let prev = s.debounceTask
                s.debounceGeneration &+= 1
                let generation = s.debounceGeneration
                s.debounceTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        return
                    }
                    await self?.flushDebouncedReload(generation: generation)
                }
                return prev
            }
            previousTask?.cancel()
        }

        private func flushDebouncedReload(generation: UInt64) async {
            let claimed: Bool = state.withLock { s in
                guard !s.closed, s.debounceGeneration == generation else { return false }
                s.debounceTask = nil
                if s.reloadInProgress {
                    s.pendingReloadAfterCurrent = true
                    return false
                }
                s.reloadInProgress = true
                s.pendingReloadAfterCurrent = false
                return true
            }
            guard claimed else { return }
            await reloadLock.acquire()
            let stillOpen: Bool = state.withLock { s in
                guard !s.closed else { return false }
                s.reloadInProgress = true
                return true
            }
            await finishReloadLocked(shouldRun: stillOpen)
        }

        private func removeWatchIfMatching(key: String, generation: UInt64) {
            state.withLock { s in
                guard let entry = s.watched[key], entry.generation == generation else { return }
                s.watched.removeValue(forKey: key)
            }
        }

        // MARK: - Config Loading

        private static func loadFile(
            _ filepath: String,
            references: inout Set<String>,
            home: String,
            fileSystem: any OpenCodeFileSystem,
            environment: any EnvironmentProviding
        ) async -> ConfigSchema.Document? {
            let fsUtil = FSUtil.Service(fileSystem: fileSystem)
            guard let text = try? await fsUtil.readFileStringSafe(filepath) else { return nil }
            references.insert(filepath)
            let sub = await CoreConfigVariable.substitute(
                CoreConfigVariable.SubstituteInput(
                    source: .path(filepath),
                    text: text,
                    home: home,
                    environment: environment
                ),
                fileSystem: fileSystem
            )
            references.formUnion(sub.references)
            guard let (info, _) = try? CoreConfigJSONC.parseInfo(sub.text) else { return nil }
            return ConfigSchema.Document(
                path: SchemaPrimitive.AbsolutePath(rawValue: filepath),
                info: info
            )
        }

        private static func loadDirectory(
            _ dir: SchemaPrimitive.AbsolutePath,
            references: inout Set<String>,
            home: String,
            fileSystem: any OpenCodeFileSystem,
            environment: any EnvironmentProviding
        ) async -> [CoreConfigEntry] {
            var out: [CoreConfigEntry] = []
            for name in CoreConfigDiscovery.names {
                let filepath = CoreConfigDiscovery.joinPath(dir.rawValue, name)
                if let doc = await loadFile(
                    filepath,
                    references: &references,
                    home: home,
                    fileSystem: fileSystem,
                    environment: environment
                ) {
                    out.append(.document(doc))
                }
            }
            out.append(.directory(ConfigSchema.Directory(path: dir)))
            return out
        }

        private static func loadAll(
            sources: CoreConfigDiscovery.Sources,
            directory: String,
            options: Options?,
            globalPaths: Global.Interface,
            integrations: [CoreConfigIntegration.Document],
            fileSystem: any OpenCodeFileSystem,
            environment: any EnvironmentProviding
        ) async -> (entries: [CoreConfigEntry], isInput: @Sendable (String) -> Bool) {
            var references: Set<String> = []
            let home = globalPaths.home

            var directDocs: [CoreConfigEntry] = []
            for path in sources.direct {
                if let doc = await loadFile(
                    path.rawValue,
                    references: &references,
                    home: home,
                    fileSystem: fileSystem,
                    environment: environment
                ) {
                    directDocs.append(.document(doc))
                }
            }

            var explicitDocs: [CoreConfigEntry] = []
            if let exp = sources.explicit,
               let doc = await loadFile(
                   exp.rawValue,
                   references: &references,
                   home: home,
                   fileSystem: fileSystem,
                   environment: environment
               )
            {
                explicitDocs.append(.document(doc))
            }

            var contentDocs: [CoreConfigEntry] = []
            if let contentText = options?.content {
                let sub = await CoreConfigVariable.substitute(
                    CoreConfigVariable.SubstituteInput(
                        source: .virtual(source: "OPENCODE_CONFIG_CONTENT", dir: directory),
                        text: contentText,
                        home: home,
                        environment: environment
                    ),
                    fileSystem: fileSystem
                )
                references.formUnion(sub.references)
                if let (info, _) = try? CoreConfigJSONC.parseInfo(sub.text) {
                    contentDocs.append(.document(ConfigSchema.Document(path: nil, info: info)))
                }
            }

            // Managed settings & split managed policies (exact upstream precedence).
            var managedRaw: [CoreConfigEntry] = []
            if let sys = sources.system, sys.present {
                managedRaw.append(contentsOf: await loadDirectory(
                    sys.path,
                    references: &references,
                    home: home,
                    fileSystem: fileSystem,
                    environment: environment
                ))
            }
            var managedPolicies: [CoreConfigEntry] = []
            for entry in managedRaw.reversed() {
                if let info = entry.info, let pols = info.policies {
                    managedPolicies.append(.managed(CoreConfigManaged.Document(
                        path: entry.path,
                        info: ConfigSchema.Info(policies: pols)
                    )))
                }
            }
            let managedSettings: [CoreConfigEntry] = managedRaw.map { entry in
                if let info = entry.info {
                    let withoutPolicies = ConfigSchema.Info(
                        schema: info.schema,
                        shell: info.shell,
                        model: info.model,
                        defaultAgent: info.defaultAgent,
                        update: info.update,
                        share: info.share,
                        enterprise: info.enterprise,
                        username: info.username,
                        timezone: info.timezone,
                        permissions: info.permissions,
                        policies: nil,
                        agents: info.agents,
                        snapshots: info.snapshots,
                        watcher: info.watcher,
                        formatter: info.formatter,
                        lsp: info.lsp,
                        media: info.media,
                        toolOutput: info.toolOutput,
                        mcp: info.mcp,
                        compaction: info.compaction,
                        skills: info.skills,
                        commands: info.commands,
                        instructions: info.instructions,
                        references: info.references,
                        websearch: info.websearch,
                        plugins: info.plugins,
                        worktree: info.worktree,
                        warming: info.warming,
                        providers: info.providers,
                        experimental: info.experimental
                    )
                    return .managed(CoreConfigManaged.Document(path: entry.path, info: withoutPolicies))
                }
                return entry
            }

            let globalEntries: [CoreConfigEntry] = if let glob = sources.global {
                await loadDirectory(
                    glob,
                    references: &references,
                    home: home,
                    fileSystem: fileSystem,
                    environment: environment
                )
            } else {
                []
            }

            var projectEntries: [CoreConfigEntry] = []
            for root in sources.project where root.present {
                projectEntries.append(contentsOf: await loadDirectory(
                    root.path,
                    references: &references,
                    home: home,
                    fileSystem: fileSystem,
                    environment: environment
                ))
            }

            let integrationEntries = integrations.map { CoreConfigEntry.integration($0) }

            var result: [CoreConfigEntry] = []
            result.append(contentsOf: managedPolicies)
            result.append(contentsOf: integrationEntries)
            result.append(contentsOf: globalEntries)
            result.append(contentsOf: explicitDocs)
            result.append(contentsOf: directDocs)
            result.append(contentsOf: projectEntries)
            result.append(contentsOf: contentDocs)
            result.append(contentsOf: managedSettings)

            let isInput = await CoreConfigWatch.inputs(
                sources: sources,
                references: references,
                fileSystem: fileSystem
            )
            return (result, isInput)
        }
    }

    // parity: core/src/config.ts#Test [status=adapted hash=6b6109e336eb]
    public final class Test: TestInterface, Sendable {
        public static let serviceKey = "@opencode/Config/Test"

        private struct State: Sendable {
            var entries: [CoreConfigEntry]
            var compatibility: CompatibilityRoots
            var integrations: [IntegrationID: CoreConfigIntegration.Document] = [:]
            var integrationOrder: [IntegrationID] = []
            var subscribers: [UInt64: AsyncStream<WatchUpdate>.Continuation] = [:]
            var nextSubscriberID: UInt64 = 1
        }

        private let state: Mutex<State>

        public init(
            initial: [CoreConfigEntry] = [],
            compatibility: CompatibilityRoots = CompatibilityRoots()
        ) {
            self.state = Mutex(State(entries: initial, compatibility: compatibility))
        }

        public func entries() async -> [CoreConfigEntry] {
            state.withLock { s in
                let docs = s.integrationOrder.compactMap { s.integrations[$0] }.map { CoreConfigEntry.integration($0) }
                return docs + s.entries
            }
        }

        public func compatibility() async -> CompatibilityRoots {
            state.withLock { $0.compatibility }
        }

        public func changes() -> AsyncStream<WatchUpdate> {
            AsyncStream { continuation in
                let id = state.withLock { s -> UInt64 in
                    let id = s.nextSubscriberID
                    s.nextSubscriberID &+= 1
                    s.subscribers[id] = continuation
                    return id
                }
                continuation.onTermination = { [weak self] _ in
                    self?.state.withLock { s in
                        _ = s.subscribers.removeValue(forKey: id)
                    }
                }
            }
        }

        public func update(_ patch: ConfigSchema.Patch) async throws {
            _ = patch
        }

        public func integration(
            _ integrationID: IntegrationID,
            document: CoreConfigIntegration.Document?
        ) async {
            state.withLock { s in
                if s.integrations[integrationID] == document { return }
                s.integrations.removeValue(forKey: integrationID)
                s.integrationOrder.removeAll { $0 == integrationID }
                if let document {
                    s.integrations[integrationID] = document
                    s.integrationOrder.append(integrationID)
                }
            }
        }

        public func setEntries(_ entries: [CoreConfigEntry]) async {
            state.withLock { $0.entries = entries }
        }

        public func emitChange(_ update: WatchUpdate) async {
            let subs = state.withLock { Array($0.subscribers.values) }
            for sub in subs {
                sub.yield(update)
            }
        }
    }

    // parity: core/src/config.ts#testLayer [status=adapted hash=6300bb046047]
    public static func testLayer(
        initial: [CoreConfigEntry] = [],
        compatibility: CompatibilityRoots = CompatibilityRoots()
    ) -> LayerNode.ExecutableLayer {
        LayerNode.ExecutableLayer { _, _ in
            let service = Test(initial: initial, compatibility: compatibility)
            return LayerNode.Output([
                Service.serviceKey: service as any Interface,
                Test.serviceKey: service as any TestInterface,
            ])
        }
    }

    // parity: core/src/config.ts#layer [status=adapted hash=880f93656adb]
    public static func layer(_ options: Options? = nil) -> LayerNode.ExecutableLayer {
        LayerNode.ExecutableLayer { deps, scope in
            let fsUtil = deps.get(FSUtil.Service.serviceKey, as: FSUtil.Service.self)
            let globalSvc = deps.get(Global.Service.serviceKey, as: Global.Service.self)
            let locationSvc = deps.get(CoreLocation.Location.Service.serviceKey, as: CoreLocation.Location.Service.self)
            let watcher = deps.get(CoreFilesystem.Watcher.Service.serviceKey, as: (any CoreFilesystem.Watcher.Interface).self)
            let bus = deps.get(CoreBus.Service.serviceKey, as: (any CoreBus.Interface).self)
            let directory = locationSvc?.info.directory.rawValue
                ?? deps.get("@opencode/Location.directory", as: String.self)
                ?? "/"
            let locRoute = locationSvc.map {
                OpenCodeLocation(directory: $0.info.directory.rawValue, workspaceID: $0.info.workspaceID)
            } ?? OpenCodeLocation(directory: directory)
            let service = await Service(
                directory: directory,
                options: options,
                globalPaths: globalSvc?.paths,
                fileSystem: fsUtil?.fileSystem ?? LocalFileSystem.shared,
                watcher: watcher,
                bus: bus,
                location: locRoute
            )
            scope.addFinalizer {
                await service.close()
            }
            return LayerNode.Output([Service.serviceKey: service as any Interface])
        }
    }

    // parity: core/src/config.ts#configured [status=adapted hash=667800e459ad]
    public static func configured(_ options: Options? = nil) -> LayerNode.Provider {
        AppNode.makeLocationNode(
            Service.serviceKey,
            layer(options),
            [CoreFilesystem.Watcher.node, CoreBus.node, FSUtil.node, Global.node]
        )
    }

    // parity: core/src/config.ts#node [status=adapted hash=aea3814ebc3b]
    public static let node: LayerNode.Provider = configured()
}

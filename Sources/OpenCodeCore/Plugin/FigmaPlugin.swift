#if canImport(Foundation)
import Foundation
#elseif canImport(FoundationEssentials)
import FoundationEssentials
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Official first-party Figma OpenCode plugin (`packages/plugins/figma/index.ts`).
///
/// Registers Figma's MCP server (remote OAuth/DCR endpoint or local Figma Desktop endpoint),
/// discovers and loads the bundled official Figma skills and their `references/**` / `scripts/**`
/// files from `Bundle.module`, installs Figma tool/skill hooks, and provides clean helpers for
/// registering into `CoreSkill.Service`, `CoreMCP.Registry.Service`, and `CorePlugin`.
public enum FigmaPlugin {
    // MARK: - Package & Plugin Constants

    /// Canonical plugin identifier matching `packages/plugins/figma/index.ts`.
    public static let pluginID = "opencode.figma"

    /// Upstream npm package name from `packages/plugins/figma/package.json`.
    public static let packageName = "@opencode/plugin-figma"

    /// Upstream package version from `packages/plugins/figma/package.json`.
    public static let packageVersion = "2.3.0"

    /// Upstream package description from `packages/plugins/figma/package.json`.
    public static let packageDescription = "Figma MCP integration and official Figma skills for OpenCode"

    /// Default MCP server key registered in `mcp.servers`.
    public static let serverName = "figma"

    /// Official hosted Figma remote MCP server endpoint (`packages/plugins/figma/index.ts`).
    public static let remoteMCPURL = "https://mcp.figma.com/mcp"

    /// Default port exposed by the Figma Desktop app's local Dev Mode MCP server.
    public static let defaultDesktopPort = 3845

    /// Official Figma Desktop local MCP server endpoint.
    public static let desktopMCPURL = "http://127.0.0.1:\(defaultDesktopPort)/mcp"

    /// Bundled resource folder name under `Sources/OpenCodeCore/Resources/`.
    public static let bundledSkillsResourceDirectory = "FigmaSkills"

    /// Full relative resource path inside `OpenCodeCore`'s SwiftPM bundle (`resources: [.copy("Resources")]`).
    public static let bundledSkillsSubdirectory = "Resources/FigmaSkills"

    // MARK: - Errors

    public enum Error: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        case bundledSkillsDirectoryNotFound
        case unreadableSkillFile(path: String, reason: String)
        case invalidFrontmatter(path: String, reason: String)
        case invalidEndpointURL(String)
        case invalidDesktopPort(Int)

        public var description: String {
            switch self {
            case .bundledSkillsDirectoryNotFound:
                return "Bundled FigmaSkills resource directory could not be located in Bundle.module"
            case .unreadableSkillFile(let path, let reason):
                return "Failed to read bundled Figma skill file '\(path)': \(reason)"
            case .invalidFrontmatter(let path, let reason):
                return "Invalid YAML frontmatter in Figma skill '\(path)': \(reason)"
            case .invalidEndpointURL(let raw):
                return "Invalid Figma MCP endpoint URL: \(raw)"
            case .invalidDesktopPort(let port):
                return "Invalid Figma Desktop MCP port \(port); expected 1...65535"
            }
        }
    }

    // MARK: - MCP Endpoint & Auth Metadata

    /// Target Figma MCP server endpoint (hosted remote OAuth/DCR or local Figma Desktop).
    public enum Endpoint: Equatable, Hashable, Sendable, Codable {
        /// Official Figma hosted remote MCP server (`https://mcp.figma.com/mcp`) using OAuth/DCR.
        case remote
        /// Local Figma Desktop Dev Mode MCP server (`http://127.0.0.1:<port>/mcp`).
        case desktop(port: Int = FigmaPlugin.defaultDesktopPort)
        /// Explicit custom Figma MCP endpoint URL override.
        case custom(url: String)

        /// Concrete Streamable HTTP MCP URL for this endpoint.
        public var url: String {
            switch self {
            case .remote:
                return FigmaPlugin.remoteMCPURL
            case .desktop(let port):
                return "http://127.0.0.1:\(port)/mcp"
            case .custom(let url):
                return url
            }
        }

        /// Whether this endpoint expects OAuth/DCR authentication.
        public var requiresOAuth: Bool {
            switch self {
            case .remote:
                return true
            case .desktop:
                return false
            case .custom(let url):
                return !FigmaPlugin.isLoopbackURL(url)
            }
        }

        /// Whether this endpoint targets the local Figma Desktop MCP server.
        public var isDesktop: Bool {
            if case .desktop = self { return true }
            return false
        }

        /// Whether this endpoint targets the default hosted remote Figma MCP server.
        public var isRemote: Bool {
            if case .remote = self { return true }
            return false
        }
    }

    /// Authentication and OAuth/DCR helper metadata describing how OpenCode connects to Figma MCP.
    public struct AuthMetadata: Equatable, Hashable, Sendable, Codable {
        public enum Mode: String, Equatable, Hashable, Sendable, Codable {
            /// Public endpoint with OAuth 2.1 Dynamic Client Registration (DCR) and loopback callback.
            case oauthDCR = "oauth_dcr"
            /// Local loopback transport exposed by Figma Desktop (no OAuth required).
            case localDesktop = "local_desktop"
        }

        public let mode: Mode
        public let serverName: String
        public let endpointURL: String
        public let dynamicClientRegistration: Bool
        public let usesLoopbackCallback: Bool
        public let requiresClientSecret: Bool
        public let clientMetadataURL: String
        public let verificationTool: String
        public let instructions: String
        public let recommendedOAuthOption: McpSchema.OAuthOption?

        public init(
            mode: Mode,
            serverName: String,
            endpointURL: String,
            dynamicClientRegistration: Bool,
            usesLoopbackCallback: Bool,
            requiresClientSecret: Bool,
            clientMetadataURL: String,
            verificationTool: String,
            instructions: String,
            recommendedOAuthOption: McpSchema.OAuthOption?
        ) {
            self.mode = mode
            self.serverName = serverName
            self.endpointURL = endpointURL
            self.dynamicClientRegistration = dynamicClientRegistration
            self.usesLoopbackCallback = usesLoopbackCallback
            self.requiresClientSecret = requiresClientSecret
            self.clientMetadataURL = clientMetadataURL
            self.verificationTool = verificationTool
            self.instructions = instructions
            self.recommendedOAuthOption = recommendedOAuthOption
        }
    }

    /// Attribution and revision metadata decoded from bundled `skills-source.json`.
    public struct SourceManifest: Equatable, Hashable, Sendable, Codable {
        public let repository: String
        public let revision: String
        public let skills: [String]

        public init(repository: String, revision: String, skills: [String]) {
            self.repository = repository
            self.revision = revision
            self.skills = skills
        }
    }

    /// Static metadata descriptor for the official Figma plugin.
    public struct Descriptor: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let packageName: String
        public let version: String
        public let description: String
        public let serverName: String
        public let defaultEndpoint: Endpoint
        public let remoteMCPURL: String
        public let desktopMCPURL: String
        public let auth: AuthMetadata
        public let source: SourceManifest?

        public init(
            id: String,
            packageName: String,
            version: String,
            description: String,
            serverName: String,
            defaultEndpoint: Endpoint,
            remoteMCPURL: String,
            desktopMCPURL: String,
            auth: AuthMetadata,
            source: SourceManifest?
        ) {
            self.id = id
            self.packageName = packageName
            self.version = version
            self.description = description
            self.serverName = serverName
            self.defaultEndpoint = defaultEndpoint
            self.remoteMCPURL = remoteMCPURL
            self.desktopMCPURL = desktopMCPURL
            self.auth = auth
            self.source = source
        }
    }

    // MARK: - Bundled Skill Models

    /// A sibling reference or supporting file bundled alongside a Figma skill's `SKILL.md`.
    public struct ReferenceFile: Equatable, Hashable, Sendable, Codable {
        /// Forward-slash path relative to the skill directory (e.g. `"references/api.md"`).
        public let relativePath: String
        /// Absolute file path on disk inside the resolved resource bundle.
        public let absolutePath: String
        /// UTF-8 text contents of the reference file.
        public let content: String

        public init(relativePath: String, absolutePath: String, content: String) {
            self.relativePath = relativePath
            self.absolutePath = absolutePath
            self.content = content
        }

        /// Basename of this reference file.
        public var fileName: String {
            PluginContract.basenameOfPath(relativePath)
        }

        /// Whether this file is a Markdown document (`*.md`).
        public var isMarkdown: Bool {
            relativePath.lowercased().hasSuffix(".md")
        }

        /// Whether this file resides under `references/`.
        public var isReference: Bool {
            relativePath.hasPrefix("references/")
        }

        /// Whether this file resides under `scripts/`.
        public var isScript: Bool {
            relativePath.hasPrefix("scripts/")
        }
    }

    /// Parsed official Figma skill loaded from `Bundle.module` together with its sibling reference files.
    public struct BundledSkill: Equatable, Hashable, Sendable, Codable {
        /// Parsed `SkillSchema.Info` ready for `CoreSkill.Service` or `PluginEffect.SkillEditor`.
        public let info: SkillSchema.Info
        /// Absolute path to this skill's directory inside the resource bundle.
        public let directoryPath: String
        /// Sorted list of reference files discovered under `references/` (including nested subdirectories).
        public let referenceFiles: [ReferenceFile]
        /// Complete map of all sibling files relative to the skill directory (excluding `SKILL.md`),
        /// suitable for passing directly to `CoreSkill.Editor.add(_:files:)`.
        public let siblingFiles: [String: String]

        public init(
            info: SkillSchema.Info,
            directoryPath: String,
            referenceFiles: [ReferenceFile] = [],
            siblingFiles: [String: String] = [:]
        ) {
            self.info = info
            self.directoryPath = directoryPath
            self.referenceFiles = referenceFiles
            self.siblingFiles = siblingFiles
        }

        public var id: SkillSchema.ID { info.id }
        public var name: SkillSchema.Name { info.name }
        public var description: String? { info.description }
        public var autoinvoke: Bool { info.autoinvoke != false }

        /// Subset of `referenceFiles` that are Markdown documents (`references/**/*.md`).
        public var markdownReferences: [ReferenceFile] {
            referenceFiles.filter(\.isMarkdown)
        }

        /// Sorted relative paths of any guidance scripts under `scripts/`.
        public var scriptPaths: [String] {
            siblingFiles.keys.filter { $0.hasPrefix("scripts/") }.sorted()
        }
    }

    /// Combined disposable handle returned when registering Figma skills and MCP config into core services.
    public struct RegistrationHandle: Sendable {
        public let skills: CoreState.Registration
        public let mcp: CoreState.Registration?

        public init(skills: CoreState.Registration, mcp: CoreState.Registration? = nil) {
            self.skills = skills
            self.mcp = mcp
        }

        public func dispose() async {
            await skills.dispose()
            if let mcp {
                await mcp.dispose()
            }
        }
    }

    // MARK: - Tool & Skill Hook Mapping

    /// Official Figma MCP tools mapped to the bundled Figma skill IDs that govern them.
    public static let prerequisiteSkillsByTool: [String: [String]] = [
        "use_figma": ["figma-use"],
        "get_design_context": ["figma-design-to-code"],
        "generate_diagram": ["figma-generate-diagram"],
        "create_new_file": ["figma-create-new-file"],
        "create_shader": ["figma-shaders"],
        "update_shader": ["figma-shaders"],
        "create_generative_plugin": ["figma-generative-plugins"],
        "update_generative_plugin": ["figma-generative-plugins"],
        "get_motion_context": ["figma-implement-motion"],
        "get_figjam": ["figma-use-figjam"],
        "get_code_connect_suggestions": ["figma-code-connect"],
        "add_code_connect_map": ["figma-code-connect"],
        "get_code_connect_map": ["figma-code-connect"],
        "send_code_connect_mappings": ["figma-code-connect"],
    ]

    /// Tools whose official Figma skills declare a mandatory prerequisite before invocation.
    public static let mandatoryPrerequisiteTools: Set<String> = [
        "use_figma",
        "get_design_context",
        "generate_diagram",
        "create_new_file",
        "create_shader",
        "update_shader",
        "create_generative_plugin",
        "update_generative_plugin",
    ]

    /// Tools that accept Figma's comma-separated `skillNames` telemetry parameter.
    public static let skillNamesAwareTools: Set<String> = [
        "use_figma",
        "get_design_context",
    ]

    /// Normalizes a raw or MCP-namespaced tool name (e.g. `figma_use_figma`, `mcp__figma__use_figma`,
    /// `figma.use_figma`, or `use_figma`) into its canonical Figma MCP tool name when recognized.
    public static func canonicalFigmaToolName(_ rawToolName: String) -> String? {
        let trimmed = rawToolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if prerequisiteSkillsByTool[trimmed] != nil {
            return trimmed
        }
        let prefixes = [
            "mcp__\(serverName)__",
            "mcp_\(serverName)_",
            "\(serverName)_",
            "\(serverName).",
            "\(serverName)/",
            "\(serverName):",
        ]
        for prefix in prefixes where trimmed.hasPrefix(prefix) {
            let candidate = String(trimmed.dropFirst(prefix.count))
            if prerequisiteSkillsByTool[candidate] != nil {
                return candidate
            }
        }
        return nil
    }

    /// Returns the recommended bundled Figma skill IDs for a given raw or prefixed tool name.
    public static func prerequisiteSkills(forTool toolName: String) -> [String] {
        guard let canonical = canonicalFigmaToolName(toolName) else { return [] }
        return prerequisiteSkillsByTool[canonical] ?? []
    }

    // MARK: - MCP Config & Auth Builders

    /// Returns `true` when `rawURL` targets a local loopback host (`127.0.0.1`, `localhost`, or `::1`).
    public static func isLoopbackURL(_ rawURL: String) -> Bool {
        guard let host = URL(string: rawURL)?.host?.lowercased() else {
            return false
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// Builds `McpSchema.ServerConfig` for Figma's hosted remote MCP server (`https://mcp.figma.com/mcp`).
    ///
    /// Matches `packages/plugins/figma/index.ts` (`{ type: "remote", url: "https://mcp.figma.com/mcp" }`),
    /// leaving `oauth` unset by default so OpenCode uses OAuth discovery + Dynamic Client Registration (DCR).
    public static func remoteServerConfig(
        headers: [String: String]? = nil,
        oauth: McpSchema.OAuthOption? = nil,
        disabled: Bool? = nil,
        codemode: Bool? = nil,
        timeout: McpSchema.TimeoutConfig? = nil,
        wireProtocol: McpSchema.WireProtocol? = nil,
        pool: Bool? = nil
    ) -> McpSchema.ServerConfig {
        .remote(
            McpSchema.RemoteConfig(
                url: remoteMCPURL,
                headers: headers,
                oauth: oauth,
                disabled: disabled,
                codemode: codemode,
                timeout: timeout,
                wireProtocol: wireProtocol,
                pool: pool
            )
        )
    }

    /// Builds `McpSchema.ServerConfig` for the Figma Desktop app's local Dev Mode MCP server
    /// (`http://127.0.0.1:<port>/mcp`), disabling OAuth since local Desktop MCP does not use OAuth.
    public static func desktopServerConfig(
        port: Int = defaultDesktopPort,
        headers: [String: String]? = nil,
        disabled: Bool? = nil,
        codemode: Bool? = nil,
        timeout: McpSchema.TimeoutConfig? = nil,
        wireProtocol: McpSchema.WireProtocol? = nil,
        pool: Bool? = nil
    ) -> McpSchema.ServerConfig {
        .remote(
            McpSchema.RemoteConfig(
                url: Endpoint.desktop(port: port).url,
                headers: headers,
                oauth: .disabled,
                disabled: disabled,
                codemode: codemode,
                timeout: timeout,
                wireProtocol: wireProtocol,
                pool: pool
            )
        )
    }

    /// Builds `McpSchema.ServerConfig` for any Figma MCP `Endpoint` (`.remote`, `.desktop`, or `.custom`).
    public static func mcpServerConfig(
        endpoint: Endpoint = .remote,
        headers: [String: String]? = nil,
        oauth: McpSchema.OAuthOption? = nil,
        disabled: Bool? = nil,
        codemode: Bool? = nil,
        timeout: McpSchema.TimeoutConfig? = nil,
        wireProtocol: McpSchema.WireProtocol? = nil,
        pool: Bool? = nil
    ) -> McpSchema.ServerConfig {
        let effectiveOAuth: McpSchema.OAuthOption? = oauth ?? (endpoint.requiresOAuth ? nil : .disabled)
        return .remote(
            McpSchema.RemoteConfig(
                url: endpoint.url,
                headers: headers,
                oauth: effectiveOAuth,
                disabled: disabled,
                codemode: codemode,
                timeout: timeout,
                wireProtocol: wireProtocol,
                pool: pool
            )
        )
    }

    /// Validates `endpoint` (port range `1...65535` for `.desktop`, valid HTTP/HTTPS URL for `.custom`)
    /// and returns the corresponding `McpSchema.ServerConfig`.
    public static func validatedMCPServerConfig(
        endpoint: Endpoint = .remote,
        headers: [String: String]? = nil,
        oauth: McpSchema.OAuthOption? = nil,
        disabled: Bool? = nil,
        codemode: Bool? = nil,
        timeout: McpSchema.TimeoutConfig? = nil,
        wireProtocol: McpSchema.WireProtocol? = nil,
        pool: Bool? = nil
    ) throws(FigmaPlugin.Error) -> McpSchema.ServerConfig {
        switch endpoint {
        case .remote:
            break
        case .desktop(let port):
            guard (1...65_535).contains(port) else {
                throw .invalidDesktopPort(port)
            }
        case .custom(let rawURL):
            let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let parsed = URL(string: trimmed),
                  let scheme = parsed.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = parsed.host,
                  !host.isEmpty
            else {
                throw .invalidEndpointURL(rawURL)
            }
        }
        return mcpServerConfig(
            endpoint: endpoint,
            headers: headers,
            oauth: oauth,
            disabled: disabled,
            codemode: codemode,
            timeout: timeout,
            wireProtocol: wireProtocol,
            pool: pool
        )
    }

    /// Resolves a Figma `Endpoint` from plugin configuration `options` (`url`, `endpoint`, `desktop`, `port`),
    /// defaulting to `.remote` (`https://mcp.figma.com/mcp`).
    public static func endpoint(from options: PluginContract.PluginOptions) -> Endpoint {
        let parsedPort: Int? = {
            switch options["port"] {
            case .int(let value) where (1...65_535).contains(Int(value)):
                return Int(value)
            case .double(let value) where value.rounded() == value && (1...65_535).contains(Int(value)):
                return Int(value)
            case .string(let text):
                if let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                   (1...65_535).contains(value)
                {
                    return value
                }
                return nil
            default:
                return nil
            }
        }()

        if case .string(let customURL) = options["url"] {
            let trimmed = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return .custom(url: trimmed)
            }
        }

        if case .string(let rawEndpoint) = options["endpoint"] {
            let trimmed = rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            switch trimmed.lowercased() {
            case "desktop", "local":
                return .desktop(port: parsedPort ?? defaultDesktopPort)
            case "remote", "cloud", "hosted":
                return .remote
            default:
                if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
                    return .custom(url: trimmed)
                }
            }
        }

        if case .bool(true) = options["desktop"] {
            return .desktop(port: parsedPort ?? defaultDesktopPort)
        }

        return .remote
    }

    /// Returns OAuth/DCR or local Desktop auth helper metadata for the chosen Figma MCP endpoint.
    public static func authMetadata(for endpoint: Endpoint = .remote) -> AuthMetadata {
        if endpoint.requiresOAuth {
            return AuthMetadata(
                mode: .oauthDCR,
                serverName: serverName,
                endpointURL: endpoint.url,
                dynamicClientRegistration: true,
                usesLoopbackCallback: true,
                requiresClientSecret: false,
                clientMetadataURL: CoreMCP.OAuth.CLIENT_METADATA_URL,
                verificationTool: "whoami",
                instructions: "Open /mcps, select figma, and sign in. OpenCode discovers OAuth scopes via Dynamic Client Registration (DCR) and selects an available loopback callback port; confirm by invoking Figma's whoami tool.",
                recommendedOAuthOption: nil
            )
        }
        return AuthMetadata(
            mode: .localDesktop,
            serverName: serverName,
            endpointURL: endpoint.url,
            dynamicClientRegistration: false,
            usesLoopbackCallback: false,
            requiresClientSecret: false,
            clientMetadataURL: CoreMCP.OAuth.CLIENT_METADATA_URL,
            verificationTool: "whoami",
            instructions: "Enable the Dev Mode MCP server in the Figma Desktop app, then connect OpenCode to \(endpoint.url). Confirm by invoking Figma's whoami tool.",
            recommendedOAuthOption: .disabled
        )
    }

    /// Builds an interactive OAuth authorization handle via `CoreMCP.OAuth.authorize` for OAuth-backed
    /// Figma endpoints, or returns `nil` for local Desktop endpoints that do not require OAuth.
    public static func oauthAuthorization(
        name: String = serverName,
        endpoint: Endpoint = .remote,
        oauthConfig: McpSchema.OAuthConfig? = nil,
        integrationID: IntegrationID = IntegrationID(rawValue: "mcp:figma"),
        methodID: IntegrationMethodID = IntegrationMethodID(rawValue: "oauth")
    ) -> CoreIntegration.Integration.OAuthAuthorization? {
        guard endpoint.requiresOAuth else { return nil }
        let remote = McpSchema.RemoteConfig(
            url: endpoint.url,
            oauth: oauthConfig.map { .configured($0) }
        )
        return CoreMCP.OAuth.authorize(
            name: name,
            config: remote,
            integrationID: integrationID,
            methodID: methodID
        )
    }

    // MARK: - Bundled Skills Discovery & Loading (`Bundle.module`)

    /// Resolves the root `FigmaSkills` directory inside `bundle` (defaults to `Bundle.module`).
    public static func bundledSkillsRootURL(in bundle: Bundle? = nil) -> URL? {
        #if os(WASI)
        _ = bundle
        return nil
        #else
        let resolvedBundle = bundle ?? .module
        let fm = FileManager.default
        let candidates: [URL?] = [
            resolvedBundle.url(forResource: bundledSkillsResourceDirectory, withExtension: nil, subdirectory: "Resources"),
            resolvedBundle.resourceURL?
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(bundledSkillsResourceDirectory, isDirectory: true),
            resolvedBundle.url(forResource: bundledSkillsResourceDirectory, withExtension: nil),
            resolvedBundle.resourceURL?
                .appendingPathComponent(bundledSkillsResourceDirectory, isDirectory: true),
        ]
        for candidate in candidates {
            guard let url = candidate else { continue }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url.standardizedFileURL
            }
        }
        return nil
        #endif
    }

    /// Reads the bundled `NOTICE.md` attribution document from `Bundle.module`, if present.
    public static func bundledNotice(in bundle: Bundle? = nil) -> String? {
        guard let root = bundledSkillsRootURL(in: bundle) else { return nil }
        let noticeURL = root.appendingPathComponent("NOTICE.md", isDirectory: false)
        return try? String(contentsOf: noticeURL, encoding: .utf8)
    }

    /// Decodes the bundled `skills-source.json` provenance manifest from `Bundle.module`, if present.
    public static func bundledSourceManifest(in bundle: Bundle? = nil) -> SourceManifest? {
        guard let root = bundledSkillsRootURL(in: bundle) else { return nil }
        let manifestURL = root.appendingPathComponent("skills-source.json", isDirectory: false)
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(SourceManifest.self, from: data)
    }

    /// Discovers all bundled Figma skill directories containing a `SKILL.md` file inside `bundle`.
    ///
    /// Returns URLs sorted lexicographically by skill directory name.
    public static func bundledSkillDirectories(in bundle: Bundle? = nil) -> [URL] {
        guard let root = bundledSkillsRootURL(in: bundle) else {
            return []
        }
        return bundledSkillDirectories(under: root.path).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Discovers all skill subdirectories containing `SKILL.md` directly under `rootDirectory`,
    /// sorted lexicographically by skill directory name.
    public static func bundledSkillDirectories(under rootDirectory: String) -> [String] {
        #if os(WASI)
        _ = rootDirectory
        return []
        #else
        let fm = FileManager.default
        let normalizedRoot = PluginContract.normalizeAbsolutePath(rootDirectory)
        var discovered: [String: String] = [:]

        // Include every valid skill declared in skills-source.json if present.
        let manifestPath = PluginContract.joinPath(normalizedRoot, "skills-source.json")
        if let data = fm.contents(atPath: manifestPath),
           let manifest = try? JSONDecoder().decode(SourceManifest.self, from: data)
        {
            for name in manifest.skills where CoreSkill.Discovery.isSafeSegment(name) {
                let candidateDir = PluginContract.joinPath(normalizedRoot, name)
                let skillFile = PluginContract.joinPath(candidateDir, "SKILL.md")
                if fm.fileExists(atPath: skillFile) {
                    discovered[name] = candidateDir
                }
            }
        }

        // Also scan all direct child directories so any bundled skill directory with SKILL.md is found.
        if let entries = try? fm.contentsOfDirectory(atPath: normalizedRoot) {
            for name in entries where !name.hasPrefix(".") && CoreSkill.Discovery.isSafeSegment(name) {
                let candidateDir = PluginContract.joinPath(normalizedRoot, name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: candidateDir, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                let skillFile = PluginContract.joinPath(candidateDir, "SKILL.md")
                if fm.fileExists(atPath: skillFile) {
                    discovered[name] = candidateDir
                }
            }
        }

        return discovered.keys.sorted().compactMap { discovered[$0] }
        #endif
    }

    /// Parses a Figma `SKILL.md` document's YAML frontmatter (`name`, `description`,
    /// `disable-model-invocation`) and markdown body into a `BundledSkill`.
    public static func parseSkillMarkdown(
        id: String,
        skillFilePath: String,
        directoryPath: String,
        rawMarkdown: String,
        referenceFiles: [ReferenceFile] = [],
        siblingFiles: [String: String] = [:]
    ) throws(FigmaPlugin.Error) -> BundledSkill {
        let parsed: CoreConfigMarkdown.Parsed
        do {
            parsed = try CoreConfigMarkdown.parse(rawMarkdown)
        } catch {
            throw .invalidFrontmatter(path: skillFilePath, reason: String(describing: error))
        }

        let parsedName: String
        if let rawName = parsed.data["name"] {
            guard case .string(let s) = rawName else {
                throw .invalidFrontmatter(path: skillFilePath, reason: "Expected string for frontmatter field 'name'")
            }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            parsedName = trimmed.isEmpty ? id : trimmed
        } else {
            parsedName = id
        }

        let parsedDescription: String?
        if let rawDesc = parsed.data["description"] {
            guard case .string(let s) = rawDesc else {
                throw .invalidFrontmatter(path: skillFilePath, reason: "Expected string for frontmatter field 'description'")
            }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            parsedDescription = trimmed.isEmpty ? nil : trimmed
        } else {
            parsedDescription = nil
        }

        // Match packages/plugins/figma/index.ts: `autoinvoke: markdown.data["disable-model-invocation"] !== true`
        let disableModelInvocation = parsed.data["disable-model-invocation"].flatMap(parseYAMLBoolean)
        let explicitAutoinvoke: Bool? = {
            if case .object(let meta) = parsed.data["metadata"], let rawVal = meta["opencode/autoinvoke"] {
                return parseYAMLBoolean(rawVal)
            }
            return nil
        }()
        let autoinvoke = explicitAutoinvoke ?? (disableModelInvocation != true)

        let info = SkillSchema.Info(
            id: SkillSchema.ID(rawValue: id),
            name: SkillSchema.Name(rawValue: parsedName),
            description: parsedDescription,
            autoinvoke: autoinvoke,
            path: SchemaPrimitive.AbsolutePath(rawValue: skillFilePath),
            content: parsed.content
        )

        return BundledSkill(
            info: info,
            directoryPath: directoryPath,
            referenceFiles: referenceFiles.sorted { $0.relativePath < $1.relativePath },
            siblingFiles: siblingFiles
        )
    }

    /// Loads and parses all bundled official Figma skills and their sibling `references/**` / `scripts/**`
    /// files from `bundle` (defaults to `Bundle.module`).
    public static func loadBundledSkills(in bundle: Bundle? = nil) throws(FigmaPlugin.Error) -> [BundledSkill] {
        guard let root = bundledSkillsRootURL(in: bundle) else {
            throw .bundledSkillsDirectoryNotFound
        }
        return try loadBundledSkills(under: root.path)
    }

    /// Loads and parses all Figma skills located under `rootDirectory`.
    public static func loadBundledSkills(under rootDirectory: String) throws(FigmaPlugin.Error) -> [BundledSkill] {
        let directories = bundledSkillDirectories(under: rootDirectory)
        var loaded: [BundledSkill] = []
        loaded.reserveCapacity(directories.count)
        for dirPath in directories {
            loaded.append(try loadSkill(fromDirectory: dirPath))
        }
        return loaded
    }

    /// Loads a single bundled Figma skill by its directory ID (e.g. `"figma-design-to-code"`).
    public static func loadBundledSkill(
        id: String,
        in bundle: Bundle? = nil
    ) throws(FigmaPlugin.Error) -> BundledSkill? {
        guard CoreSkill.Discovery.isSafeSegment(id),
              let root = bundledSkillsRootURL(in: bundle)
        else {
            return nil
        }
        let dirPath = PluginContract.joinPath(root.path, id)
        let skillPath = PluginContract.joinPath(dirPath, "SKILL.md")
        #if os(WASI)
        _ = skillPath
        return nil
        #else
        guard FileManager.default.fileExists(atPath: skillPath) else {
            return nil
        }
        return try loadSkill(fromDirectory: dirPath)
        #endif
    }

    private static func loadSkill(fromDirectory directoryPath: String) throws(FigmaPlugin.Error) -> BundledSkill {
        #if os(WASI)
        throw .bundledSkillsDirectoryNotFound
        #else
        let normalizedDir = PluginContract.normalizeAbsolutePath(directoryPath)
        let skillID = PluginContract.basenameOfPath(normalizedDir)
        let skillFilePath = PluginContract.joinPath(normalizedDir, "SKILL.md")

        let rawMarkdown: String
        do {
            rawMarkdown = try String(contentsOfFile: skillFilePath, encoding: .utf8)
        } catch {
            throw .unreadableSkillFile(path: skillFilePath, reason: String(describing: error))
        }

        let (referenceFiles, siblingFiles) = try collectSiblingFiles(in: normalizedDir)
        return try parseSkillMarkdown(
            id: skillID,
            skillFilePath: skillFilePath,
            directoryPath: normalizedDir,
            rawMarkdown: rawMarkdown,
            referenceFiles: referenceFiles,
            siblingFiles: siblingFiles
        )
        #endif
    }

    #if !os(WASI)
    private static func collectSiblingFiles(
        in skillDirectory: String
    ) throws(FigmaPlugin.Error) -> (references: [ReferenceFile], siblings: [String: String]) {
        let fm = FileManager.default
        var references: [ReferenceFile] = []
        var siblings: [String: String] = [:]

        var queue: [(dir: String, relativePrefix: String)] = [(skillDirectory, "")]
        var index = 0
        while index < queue.count {
            let current = queue[index]
            index += 1

            let entries: [String]
            do {
                entries = try fm.contentsOfDirectory(atPath: current.dir).sorted()
            } catch {
                throw .unreadableSkillFile(path: current.dir, reason: String(describing: error))
            }

            for name in entries where !name.hasPrefix(".") {
                let fullPath = PluginContract.joinPath(current.dir, name)
                let relativePath = current.relativePrefix.isEmpty ? name : "\(current.relativePrefix)/\(name)"

                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    queue.append((fullPath, relativePath))
                    continue
                }
                if relativePath == "SKILL.md" {
                    continue
                }

                let content: String
                do {
                    content = try String(contentsOfFile: fullPath, encoding: .utf8)
                } catch {
                    throw .unreadableSkillFile(path: fullPath, reason: String(describing: error))
                }

                siblings[relativePath] = content
                if relativePath.hasPrefix("references/") {
                    references.append(
                        ReferenceFile(
                            relativePath: relativePath,
                            absolutePath: fullPath,
                            content: content
                        )
                    )
                }
            }
        }

        references.sort { $0.relativePath < $1.relativePath }
        return (references, siblings)
    }
    #endif

    private static func parseYAMLBoolean(_ value: JSONValue) -> Bool? {
        switch value {
        case .bool(let b):
            return b
        case .int(let n):
            return n == 1 ? true : (n == 0 ? false : nil)
        case .double(let d):
            return d == 1 ? true : (d == 0 ? false : nil)
        case .string(let s):
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    // MARK: - Plugin Descriptor & Effect Definition

    /// Static metadata descriptor summarizing the Figma plugin, endpoints, auth metadata, and upstream source manifest.
    public static var descriptor: Descriptor {
        Descriptor(
            id: pluginID,
            packageName: packageName,
            version: packageVersion,
            description: packageDescription,
            serverName: serverName,
            defaultEndpoint: .remote,
            remoteMCPURL: remoteMCPURL,
            desktopMCPURL: desktopMCPURL,
            auth: authMetadata(for: .remote),
            source: bundledSourceManifest()
        )
    }

    /// Official Figma `PluginEffect.Plugin` definition (`id: "opencode.figma"`).
    ///
    /// Mirrors `packages/plugins/figma/index.ts`:
    /// 1. Registers `mcp.servers.figma` (preserving any existing user configuration).
    /// 2. Loads all bundled official Figma skills from `Bundle.module` and registers them
    ///    into `ctx.skill` (preserving any existing user skills with the same ID).
    /// 3. Installs tool/skill lifecycle hooks tracking loaded Figma skills per session,
    ///    supplying `skillNames` on `use_figma` / `get_design_context` calls when omitted,
    ///    and appending prerequisite skill guidance when a mandatory Figma tool errors
    ///    before its governing skill was loaded.
    public static let definition: PluginEffect.Plugin = makePlugin()

    /// Alias matching `BrowserPlugin.Plugin` and `CorePlugin.*Plugin.Plugin` naming conventions.
    public static let Plugin: PluginEffect.Plugin = definition

    /// Constructs a configurable `PluginEffect.Plugin` instance for Figma.
    ///
    /// - Parameters:
    ///   - endpoint: Explicit endpoint override; when `nil`, derived from `ctx.options` (defaulting to `.remote`).
    ///   - headers: Optional extra HTTP headers attached to the remote/desktop MCP server config.
    ///   - oauth: Optional explicit `McpSchema.OAuthOption` override.
    ///   - bundle: Resource bundle containing `Resources/FigmaSkills` (defaults to `Bundle.module`).
    ///   - registerHooks: Whether to register Figma tool/skill hooks on `ctx.tool.hook`.
    public static func makePlugin(
        endpoint explicitEndpoint: Endpoint? = nil,
        headers: [String: String]? = nil,
        oauth: McpSchema.OAuthOption? = nil,
        bundle: Bundle? = nil,
        registerHooks: Bool = true
    ) -> PluginEffect.Plugin {
        let resolvedSkillsRoot = bundledSkillsRootURL(in: bundle)?.path
        return makePlugin(
            endpoint: explicitEndpoint,
            headers: headers,
            oauth: oauth,
            skillsRootDirectory: resolvedSkillsRoot,
            registerHooks: registerHooks
        )
    }

    /// Constructs a configurable `PluginEffect.Plugin` loading bundled skills from an explicit directory path.
    public static func makePlugin(
        endpoint explicitEndpoint: Endpoint? = nil,
        headers: [String: String]? = nil,
        oauth: McpSchema.OAuthOption? = nil,
        skillsRootDirectory: String?,
        registerHooks: Bool = true
    ) -> PluginEffect.Plugin {
        PluginEffect.define(
            PluginEffect.Plugin(id: pluginID) { ctx in
                let targetEndpoint = explicitEndpoint ?? endpoint(from: ctx.options)
                let serverConfig = try validatedMCPServerConfig(
                    endpoint: targetEndpoint,
                    headers: headers,
                    oauth: oauth
                )

                let mcpReg = await ctx.mcp.transform { editor in
                    if editor.get(serverName) != nil { return }
                    editor.set(serverName, serverConfig)
                }
                ctx.addFinalizer(mcpReg.dispose)

                guard let rootPath = skillsRootDirectory else {
                    throw Error.bundledSkillsDirectoryNotFound
                }
                let bundledSkills = try loadBundledSkills(under: rootPath)
                let bundledIDs = Set(bundledSkills.map(\.info.id.rawValue))

                let skillReg = await ctx.skill.transform { editor in
                    for bundled in bundledSkills {
                        if editor.get(bundled.info.id.rawValue) == nil {
                            editor.add(bundled.info)
                        }
                    }
                }
                ctx.addFinalizer(skillReg.dispose)

                if registerHooks {
                    let loadedSkillsBySession = Mutex<[String: Set<String>]>([:])
                    ctx.addFinalizer {
                        loadedSkillsBySession.withLock { $0.removeAll() }
                    }

                    _ = await ctx.tool.hook("execute.before") { event in
                        guard case .executeBefore(var before) = event else { return event }
                        if before.tool == "skill",
                           case .object(let args) = before.input,
                           let skillID = extractSkillIdentifier(from: args),
                           bundledIDs.contains(skillID)
                        {
                            loadedSkillsBySession.withLock { map in
                                _ = map[before.sessionID.rawValue, default: []].insert(skillID)
                            }
                            return .executeBefore(before)
                        }

                        if let canonicalTool = canonicalFigmaToolName(before.tool),
                           skillNamesAwareTools.contains(canonicalTool),
                           case .object(var args) = before.input,
                           args["skillNames"] == nil
                        {
                            let loaded = loadedSkillsBySession.withLock { $0[before.sessionID.rawValue] ?? [] }
                            if !loaded.isEmpty {
                                args["skillNames"] = .string(loaded.sorted().joined(separator: ","))
                                before.input = .object(args)
                            }
                        }
                        return .executeBefore(before)
                    }

                    _ = await ctx.tool.hook("execute.after") { event in
                        guard case .executeAfter(var after) = event else { return event }
                        guard let canonicalTool = canonicalFigmaToolName(after.tool),
                              mandatoryPrerequisiteTools.contains(canonicalTool),
                              case .error(let err) = after.outcome
                        else {
                            return event
                        }
                        let required = prerequisiteSkillsByTool[canonicalTool] ?? []
                        guard !required.isEmpty else { return event }
                        let loaded = loadedSkillsBySession.withLock { $0[after.sessionID.rawValue] ?? [] }
                        let missing = required.filter { !loaded.contains($0) }
                        guard !missing.isEmpty else { return event }

                        let hint = "Load required Figma skill(s) (\(missing.joined(separator: ", "))) via the skill tool before calling \"\(canonicalTool)\"."
                        if !err.message.contains(hint) {
                            after.outcome = .error(
                                ToolSchema.ToolError(
                                    message: "\(err.message)\n\n\(hint)",
                                    error: err.error,
                                    metadata: err.metadata
                                )
                            )
                        }
                        return .executeAfter(after)
                    }
                }
            }
        )
    }

    /// Native Swift plugin conformance (`PluginSDK.NativePlugin`) wrapping `FigmaPlugin`.
    public struct Native: PluginSDK.NativePlugin {
        public let id: String
        public let endpoint: Endpoint?
        public let headers: [String: String]?
        public let oauth: McpSchema.OAuthOption?
        public let skillsRootDirectory: String?
        public let registerHooks: Bool

        public init(
            endpoint: Endpoint? = nil,
            headers: [String: String]? = nil,
            oauth: McpSchema.OAuthOption? = nil,
            bundle: Bundle? = nil,
            registerHooks: Bool = true
        ) {
            self.id = FigmaPlugin.pluginID
            self.endpoint = endpoint
            self.headers = headers
            self.oauth = oauth
            self.skillsRootDirectory = FigmaPlugin.bundledSkillsRootURL(in: bundle)?.path
            self.registerHooks = registerHooks
        }

        public func activate(in context: PluginEffect.Context) async throws -> (@Sendable () async -> Void)? {
            let plugin = FigmaPlugin.makePlugin(
                endpoint: endpoint,
                headers: headers,
                oauth: oauth,
                skillsRootDirectory: skillsRootDirectory,
                registerHooks: registerHooks
            )
            try await plugin.effect(context)
            return nil
        }
    }

    // MARK: - CoreSkill.Service, CoreMCP & CorePlugin Registration Helpers

    /// Registers all bundled official Figma skills (including their sibling `references/**` and `scripts/**`
    /// files) into `skillService`, returning a disposable `CoreState.Registration`.
    @discardableResult
    public static func registerBundledSkills(
        into skillService: any CoreSkill.Interface,
        preserveExisting: Bool = true,
        bundle: Bundle? = nil
    ) async throws -> CoreState.Registration {
        let bundled = try loadBundledSkills(in: bundle)
        return try await skillService.transform { editor in
            for item in bundled {
                if preserveExisting && editor.get(item.info.id.rawValue) != nil {
                    continue
                }
                editor.add(item.info, files: item.siblingFiles.isEmpty ? nil : item.siblingFiles)
            }
        }
    }

    /// Registers Figma's MCP server configuration into `mcpService`, preserving any pre-existing
    /// `"figma"` server entry when `preserveExisting` is `true`.
    @discardableResult
    public static func registerMCPServer(
        into mcpService: any CoreMCP.Registry.Interface,
        endpoint: Endpoint = .remote,
        headers: [String: String]? = nil,
        oauth: McpSchema.OAuthOption? = nil,
        codemode: Bool? = nil,
        timeout: McpSchema.TimeoutConfig? = nil,
        wireProtocol: McpSchema.WireProtocol? = nil,
        pool: Bool? = nil,
        preserveExisting: Bool = true
    ) async throws -> CoreState.Registration {
        let config = try validatedMCPServerConfig(
            endpoint: endpoint,
            headers: headers,
            oauth: oauth,
            codemode: codemode,
            timeout: timeout,
            wireProtocol: wireProtocol,
            pool: pool
        )
        return try await mcpService.transform { editor in
            if preserveExisting && editor.get(serverName) != nil {
                return
            }
            editor.set(serverName, config: config)
        }
    }

    /// Registers both Figma's bundled skills (with sibling references) into `CoreSkill.Interface`
    /// and (optionally) Figma's MCP server config into `CoreMCP.Registry.Interface`.
    @discardableResult
    public static func register(
        into skillService: any CoreSkill.Interface,
        mcpService: (any CoreMCP.Registry.Interface)? = nil,
        endpoint: Endpoint = .remote,
        headers: [String: String]? = nil,
        oauth: McpSchema.OAuthOption? = nil,
        preserveExisting: Bool = true,
        bundle: Bundle? = nil
    ) async throws -> RegistrationHandle {
        let skillReg = try await registerBundledSkills(
            into: skillService,
            preserveExisting: preserveExisting,
            bundle: bundle
        )
        let mcpReg: CoreState.Registration?
        if let mcpService {
            do {
                mcpReg = try await registerMCPServer(
                    into: mcpService,
                    endpoint: endpoint,
                    headers: headers,
                    oauth: oauth,
                    preserveExisting: preserveExisting
                )
            } catch {
                await skillReg.dispose()
                throw error
            }
        } else {
            mcpReg = nil
        }
        return RegistrationHandle(skills: skillReg, mcp: mcpReg)
    }

    /// Creates a `CorePlugin.Generation` descriptor ready for `CorePlugin.Service.activate(_:failures:)`.
    public static func generation(
        endpoint: Endpoint? = nil,
        headers: [String: String]? = nil,
        oauth: McpSchema.OAuthOption? = nil,
        revision: String = packageVersion,
        source: PluginSchema.Source = .builtin,
        bundle: Bundle? = nil,
        registerHooks: Bool = true
    ) -> CorePlugin.Generation {
        let plugin = makePlugin(
            endpoint: endpoint,
            headers: headers,
            oauth: oauth,
            bundle: bundle,
            registerHooks: registerHooks
        )
        return CorePlugin.Generation(
            plugin: plugin,
            revision: revision,
            source: source,
            features: PluginSchema.Features(server: true)
        )
    }

    /// Registers the Figma plugin into a host-global `CorePlugin.SdkPlugins.Interface` registry.
    public static func register(
        into sdkPlugins: any CorePlugin.SdkPlugins.Interface,
        endpoint: Endpoint? = nil,
        headers: [String: String]? = nil,
        oauth: McpSchema.OAuthOption? = nil,
        bundle: Bundle? = nil,
        registerHooks: Bool = true
    ) {
        let plugin = makePlugin(
            endpoint: endpoint,
            headers: headers,
            oauth: oauth,
            bundle: bundle,
            registerHooks: registerHooks
        )
        sdkPlugins.register(plugin)
    }

    /// Activates the Figma plugin directly in a `CorePlugin.ServiceInterface` instance.
    public static func activate(
        in pluginService: any CorePlugin.ServiceInterface,
        endpoint: Endpoint? = nil,
        headers: [String: String]? = nil,
        oauth: McpSchema.OAuthOption? = nil,
        revision: String = packageVersion,
        source: PluginSchema.Source = .builtin,
        bundle: Bundle? = nil,
        registerHooks: Bool = true
    ) async throws {
        let gen = generation(
            endpoint: endpoint,
            headers: headers,
            oauth: oauth,
            revision: revision,
            source: source,
            bundle: bundle,
            registerHooks: registerHooks
        )
        try await pluginService.activate([gen], failures: [])
    }

    // MARK: - Private Helpers

    private static func extractSkillIdentifier(from args: [String: JSONValue]) -> String? {
        for key in ["id", "name", "skill"] {
            if case .string(let raw) = args[key] {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}

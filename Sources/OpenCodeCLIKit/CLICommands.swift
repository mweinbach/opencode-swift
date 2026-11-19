import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Synchronization
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeTUI
import OpenCodeUtil
import OpenTUICore
import OpenTUITerminal

// MARK: - CLI Command Tree & All Command Handlers (`packages/cli/src/commands/*`)

public enum CLICommands {
    // MARK: Global Flags & Command Tree (`packages/cli/src/commands/commands.ts`)

    // parity: cli/src/commands/commands.ts#PrintLogs [status=implemented hash=7ee7bb40aa62]
    public static let PrintLogs = CLIFramework.Flag.GlobalDefinition(
        id: "print-logs",
        flag: CLIFramework.Flag.boolean(
            "print-logs",
            default: false,
            description: "Print logs to stderr (server logs require --standalone)"
        )
    )

    // parity: cli/src/commands/commands.ts#Standalone [status=implemented hash=7b3603bb312f]
    public static let Standalone = CLIFramework.Flag.GlobalDefinition(
        id: "standalone",
        flag: CLIFramework.Flag.boolean(
            "standalone",
            default: false,
            description: "Run with a private server instead of the background service"
        )
    )

    // parity: cli/src/commands/commands.ts#Server [status=implemented hash=c41c98df9d25]
    public static let Server = CLIFramework.Flag.GlobalDefinition(
        id: "server",
        flag: CLIFramework.Flag.string(
            "server",
            optional: true,
            description: "Connect to a server URL instead of the background service"
        )
    )

    private static let serverFlags: [CLIFramework.Flag.GlobalDefinition] = [Standalone, Server]

    private static let permissionFlags: [CLIFramework.Flag.Definition] = [
        CLIFramework.Flag.boolean("auto", default: false, description: "Auto-approve permissions that are not explicitly denied"),
        CLIFramework.Flag.boolean("yolo", default: false, hidden: true),
        CLIFramework.Flag.boolean("dangerously-skip-permissions", default: false, hidden: true),
    ]

    /// Complete OpenCode CLI command tree (`opencode` root + all subcommands & aliases).
    // parity: cli/src/commands/commands.ts#Commands [status=implemented hash=bd73bbf54992]
    public static let Commands: CLIFramework.Spec.CommandNode = CLIFramework.Spec.make(
        "opencode",
        options: CLIFramework.Spec.Options(
            description: "OpenCode command line interface",
            flags: [
                Standalone.flag,
                Server.flag,
            ] + permissionFlags + [
                CLIFramework.Flag.boolean("continue", default: false, alias: "c", description: "Continue the last session"),
                CLIFramework.Flag.string("session", optional: true, alias: "s", description: "Session ID to continue, or to create if it does not exist"),
                CLIFramework.Flag.string("prompt", optional: true, description: "Prompt to use"),
            ],
            arguments: [
                CLIFramework.Flag.ArgumentDefinition(name: "directory", description: "Directory to start OpenCode in", optional: true),
            ],
            commands: [
                CLIFramework.Spec.make("upgrade", options: CLIFramework.Spec.Options(
                    description: "Upgrade OpenCode to the latest or a specific version",
                    aliases: ["update"],
                    flags: [
                        CLIFramework.Flag.literals("method", CLIServices.Updater.methods.map(\.rawValue), optional: true, alias: "m", description: "Installation method to use"),
                    ],
                    arguments: [
                        CLIFramework.Flag.ArgumentDefinition(name: "target", description: "Version to upgrade to (with or without a leading v)", optional: true),
                    ]
                )),
                CLIFramework.Spec.make("uninstall", options: CLIFramework.Spec.Options(
                    description: "Uninstall OpenCode, keeping session data, configuration, and state",
                    flags: [
                        CLIFramework.Flag.boolean("dry-run", default: false, description: "Show what would be removed without removing"),
                        CLIFramework.Flag.boolean("force", default: false, alias: "f", description: "Skip confirmation prompts"),
                    ]
                )),
                CLIFramework.Spec.make("acp", options: CLIFramework.Spec.Options(
                    description: "Start an Agent Client Protocol server",
                    flags: [
                        CLIFramework.Flag.boolean("login", default: false, description: "Run auth login instead of starting the server"),
                    ]
                )),
                CLIFramework.Spec.make("api", options: CLIFramework.Spec.Options(
                    description: "Make a request to the running server",
                    flags: [
                        CLIFramework.Flag.string("data", optional: true, alias: "d", description: "Request body"),
                        CLIFramework.Flag.repeatedString("header", maxCount: 100, alias: "H", description: "Request header in name:value form"),
                        CLIFramework.Flag.keyValuePair("param", description: "OpenAPI path or query parameter"),
                    ],
                    arguments: [
                        CLIFramework.Flag.ArgumentDefinition(
                            name: "request",
                            description: "OpenAPI operation ID, or an HTTP method followed by a path",
                            variadicMin: 1,
                            variadicMax: 2
                        ),
                    ],
                    globalFlags: serverFlags
                )),
                CLIFramework.Spec.make("debug", options: CLIFramework.Spec.Options(
                    description: "Debugging and troubleshooting tools",
                    commands: [
                        CLIFramework.Spec.make("agents", options: CLIFramework.Spec.Options(description: "List all agents", globalFlags: serverFlags)),
                        CLIFramework.Spec.make("config", options: CLIFramework.Spec.Options(description: "List configuration sources", globalFlags: serverFlags)),
                        CLIFramework.Spec.make("heap-dump", options: CLIFramework.Spec.Options(
                            description: "Write a heap snapshot of the running server and print its path",
                            flags: [
                                CLIFramework.Flag.string("directory", optional: true, description: "Directory to write the snapshot into instead of the server's log directory"),
                            ],
                            globalFlags: [Server]
                        )),
                        CLIFramework.Spec.make("paths", options: CLIFramework.Spec.Options(
                            description: "Show global paths (data, config, cache, state)",
                            arguments: [
                                CLIFramework.Flag.ArgumentDefinition(
                                    name: "name",
                                    description: "Print only one path: db, home, data, config, cache, state, tmp, bin, log, repos",
                                    optional: true,
                                    literals: ["db", "home", "data", "config", "cache", "state", "tmp", "bin", "log", "repos"]
                                ),
                            ]
                        )),
                    ]
                )),
                CLIFramework.Spec.make("auth", options: CLIFramework.Spec.Options(
                    description: "manage integrations and credentials",
                    globalFlags: serverFlags,
                    commands: [
                        CLIFramework.Spec.make("list", options: CLIFramework.Spec.Options(
                            description: "list integrations and credentials",
                            flags: [
                                CLIFramework.Flag.literals("format", ["default", "json"], optional: true, description: "Output format"),
                            ]
                        )),
                        CLIFramework.Spec.make("login", options: CLIFramework.Spec.Options(
                            description: "connect an integration",
                            flags: [
                                CLIFramework.Flag.string("method", optional: true, description: "Authentication method ID"),
                                CLIFramework.Flag.repeatedString("answer", maxCount: 100, description: "Provider form answer (key=value; repeat for multiple fields)"),
                            ],
                            arguments: [
                                CLIFramework.Flag.ArgumentDefinition(name: "target", description: "Integration ID, name, or well-known provider URL", optional: true),
                            ]
                        )),
                        CLIFramework.Spec.make("logout", options: CLIFramework.Spec.Options(
                            description: "log out of a saved account",
                            arguments: [
                                CLIFramework.Flag.ArgumentDefinition(name: "target", description: "Integration ID or name", optional: true),
                                CLIFramework.Flag.ArgumentDefinition(name: "credential", description: "Credential ID or label (opens an account picker when omitted)", optional: true),
                            ]
                        )),
                        CLIFramework.Spec.make("export", options: CLIFramework.Spec.Options(
                            description: "print stored credentials, including secrets, as JSON",
                            arguments: [
                                CLIFramework.Flag.ArgumentDefinition(name: "target", description: "Integration ID or name (exports every integration when omitted)", optional: true),
                            ]
                        )),
                        CLIFramework.Spec.make("import", options: CLIFramework.Spec.Options(
                            description: "import credentials exported by auth export",
                            arguments: [
                                CLIFramework.Flag.ArgumentDefinition(name: "file", description: "JSON file to import (reads stdin when omitted)", optional: true),
                            ]
                        )),
                        CLIFramework.Spec.make("switch", options: CLIFramework.Spec.Options(
                            description: "switch the active account for an integration",
                            arguments: [
                                CLIFramework.Flag.ArgumentDefinition(name: "target", description: "Integration ID or name", optional: true),
                                CLIFramework.Flag.ArgumentDefinition(name: "credential", description: "Credential ID or label (opens an account picker when omitted)", optional: true),
                            ]
                        )),
                    ]
                )),
                CLIFramework.Spec.make("mcp", options: CLIFramework.Spec.Options(
                    description: "Manage MCP (Model Context Protocol) servers",
                    commands: [
                        CLIFramework.Spec.make("list", options: CLIFramework.Spec.Options(description: "List configured MCP servers and their status", globalFlags: serverFlags)),
                        CLIFramework.Spec.make("add", options: CLIFramework.Spec.Options(
                            description: "Add an MCP server to your configuration",
                            flags: [
                                CLIFramework.Flag.string("url", optional: true, description: "URL for a remote MCP server"),
                                CLIFramework.Flag.keyValuePair("header", description: "HTTP header for a remote server, as name=value"),
                                CLIFramework.Flag.keyValuePair("env", description: "Environment variable for a local server, as name=value"),
                                CLIFramework.Flag.boolean("global", default: false, description: "Write to the global config instead of the project config"),
                            ],
                            arguments: [
                                CLIFramework.Flag.ArgumentDefinition(name: "name", description: "Name of the MCP server"),
                                CLIFramework.Flag.ArgumentDefinition(name: "command", description: "Command and arguments for a local server, passed after --", variadicMin: 0),
                            ]
                        )),
                        CLIFramework.Spec.make("auth", options: CLIFramework.Spec.Options(
                            description: "Authenticate with an OAuth-capable remote MCP server",
                            arguments: [
                                CLIFramework.Flag.ArgumentDefinition(name: "name", description: "Name of the MCP server", optional: true),
                            ],
                            globalFlags: serverFlags
                        )),
                        CLIFramework.Spec.make("logout", options: CLIFramework.Spec.Options(
                            description: "Remove stored OAuth credentials for an MCP server",
                            arguments: [
                                CLIFramework.Flag.ArgumentDefinition(name: "name", description: "Name of the MCP server"),
                            ],
                            globalFlags: serverFlags
                        )),
                    ]
                )),
                CLIFramework.Spec.make("plugin", options: CLIFramework.Spec.Options(
                    description: "Manage plugins",
                    commands: [
                        CLIFramework.Spec.make("list", options: CLIFramework.Spec.Options(
                            description: "List plugins",
                            flags: [
                                CLIFramework.Flag.boolean("builtin", default: false, description: "Include built-in server plugins"),
                            ],
                            globalFlags: serverFlags
                        )),
                        CLIFramework.Spec.make("add", options: CLIFramework.Spec.Options(
                            description: "Install a plugin and add it to the global configuration",
                            arguments: [
                                CLIFramework.Flag.ArgumentDefinition(name: "package", description: "npm registry or Git package specifier"),
                            ]
                        )),
                        CLIFramework.Spec.make("check", options: CLIFramework.Spec.Options(
                            description: "Check package plugins for updates",
                            arguments: [
                                CLIFramework.Flag.ArgumentDefinition(name: "target", description: "Configured package target", optional: true),
                            ],
                            globalFlags: serverFlags
                        )),
                        CLIFramework.Spec.make("update", options: CLIFramework.Spec.Options(
                            description: "Update package plugins",
                            arguments: [
                                CLIFramework.Flag.ArgumentDefinition(name: "target", description: "Configured package target; omit to update all outdated plugins", optional: true),
                            ],
                            globalFlags: serverFlags
                        )),
                        CLIFramework.Spec.make("remove", options: CLIFramework.Spec.Options(
                            description: "Remove a plugin from global configuration",
                            arguments: [
                                CLIFramework.Flag.ArgumentDefinition(name: "package", description: "configured package specifier"),
                            ]
                        )),
                    ]
                )),
                CLIFramework.Spec.make("models", options: CLIFramework.Spec.Options(description: "List all available models", globalFlags: serverFlags)),
                CLIFramework.Spec.make("stats", options: CLIFramework.Spec.Options(
                    description: "Show shareable usage statistics",
                    flags: [
                        CLIFramework.Flag.integer("days", optional: true, min: 0, description: "Show the last N days; 0 means today"),
                        CLIFramework.Flag.integer("year", optional: true, min: 1970, max: 9_999, description: "Show a calendar year"),
                        CLIFramework.Flag.boolean("all", default: false, description: "Show lifetime statistics"),
                        CLIFramework.Flag.string("project", optional: true, description: "Filter by project ID, or use \".\" for the current project"),
                        CLIFramework.Flag.boolean("models", default: false, description: "Show model usage"),
                        CLIFramework.Flag.boolean("tools", default: false, description: "Show tool reliability"),
                        CLIFramework.Flag.boolean("cost", default: false, description: "Show cost and token details"),
                        CLIFramework.Flag.boolean("full", default: false, description: "Show every detailed section"),
                        CLIFramework.Flag.integer("limit", optional: true, default: 5, min: 1, description: "Number of rows in detailed sections"),
                        CLIFramework.Flag.boolean("json", default: false, description: "Output statistics as JSON"),
                    ],
                    globalFlags: serverFlags
                )),
                CLIFramework.Spec.make("mini", options: CLIFramework.Spec.Options(
                    description: "Start the minimal interactive interface",
                    flags: [
                        CLIFramework.Flag.boolean("continue", default: false, alias: "c", description: "Continue the last session"),
                        CLIFramework.Flag.string("session", optional: true, alias: "s", description: "Session ID to continue, or to create if it does not exist"),
                        CLIFramework.Flag.boolean("fork", default: false, description: "Fork the session when continuing"),
                        CLIFramework.Flag.boolean("replay", default: nil, description: "Restore session history on resume and resize (disable with --no-replay)"),
                        CLIFramework.Flag.integer("replay-limit", optional: true, description: "Limit replay to the newest N messages (default: 200)"),
                        CLIFramework.Flag.string("model", optional: true, alias: "m", description: "Model to use in the format provider/model"),
                        CLIFramework.Flag.string("agent", optional: true, description: "Agent to use"),
                        CLIFramework.Flag.string("prompt", optional: true, description: "Prompt to use"),
                        CLIFramework.Flag.boolean("demo", default: false, hidden: true),
                    ],
                    globalFlags: serverFlags
                )),
                CLIFramework.Spec.make("run", options: CLIFramework.Spec.Options(
                    description: "Run OpenCode with a message",
                    flags: [
                        CLIFramework.Flag.boolean("continue", default: false, alias: "c", description: "Continue the last session"),
                        CLIFramework.Flag.string("session", optional: true, alias: "s", description: "Session ID to continue, or to create if it does not exist"),
                        CLIFramework.Flag.boolean("fork", default: false, description: "Fork the session before continuing"),
                        CLIFramework.Flag.optionalValue("worktree", metavar: "name").withAlias("w").withDescription("Start a new session in a new git worktree, optionally with this name"),
                        CLIFramework.Flag.string("model", optional: true, alias: "m", description: "Model to use in the format provider/model#variant"),
                        CLIFramework.Flag.string("agent", optional: true, description: "Agent to use"),
                        CLIFramework.Flag.literals("format", ["default", "json"], optional: true, description: "Output format"),
                        CLIFramework.Flag.repeatedString("file", maxCount: 100, alias: "f", description: "File to attach to the message"),
                        CLIFramework.Flag.string("title", optional: true, description: "Session title"),
                        CLIFramework.Flag.boolean("archived", default: false, description: "Create the session archived so it stays out of session lists (useful for scripted or CI runs)"),
                        CLIFramework.Flag.boolean("thinking", default: false, description: "Show thinking blocks"),
                    ] + permissionFlags,
                    arguments: [
                        CLIFramework.Flag.ArgumentDefinition(name: "message", description: "Message to send", variadicMin: 0),
                    ],
                    globalFlags: serverFlags
                )),
                CLIFramework.Spec.make("session", options: CLIFramework.Spec.Options(
                    description: "Manage sessions",
                    globalFlags: serverFlags,
                    commands: [
                        CLIFramework.Spec.make("list", options: CLIFramework.Spec.Options(
                            description: "List top-level sessions in the current project, newest first",
                            flags: [
                                CLIFramework.Flag.integer("max-count", optional: true, min: 1, alias: "n", description: "Limit to N most recent sessions (default: 100)"),
                                CLIFramework.Flag.literals("format", ["table", "json"], optional: true, description: "Output format"),
                            ]
                        )),
                        CLIFramework.Spec.make("delete", options: CLIFramework.Spec.Options(
                            description: "Delete a session and its child sessions",
                            arguments: [
                                CLIFramework.Flag.ArgumentDefinition(name: "sessionID", description: "Session ID to delete"),
                            ]
                        )),
                        CLIFramework.Spec.make("export", options: CLIFramework.Spec.Options(
                            description: "Export session data as JSON",
                            flags: [
                                CLIFramework.Flag.boolean("sanitize", default: false, description: "Redact sensitive transcript and file data"),
                            ],
                            arguments: [
                                CLIFramework.Flag.ArgumentDefinition(name: "session", description: "Session ID to export", optional: true),
                            ]
                        )),
                        CLIFramework.Spec.make("import", options: CLIFramework.Spec.Options(
                            description: "Import session data from a JSON file or URL",
                            flags: [
                                CLIFramework.Flag.string("directory", optional: true, description: "Directory in which to import the session"),
                            ],
                            arguments: [
                                CLIFramework.Flag.ArgumentDefinition(name: "file", description: "JSON file or URL to import"),
                            ]
                        )),
                    ]
                )),
                CLIFramework.Spec.make("service", options: CLIFramework.Spec.Options(
                    description: "Manage the background server",
                    commands: [
                        CLIFramework.Spec.make("start", options: CLIFramework.Spec.Options(description: "Start the background server")),
                        CLIFramework.Spec.make("restart", options: CLIFramework.Spec.Options(description: "Restart the background server")),
                        CLIFramework.Spec.make("status", options: CLIFramework.Spec.Options(description: "Show background server status")),
                        CLIFramework.Spec.make("stop", options: CLIFramework.Spec.Options(description: "Stop the background server")),
                        CLIFramework.Spec.make("get", options: CLIFramework.Spec.Options(
                            description: "Get service configuration",
                            arguments: [
                                CLIFramework.Flag.ArgumentDefinition(name: "key", description: "Service setting or env", optional: true),
                                CLIFramework.Flag.ArgumentDefinition(name: "name", description: "Environment variable name", optional: true),
                            ]
                        )),
                        CLIFramework.Spec.make("set", options: CLIFramework.Spec.Options(
                            description: "Set service configuration",
                            arguments: [
                                CLIFramework.Flag.ArgumentDefinition(name: "key", description: "Service setting or env"),
                                CLIFramework.Flag.ArgumentDefinition(name: "value", description: "Setting value or environment variable name"),
                                CLIFramework.Flag.ArgumentDefinition(name: "nestedValue", description: "Environment variable value", optional: true),
                            ]
                        )),
                        CLIFramework.Spec.make("unset", options: CLIFramework.Spec.Options(
                            description: "Unset service configuration",
                            arguments: [
                                CLIFramework.Flag.ArgumentDefinition(name: "key", description: "Service setting or env"),
                                CLIFramework.Flag.ArgumentDefinition(name: "name", description: "Environment variable name", optional: true),
                            ]
                        )),
                    ]
                )),
                CLIFramework.Spec.make("reload", options: CLIFramework.Spec.Options(description: "Reload configuration", globalFlags: serverFlags)),
                CLIFramework.Spec.make("pair", options: CLIFramework.Spec.Options(
                    description: "Print one-time links to connect a browser or app",
                    flags: [
                        CLIFramework.Flag.string("url", optional: true, description: "Use an external HTTP(S) server URL in pairing links"),
                        CLIFramework.Flag.boolean("remote", default: false, description: "Pair through the OpenTunnel remote address, enabling remote access if needed (exposes the server to the internet)"),
                        CLIFramework.Flag.boolean("yes", default: false, alias: "y", description: "Accept exposing the server to the internet when --remote enables remote access for the first time (required without an interactive terminal)"),
                    ]
                )),
                CLIFramework.Spec.make("serve", options: CLIFramework.Spec.Options(
                    description: "Start the v2 API and web server",
                    flags: [
                        CLIFramework.Flag.string("hostname", optional: true),
                        CLIFramework.Flag.integer("port", optional: true),
                        CLIFramework.Flag.repeatedString("cors", description: "Additional allowed CORS origin (repeat for multiple origins)"),
                        CLIFramework.Flag.boolean("service", default: false),
                        CLIFramework.Flag.boolean("stdio", default: false),
                    ]
                )),
            ]
        )
    )

    // MARK: API Command (`packages/cli/src/commands/handlers/api.ts`)

    public enum API {
        public struct OpenAPIOperation: Equatable, Hashable, Sendable, Codable {
            public let operationId: String?

            public init(operationId: String? = nil) {
                self.operationId = operationId
            }
        }

        public struct OpenAPIDocument: Equatable, Sendable, Codable {
            public let paths: [String: [String: OpenAPIOperation]]?

            public init(paths: [String: [String: OpenAPIOperation]]? = nil) {
                self.paths = paths
            }
        }

        public struct ResolvedRequest: Equatable, Hashable, Sendable {
            public let method: String
            public let path: String

            public init(method: String, path: String) {
                self.method = method
                self.path = path
            }
        }

        private static let validMethods: Set<String> = ["delete", "get", "head", "options", "patch", "post", "put"]

        // parity: cli/src/commands/handlers/api.ts#resolveOperation [status=implemented hash=c35f221a9042]
        public static func resolveOperation(
            spec: OpenAPIDocument,
            operationID: String,
            params: [String: String] = [:]
        ) throws -> ResolvedRequest {
            for (rawPath, operations) in spec.paths ?? [:] {
                for (method, op) in operations {
                    guard validMethods.contains(method.lowercased()), op.operationId == operationID else { continue }
                    return ResolvedRequest(
                        method: method.uppercased(),
                        path: try interpolatePath(rawPath, params: params)
                    )
                }
            }
            throw CLIError("Operation not found: \(operationID)")
        }

        // parity: cli/src/commands/handlers/api.ts#rawRequest [status=implemented hash=81514d2e96f8]
        public static func rawRequest(_ input: [String]) -> ResolvedRequest? {
            guard input.count == 2,
                  validMethods.contains(input[0].lowercased()),
                  input[1].hasPrefix("/")
            else {
                return nil
            }
            return ResolvedRequest(method: input[0].uppercased(), path: input[1])
        }

        private static func interpolatePath(_ rawPath: String, params: [String: String]) throws -> String {
            var used: Set<String> = []
            var pathname = ""
            var idx = rawPath.startIndex
            while idx < rawPath.endIndex {
                if rawPath[idx] == "{", let close = rawPath[idx...].firstIndex(of: "}") {
                    let name = String(rawPath[rawPath.index(after: idx)..<close])
                    guard let value = params[name] else {
                        throw CLIError("Missing path parameter: \(name)")
                    }
                    used.insert(name)
                    pathname += ClientURLBuilder.encodeURIComponent(value)
                    idx = rawPath.index(after: close)
                } else {
                    pathname.append(rawPath[idx])
                    idx = rawPath.index(after: idx)
                }
            }
            let queryItems = params
                .filter { !used.contains($0.key) }
                .sorted { $0.key < $1.key }
                .map { "\(ClientURLBuilder.encodeURIComponent($0.key))=\(ClientURLBuilder.encodeURIComponent($0.value))" }
            return queryItems.isEmpty ? pathname : "\(pathname)?\(queryItems.joined(separator: "&"))"
        }

        public static func run(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
            let server = try await CLIServices.ServerConnection.resolve(
                CLIServices.ServerConnection.Args(mismatch: .ignore),
                context: context
            )
            let endpoint = server.endpoint
            let reqArgs = input.args("request")
            let params = input.keyValueMap("param") ?? [:]
            let resolved: ResolvedRequest
            if let raw = rawRequest(reqArgs) {
                resolved = raw
            } else if reqArgs.count == 1 {
                let openAPIURL = ClientURLBuilder.join(baseUrl: endpoint.url, path: "/openapi.json")
                let resp = try await context.transport.send(
                    HTTPRequest(method: "GET", url: openAPIURL, headers: OpenCodeClient.serviceHeaders(for: endpoint) ?? [:])
                )
                guard (200..<300).contains(resp.head.statusCode) else {
                    throw CLIError("Failed to load OpenAPI document: HTTP \(resp.head.statusCode)")
                }
                let doc = try JSONDecoder().decode(OpenAPIDocument.self, from: Data(resp.body))
                resolved = try resolveOperation(spec: doc, operationID: reqArgs[0], params: params)
            } else {
                throw CLIError("Expected an operation name or an HTTP method and path")
            }

            var headers = OpenCodeClient.serviceHeaders(for: endpoint) ?? [:]
            for rawHeader in input.stringsList("header") {
                guard let colon = rawHeader.firstIndex(of: ":"), colon != rawHeader.startIndex else {
                    throw CLIError("Invalid header, expected name:value: \(rawHeader)")
                }
                let k = rawHeader[..<colon].trimmingCharacters(in: .whitespaces)
                let v = rawHeader[rawHeader.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
            let bodyStr = input.string("data")
            if bodyStr != nil && !headers.keys.contains(where: { $0.lowercased() == "content-type" }) {
                headers["content-type"] = "application/json"
            }

            let targetURL = ClientURLBuilder.join(baseUrl: endpoint.url, path: resolved.path)
            let response = try await context.transport.send(
                HTTPRequest(
                    method: resolved.method,
                    url: targetURL,
                    headers: headers,
                    body: bodyStr.map { Array($0.utf8) }
                )
            )
            let output = String(decoding: response.body, as: UTF8.self)
            if !output.isEmpty {
                context.io.writeStdout(output + (output.hasSuffix(context.io.eol) ? "" : context.io.eol))
            }
            if !(200..<300).contains(response.head.statusCode) {
                context.io.writeStderr("HTTP \(response.head.statusCode)\(context.io.eol)")
                context.exitCode.value = 1
            }
        }
    }

    // MARK: Auth Commands & Helpers (`packages/cli/src/commands/handlers/auth/*`)

    public enum Auth {
        // parity: cli/src/commands/handlers/auth/shared.ts#location [status=implemented hash=5284208eaa51]
        public static var location: LocationQuery.LocationField {
            LocationQuery.LocationField(directory: CLIContext.current.cwd)
        }

        // parity: cli/src/commands/handlers/auth/shared.ts#createClient [status=implemented hash=7a7122c6c2bf]
        public static func createClient(
            _ args: CLIServices.ServerConnection.Args = CLIServices.ServerConnection.Args(),
            context: CLIContext = CLIContext.current
        ) async throws -> OpenCodeClient {
            let server = try await CLIServices.ServerConnection.resolve(args, context: context)
            return context.makeClient(endpoint: server.endpoint)
        }

        // parity: cli/src/commands/handlers/auth/shared.ts#request [status=adapted hash=d07e123990df]
        public static func request<A: Sendable>(
            signal: AbortSignal = AbortController().signal,
            _ run: @Sendable (AbortSignal) async throws -> A
        ) async throws -> A {
            try await run(signal)
        }

        // parity: cli/src/commands/handlers/auth/shared.ts#loadIntegrations [status=implemented hash=68a6eb8936b3]
        public static func loadIntegrations(
            _ client: OpenCodeClient,
            directory: String = CLIContext.current.cwd
        ) async throws -> [IntegrationSchema.Info] {
            await CLIServices.waitForPlugins(client, directory)
            let response = try await client.integration.list(
                IntegrationListInput(location: LocationQuery.LocationField(directory: directory))
            )
            return response.data.sorted { lhs, rhs in
                let lGo = lhs.id.rawValue == "opencode-go"
                let rGo = rhs.id.rawValue == "opencode-go"
                if lGo != rGo { return lGo }
                return false
            }
        }

        // parity: cli/src/commands/handlers/auth/shared.ts#resolveIntegration [status=implemented hash=2717709aad37]
        public static func resolveIntegration(
            _ integrations: [IntegrationSchema.Info],
            target: String
        ) throws -> IntegrationSchema.Info {
            var normalized = target
            while normalized.hasSuffix("/") { normalized.removeLast() }
            if let byID = integrations.first(where: { $0.id.rawValue == normalized }) {
                return byID
            }
            let lower = normalized.lowercased()
            let matches = integrations.filter { $0.name.lowercased() == lower }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 {
                let ids = matches.map(\.id.rawValue).joined(separator: ", ")
                throw CLIError("Integration name \"\(target)\" is ambiguous: \(ids)")
            }
            throw CLIError("Integration not found: \(target)")
        }

        /// Any interactive connection method (excludes `env` methods).
        // parity: cli/src/commands/handlers/auth/shared.ts#ConnectMethod [status=implemented hash=347f6dd5e420]
        public enum ConnectMethod: Equatable, Hashable, Sendable {
            case oauth(IntegrationSchema.OAuthMethod)
            case command(IntegrationSchema.CommandMethod)
            case key(IntegrationSchema.KeyMethod)
            case external(IntegrationSchema.ExternalMethod)

            public var isKey: Bool {
                if case .key = self { return true }
                return false
            }

            public var methodID: String {
                switch self {
                case .oauth(let m): return m.id.rawValue
                case .command(let m): return m.id.rawValue
                case .key: return "key"
                case .external(let m): return m.id.rawValue
                }
            }

            public var label: String {
                switch self {
                case .oauth(let m): return m.label
                case .command(let m): return m.label
                case .key(let m): return m.label ?? "API key"
                case .external(let m): return m.label
                }
            }

            public var form: FormSchema.Fields? {
                switch self {
                case .oauth(let m): return m.form
                case .command: return nil
                case .key(let m): return m.form
                case .external(let m): return m.form
                }
            }
        }

        // parity: cli/src/commands/handlers/auth/shared.ts#connectMethods [status=implemented hash=fdf3e7e2fd21]
        public static func connectMethods(_ integration: IntegrationSchema.Info) -> [ConnectMethod] {
            var nonKey: [ConnectMethod] = []
            var keys: [ConnectMethod] = []
            for method in integration.methods {
                switch method {
                case .oauth(let m): nonKey.append(.oauth(m))
                case .command(let m): nonKey.append(.command(m))
                case .external(let m): nonKey.append(.external(m))
                case .key(let m): keys.append(.key(m))
                case .env: break
                }
            }
            return nonKey + keys
        }

        // parity: cli/src/commands/handlers/auth/shared.ts#resolveMethod [status=implemented hash=36ad003a6f90]
        public static func resolveMethod(_ methods: [ConnectMethod], target: String) throws -> ConnectMethod {
            let normalized = target.lowercased()
            let matches = methods.filter { method in
                switch method {
                case .key(let k):
                    return normalized == "key" || k.label?.lowercased() == normalized
                case .oauth(let m):
                    return m.id.rawValue == target || m.label.lowercased() == normalized
                case .command(let m):
                    return m.id.rawValue == target || m.label.lowercased() == normalized
                case .external(let m):
                    return m.id.rawValue == target || m.label.lowercased() == normalized
                }
            }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 {
                throw CLIError("Authentication method \"\(target)\" is ambiguous")
            }
            let available = methods.map(\.methodID).joined(separator: ", ")
            let suffix = available.isEmpty ? "" : ". Available: \(available)"
            throw CLIError("Authentication method not found: \(target)\(suffix)")
        }

        // parity: cli/src/commands/handlers/auth/account.ts#chooseIntegration [status=implemented hash=5775f7a7368b]
        public static func chooseIntegration(
            _ integrations: [IntegrationSchema.Info],
            target: String? = nil,
            context: CLIContext = CLIContext.current
        ) async throws -> IntegrationSchema.Info {
            if let target {
                return try resolveIntegration(integrations, target: target)
            }
            let configured = integrations.filter { integration in
                integration.connections.contains { if case .credential = $0 { return true } else { return false } }
            }
            guard !configured.isEmpty else {
                throw CLIError("No stored credentials found")
            }
            let options = configured.map { integration in
                let labels = integration.connections.compactMap { conn -> String? in
                    if case .credential(let c) = conn { return c.label }
                    return nil
                }.joined(separator: ", ")
                return CLIUI.Prompt.SelectOption(value: integration.id.rawValue, label: integration.name, hint: labels)
            }
            let id = try await CLIUI.Prompt.backend(for: context).select(
                message: "Select integration",
                options: options,
                initialValue: options.first?.value
            )
            return try resolveIntegration(configured, target: id)
        }

        // parity: cli/src/commands/handlers/auth/account.ts#chooseCredential [status=implemented hash=f8ef8da40694]
        public static func chooseCredential(
            _ integration: IntegrationSchema.Info,
            action: String,
            target: String? = nil,
            context: CLIContext = CLIContext.current
        ) async throws -> String {
            let credentials: [ConnectionSchema.CredentialInfo] = integration.connections.compactMap {
                if case .credential(let c) = $0 { return c }
                return nil
            }
            if credentials.isEmpty {
                let envNames: [String] = integration.connections.compactMap {
                    if case .env(let e) = $0 { return e.name }
                    return nil
                }
                if !envNames.isEmpty && action == "log out" {
                    throw CLIError("\(integration.name) is authenticated through \(envNames.joined(separator: ", ")); unset the environment variable to disconnect")
                }
                throw CLIError("No stored credentials for \(integration.name)")
            }
            if let target {
                if let byID = credentials.first(where: { $0.id.rawValue == target }) {
                    return byID.id.rawValue
                }
                let lower = target.lowercased()
                let matches = credentials.filter { $0.label.lowercased() == lower }
                if matches.count == 1 { return matches[0].id.rawValue }
                if matches.count > 1 {
                    let ids = matches.map(\.id.rawValue).joined(separator: ", ")
                    throw CLIError("Credential label \"\(target)\" is ambiguous. Use an ID: \(ids)")
                }
                throw CLIError("Credential not found for \(integration.name): \(target)")
            }
            let options = credentials.enumerated().map { idx, cred in
                CLIUI.Prompt.SelectOption(
                    value: cred.id.rawValue,
                    label: idx == 0 ? "\(cred.label) (active)" : cred.label,
                    hint: cred.id.rawValue
                )
            }
            return try await CLIUI.Prompt.backend(for: context).select(
                message: "Select \(integration.name) account to \(action)",
                options: options,
                initialValue: options.first?.value
            )
        }

        // parity: cli/src/commands/handlers/auth/form.ts#answerForm [status=implemented hash=523d2e8ac9e9]
        public static func answerForm(
            _ fields: FormSchema.Fields?,
            input: [String] = [],
            context: CLIContext = CLIContext.current
        ) async throws -> FormSchema.Answer? {
            var supplied: [String: String] = [:]
            for item in input {
                guard let eq = item.firstIndex(of: "="), eq != item.startIndex else {
                    throw CLIError("Expected --answer key=value")
                }
                let key = String(item[..<eq])
                guard let fields, fields.contains(where: { formFieldKey($0) == key }) else {
                    throw CLIError("Unknown form field: \(key)")
                }
                supplied[key] = String(item[item.index(after: eq)...])
            }
            guard let fields else { return nil }
            var answer: FormSchema.Answer = [:]
            for field in fields {
                let key = formFieldKey(field)
                if !isFormFieldActive(field, answer: answer) {
                    if supplied[key] != nil {
                        throw CLIError("Form field is not active: \(key)")
                    }
                    continue
                }
                let value: FormSchema.Value?
                if let provided = supplied[key] {
                    value = try decodeSuppliedAnswer(field: field, raw: provided)
                } else if isHiddenField(field) {
                    value = defaultFormValue(field)
                } else {
                    value = try await promptFormField(field, context: context)
                }
                if let err = validateFormValue(field: field, value: value) {
                    throw CLIError("\(key): \(err)")
                }
                if let value {
                    answer[key] = value
                }
            }
            return answer
        }

        // parity: cli/src/commands/handlers/auth/form.ts#secret [status=implemented hash=76d46af5afd4]
        public static func secret(
            _ message: String,
            context: CLIContext = CLIContext.current
        ) async throws -> String {
            try CLIUI.Prompt.requireInteractive("API key input requires an interactive terminal", context: context)
            return try await CLIUI.Prompt.backend(for: context).password(message: message) { value in
                value.isEmpty ? "Required" : nil
            }
        }

        private static let integrationPriority: [String: Int] = [
            "opencode-go": 0,
            "opencode": 1,
            "openai": 2,
            "github-copilot": 3,
            "anthropic": 4,
            "google": 5,
        ]

        // parity: cli/src/commands/handlers/auth/login.ts#loginChoices [status=implemented hash=f5d32260cb10]
        public static func loginChoices(_ integrations: [IntegrationSchema.Info]) -> [CLIUI.IntegrationChoice] {
            let eligible = integrations.filter { !connectMethods($0).isEmpty }
            let sorted = eligible.sorted { a, b in
                let aMcp = (a.metadata?["source"] == .string("mcp")) ? 1 : 0
                let bMcp = (b.metadata?["source"] == .string("mcp")) ? 1 : 0
                if aMcp != bMcp { return aMcp > bMcp }
                let aPrio = integrationPriority[a.id.rawValue] ?? integrationPriority.count
                let bPrio = integrationPriority[b.id.rawValue] ?? integrationPriority.count
                if aPrio != bPrio { return aPrio < bPrio }
                let nameCmp = a.name.localizedStandardCompare(b.name)
                if nameCmp != .orderedSame { return nameCmp == .orderedAscending }
                return a.id.rawValue < b.id.rawValue
            }
            return sorted.map { integration in
                let category: CLIUI.IntegrationCategory
                if integration.metadata?["source"] == .string("mcp") {
                    category = .mcp
                } else if integrationPriority[integration.id.rawValue] != nil {
                    category = .popular
                } else {
                    category = .services
                }
                return CLIUI.IntegrationChoice(
                    value: integration.id.rawValue,
                    label: integration.name,
                    category: category,
                    connected: !integration.connections.isEmpty
                )
            }
        }

        // parity: cli/src/commands/handlers/auth/login.ts#oauthLogin [status=implemented hash=4f35058f4def]
        public static func oauthLogin(
            client: OpenCodeClient,
            integration: IntegrationSchema.Info,
            method: IntegrationSchema.OAuthMethod,
            answer: FormSchema.Answer? = nil,
            label: String? = nil,
            context: CLIContext = CLIContext.current
        ) async throws {
            let loc = LocationQuery.LocationField(directory: context.cwd)
            let started = try await client.integration.oauth.connect(
                IntegrationOauthConnectInput(
                    integrationID: integration.id.rawValue,
                    location: loc,
                    methodID: method.id.rawValue,
                    answer: answer,
                    label: label
                )
            )
            let attempt = started.data
            context.io.writeStderr("\(attempt.instructions)\(context.io.eol)")
            context.io.writeStderr("\(attempt.url)\(context.io.eol)")
            if context.io.isStdinTTY() && context.io.isStdoutTTY() {
                await CLIUI.Prompt.openUrl(attempt.url)
            }

            if attempt.mode == .code {
                try CLIUI.Prompt.requireInteractive("This login requires an interactive terminal to enter the authorization code", context: context)
                let code = try await CLIUI.Prompt.backend(for: context).text(
                    message: "Paste the authorization code",
                    placeholder: nil,
                    initialValue: nil,
                    validate: { $0.isEmpty ? "Required" : nil }
                )
                try await client.integration.oauth.complete(
                    IntegrationOauthCompleteInput(
                        integrationID: integration.id.rawValue,
                        attemptID: attempt.attemptID.rawValue,
                        location: loc,
                        code: code
                    )
                )
                context.io.writeStderr("Connected to \(integration.name)\(context.io.eol)")
                return
            }

            context.io.writeStderr("Waiting for authorization...\(context.io.eol)")
            while true {
                let response = try await client.integration.oauth.status(
                    IntegrationOauthStatusInput(
                        integrationID: integration.id.rawValue,
                        attemptID: attempt.attemptID.rawValue,
                        location: loc
                    )
                )
                switch response.data {
                case .pending:
                    try await Task.sleep(for: .milliseconds(500))
                case .complete:
                    context.io.writeStderr("Connected to \(integration.name)\(context.io.eol)")
                    return
                case .failed(let message, _):
                    throw CLIError(message)
                case .expired:
                    throw CLIError("Authorization expired")
                }
            }
        }

        // MARK: Auth Subcommand Handlers

        public static func runList(_ input: CLIFramework.Runtime.Input, context: CLIContext) async {
            do {
                let client = try await createClient(context: context)
                let integrations = (try await loadIntegrations(client, directory: context.cwd))
                    .filter { !$0.connections.isEmpty }
                if input.string("format") == "json" {
                    let payload = integrations.map { integration -> JSONValue in
                        let conns = (try? JSONEncoder().encode(integration.connections))
                            .flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .array([])
                        return .object([
                            "id": .string(integration.id.rawValue),
                            "name": .string(integration.name),
                            "connections": conns,
                        ])
                    }
                    context.io.writeStdout((try CLIPath.encodePrettyJSON(JSONValue.array(payload))) + context.io.eol)
                    return
                }
                var rows: [(integration: String, source: String, type: String)] = []
                for integration in integrations {
                    for conn in integration.connections {
                        switch conn {
                        case .credential(let c):
                            rows.append((integration.name, c.label, "stored"))
                        case .env(let e):
                            rows.append((integration.name, e.name, "environment"))
                        }
                    }
                }
                if rows.isEmpty {
                    context.io.writeStdout("No authenticated integrations\(context.io.eol)")
                    return
                }
                let width = (rows.map(\.integration.count).max() ?? 0) + 2
                let lines = rows.map { row in
                    let col1 = row.integration.padding(toLength: width, withPad: " ", startingAt: 0)
                    let col2 = row.source.padding(toLength: max(28, row.source.count + 1), withPad: " ", startingAt: 0)
                    return "\(col1)\(col2)\(row.type)"
                }
                context.io.writeStdout(lines.joined(separator: context.io.eol) + context.io.eol)
            } catch {
                context.io.writeStderr(CLIUtil.errorMessage(error) + context.io.eol)
                context.exitCode.value = 1
            }
        }

        public static func runLogin(_ input: CLIFramework.Runtime.Input, context: CLIContext) async {
            _ = await CLIUI.Prompt.handlePromptErrors(context: context) {
                let target = input.arg("target")
                let methodArg = input.string("method")
                let answers = input.stringsList("answer")
                if target == nil {
                    try CLIUI.Prompt.requireInteractive("Pass an integration ID or name when running without an interactive terminal", context: context)
                }
                let client = try await createClient(context: context)
                let loc = LocationQuery.LocationField(directory: context.cwd)
                if let target, let url = URL(string: target), let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https") {
                    try await client.integration.wellknown.add(
                        ExperimentalIntegrationWellknownAddInput(location: loc, url: target)
                    )
                }
                let integrations = try await loadIntegrations(client, directory: context.cwd)
                let integration: IntegrationSchema.Info
                if let target {
                    integration = try resolveIntegration(integrations, target: target)
                } else {
                    let choices = loginChoices(integrations)
                    if choices.isEmpty { throw CLIError("No authentication integrations are available") }
                    let id = try await CLIUI.selectIntegration(choices, context: context)
                    integration = try resolveIntegration(integrations, target: id)
                }
                let methods = connectMethods(integration)
                guard !methods.isEmpty else {
                    throw CLIError("\(integration.name) has no interactive login methods")
                }
                let method: ConnectMethod
                if let methodArg {
                    method = try resolveMethod(methods, target: methodArg)
                } else if methods.count == 1 {
                    method = methods[0]
                } else {
                    try CLIUI.Prompt.requireInteractive("Pass --method when running without an interactive terminal", context: context)
                    let opts = methods.map { CLIUI.Prompt.SelectOption(value: $0.methodID, label: $0.label) }
                    let chosen = try await CLIUI.Prompt.backend(for: context).select(
                        message: "Select login method",
                        options: opts,
                        initialValue: opts.first?.value
                    )
                    method = try resolveMethod(methods, target: chosen)
                }
                let answer = try await answerForm(method.form, input: answers, context: context)
                switch method {
                case .key(let k):
                    let keyVal = try await secret(k.label ?? "Enter your \(integration.name) API key", context: context)
                    try await client.integration.connect.key(
                        IntegrationConnectKeyInput(integrationID: integration.id.rawValue, location: loc, key: keyVal, answer: answer)
                    )
                case .external(let ext):
                    try await client.integration.connect.external(
                        IntegrationConnectExternalInput(integrationID: integration.id.rawValue, location: loc, methodID: ext.id.rawValue, answer: answer)
                    )
                case .oauth(let oauth):
                    try await oauthLogin(client: client, integration: integration, method: oauth, answer: answer, context: context)
                case .command(let cmd):
                    let started = try await client.integration.command.connect(
                        IntegrationCommandConnectInput(integrationID: integration.id.rawValue, location: loc, methodID: cmd.id.rawValue)
                    )
                    while true {
                        let st = try await client.integration.command.status(
                            IntegrationCommandStatusInput(integrationID: integration.id.rawValue, attemptID: started.data.attemptID.rawValue, location: loc)
                        )
                        switch st.data {
                        case .pending:
                            try await Task.sleep(for: .milliseconds(500))
                        case .complete:
                            return
                        case .failed(let message, _):
                            throw CLIError(message)
                        case .expired:
                            throw CLIError("Authentication expired")
                        }
                    }
                }
            }
        }

        public static func runLogout(_ input: CLIFramework.Runtime.Input, context: CLIContext) async {
            _ = await CLIUI.Prompt.handlePromptErrors(context: context) {
                let target = input.arg("target")
                let cred = input.arg("credential")
                if target == nil {
                    try CLIUI.Prompt.requireInteractive("Pass an integration ID or name when running without an interactive terminal", context: context)
                }
                if cred == nil {
                    try CLIUI.Prompt.requireInteractive("Pass a credential ID or label when running without an interactive terminal", context: context)
                }
                let client = try await createClient(context: context)
                let integrations = try await loadIntegrations(client, directory: context.cwd)
                let integration = try await chooseIntegration(integrations, target: target, context: context)
                let credID = try await chooseCredential(integration, action: "log out", target: cred, context: context)
                try await client.credential.remove(CredentialRemoveInput(credentialID: credID))
                context.io.writeStderr("Removed account from \(integration.name)\(context.io.eol)")
            }
        }

        public static func runSwitch(_ input: CLIFramework.Runtime.Input, context: CLIContext) async {
            _ = await CLIUI.Prompt.handlePromptErrors(context: context) {
                let target = input.arg("target")
                let cred = input.arg("credential")
                if target == nil {
                    try CLIUI.Prompt.requireInteractive("Pass an integration ID or name when running without an interactive terminal", context: context)
                }
                if cred == nil {
                    try CLIUI.Prompt.requireInteractive("Pass a credential ID or label when running without an interactive terminal", context: context)
                }
                let client = try await createClient(context: context)
                let integrations = try await loadIntegrations(client, directory: context.cwd)
                let integration = try await chooseIntegration(integrations, target: target, context: context)
                let credID = try await chooseCredential(integration, action: "switch to", target: cred, context: context)
                try await client.credential.activate(CredentialActivateInput(credentialID: credID))
                context.io.writeStderr("Switched account for \(integration.name)\(context.io.eol)")
            }
        }

        public static func runExport(_ input: CLIFramework.Runtime.Input, context: CLIContext) async {
            do {
                let client = try await createClient(context: context)
                let target = input.arg("target")
                let integrationID: String?
                if let target {
                    let list = try await loadIntegrations(client, directory: context.cwd)
                    integrationID = try resolveIntegration(list, target: target).id.rawValue
                } else {
                    integrationID = nil
                }
                let all = try await client.credential.list()
                let filtered = all.filter { entry in
                    integrationID == nil || entry.integrationID.rawValue == integrationID
                }
                if context.io.isStdoutTTY() {
                    context.io.writeStderr("Warning: the output contains secrets; redirect it to a file or pipe it to auth import\(context.io.eol)")
                }
                context.io.writeStdout((try CLIPath.encodePrettyJSON(filtered)) + context.io.eol)
            } catch {
                context.io.writeStderr(CLIUtil.errorMessage(error) + context.io.eol)
                context.exitCode.value = 1
            }
        }

        public static func runImport(_ input: CLIFramework.Runtime.Input, context: CLIContext) async {
            do {
                let file = input.arg("file")
                if file == nil && context.io.isStdinTTY() {
                    throw CLIError("Pipe auth export output into stdin or pass a file to import")
                }
                let text: String
                if let file {
                    let bytes = try await context.fileSystem.readFile(at: CLIPath.resolve(context.cwd, file))
                    text = String(decoding: bytes, as: UTF8.self)
                } else {
                    text = try await CLIUtil.readStdin(context: context)
                }
                let decoded = try JSONDecoder().decode([CredentialLegacySchema.Entry].self, from: Data(text.utf8))
                let client = try await createClient(context: context)
                let existing = try await client.credential.list()
                let ids = Set(existing.map(\.id.rawValue))
                let existingIntegrations = Set(existing.map(\.integrationID.rawValue))
                var imported = 0
                for legacy in decoded {
                    let entry = legacy.entry
                    if ids.contains(entry.id.rawValue) { continue }
                    do {
                        _ = try await client.credential.create(
                            CredentialCreateInput(
                                id: entry.id.rawValue,
                                integrationID: entry.integrationID.rawValue,
                                label: entry.label,
                                value: entry.value,
                                activate: entry.active && !existingIntegrations.contains(entry.integrationID.rawValue)
                            )
                        )
                        imported += 1
                    } catch {
                        if !isConflictError(error) { throw error }
                    }
                }
                let skipped = decoded.count - imported
                let noun = imported == 1 ? "credential" : "credentials"
                let skipSuffix = skipped > 0 ? ", skipped \(skipped) already present" : ""
                context.io.writeStderr("Imported \(imported) \(noun)\(skipSuffix)\(context.io.eol)")
            } catch {
                context.io.writeStderr(CLIUtil.errorMessage(error) + context.io.eol)
                context.exitCode.value = 1
            }
        }

        // MARK: Auth Form Helpers

        private static func formFieldKey(_ field: FormSchema.Field) -> String {
            switch field {
            case .string(let f): return f.key
            case .number(let f): return f.key
            case .integer(let f): return f.key
            case .boolean(let f): return f.key
            case .multiselect(let f): return f.key
            case .external(let f): return f.key
            }
        }

        private static func isHiddenField(_ field: FormSchema.Field) -> Bool {
            switch field {
            case .string(let f): return f.hidden == true
            case .number(let f): return f.hidden == true
            case .integer(let f): return f.hidden == true
            case .boolean(let f): return f.hidden == true
            case .multiselect(let f): return f.hidden == true
            case .external: return false
            }
        }

        private static func defaultFormValue(_ field: FormSchema.Field) -> FormSchema.Value? {
            switch field {
            case .string(let f): return f.defaultValue.map(FormSchema.Value.string)
            case .number(let f): return f.defaultValue.map(FormSchema.Value.number)
            case .integer(let f): return f.defaultValue.map { .number(Double($0)) }
            case .boolean(let f): return f.defaultValue.map(FormSchema.Value.bool)
            case .multiselect(let f): return f.defaultValue.map(FormSchema.Value.strings)
            case .external: return nil
            }
        }

        private static func isFormFieldActive(_ field: FormSchema.Field, answer: FormSchema.Answer) -> Bool {
            let conditions: [FormSchema.When]?
            switch field {
            case .string(let f): conditions = f.when
            case .number(let f): conditions = f.when
            case .integer(let f): conditions = f.when
            case .boolean(let f): conditions = f.when
            case .multiselect(let f): conditions = f.when
            case .external: return true
            }
            guard let conditions else { return true }
            return conditions.allSatisfy { cond in
                guard let current = answer[cond.key] else { return false }
                let matches: Bool
                switch (current, cond.value) {
                case (.string(let a), .string(let b)): matches = a == b
                case (.number(let a), .number(let b)): matches = a == b
                case (.bool(let a), .bool(let b)): matches = a == b
                case (.strings(let arr), .string(let b)): matches = arr.contains(b)
                case (.strings(let arr), .number(let b)): matches = arr.contains(String(b))
                case (.strings(let arr), .bool(let b)): matches = arr.contains(String(b))
                default: matches = false
                }
                return cond.op == .eq ? matches : !matches
            }
        }

        private static func decodeSuppliedAnswer(field: FormSchema.Field, raw: String) throws -> FormSchema.Value {
            switch field {
            case .external(let f):
                throw CLIError("External form field requires interactive confirmation: \(f.key)")
            case .string:
                return .string(raw)
            default:
                guard let data = raw.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(FormSchema.Value.self, from: data)
                else {
                    throw CLIError("Expected a JSON value for form field: \(formFieldKey(field))")
                }
                return decoded
            }
        }

        private static func validateFormValue(field: FormSchema.Field, value: FormSchema.Value?) -> String? {
            switch field {
            case .external:
                return nil
            case .string(let f):
                guard let value else { return f.required == true ? "Required" : nil }
                guard case .string(let s) = value else { return "Expected a string" }
                if s.isEmpty && f.required == true { return "Required" }
                if let minLen = f.minLength, s.count < minLen.rawValue { return "Must be at least \(minLen.rawValue) characters" }
                if let maxLen = f.maxLength, s.count > maxLen.rawValue { return "Must be at most \(maxLen.rawValue) characters" }
                if let pattern = f.pattern {
                    guard let rx = try? NSRegularExpression(pattern: pattern),
                          rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
                    else { return "Invalid format" }
                }
                if let fmt = f.format {
                    switch fmt {
                    case .uri:
                        if URL(string: s)?.scheme == nil { return "Expected a URL" }
                    case .email:
                        let parts = s.split(separator: "@")
                        if parts.count != 2 || !parts[1].contains(".") || s.contains(" ") { return "Expected an email address" }
                    case .date:
                        if s.count != 10 || s.split(separator: "-").count != 3 { return "Expected a date" }
                    case .dateTime:
                        if ISO8601DateFormatter().date(from: s) == nil { return "Expected a date and time" }
                    }
                }
                return nil
            case .number(let f):
                guard let value else { return f.required == true ? "Required" : nil }
                guard case .number(let n) = value, n.isFinite else { return "Expected a number" }
                if let minV = f.minimum, n < minV { return "Must be at least \(minV)" }
                if let maxV = f.maximum, n > maxV { return "Must be at most \(maxV)" }
                return nil
            case .integer(let f):
                guard let value else { return f.required == true ? "Required" : nil }
                guard case .number(let n) = value, n.isFinite, n.rounded(.towardZero) == n else { return "Expected an integer" }
                if let minV = f.minimum, n < minV { return "Must be at least \(minV)" }
                if let maxV = f.maximum, n > maxV { return "Must be at most \(maxV)" }
                return nil
            case .boolean(let f):
                guard let value else { return f.required == true ? "Required" : nil }
                guard case .bool = value else { return "Expected a boolean" }
                return nil
            case .multiselect(let f):
                guard let value else { return f.required == true ? "Required" : nil }
                guard case .strings(let arr) = value else { return "Expected an array of strings" }
                if let minI = f.minItems, arr.count < minI.rawValue { return "Select at least \(minI.rawValue)" }
                if let maxI = f.maxItems, arr.count > maxI.rawValue { return "Select at most \(maxI.rawValue)" }
                return nil
            }
        }

        private static func promptFormField(_ field: FormSchema.Field, context: CLIContext) async throws -> FormSchema.Value? {
            try CLIUI.Prompt.requireInteractive("Authentication form input requires an interactive terminal", context: context)
            let backend = CLIUI.Prompt.backend(for: context)
            switch field {
            case .external(let ext):
                let msg = ext.title ?? ext.key
                context.io.writeStderr("\(ext.url)\(context.io.eol)")
                await CLIUI.Prompt.openUrl(ext.url)
                let ok = try await backend.confirm(message: msg.isEmpty ? "Continue after completing this step?" : msg, initialValue: true)
                if !ok { throw CLIError("\(msg.isEmpty ? "External step" : msg) is required") }
                return .bool(true)
            case .boolean(let f):
                let msg = f.title ?? f.key
                let ok = try await backend.confirm(message: msg, initialValue: f.defaultValue ?? true)
                return .bool(ok)
            case .multiselect(let f):
                let opts = f.options.map { CLIUI.Prompt.SelectOption(value: $0.value, label: $0.label, hint: $0.description) }
                let selected = try await backend.multiselect(
                    message: f.title ?? f.key,
                    options: opts,
                    initialValues: f.defaultValue,
                    required: f.required == true || (f.minItems?.rawValue ?? 0) > 0
                )
                return .strings(selected)
            case .string(let f):
                if let opts = f.options {
                    let selectOpts = opts.map { CLIUI.Prompt.SelectOption(value: $0.value, label: $0.label, hint: $0.description) }
                    let chosen = try await backend.select(message: f.title ?? f.key, options: selectOpts, initialValue: f.defaultValue)
                    return .string(chosen)
                }
                let text = try await backend.text(message: f.title ?? f.key, placeholder: f.placeholder, initialValue: f.defaultValue, validate: nil)
                return text.isEmpty && f.required != true ? nil : .string(text)
            case .number(let f):
                let text = try await backend.text(message: f.title ?? f.key, placeholder: nil, initialValue: f.defaultValue.map { String($0) }, validate: nil)
                if text.isEmpty && f.required != true { return nil }
                guard let n = Double(text) else { throw CLIError("Expected a number") }
                return .number(n)
            case .integer(let f):
                let text = try await backend.text(message: f.title ?? f.key, placeholder: nil, initialValue: f.defaultValue.map { String($0) }, validate: nil)
                if text.isEmpty && f.required != true { return nil }
                guard let n = Int(text) else { throw CLIError("Expected an integer") }
                return .number(Double(n))
            }
        }
    }

    // MARK: Debug Commands (`packages/cli/src/commands/handlers/debug/*`)

    public enum Debug {
        private static let secretNameRegex = try! NSRegularExpression(
            pattern: #"(?:api.?key|secret|password|token$|authorization$|cookie$|credential|private.?key)"#,
            options: [.caseInsensitive]
        )

        private static func isSecretKey(_ name: String) -> Bool {
            secretNameRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }

        /// Redacts secret keys, header values, and credential-bearing URLs from debug config JSON.
        // parity: cli/src/commands/handlers/debug/redact.ts#redactConfig [status=implemented hash=75c84955f6c2]
        public static func redactConfig(_ value: JSONValue, headers: Bool = false) -> JSONValue {
            switch value {
            case .array(let items):
                return .array(items.map { redactConfig($0, headers: headers) })
            case .object(let dict):
                var out: [String: JSONValue] = [:]
                out.reserveCapacity(dict.count)
                for (key, item) in dict {
                    if case .string(let s) = item {
                        if headers || isSecretKey(key) {
                            out[key] = .string("***")
                            continue
                        }
                        if s.lowercased().hasPrefix("http://") || s.lowercased().hasPrefix("https://") {
                            guard let comps = URLComponents(string: s), comps.host != nil else {
                                out[key] = .string("***")
                                continue
                            }
                            let hasSecretQuery = (comps.queryItems ?? []).contains { isSecretKey($0.name) }
                            if comps.user != nil || comps.password != nil || hasSecretQuery {
                                out[key] = .string("***")
                                continue
                            }
                        }
                    }
                    out[key] = redactConfig(item, headers: headers || key.lowercased() == "headers")
                }
                return .object(out)
            default:
                return value
            }
        }

        public static func runPaths(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
            let global = context.globalPaths
            let db = CLIUtil.databasePath(global.data, channel: context.channel, environment: context.environment)
            let ordered: [(String, String)] = [
                ("home", global.home),
                ("data", global.data),
                ("cache", global.cache),
                ("config", global.config),
                ("state", global.state),
                ("tmp", global.tmp),
                ("bin", global.bin),
                ("log", global.log),
                ("repos", global.repos),
                ("db", db),
            ]
            if let name = input.arg("name"), let match = ordered.first(where: { $0.0 == name }) {
                context.io.writeStdout(match.1 + context.io.eol)
                return
            }
            let lines = ordered.map { key, val in
                "\(key.padding(toLength: 10, withPad: " ", startingAt: 0)) \(val)\(context.io.eol)"
            }
            context.io.writeStdout(lines.joined())
        }

        public static func runAgents(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
            _ = input
            let server = try await CLIServices.ServerConnection.resolve(context: context)
            let client = context.makeClient(endpoint: server.endpoint)
            await CLIServices.waitForPlugins(client, context.cwd)
            let response = try await client.agent.list(
                AgentListInput(location: LocationQuery.LocationField(directory: context.cwd))
            )
            let sorted = response.data.sorted { $0.id.rawValue < $1.id.rawValue }
            context.io.writeStdout((try CLIPath.encodePrettyJSON(sorted)) + context.io.eol)
        }

        public static func runConfig(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
            _ = input
            let server = try await CLIServices.ServerConnection.resolve(context: context)
            let client = context.makeClient(endpoint: server.endpoint)
            let entries = try await client.config.get(
                ConfigGetInput(location: LocationQuery.LocationField(directory: context.cwd))
            )
            let data = try JSONEncoder().encode(entries)
            let rawJSON = try JSONDecoder().decode(JSONValue.self, from: data)
            let redacted = redactConfig(rawJSON)
            context.io.writeStdout((try CLIPath.encodePrettyJSON(redacted)) + context.io.eol)
        }

        public static func runHeapDump(_ input: CLIFramework.Runtime.Input, context: CLIContext) async {
            do {
                let endpoint: ServiceEndpoint
                if let explicit = context.globalFlags.server {
                    endpoint = try await CLIServices.ServerConnection.resolve(
                        CLIServices.ServerConnection.Args(server: explicit),
                        context: context
                    ).endpoint
                } else {
                    let opts = try await CLIServices.ServiceConfig.options(CLIServices.ServiceConfig.OptionsInput(), context)
                    guard let found = await EffectClient.Service.discover(
                        options: ServiceDiscoverOptions(file: opts.file, version: nil),
                        fileSystem: context.fileSystem,
                        transport: context.transport,
                        environment: context.environment
                    ) else {
                        throw CLIError("No background server is running. Pass --server <url> to capture a server started another way.")
                    }
                    endpoint = found
                }
                let client = context.makeClient(endpoint: endpoint)
                let directory = input.string("directory").map { dir in
                    CLIPath.isAbsolute(dir) ? dir : CLIPath.resolve(context.cwd, dir)
                }
                let snapshot: DebugHeapDumpOutput
                do {
                    snapshot = try await client.debug.heapDump(DebugHeapDumpInput(directory: directory))
                } catch let err as ClientError where err.reason == .unexpectedStatus && err.statusCode == 404 {
                    throw CLIError("The server at \(endpoint.url) does not support heap dumps. Update and restart it first.")
                }
                if let directory {
                    let expected = CLIPath.join(directory, CLIPath.basename(snapshot.path))
                    if expected != snapshot.path {
                        context.io.writeStderr("The server ignored --directory. Update and restart it to choose where snapshots go.\(context.io.eol)")
                    }
                }
                context.io.writeStdout(snapshot.path + context.io.eol)
            } catch {
                context.io.writeStderr(CLIUtil.errorMessage(error) + context.io.eol)
                context.exitCode.value = 1
            }
        }
    }

    // MARK: MCP Commands (`packages/cli/src/commands/handlers/mcp/*`)

    public enum MCP {
        // parity: cli/src/commands/handlers/mcp/add.ts#resolveConfigPath [status=implemented hash=e8942cf9055f]
        public static func resolveConfigPath(
            _ directory: String,
            fileSystem: any OpenCodeFileSystem = CLIContext.current.fileSystem
        ) async -> String {
            let candidates = [
                CLIPath.join(directory, "opencode.json"),
                CLIPath.join(directory, "opencode.jsonc"),
                CLIPath.join(directory, ".opencode", "opencode.json"),
                CLIPath.join(directory, ".opencode", "opencode.jsonc"),
            ]
            for candidate in candidates {
                if let info = try? await fileSystem.stat(at: candidate), info.type == .file {
                    return candidate
                }
            }
            return candidates[0]
        }

        // parity: cli/src/commands/handlers/mcp/auth.ts#mcpAuthChoices [status=implemented hash=d63b2be47d01]
        public static func mcpAuthChoices(
            servers: [McpSchema.Server],
            integrations: [IntegrationSchema.Info]
        ) -> [CLIUI.IntegrationChoice] {
            var byID: [String: IntegrationSchema.Info] = [:]
            for item in integrations { byID[item.id.rawValue] = item }

            var out: [CLIUI.IntegrationChoice] = []
            for server in servers {
                guard let iid = server.integrationID?.rawValue,
                      let integration = byID[iid],
                      integration.methods.contains(where: { if case .oauth = $0 { return true } else { return false } })
                else { continue }
                let hint: String?
                switch server.status {
                case .needsAuth: hint = "needs authentication"
                case .failed: hint = "failed"
                case .disabled: hint = "disabled"
                default: hint = nil
                }
                out.append(
                    CLIUI.IntegrationChoice(
                        value: integration.id.rawValue,
                        label: server.name,
                        category: .mcp,
                        connected: !integration.connections.isEmpty,
                        hint: hint
                    )
                )
            }
            return out.sorted { a, b in
                if a.label != b.label { return a.label < b.label }
                return a.value < b.value
            }
        }

        // parity: cli/src/commands/handlers/mcp/resolve.ts#resolveIntegration [status=implemented hash=3f8b9bf8d938]
        public static let resolveIntegration: @Sendable (OpenCodeClient, String, String) async throws -> IntegrationSchema.Info? = {
            client, name, directory in
            let loc = LocationQuery.LocationField(directory: directory)
            let servers = try await client.mcp.list(McpListInput(location: loc))
            guard let server = servers.data.first(where: { $0.name == name }) else {
                throw CLIError("MCP server not found: \(name)")
            }
            guard let integrationID = server.integrationID?.rawValue else {
                return nil
            }
            let result = try await client.integration.get(
                IntegrationGetInput(integrationID: integrationID, location: loc)
            )
            return result.data
        }

        public static func runList(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
            _ = input
            let server = try await CLIServices.ServerConnection.resolve(context: context)
            let client = context.makeClient(endpoint: server.endpoint)
            let response = try await client.mcp.list(
                McpListInput(location: LocationQuery.LocationField(directory: context.cwd))
            )
            let servers = response.data.sorted { $0.name < $1.name }
            if servers.isEmpty {
                context.io.writeStdout("No MCP servers configured\(context.io.eol)")
                return
            }
            let width = servers.map(\.name.count).max() ?? 0
            let lines = servers.map { item -> String in
                let icon: String
                let desc: String
                switch item.status {
                case .connected:
                    icon = "✓"; desc = "connected"
                case .needsAuth:
                    icon = "⚠"; desc = "needs authentication"
                case .failed(let err):
                    icon = "✗"; desc = "failed: \(err)"
                case .disabled:
                    icon = "○"; desc = "disabled"
                case .pending:
                    icon = "○"; desc = "pending"
                }
                let padded = item.name.padding(toLength: width, withPad: " ", startingAt: 0)
                return "\(icon) \(padded)  \(desc)"
            }
            context.io.writeStdout(lines.joined(separator: context.io.eol) + context.io.eol)
        }

        public static func runAdd(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
            guard let name = input.arg("name") else {
                throw CLIError("Missing required argument: name")
            }
            let url = input.string("url")
            let headers = input.keyValueMap("header")
            let environment = input.keyValueMap("env")
            let command = !input.passthrough.isEmpty ? input.passthrough : input.args("command")
            let hasCommand = !command.isEmpty

            if url != nil && hasCommand {
                throw CLIError("Provide either --url <url> or a command after --, not both")
            }
            if url == nil && !hasCommand {
                throw CLIError("Provide either --url <url> or a command after --")
            }
            if let url, URL(string: url)?.scheme == nil {
                throw CLIError("Invalid URL: \(url)")
            }
            if url != nil && environment != nil {
                throw CLIError("--env is only valid for local MCP servers")
            }
            if hasCommand && headers != nil {
                throw CLIError("--header is only valid for remote MCP servers")
            }

            var serverObj: [String: JSONValue]
            if let url {
                serverObj = ["type": .string("remote"), "url": .string(url)]
                if let headers {
                    serverObj["headers"] = .object(headers.mapValues(JSONValue.string))
                }
            } else {
                serverObj = ["type": .string("local"), "command": .array(command.map(JSONValue.string))]
                if let environment {
                    serverObj["environment"] = .object(environment.mapValues(JSONValue.string))
                }
            }

            let baseDir = input.bool("global") ? context.globalPaths.config : context.cwd
            let configPath = await resolveConfigPath(baseDir, fileSystem: context.fileSystem)
            var rootObj: [String: JSONValue] = [:]
            if let bytes = try? await context.fileSystem.readFile(at: configPath),
               let parsed = try? CoreConfigJSONC.parse(String(decoding: bytes, as: UTF8.self)),
               case .object(let existing) = parsed
            {
                rootObj = existing
            }
            var mcpObj: [String: JSONValue] = {
                if case .object(let m) = rootObj["mcp"] { return m }
                return [:]
            }()
            var serversObj: [String: JSONValue] = {
                if case .object(let s) = mcpObj["servers"] { return s }
                return [:]
            }()
            serversObj[name] = .object(serverObj)
            mcpObj["servers"] = .object(serversObj)
            rootObj["mcp"] = .object(mcpObj)

            let encoded = try CLIPath.encodePrettyJSON(JSONValue.object(rootObj)) + "\n"
            try await context.fileSystem.writeFile(Array(encoded.utf8), to: configPath, createDirectories: true)
            context.io.writeStdout("MCP server \"\(name)\" added to \(configPath)\(context.io.eol)")
        }

        public static func runAuth(_ input: CLIFramework.Runtime.Input, context: CLIContext) async {
            _ = await CLIUI.Prompt.handlePromptErrors(context: context) {
                let name = input.arg("name")
                if name == nil {
                    try CLIUI.Prompt.requireInteractive("Pass an MCP server name when running without an interactive terminal", context: context)
                }
                let server = try await CLIServices.ServerConnection.resolve(context: context)
                let client = context.makeClient(endpoint: server.endpoint)
                let integrations = try await Auth.loadIntegrations(client, directory: context.cwd)
                let servers = try await client.mcp.list(
                    McpListInput(location: LocationQuery.LocationField(directory: context.cwd))
                )
                let choices = mcpAuthChoices(servers: servers.data, integrations: integrations)
                if name == nil && choices.isEmpty {
                    context.io.writeStderr("No OAuth-capable MCP servers configured\(context.io.eol)")
                    return
                }
                let targetServer = name.flatMap { n in servers.data.first(where: { $0.name == n }) }
                if let name, targetServer == nil {
                    throw CLIError("MCP server not found: \(name)")
                }
                let integrationID: String?
                if let targetServer {
                    integrationID = targetServer.integrationID?.rawValue
                } else {
                    integrationID = try await CLIUI.selectIntegration(choices, kind: "MCP server", context: context)
                }
                guard let integrationID,
                      let integration = integrations.first(where: { $0.id.rawValue == integrationID }),
                      let oauthMethod = integration.methods.compactMap({ m -> IntegrationSchema.OAuthMethod? in
                          if case .oauth(let o) = m { return o }
                          return nil
                      }).first
                else {
                    throw CLIError("MCP server \"\(name ?? "")\" is not an OAuth-capable remote server")
                }
                let previous: [ConnectionSchema.CredentialInfo] = integration.connections.compactMap {
                    if case .credential(let c) = $0 { return c }
                    return nil
                }
                let answer = try await Auth.answerForm(oauthMethod.form, context: context)
                try await Auth.oauthLogin(
                    client: client,
                    integration: integration,
                    method: oauthMethod,
                    answer: answer,
                    label: previous.first?.label,
                    context: context
                )
                for conn in previous {
                    try await client.credential.remove(CredentialRemoveInput(credentialID: conn.id.rawValue))
                }
            }
        }

        public static func runLogout(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
            guard let name = input.arg("name") else {
                throw CLIError("Missing required argument: name")
            }
            let server = try await CLIServices.ServerConnection.resolve(context: context)
            let client = context.makeClient(endpoint: server.endpoint)
            guard let integration = try await resolveIntegration(client, name, context.cwd) else {
                context.io.writeStdout("No stored credentials for \(name)\(context.io.eol)")
                return
            }
            let creds: [ConnectionSchema.CredentialInfo] = integration.connections.compactMap {
                if case .credential(let c) = $0 { return c }
                return nil
            }
            if creds.isEmpty {
                context.io.writeStdout("No stored credentials for \(name)\(context.io.eol)")
                return
            }
            for cred in creds {
                try await client.credential.remove(CredentialRemoveInput(credentialID: cred.id.rawValue))
            }
            context.io.writeStdout("Removed OAuth credentials for \(name)\(context.io.eol)")
        }
    }

    // MARK: Pairing Command (`packages/cli/src/commands/handlers/pair.ts`)

    public enum Pair {
        // parity: cli/src/commands/handlers/pair.ts#remoteWarning [status=implemented hash=af518c548db4]
        public static let remoteWarning: String = [
            "This will expose your OpenCode server to the internet.",
            "Traffic is end-to-end encrypted, and access requires your server password.",
            "To pair locally instead, run `opencode pair` without the --remote flag.",
        ].joined(separator: Platform.current == .windows ? "\r\n" : "\n")

        // parity: cli/src/commands/handlers/pair.ts#RemoteConsentPrompt [status=implemented hash=b4f1eb9913f0]
        public protocol RemoteConsentPrompt: Sendable {
            func interactive() -> Bool
            func confirm() async throws -> Bool?
        }

        public struct TerminalConsentPrompt: RemoteConsentPrompt, Sendable {
            private let context: CLIContext

            public init(context: CLIContext = CLIContext.current) {
                self.context = context
            }

            public func interactive() -> Bool {
                context.io.isStdinTTY() && context.io.isStdoutTTY()
            }

            public func confirm() async throws -> Bool? {
                do {
                    return try await CLIUI.Prompt.backend(for: context).confirm(
                        message: "Expose your server to the internet?",
                        initialValue: true
                    )
                } catch is CLIUI.Prompt.CancelledError {
                    return nil
                }
            }
        }

        // parity: cli/src/commands/handlers/pair.ts#remoteConsent [status=implemented hash=776c08992fc5]
        public static func remoteConsent(
            config: CLIServices.ServiceConfig.Info,
            yes: Bool,
            terminal: (any RemoteConsentPrompt)? = nil,
            context: CLIContext = CLIContext.current
        ) async throws -> Bool {
            if config.remote != nil || config.remoteAccepted == true {
                return true
            }
            let prompt = terminal ?? TerminalConsentPrompt(context: context)
            if !yes && !prompt.interactive() {
                context.io.writeStderr(
                    [remoteWarning, "Run interactively or pass --yes to continue."].joined(separator: context.io.eol) + context.io.eol
                )
                context.exitCode.value = 1
                return false
            }
            context.io.writeStderr(remoteWarning + context.io.eol)
            if !yes {
                guard let accepted = try await prompt.confirm() else {
                    context.io.writeStderr("Remote access was not enabled. To pair locally, run `opencode pair`.\(context.io.eol)")
                    context.exitCode.value = 130
                    return false
                }
                if !accepted {
                    context.io.writeStderr("Remote access was not enabled. To pair locally, run `opencode pair`.\(context.io.eol)")
                    return false
                }
            }
            try await CLIServices.ServiceConfig.acceptRemote(context: context)
            return true
        }

        public static func run(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
            let config = try await CLIServices.ServiceConfig.read(context: context)
            if config.disabled == true {
                throw CLIError("Pairing requires the background service; run `opencode service unset disabled` first")
            }
            let remoteFlag = input.bool("remote")
            let urlFlag = input.string("url")
            if remoteFlag && urlFlag != nil {
                throw CLIError("--remote cannot be combined with --url")
            }
            let validatedURL: String? = try urlFlag.map { raw in
                guard let comps = URLComponents(string: raw),
                      let scheme = comps.scheme?.lowercased(),
                      (scheme == "http" || scheme == "https"),
                      comps.host != nil,
                      comps.user == nil,
                      comps.password == nil,
                      comps.query == nil,
                      comps.fragment == nil
                else {
                    throw CLIError("Expected an HTTP(S) server URL without credentials, query parameters, or a fragment")
                }
                var trimmed = raw
                while trimmed.hasSuffix("/") { trimmed.removeLast() }
                return trimmed
            }

            if remoteFlag && config.remote == nil {
                let allowed = try await remoteConsent(config: config, yes: input.bool("yes"), context: context)
                if !allowed { return }
                try await CLIServices.ServiceConfig.set(key: "remote", value: "true", context: context)
            }

            let opts = try await CLIServices.ServiceConfig.options(CLIServices.ServiceConfig.OptionsInput(), context)
            let endpoint = try await EffectClient.Service.ensure(
                options: opts,
                fileSystem: context.fileSystem,
                transport: context.transport,
                launcher: context.launcher,
                signaler: context.signaler,
                environment: context.environment
            )
            let client = context.makeClient(endpoint: endpoint)
            let urls: [String]
            if remoteFlag {
                let route = (try await CLIServices.ServiceConfig.read(context: context)).remote?.route
                let expectedHost = route != nil ? await CLIServices.RemoteTunnel.hostname(route!, context) : nil
                let info = try await client.server.info()
                guard let tunnel = info.urls.first(where: { candidate in
                    guard let expectedHost, let h = URLComponents(string: candidate)?.host else { return false }
                    return h == expectedHost
                }) else {
                    throw CLIError("Remote tunnel is not ready")
                }
                urls = [tunnel]
            } else if let validatedURL {
                urls = [validatedURL]
            } else {
                urls = try await client.server.info().urls
            }

            let pairing = try await client.server.pair()
            let links = urls.map { base -> String in
                let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
                return "\(trimmed)/auth/connect/\(pairing.code)"
            }
            let remoteURLs = urls.filter { candidate in
                guard let host = URLComponents(string: candidate)?.host else { return false }
                return !isLoopback(host)
            }

            let minutes = Int((Double(pairing.expiresIn) / 60.0).rounded())
            var lines: [String] = [
                "",
                "  Open a link to connect. Links work once and expire in \(minutes) minutes.",
                "",
            ]
            if links.isEmpty {
                lines.append("  (no server URLs)")
            } else {
                lines.append(contentsOf: links.map { "  \($0)" })
            }
            if !remoteURLs.isEmpty {
                lines.append("")
                let qrPayload = try CLIPath.encodeCompactJSON(
                    JSONValue.object([
                        "code": .string(pairing.code),
                        "urls": .array(remoteURLs.map(JSONValue.string)),
                    ])
                )
                if let qrText = try? QR.renderUnicodeCompact(qrPayload, border: 2) {
                    let indented = qrText.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { "  \($0)" }
                        .joined(separator: context.io.eol)
                    lines.append(indented)
                }
            }
            lines.append("")
            context.io.writeStdout(lines.joined(separator: context.io.eol) + context.io.eol)

            if !remoteFlag && validatedURL == nil,
               let comps = URLComponents(string: endpoint.url),
               let host = comps.host,
               ["localhost", "127.0.0.1", "::1"].contains(host),
               let port = comps.port
            {
                let sshNote = [
                    "  Over SSH? Forward the port, then open the link on your machine:",
                    "  ssh -L \(port):\(host):\(port) <host>",
                    "  If port \(port) is busy locally, forward another port and use it in the link.",
                    "",
                    "  To connect from other devices, run `opencode service set hostname 0.0.0.0`.",
                    "",
                ].joined(separator: context.io.eol) + context.io.eol
                context.io.writeStderr(sshNote)
            }
        }

        private static func isLoopback(_ host: String) -> Bool {
            host == "localhost" || host.hasSuffix(".localhost") || host.hasPrefix("127.") || host == "::1" || host == "[::1]"
        }
    }

    // MARK: Plugin Commands (`packages/cli/src/commands/handlers/plugin/*`)

    public enum Plugin {
        public enum TargetKind: String, Equatable, Hashable, Sendable {
            case server
            case tui
        }

        // parity: cli/src/commands/handlers/plugin/add.ts#configurationTarget [status=implemented hash=949eb04d9d21]
        public static func configurationTarget(_ entrypoints: PluginContract.Host.Entrypoints) -> TargetKind? {
            if entrypoints.server != nil || entrypoints.gui != nil { return .server }
            if entrypoints.tui != nil { return .tui }
            return nil
        }

        // parity: cli/src/commands/handlers/plugin/add.ts#writePluginConfig [status=implemented hash=424bba333eb5]
        public static func writePluginConfig(
            configPath: String,
            spec: String,
            fileSystem: any OpenCodeFileSystem = CLIContext.current.fileSystem
        ) async throws -> Bool {
            let text: String
            if let bytes = try? await fileSystem.readFile(at: configPath) {
                text = String(decoding: bytes, as: UTF8.self)
            } else {
                text = "{}"
            }
            guard let parsed = try? CoreConfigJSONC.parse(text),
                  case .object(var root) = parsed
            else {
                throw CLIError("Invalid global configuration: \(configPath)")
            }
            var plugins: [JSONValue] = []
            if let existing = root["plugins"] {
                guard case .array(let arr) = existing else {
                    throw CLIError("Invalid plugins configuration: \(configPath)")
                }
                plugins = arr
            }
            if isPluginConfigured(plugins, spec: spec) {
                return false
            }
            plugins.append(.string(spec))
            root["plugins"] = .array(plugins)
            let updated = try CLIPath.encodePrettyJSON(JSONValue.object(root)) + "\n"
            try await fileSystem.makeDirectory(at: CLIPath.dirname(configPath), recursive: true)
            let temp = configPath + ".tmp"
            try await fileSystem.writeFile(Array(updated.utf8), to: temp, createDirectories: true)
            try? await fileSystem.chmod(at: temp, mode: 0o600)
            try await fileSystem.rename(from: temp, to: configPath)
            return true
        }

        // parity: cli/src/commands/handlers/plugin/remove.ts#removePluginConfig [status=implemented hash=d21536cea452]
        public static func removePluginConfig(
            configPath: String,
            spec: String,
            fileSystem: any OpenCodeFileSystem = CLIContext.current.fileSystem
        ) async throws -> Bool {
            guard let bytes = try? await fileSystem.readFile(at: configPath) else {
                return false
            }
            let text = String(decoding: bytes, as: UTF8.self)
            guard let parsed = try? CoreConfigJSONC.parse(text),
                  case .object(var root) = parsed
            else {
                throw CLIError("Invalid global configuration: \(configPath)")
            }
            var plugins: [JSONValue] = []
            if let existing = root["plugins"] {
                guard case .array(let arr) = existing else {
                    throw CLIError("Invalid plugins configuration: \(configPath)")
                }
                plugins = arr
            }
            if !isPluginConfigured(plugins, spec: spec) {
                return false
            }
            let remaining = plugins.filter { !matchesPluginEntry($0, spec: spec) }
            root["plugins"] = .array(remaining)
            let updated = try CLIPath.encodePrettyJSON(JSONValue.object(root)) + "\n"
            let temp = configPath + ".tmp"
            try await fileSystem.writeFile(Array(updated.utf8), to: temp, createDirectories: true)
            try? await fileSystem.chmod(at: temp, mode: 0o600)
            try await fileSystem.rename(from: temp, to: configPath)
            return true
        }

        private static func isPluginConfigured(_ plugins: [JSONValue], spec: String) -> Bool {
            plugins.contains { matchesPluginEntry($0, spec: spec) }
        }

        private static func matchesPluginEntry(_ entry: JSONValue, spec: String) -> Bool {
            if case .string(let s) = entry { return s == spec }
            if case .object(let obj) = entry, case .string(let pkg) = obj["package"] { return pkg == spec }
            return false
        }

        public enum Inventory {
            public enum RuntimeKind: String, CaseIterable, Equatable, Hashable, Sendable {
                case server = "Server"
                case tui = "TUI"
            }

            // parity: cli/src/commands/handlers/plugin/inventory.ts#Item [status=implemented hash=3c6db83b9ef6]
            public struct Item: Equatable, Hashable, Sendable {
                public let runtime: RuntimeKind
                public let target: String
                public let name: String
                public let version: String?
                public let outdated: Bool
                public let error: String?

                public init(
                    runtime: RuntimeKind,
                    target: String,
                    name: String,
                    version: String? = nil,
                    outdated: Bool = false,
                    error: String? = nil
                ) {
                    self.runtime = runtime
                    self.target = target
                    self.name = name
                    self.version = version
                    self.outdated = outdated
                    self.error = error
                }
            }

            public struct InspectResult: Sendable {
                public let client: OpenCodeClient
                public let location: LocationQuery.LocationField
                public let items: [Item]

                public init(client: OpenCodeClient, location: LocationQuery.LocationField, items: [Item]) {
                    self.client = client
                    self.location = location
                    self.items = items
                }
            }

            // parity: cli/src/commands/handlers/plugin/inventory.ts#displayVersion [status=implemented hash=02e463a96332]
            public static func displayVersion(_ version: String) -> String {
                if (version.count == 40 || version.count == 64), version.allSatisfy(\.isHexDigit) {
                    return String(version.prefix(7))
                }
                return version
            }

            // parity: cli/src/commands/handlers/plugin/inventory.ts#format [status=implemented hash=3aebbdfa47a1]
            public static func format(_ items: [Item], eol: String = "\n") -> String {
                var sections: [String] = []
                for runtime in [RuntimeKind.server, RuntimeKind.tui] {
                    let rows = items.filter { $0.runtime == runtime }
                    if rows.isEmpty { continue }
                    sections.append(runtime.rawValue)
                    for item in rows {
                        let verPart = item.version.map { " \($0)" } ?? ""
                        let status = item.error != nil ? "check failed" : (item.outdated ? "update available" : "current")
                        sections.append("  \(item.name)\(verPart) (\(status))")
                    }
                }
                return sections.joined(separator: eol)
            }

            // parity: cli/src/commands/handlers/plugin/inventory.ts#inspect [status=implemented hash=ced7caebe2aa]
            public static func inspect(
                selected: String? = nil,
                context: CLIContext = CLIContext.current
            ) async throws -> InspectResult {
                let server = try await CLIServices.ServerConnection.resolve(context: context)
                let client = context.makeClient(endpoint: server.endpoint)
                let loc = LocationQuery.LocationField(directory: context.cwd)
                let listed = try await client.plugin.list(PluginListInput(location: loc))
                let serverTargets = Set(listed.data.compactMap { plugin -> String? in
                    if case .package(let target, _, _, _) = plugin.source { return target }
                    return nil
                })
                let checked: [PluginSchema.Info]
                if selected == nil || serverTargets.contains(selected!) {
                    checked = try await client.plugin.check(PluginCheckInput(location: loc, target: selected)).data
                } else {
                    checked = listed.data
                }
                var items: [Item] = []
                for plugin in checked {
                    guard case .package(let target, let version, let outdated, _) = plugin.source else { continue }
                    if let selected, target != selected { continue }
                    let errStr: String?
                    if case .failed(let err, _) = plugin.state { errStr = err } else { errStr = nil }
                    items.append(
                        Item(
                            runtime: .server,
                            target: target,
                            name: plugin.id?.rawValue ?? target,
                            version: version.map(displayVersion),
                            outdated: outdated == true,
                            error: errStr
                        )
                    )
                }

                let config = try await context.configService.get()
                var seenTargets: Set<String> = []
                var tuiTargets: [String] = []
                for entry in config.plugins ?? [] {
                    let target: String
                    switch entry {
                    case .specifier(let s): target = s
                    case .configured(let pkg, _): target = pkg
                    }
                    if target.hasPrefix("-") || target == "*" || target.hasSuffix(".*") || target.hasPrefix("opencode.") {
                        continue
                    }
                    if seenTargets.insert(target).inserted,
                       NpmSpec.isInstallablePackage(target),
                       (selected == nil || selected == target)
                    {
                        tuiTargets.append(target)
                    }
                }
                let npm = context.npmService
                for target in tuiTargets {
                    let installed = await npm.resolve(target)
                    do {
                        let outdated = try await npm.check(target)
                        items.append(
                            Item(
                                runtime: .tui,
                                target: target,
                                name: target,
                                version: installed.version.map(displayVersion),
                                outdated: outdated,
                                error: nil
                            )
                        )
                    } catch {
                        items.append(
                            Item(
                                runtime: .tui,
                                target: target,
                                name: target,
                                version: installed.version.map(displayVersion),
                                outdated: false,
                                error: CLIUtil.errorMessage(error)
                            )
                        )
                    }
                }

                if let selected, items.isEmpty {
                    throw CLIError("Plugin is not configured: \(selected)")
                }
                return InspectResult(client: client, location: loc, items: items)
            }
        }

        public struct TUIPluginSummary: Equatable, Hashable, Sendable {
            public let target: String
            public let version: String?

            public init(target: String, version: String? = nil) {
                self.target = target
                self.version = version
            }
        }

        // parity: cli/src/commands/handlers/plugin/list.ts#format [status=implemented hash=77a0ee9316e4]
        public static func format(
            plugins: [PluginSchema.Info],
            tui: [TUIPluginSummary],
            builtin: Bool = false,
            eol: String = "\n"
        ) -> String {
            var rows: [(id: String, version: String, target: String)] = []
            for plugin in plugins {
                if !builtin, case .builtin = plugin.source { continue }
                let id = plugin.id?.rawValue ?? "-"
                let version: String
                let target: String
                switch plugin.source {
                case .package(let t, let v, _, _):
                    version = v ?? "-"
                    target = t
                case .local(let p):
                    version = "local"
                    target = p
                case .builtin:
                    version = "-"
                    target = "builtin"
                case .sdk:
                    version = "-"
                    target = "sdk"
                }
                rows.append((id: id, version: version, target: target))
            }
            var seenTui: Set<String> = []
            for item in tui {
                let alreadyInServer = plugins.contains { plugin in
                    switch plugin.source {
                    case .package(let t, _, _, _): return t == item.target
                    case .local(let p): return p == item.target
                    default: return false
                    }
                }
                if alreadyInServer || !seenTui.insert(item.target).inserted { continue }
                rows.append((id: "-", version: item.version ?? "-", target: item.target))
            }
            let sorted = rows
                .sorted { a, b in
                    if a.id != b.id { return a.id < b.id }
                    return a.target < b.target
                }
                .map { item -> [String] in
                    let displayVer = Inventory.displayVersion(item.version)
                    return [item.id, displayVer, item.target]
                }
            if sorted.isEmpty { return "" }
            let table = [["ID", "VERSION", "SOURCE"]] + sorted
            let w0 = table.map { $0[0].count }.max() ?? 0
            let w1 = table.map { $0[1].count }.max() ?? 0
            return table.map { row in
                "\(row[0].padding(toLength: w0, withPad: " ", startingAt: 0))  \(row[1].padding(toLength: w1, withPad: " ", startingAt: 0))  \(row[2])"
            }.joined(separator: eol)
        }

        public static func runList(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
            let server = try await CLIServices.ServerConnection.resolve(context: context)
            let client = context.makeClient(endpoint: server.endpoint)
            let response = try await client.plugin.list(
                PluginListInput(location: LocationQuery.LocationField(directory: context.cwd))
            )
            let info = try await context.configService.get()
            let npm = context.npmService
            var tuiList: [TUIPluginSummary] = []
            for entry in info.plugins ?? [] {
                let target: String
                switch entry {
                case .specifier(let s): target = s
                case .configured(let pkg, _): target = pkg
                }
                if target.hasPrefix("-") || target == "*" || target.hasSuffix(".*") || target.hasPrefix("opencode.") { continue }
                if NpmSpec.isInstallablePackage(target) {
                    let resolved = await npm.resolve(target)
                    let ep = await PluginContract.Host.resolve(PluginContract.Host.Target(directory: resolved.directory, name: resolved.name), fileSystem: context.fileSystem)
                    if ep.tui != nil {
                        tuiList.append(TUIPluginSummary(target: target, version: resolved.version))
                    }
                }
            }
            let output = format(plugins: response.data, tui: tuiList, builtin: input.bool("builtin"), eol: context.io.eol)
            if output.isEmpty {
                context.io.writeStdout("No plugins found\(context.io.eol)")
            } else {
                context.io.writeStdout(output + context.io.eol)
            }
        }

        public static func runAdd(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
            guard let pkg = input.arg("package") else { throw CLIError("Missing required argument: package") }
            guard NpmSpec.isInstallablePackage(pkg) else {
                throw CLIError("Plugin target must be an npm registry package or Git package specifier")
            }
            let installed = try await context.npmService.add(pkg)
            let entrypoints = await PluginContract.Host.resolve(
                PluginContract.Host.Target(directory: installed.directory, name: installed.name),
                fileSystem: context.fileSystem
            )
            guard let target = configurationTarget(entrypoints) else {
                throw CLIError("Plugin package has no server, GUI, or TUI entrypoint: \(pkg)")
            }
            if target == .server {
                let configPath = await MCP.resolveConfigPath(context.globalPaths.config, fileSystem: context.fileSystem)
                let changed = try await writePluginConfig(configPath: configPath, spec: pkg, fileSystem: context.fileSystem)
                context.io.writeStdout(
                    changed
                        ? "Plugin \"\(pkg)\" installed and added to \(configPath)\(context.io.eol)"
                        : "Plugin \"\(pkg)\" is already configured in \(configPath)\(context.io.eol)"
                )
                return
            }
            _ = try await context.configService.update { draft in
                let existing = draft.plugins ?? []
                let already = existing.contains { entry in
                    switch entry {
                    case .specifier(let s): return s == pkg
                    case .configured(let p, _): return p == pkg
                    }
                }
                if !already {
                    draft.plugins = existing + [.specifier(pkg)]
                }
            }
            context.io.writeStdout("TUI plugin \"\(pkg)\" installed and added to \(context.configService.path)\(context.io.eol)")
        }

        public static func runCheck(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
            let result = try await Inventory.inspect(selected: input.arg("target"), context: context)
            let formatted = Inventory.format(result.items, eol: context.io.eol)
            context.io.writeStdout((formatted.isEmpty ? "No package plugins found" : formatted) + context.io.eol)
            if result.items.contains(where: { $0.error != nil }) {
                context.exitCode.value = 1
            }
        }

        public static func runUpdate(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
            let result = try await Inventory.inspect(selected: input.arg("target"), context: context)
            for item in result.items where item.error != nil {
                context.io.writeStderr("Failed to check \(item.runtime.rawValue) plugin \"\(item.name)\": \(item.error!)\(context.io.eol)")
            }
            let selected = result.items.filter(\.outdated)
            if selected.isEmpty {
                context.io.writeStdout("No plugin updates available\(context.io.eol)")
                if result.items.contains(where: { $0.error != nil }) {
                    context.exitCode.value = 1
                }
                return
            }
            for item in selected {
                do {
                    if item.runtime == .server {
                        try await result.client.plugin.update(PluginUpdateInput(location: result.location, targets: [item.target]))
                    } else {
                        _ = try await context.npmService.update(item.target)
                    }
                    context.io.writeStdout("Updated \(item.runtime.rawValue) plugin \"\(item.name)\"\(context.io.eol)")
                } catch {
                    context.io.writeStderr("Failed to update \(item.runtime.rawValue) plugin \"\(item.name)\": \(CLIUtil.errorMessage(error))\(context.io.eol)")
                    context.exitCode.value = 1
                }
            }
        }

        public static func runRemove(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
            guard let pkg = input.arg("package") else { throw CLIError("Missing required argument: package") }
            let configPath = await MCP.resolveConfigPath(context.globalPaths.config, fileSystem: context.fileSystem)
            let removedServer = try await removePluginConfig(configPath: configPath, spec: pkg, fileSystem: context.fileSystem)
            let info = try await context.configService.get()
            let hasTui = (info.plugins ?? []).contains { entry in
                switch entry {
                case .specifier(let s): return s == pkg
                case .configured(let p, _): return p == pkg
                }
            }
            if hasTui {
                _ = try await context.configService.update { draft in
                    draft.plugins = draft.plugins?.filter { entry in
                        switch entry {
                        case .specifier(let s): return s != pkg
                        case .configured(let p, _): return p != pkg
                        }
                    }
                }
            }
            var removed: [String] = []
            if removedServer { removed.append(configPath) }
            if hasTui { removed.append(context.configService.path) }
            if removed.isEmpty {
                context.io.writeStdout("Plugin \"\(pkg)\" is not configured\(context.io.eol)")
            } else {
                context.io.writeStdout("Plugin \"\(pkg)\" removed from \(removed.joined(separator: ", "))\(context.io.eol)")
            }
        }
    }

    // MARK: Stats Command & Formatter (`packages/cli/src/commands/handlers/stats.ts`)

    public enum Stats {
        public struct RenderOptions: Equatable, Hashable, Sendable {
            public let label: String
            public let scope: String
            public let models: Bool
            public let tools: Bool
            public let cost: Bool
            public let limit: Int
            public let color: Bool
            public let width: Int
            public let eol: String

            public init(
                label: String,
                scope: String,
                models: Bool = false,
                tools: Bool = false,
                cost: Bool = false,
                limit: Int = 5,
                color: Bool = false,
                width: Int = 80,
                eol: String = "\n"
            ) {
                self.label = label
                self.scope = scope
                self.models = models
                self.tools = tools
                self.cost = cost
                self.limit = limit
                self.color = color
                self.width = width
                self.eol = eol
            }
        }

        // parity: cli/src/commands/handlers/stats.ts#request [status=adapted hash=53426104f5ca]
        public static func request<A: Sendable>(
            url: String,
            _ run: @Sendable (AbortSignal) async throws -> A
        ) async throws -> A {
            let controller = AbortController()
            do {
                return try await run(controller.signal)
            } catch let err as ClientError where err.reason == .transport {
                throw CLIError("Could not reach server at \(url)")
            }
        }

        // parity: cli/src/commands/handlers/stats.ts#renderStats [status=implemented hash=93b5fc00fd59]
        public static func renderStats(
            _ stats: SessionStatsSchema.Info,
            options: RenderOptions
        ) -> String {
            let palette = terminalPalette()
            let totalTokens = stats.tokens.total
            let toolTotals: SessionStatsSchema.ToolTotals?
            switch stats.tools {
            case .none: toolTotals = nil
            case .summary(let totals): toolTotals = totals
            case .detail(let totals, _): toolTotals = totals
            }
            let terminalTools = toolTotals.map { $0.succeeded + $0.failed } ?? 0
            let toolRate: Double? = (toolTotals != nil && terminalTools > 0)
                ? (Double(toolTotals!.succeeded) / Double(terminalTools)) * 100.0
                : nil
            let primary = "1;\(palette.primary)"

            var sessionParts = [metricCount(Double(stats.sessions), noun: "session", primary: primary, color: options.color)]
            if stats.subagents > 0 {
                sessionParts.append(metricCount(Double(stats.subagents), noun: "subagent", primary: primary, color: options.color))
            }
            let sessionLine = sessionParts.joined(separator: " · ")

            let toolSummary: String
            if toolTotals == nil {
                toolSummary = "tool stats unavailable"
            } else if let rate = toolRate {
                toolSummary = "\(style(formatPercent(rate), code: primary, color: options.color)) tool success"
            } else {
                toolSummary = "no tool calls"
            }

            let details = options.models || options.tools || options.cost
            let isEmpty = stats.sessions == 0 && stats.prompts == 0 && stats.steps == 0
            let heading = "\(style("opencode stats", code: primary, color: options.color)) \(style("· \(options.label) · \(options.scope)", code: "2", color: options.color))"

            var lines: [String]
            if details {
                lines = [style("\(options.label) · \(options.scope)", code: "2", color: options.color)]
            } else if isEmpty {
                lines = [
                    heading,
                    "",
                    style("no activity in this range", code: "2", color: options.color),
                    "",
                    style("opencode.ai", code: "2", color: options.color),
                ]
            } else {
                lines = [heading, ""]
                lines.append(contentsOf: renderActivity(stats.activity, from: stats.range.from, to: stats.range.to, color: options.color, width: options.width, palette: palette))
                lines.append("")
                lines.append(sessionLine)
                lines.append(
                    "\(metricCount(Double(stats.prompts), noun: "prompt", primary: primary, color: options.color)) · \(metricCount(Double(stats.steps), noun: "step", primary: primary, color: options.color)) · \(metricCount(totalTokens, noun: "token", primary: primary, color: options.color))"
                )
                let streakPlural = stats.streak == 1 ? "" : "s"
                lines.append(
                    "\(toolSummary) · \(metricCount(Double(stats.activeDays), noun: "active day", primary: primary, color: options.color)) · best streak \(style(String(stats.streak), code: primary, color: options.color)) day\(streakPlural)"
                )
                lines.append("")
                lines.append(style("opencode.ai", code: "2", color: options.color))
            }

            if options.cost {
                if !lines.isEmpty { lines.append("") }
                lines.append(contentsOf: renderCost(stats))
            }
            if options.models {
                if !lines.isEmpty { lines.append("") }
                lines.append(contentsOf: renderModels(stats, limit: options.limit, width: options.width))
            }
            if options.tools {
                if !lines.isEmpty { lines.append("") }
                lines.append(contentsOf: renderTools(stats, limit: options.limit, width: options.width))
            }
            return lines.joined(separator: options.eol)
        }

        private static func renderActivity(
            _ activity: [SessionStatsSchema.Activity],
            from: Int64,
            to: Int64,
            color: Bool,
            width: Int,
            palette: (primary: String, activity: [String])
        ) -> [String] {
            let input = ActivityCalendarInput(
                activity: activity.map { ActivityDayInput(date: $0.date, steps: $0.steps) },
                from: from,
                to: to,
                maxWeeks: max(1, width - 4)
            )
            let cal = activityCalendar(input)
            var monthsStr = ""
            for (idx, m) in cal.months.enumerated() {
                let text = (idx == cal.months.count - 1 || m.label.count <= m.span) ? m.label : ""
                monthsStr += text.padding(toLength: max(text.count, m.span), withPad: " ", startingAt: 0)
            }
            while monthsStr.last == " " { monthsStr.removeLast() }

            let weekdays = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
            var out: [String] = [
                style(cal.clipped ? "activity · last \(cal.weeks.count) weeks" : "activity", code: "1;\(palette.primary)", color: color),
                "   \(style(monthsStr, code: "2", color: color))",
            ]
            for (day, label) in weekdays.enumerated() {
                let rowGlyphs = cal.weeks.map { week -> String in
                    guard day < week.count, week[day].level >= 0 else { return " " }
                    return paintActivity(level: week[day].level, color: color, palette: palette)
                }.joined()
                out.append("\(style(label, code: "2", color: color)) \(rowGlyphs)")
                if day < weekdays.count - 1 { out.append("") }
            }
            let legend = (0...4).map { paintActivity(level: $0, color: color, palette: palette) }.joined()
            out.append("")
            out.append("   \(style("less", code: "2", color: color)) \(legend) \(style("more", code: "2", color: color))")
            return out
        }

        private static func renderCost(_ stats: SessionStatsSchema.Info) -> [String] {
            let inputTokens = stats.tokens.input + stats.tokens.cache.read + stats.tokens.cache.write
            let cachedPct = inputTokens == 0 ? 0.0 : (stats.tokens.cache.read / inputTokens) * 100.0
            return [
                "COST & TOKENS",
                kvRow("cost", String(format: "$%.2f", stats.cost)),
                kvRow("input", formatNumber(stats.tokens.input)),
                kvRow("output", formatNumber(stats.tokens.output)),
                kvRow("reasoning", formatNumber(stats.tokens.reasoning)),
                kvRow("cache read", formatNumber(stats.tokens.cache.read)),
                kvRow("cache write", formatNumber(stats.tokens.cache.write)),
                kvRow("cached input", formatPercent(cachedPct)),
            ]
        }

        private static func renderModels(_ stats: SessionStatsSchema.Info, limit: Int, width: Int) -> [String] {
            if stats.models.isEmpty { return ["MODELS", "  no model usage"] }
            let slice = Array(stats.models.prefix(limit))
            let more = stats.models.count - slice.count
            var lines: [String] = ["MODELS"]
            if width < 68 {
                for item in slice {
                    let label = "\(item.model.providerID)/\(item.model.id)\(item.model.variant.map { "#\($0)" } ?? "")"
                    lines.append(truncate(label, width: width))
                    lines.append("  \(formatNumber(item.tokens.total)) tokens · \(formatNumber(Double(item.steps))) steps · \(String(format: "$%.2f", item.cost))")
                }
            } else {
                lines.append(tableRow("model", "tokens", "steps", "cost"))
                for item in slice {
                    let label = "\(item.model.providerID)/\(item.model.id)\(item.model.variant.map { "#\($0)" } ?? "")"
                    lines.append(tableRow(label, formatNumber(item.tokens.total), formatNumber(Double(item.steps)), String(format: "$%.2f", item.cost)))
                }
            }
            if more > 0 {
                lines.append("")
                lines.append("+\(formatIntegerWithCommas(more)) more model\(more == 1 ? "" : "s")")
            }
            return lines
        }

        private static func renderTools(_ stats: SessionStatsSchema.Info, limit: Int, width: Int) -> [String] {
            guard case .detail(let totals, let usage) = stats.tools else {
                return ["TOOL RELIABILITY", "  tool details unavailable"]
            }
            if usage.isEmpty { return ["TOOL RELIABILITY", "  no tool calls"] }
            let slice = Array(usage.prefix(limit))
            let more = usage.count - slice.count
            var lines: [String] = ["TOOL RELIABILITY"]
            if width < 68 {
                for tool in slice {
                    let term = tool.succeeded + tool.failed
                    let errPct = term == 0 ? "-" : formatPercent((Double(tool.failed) / Double(term)) * 100.0)
                    let p50 = tool.durationP50.map(formatDuration) ?? "-"
                    lines.append(truncate(tool.name, width: width))
                    lines.append("  \(formatNumber(Double(tool.calls))) calls · \(errPct) error · \(p50) p50")
                }
            } else {
                lines.append(tableRow("tool", "calls", "error", "p50"))
                for tool in slice {
                    let term = tool.succeeded + tool.failed
                    let errPct = term == 0 ? "-" : formatPercent((Double(tool.failed) / Double(term)) * 100.0)
                    let p50 = tool.durationP50.map(formatDuration) ?? "-"
                    lines.append(tableRow(tool.name, formatNumber(Double(tool.calls)), errPct, p50))
                }
            }
            lines.append("")
            lines.append("\(formatNumber(Double(totals.succeeded + totals.failed))) finished calls · \(formatNumber(Double(totals.unfinished))) unfinished")
            if more > 0 {
                lines.append("+\(formatIntegerWithCommas(more)) more tool\(more == 1 ? "" : "s")")
            }
            return lines
        }

        private static func kvRow(_ label: String, _ value: String) -> String {
            "  \(label.padding(toLength: 20, withPad: " ", startingAt: 0))\(value)"
        }

        private static func tableRow(_ c1: String, _ c2: String, _ c3: String, _ c4: String) -> String {
            let p1 = truncate(c1, width: 34).padding(toLength: 34, withPad: " ", startingAt: 0)
            let p2 = padStart(c2, to: 10)
            let p3 = padStart(c3, to: 12)
            let p4 = padStart(c4, to: 12)
            return "\(p1)\(p2)\(p3)\(p4)"
        }

        private static func padStart(_ value: String, to width: Int) -> String {
            if value.count >= width { return value }
            return String(repeating: " ", count: width - value.count) + value
        }

        private static func truncate(_ value: String, width: Int) -> String {
            guard width > 1, value.count > width else { return value }
            return String(value.prefix(width - 1)) + "…"
        }

        private static func formatNumber(_ value: Double) -> String {
            if value >= 1_000_000_000 { return "\(trimDecimal(value / 1_000_000_000))b" }
            if value >= 1_000_000 { return "\(trimDecimal(value / 1_000_000))m" }
            if value >= 1_000 { return "\(trimDecimal(value / 1_000))k" }
            return formatIntegerWithCommas(Int(value.rounded()))
        }

        private static func formatIntegerWithCommas(_ n: Int) -> String {
            let neg = n < 0
            let digits = Array(String(abs(n)))
            var out = ""
            for (idx, ch) in digits.enumerated() {
                let remaining = digits.count - idx
                if idx > 0 && remaining % 3 == 0 { out.append(",") }
                out.append(ch)
            }
            return neg ? "-\(out)" : out
        }

        private static func trimDecimal(_ value: Double) -> String {
            let formatted = String(format: "%.1f", value)
            return formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) : formatted
        }

        private static func formatPercent(_ value: Double) -> String {
            value >= 10.0 ? String(format: "%.1f%%", value) : String(format: "%.2f%%", value)
        }

        private static func formatDuration(_ value: Double) -> String {
            if value < 1_000 { return "\(Int(value.rounded()))ms" }
            return "\(trimDecimal(value / 1_000))s"
        }

        private static func metricCount(_ value: Double, noun: String, primary: String, color: Bool) -> String {
            "\(style(formatNumber(value), code: primary, color: color)) \(noun)\(value == 1 ? "" : "s")"
        }

        private static func style(_ value: String, code: String, color: Bool) -> String {
            color ? "\u{1B}[\(code)m\(value)\u{1B}[0m" : value
        }

        private static func paintActivity(level: Int, color: Bool, palette: (primary: String, activity: [String])) -> String {
            let glyphs = ["·", "░", "▒", "▓", "█"]
            let idx = min(max(0, level), glyphs.count - 1)
            let glyph = glyphs[idx]
            if !color { return glyph }
            if idx == 0 { return "\u{1B}[2m\(glyph)\u{1B}[22m" }
            return "\u{1B}[\(palette.activity[idx - 1])m\(glyph)\u{1B}[39m"
        }

        private static func terminalPalette() -> (primary: String, activity: [String]) {
            if let fgbg = CLIContext.current.envVariable("COLORFGBG"),
               let last = fgbg.split(separator: ";").last,
               let bg = Int(last)
            {
                if bg >= 7 {
                    return ("38;2;59;125;216", ["38;2;153;169;192", "38;2;122;155;200", "38;2;90;140;208", "38;2;59;125;216"])
                }
                return ("38;2;250;178;131", ["38;2;117;99;87", "38;2;161;125;102", "38;2;206;152;116", "38;2;250;178;131"])
            }
            return ("36", ["2;36", "36", "1;36", "1;96"])
        }

        public static func run(_ input: CLIFramework.Runtime.Input, context: CLIContext) async {
            do {
                let days = input.integer("days")
                let year = input.integer("year")
                let all = input.bool("all")
                let project = input.string("project")
                let rangeCount = [days != nil, year != nil, all].filter { $0 }.count
                if rangeCount > 1 {
                    throw CLIError("--days, --year, and --all cannot be combined")
                }
                let server = try await CLIServices.ServerConnection.resolve(context: context)
                let client = context.makeClient(endpoint: server.endpoint)
                let range = computeRange(days: days, year: year, all: all)
                let projectID: String?
                if project == "." {
                    let loc = try await request(url: server.endpoint.url) { signal in
                        try await client.location.get(
                            LocationGetInput(location: LocationQuery.LocationField(directory: context.cwd)),
                            options: RequestOptions(signal: signal)
                        )
                    }
                    projectID = loc.project.id.rawValue
                } else {
                    projectID = project
                }

                let showModels = input.bool("models")
                let showTools = input.bool("tools")
                let showCost = input.bool("cost")
                let showFull = input.bool("full")
                let asJson = input.bool("json")
                let details = showModels || showTools || showCost || showFull
                let toolsMode = (asJson || showTools || showFull) ? "detail" : (details ? "none" : "summary")
                let tz = TimeZone.current.identifier

                let stats = try await request(url: server.endpoint.url) { signal in
                    try await client.experimental.session.stats(
                        ExperimentalSessionStatsInput(
                            from: range.from.map(Double.init),
                            to: Double(range.to),
                            project: projectID,
                            timezone: tz,
                            tools: toolsMode
                        ),
                        options: RequestOptions(signal: signal)
                    )
                }

                let output: String
                if asJson {
                    output = try CLIPath.encodePrettyJSON(stats)
                } else {
                    let scope = project == nil ? "all projects" : (project == "." ? "current project" : "selected project")
                    let color = context.io.isStdoutTTY() && context.envVariable("NO_COLOR") == nil
                    output = renderStats(
                        stats,
                        options: RenderOptions(
                            label: range.label,
                            scope: scope,
                            models: showModels || showFull,
                            tools: showTools || showFull,
                            cost: showCost || showFull,
                            limit: input.integer("limit") ?? 5,
                            color: color,
                            width: context.io.columns(),
                            eol: context.io.eol
                        )
                    )
                }
                context.io.writeStdout(output + context.io.eol)
            } catch {
                context.io.writeStderr(CLIUtil.errorMessage(error) + context.io.eol)
                context.exitCode.value = 1
            }
        }

        private static func computeRange(days: Int?, year: Int?, all: Bool) -> (from: Int64?, to: Int64, label: String) {
            let now = Date()
            let to = Int64((now.timeIntervalSince1970 * 1_000.0).rounded()) + 1
            if all { return (nil, to, "all time") }
            var cal = Calendar.current
            cal.timeZone = TimeZone.current
            if let days {
                let startOfToday = cal.startOfDay(for: now)
                let start = cal.date(byAdding: .day, value: -max(0, days - 1), to: startOfToday) ?? startOfToday
                let fromMs = Int64((start.timeIntervalSince1970 * 1_000.0).rounded())
                let label = (days == 0 || days == 1) ? "today" : "last \(days) days"
                return (fromMs, to, label)
            }
            let currentYear = cal.component(.year, from: now)
            let targetYear = year ?? currentYear
            let startComps = DateComponents(year: targetYear, month: 1, day: 1)
            let startDate = cal.date(from: startComps) ?? now
            let fromMs = Int64((startDate.timeIntervalSince1970 * 1_000.0).rounded())
            if targetYear == currentYear {
                return (fromMs, to, "\(targetYear) so far")
            }
            let endComps = DateComponents(year: targetYear + 1, month: 1, day: 1)
            let endDate = cal.date(from: endComps) ?? now
            return (fromMs, Int64((endDate.timeIntervalSince1970 * 1_000.0).rounded()), String(targetYear))
        }
    }

    // MARK: Session Commands (`packages/cli/src/commands/handlers/session/*`)

    public enum Session {
        public static func runList(_ input: CLIFramework.Runtime.Input, context: CLIContext) async {
            do {
                let server = try await CLIServices.ServerConnection.resolve(context: context)
                let client = context.makeClient(endpoint: server.endpoint)
                let loc = try await client.location.get(
                    LocationGetInput(location: LocationQuery.LocationField(directory: context.cwd))
                )
                let limit = input.integer("max-count") ?? 100
                let page = try await client.session.list(
                    SessionListInput(limit: limit, order: .desc, project: loc.project.id.rawValue)
                )
                let format = input.string("format") ?? "table"
                if format == "table" && page.data.isEmpty { return }
                let output: String
                if format == "json" {
                    let payload = page.data.map { s -> JSONValue in
                        .object([
                            "id": .string(s.id.rawValue),
                            "title": s.title.map(JSONValue.string) ?? .null,
                            "updated": .int(s.time.updated),
                            "created": .int(s.time.created),
                            "projectId": .string(s.projectID.rawValue),
                            "directory": .string(s.location.directory),
                        ])
                    }
                    output = try CLIPath.encodePrettyJSON(JSONValue.array(payload))
                } else {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .short
                    formatter.timeStyle = .medium
                    output = page.data.map { s -> String in
                        let title = (s.title ?? "Untitled session")
                            .replacing("\r", with: " ")
                            .replacing("\n", with: " ")
                            .replacing("\t", with: " ")
                        let updated = formatter.string(from: Date(timeIntervalSince1970: Double(s.time.updated) / 1_000.0))
                        return "\(s.id.rawValue)\t\(title)\t\(updated)"
                    }.joined(separator: context.io.eol)
                }
                context.io.writeStdout(output + context.io.eol)
            } catch {
                context.io.writeStderr(CLIUtil.errorMessage(error) + context.io.eol)
                context.exitCode.value = 1
            }
        }

        public static func runDelete(_ input: CLIFramework.Runtime.Input, context: CLIContext) async {
            do {
                guard let sessionID = input.arg("sessionID") else {
                    throw CLIError("Missing required argument: sessionID")
                }
                let server = try await CLIServices.ServerConnection.resolve(context: context)
                let client = context.makeClient(endpoint: server.endpoint)
                try await client.session.remove(SessionRemoveInput(sessionID: sessionID))
                context.io.writeStdout("Session \(sessionID) deleted\(context.io.eol)")
            } catch {
                context.io.writeStderr(CLIUtil.errorMessage(error) + context.io.eol)
                context.exitCode.value = 1
            }
        }

        public static func runExport(_ input: CLIFramework.Runtime.Input, context: CLIContext) async {
            do {
                let requested = input.arg("session")
                if requested == nil && !context.io.isStdinTTY() {
                    throw CLIError("Pass a session ID when running without an interactive terminal")
                }
                let server = try await CLIServices.ServerConnection.resolve(context: context)
                let client = context.makeClient(endpoint: server.endpoint)
                let sessionID: String
                if let requested {
                    sessionID = requested
                } else {
                    let loc = try await client.location.get(
                        LocationGetInput(location: LocationQuery.LocationField(directory: context.cwd))
                    )
                    let page = try await client.session.list(
                        SessionListInput(limit: 50, order: .desc, directory: loc.directory.rawValue)
                    )
                    if page.data.isEmpty {
                        context.io.writeStderr("No sessions found\(context.io.eol)")
                        return
                    }
                    let opts = page.data.map { s in
                        CLIUI.Prompt.SelectOption(
                            value: s.id.rawValue,
                            label: s.title ?? "Untitled session",
                            hint: String(s.id.rawValue.suffix(8))
                        )
                    }
                    do {
                        sessionID = try await CLIUI.Prompt.backend(for: context).select(
                            message: "Select session to export",
                            options: opts,
                            initialValue: opts.first?.value
                        )
                    } catch is CLIUI.Prompt.CancelledError {
                        context.exitCode.value = 130
                        return
                    }
                }
                let exported = try await client.experimental.session.export(
                    ExperimentalSessionExportInput(sessionID: sessionID, sanitize: input.bool("sanitize"))
                )
                context.io.writeStdout((try CLIPath.encodePrettyJSON(exported)) + context.io.eol)
            } catch {
                context.io.writeStderr(CLIUtil.errorMessage(error) + context.io.eol)
                context.exitCode.value = 1
            }
        }

        public static func runImport(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
            guard let file = input.arg("file") else { throw CLIError("Missing required argument: file") }
            let rawText: String
            if file.hasPrefix("http://") || file.hasPrefix("https://") {
                let resp = try await context.transport.send(HTTPRequest(method: "GET", url: file))
                guard (200..<300).contains(resp.head.statusCode) else {
                    throw CLIError("Failed to fetch session data: HTTP \(resp.head.statusCode)")
                }
                rawText = String(decoding: resp.body, as: UTF8.self)
            } else {
                let bytes = try await context.fileSystem.readFile(at: CLIPath.resolve(context.cwd, file))
                rawText = String(decoding: bytes, as: UTF8.self)
            }
            guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(rawText.utf8)),
                  case .object(var bodyObj) = parsed
            else {
                throw CLIError("Failed to read session data: invalid JSON object")
            }
            let server = try await CLIServices.ServerConnection.resolve(context: context)
            let client = context.makeClient(endpoint: server.endpoint)
            let targetDir = input.string("directory").map { CLIPath.resolve(context.cwd, $0) } ?? context.cwd
            let loc = try await client.location.get(
                LocationGetInput(location: LocationQuery.LocationField(directory: targetDir))
            )
            bodyObj["location"] = .object(["directory": .string(loc.directory.rawValue)])
            var headers = OpenCodeClient.serviceHeaders(for: server.endpoint) ?? [:]
            headers["content-type"] = "application/json"
            let url = ClientURLBuilder.join(baseUrl: server.endpoint.url, path: "/api/experimental/session/import")
            let bodyBytes = Array((try CLIPath.encodeCompactJSON(JSONValue.object(bodyObj))).utf8)
            let resp = try await context.transport.send(
                HTTPRequest(method: "POST", url: url, headers: headers, body: bodyBytes)
            )
            if resp.head.statusCode == 409 {
                context.io.writeStderr("Session already exists\(context.io.eol)")
                return
            }
            guard (200..<300).contains(resp.head.statusCode) else {
                throw CLIError("Failed to import session: HTTP \(resp.head.statusCode)")
            }
            let envelope = try JSONDecoder().decode(ClientDataEnvelope<SessionSchema.Info>.self, from: Data(resp.body))
            context.io.writeStdout("Imported session: \(envelope.data.id.rawValue)\(context.io.eol)")
        }
    }

    // MARK: Service Lifecycle Commands (`packages/cli/src/commands/handlers/service/*`)

    public enum ServiceCmd {
        public static func runStart(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
            _ = input
            let opts = try await CLIServices.ServiceConfig.options(CLIServices.ServiceConfig.OptionsInput(), context)
            let endpoint = try await EffectClient.Service.ensure(
                options: opts,
                fileSystem: context.fileSystem,
                transport: context.transport,
                launcher: context.launcher,
                signaler: context.signaler,
                environment: context.environment
            )
            context.io.writeStdout(endpoint.url + context.io.eol)
        }

        public static func runRestart(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
            _ = input
            let opts = try await CLIServices.ServiceConfig.options(CLIServices.ServiceConfig.OptionsInput(), context)
            try await EffectClient.Service.stop(
                options: ServiceStopOptions(file: opts.file),
                fileSystem: context.fileSystem,
                transport: context.transport,
                signaler: context.signaler,
                environment: context.environment
            )
            let endpoint = try await EffectClient.Service.ensure(
                options: opts,
                fileSystem: context.fileSystem,
                transport: context.transport,
                launcher: context.launcher,
                signaler: context.signaler,
                environment: context.environment
            )
            context.io.writeStdout(endpoint.url + context.io.eol)
        }

        public static func runStatus(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
            _ = input
            let opts = try await CLIServices.ServiceConfig.options(CLIServices.ServiceConfig.OptionsInput(), context)
            let found = await EffectClient.Service.discover(
                options: ServiceDiscoverOptions(file: opts.file, version: nil),
                fileSystem: context.fileSystem,
                transport: context.transport,
                environment: context.environment
            )
            context.io.writeStdout((found?.url ?? "stopped") + context.io.eol)
        }

        public static func runStop(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
            _ = input
            let opts = try await CLIServices.ServiceConfig.options(CLIServices.ServiceConfig.OptionsInput(), context)
            try await EffectClient.Service.stop(
                options: ServiceStopOptions(file: opts.file),
                fileSystem: context.fileSystem,
                transport: context.transport,
                signaler: context.signaler,
                environment: context.environment
            )
        }

        public static func runGet(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
            let value = try await CLIServices.ServiceConfig.get(
                key: input.arg("key"),
                name: input.arg("name"),
                context: context
            )
            context.io.writeStdout(value + context.io.eol)
        }

        public static func runSet(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
            guard let key = input.arg("key"), let value = input.arg("value") else {
                throw CLIError("Usage: opencode service set <key> <value>")
            }
            try await CLIServices.ServiceConfig.set(
                key: key,
                value: value,
                nestedValue: input.arg("nestedValue"),
                context: context
            )
        }

        public static func runUnset(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
            guard let key = input.arg("key") else {
                throw CLIError("Usage: opencode service unset <key>")
            }
            try await CLIServices.ServiceConfig.unset(
                key: key,
                name: input.arg("name"),
                context: context
            )
        }
    }

    // MARK: Top-Level Commands (`default`, `serve`, `run`, `mini`, `acp`, `models`, `reload`, `upgrade`, `uninstall`)

    public static func runDefault(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
        if let dir = input.arg("directory") {
            context.cwd = CLIPath.resolve(context.cwd, dir)
        }
        let preflight = CLIServices.UpdatePreflight.makeHandle(context: context)
        let server: CLIServices.ServerConnection.Resolved
        do {
            server = try await CLIServices.ServerConnection.resolve(
                CLIServices.ServerConnection.Args(
                    server: input.string("server"),
                    standalone: input.bool("standalone"),
                    mismatch: .replace,
                    onStart: { reason, previousVersion in
                        if reason == .versionMismatch && preflight.begin(previousVersion) { return }
                        context.io.writeStderr(
                            reason == .versionMismatch
                                ? "Restarting background server (version mismatch)...\n"
                                : "Starting background server...\n"
                        )
                    }
                ),
                context: context
            )
        } catch {
            await preflight.fail("OpenCode update could not start the new background service")
            throw error
        }
        defer {
            Task { await preflight.close() }
            if let standaloneHandle = server.standaloneHandle {
                Task { await standaloneHandle.stop() }
            }
        }

        let requestedSession = input.string("session")
        let sessionExists: Bool
        if let requestedSession {
            let client = context.makeClient(endpoint: server.endpoint)
            sessionExists = (try await CLIServices.SessionTargetService.findSession(client: client, sessionID: requestedSession)) != nil
        } else {
            sessionExists = false
        }

        preflight.loading()
        let tuiReconnect: (@Sendable (AbortSignal) async throws -> (url: String, headers: [String: String]))?
        if let svc = server.service {
            tuiReconnect = { _ in
                let ep = try await svc.reconnect()
                return (url: ep.url, headers: OpenCodeClient.serviceHeaders(for: ep) ?? [:])
            }
        } else {
            tuiReconnect = nil
        }
        var tuiEnv = input.string("server") == nil ? CLIUtil.Env.session() : [:]
        tuiEnv["OPENCODE_CWD"] = context.cwd
        let tuiInput = TUIApp.TuiInput(
            app: TUIContext.TuiApp(
                name: context.envVariable("OPENCODE_CLIENT") ?? context.artifact,
                version: context.version,
                channel: context.envVariable("OPENCODE_TUI_CHANNEL") ?? context.channel
            ),
            server: TUIApp.ServerEndpointConfig(
                baseUrl: server.endpoint.url,
                headers: OpenCodeClient.serviceHeaders(for: server.endpoint) ?? [:],
                local: input.string("server") == nil,
                reconnect: tuiReconnect,
                restart: server.service?.restart
            ),
            args: TUIContext.Args(
                prompt: input.string("prompt"),
                continue: input.bool("continue"),
                sessionID: sessionExists ? requestedSession : nil,
                newSessionID: sessionExists ? nil : requestedSession,
                auto: input.bool("auto") || input.bool("yolo") || input.bool("dangerously-skip-permissions")
            ),
            config: CLIConfig.TUIConfigAdapter(context.configService),
            environment: tuiEnv,
            terminalHandoff: { await preflight.finish() }
        )

        if let customRunner = context.tuiRunner {
            _ = try await customRunner(tuiInput)
        } else {
            _ = try await TUIApp.run(tuiInput)
        }
    }

    public static func runServe(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
        let isService = input.bool("service")
        let isStdio = input.bool("stdio")
        if isService && isStdio {
            throw CLIError("--service and --stdio cannot be combined")
        }
        let mode: CLIServices.ServerProcess.Mode = isService ? .service : (isStdio ? .stdio : .default)
        let cors = input.stringsList("cors")
        try await CLIServices.ServerProcess.run(
            CLIServices.ServerProcess.Options(
                mode: mode,
                hostname: input.string("hostname"),
                port: input.integer("port"),
                cors: cors.isEmpty ? nil : cors
            ),
            context
        )
    }

    public static func runCommand(_ input: CLIFramework.Runtime.Input, context: CLIContext) async {
        let format = CLIRun.OutputFormat(rawValue: input.string("format") ?? "default") ?? .default
        let server: CLIServices.ServerConnection.Resolved
        do {
            server = try await CLIServices.ServerConnection.resolve(
                CLIServices.ServerConnection.Args(autostart: false),
                context: context
            )
        } catch {
            CLIRun.reportRunError(format: format, message: CLIUtil.errorMessage(error), context: context)
            return
        }
        defer {
            if let handle = server.standaloneHandle {
                Task { await handle.stop() }
            }
        }
        let controller = AbortController()
        let cmdInput = CLIRun.RunCommandInput(
            server: server,
            message: input.args("message"),
            continue: input.bool("continue"),
            session: input.string("session"),
            fork: input.bool("fork"),
            worktree: input.optionalFlag("worktree"),
            model: input.string("model"),
            agent: input.string("agent"),
            format: format,
            file: input.stringsList("file"),
            title: input.string("title"),
            archived: input.bool("archived"),
            thinking: input.bool("thinking"),
            auto: input.bool("auto") || input.bool("yolo") || input.bool("dangerously-skip-permissions")
        )
        await CLIRun.runNonInteractive(cmdInput, signal: controller.signal, context: context)
    }

    public static func runMini(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
        try CLIRun.Mini.validateMiniTerminal(context: context)
        let server = try await CLIServices.ServerConnection.resolve(
            CLIServices.ServerConnection.Args(mismatch: .replace),
            context: context
        )
        let rawConfig = try await context.configService.get()
        let resolved = TUIConfig.resolve(
            rawConfig.tui,
            options: TUIConfig.ResolveOptions(terminalSuspend: context.platformOS != .windows)
        )
        let global = context.globalPaths
        let miniReconnect: (@Sendable (AbortSignal) async throws -> ServiceEndpoint)?
        if let svc = server.service {
            miniReconnect = { _ in try await svc.reconnect() }
        } else {
            miniReconnect = nil
        }
        let miniInput = CLIRun.Mini.MiniCommandInput(
            server: CLIRun.Mini.ServerInput(
                endpoint: server.endpoint,
                reconnect: miniReconnect
            ),
            continue: input.bool("continue"),
            session: input.string("session"),
            fork: input.bool("fork"),
            model: input.string("model"),
            agent: input.string("agent"),
            prompt: input.string("prompt"),
            replay: input.optionalBool("replay") ?? resolved.mini?.replay ?? true,
            replayLimit: input.integer("replay-limit") ?? resolved.mini?.replayLimit,
            demo: input.bool("demo"),
            tuiConfig: resolved,
            paths: CLIRun.MiniHost.HostPaths(home: global.home, state: global.state, log: global.log)
        )
        try await CLIRun.Mini.runMini(miniInput, context: context)
    }

    public static func runACP(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
        if input.bool("login") {
            await Auth.runLogin(CLIFramework.Runtime.Input(commandPath: ["auth", "login"]), context: context)
            return
        }
        context.setEnvOverride("OPENCODE_CLIENT", value: "acp")
        if let acpRunner = context.acpRunner {
            let code = try await acpRunner(context, false)
            context.exitCode.value = code
            return
        }
        let handle = try await CLIServices.Standalone.start(context: context)
        defer { Task { await handle.stop() } }
        context.io.writeStderr("opencode acp: ACP bridge ready on \(handle.endpoint.url)\(context.io.eol)")
    }

    public static func runModels(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
        _ = input
        let server = try await CLIServices.ServerConnection.resolve(context: context)
        let client = context.makeClient(endpoint: server.endpoint)
        await CLIServices.waitForPlugins(client, context.cwd)
        let response = try await client.model.list(
            ModelListInput(location: LocationQuery.LocationField(directory: context.cwd))
        )
        let models = response.data
            .map { "\($0.providerID)/\($0.id)" }
            .sorted()
        if !models.isEmpty {
            context.io.writeStdout(models.joined(separator: context.io.eol) + context.io.eol)
        }
    }

    public static func runReload(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
        _ = input
        let server = try await CLIServices.ServerConnection.resolve(context: context)
        let client = context.makeClient(endpoint: server.endpoint)
        try await client.location.reload()
        context.io.writeStdout("Configuration reloaded\(context.io.eol)")
    }

    public static func runUpgrade(_ input: CLIFramework.Runtime.Input, context: CLIContext) async {
        _ = await CLIUI.Prompt.handlePromptErrors(context: context) {
            let updater = context.updaterService
            let explicitMethod = input.string("method").flatMap(CLIServices.Updater.Method.init(rawValue:))
            let method: CLIServices.Updater.Method
            if let explicitMethod {
                method = explicitMethod
            } else if let detected = await updater.method() {
                method = detected
            } else {
                if let managedErr = try await updater.managed(version: input.arg("target")) {
                    throw CLIError(formatUpgradeError(managedErr, columns: context.io.columns()))
                }
                throw CLIError("Could not detect the installation method. Pass --method to choose how to upgrade OpenCode.")
            }
            context.io.writeStderr("Using method: \(method.rawValue)\(context.io.eol)")
            let target: String
            do {
                if let explicitTarget = input.arg("target") {
                    target = explicitTarget
                } else {
                    target = try await updater.latest(method: method)
                }
            } catch let err as CLIServices.Updater.UpgradeError {
                throw CLIError(formatUpgradeError(err, columns: context.io.columns()))
            }
            var version = target.trimmingCharacters(in: .whitespacesAndNewlines)
            if version.hasPrefix("v") { version.removeFirst() }
            if version == context.version {
                context.io.writeStderr("OpenCode upgrade skipped: \(version) is already installed\(context.io.eol)")
                return
            }
            context.io.writeStderr("From \(context.version) → \(version)\(context.io.eol)")
            do {
                try await updater.upgrade(method: method, version: target)
            } catch let err as CLIServices.Updater.UpgradeError {
                throw CLIError(formatUpgradeError(err, columns: context.io.columns()))
            }
            context.io.writeStderr("Upgrade complete\(context.io.eol)")
        }
    }

    private static func formatUpgradeError(_ error: CLIServices.Updater.UpgradeError, columns: Int) -> String {
        let clean: (String) -> String = { CLIPath.stripANSI($0).replacing("\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let line: (String) -> String = { clean($0).split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        var lines: [String] = [line(error.title), "", clean(error.detail)]
        if let cmd = error.command {
            lines.append("")
            lines.append("Command  \(line(cmd))")
        }
        lines.append("Retry    \(line(error.retry))")
        _ = columns
        return lines.joined(separator: "\n")
    }

    public static func runUninstall(_ input: CLIFramework.Runtime.Input, context: CLIContext) async {
        _ = await CLIUI.Prompt.handlePromptErrors(context: context) {
            let fs = context.fileSystem
            let global = context.globalPaths
            let updater = context.updaterService
            let method = await updater.method()
            let removal = method.flatMap { updater.removal(method: $0) }
            let services: [String]
            if await fs.exists(at: global.state),
               let entries = try? await fs.readDirectory(at: global.state)
            {
                services = entries.filter { name in
                    name == "service.json" || (name.hasPrefix("service-") && name.hasSuffix(".json"))
                }
            } else {
                services = []
            }

            context.io.writeStderr("Installation method: \(method?.rawValue ?? "unknown")\(context.io.eol)")
            if await fs.exists(at: global.cache) {
                context.io.writeStderr("  Cache: \(global.cache)\(context.io.eol)")
            }
            for name in services {
                context.io.writeStderr("  Stop background service and persistent terminals: \(CLIPath.join(global.state, name))\(context.io.eol)")
            }
            if let removal {
                context.io.writeStderr("  Package: \(removal.command.joined(separator: " "))\(context.io.eol)")
            }
            if method == .curl {
                context.io.writeStderr("  Binary (manual removal): \(context.executablePath)\(context.io.eol)")
            }
            if method == nil {
                context.io.writeStderr("Could not detect the installation method. Remove the installation manually after cleanup.\(context.io.eol)")
            }

            if input.bool("dry-run") {
                context.io.writeStderr("Dry run - no changes made\(context.io.eol)")
                return
            }
            if !input.bool("force") {
                try CLIUI.Prompt.requireInteractive("Use --force to uninstall without an interactive terminal, or --dry-run to preview.", context: context)
                let accepted = try await CLIUI.Prompt.backend(for: context).confirm(
                    message: "Are you sure you want to uninstall?",
                    initialValue: false
                )
                if !accepted {
                    context.io.writeStderr("Cancelled\(context.io.eol)")
                    return
                }
            }

            for name in services {
                let file = CLIPath.join(global.state, name)
                try? await CLIServices.ServerConnection.shutdownPersistentPty(ServiceDiscoverOptions(file: file), context: context)
                try? await EffectClient.Service.stop(
                    options: ServiceStopOptions(file: file),
                    fileSystem: fs,
                    transport: context.transport,
                    signaler: context.signaler,
                    environment: context.environment
                )
            }
            if context.platformOS == .windows {
                await CLIServices.RetainedImage.relocate(global.cache, global.tmp, context)
            }
            var errors: [String] = []
            do {
                try await fs.remove(at: global.cache)
            } catch {
                errors.append("Cache: \(CLIUtil.errorMessage(error))")
            }
            if let removal {
                do {
                    try await removal.run()
                } catch {
                    errors.append(CLIUtil.errorMessage(error))
                }
            }
            if method == .curl {
                let escaped = context.executablePath.replacing("'", with: "'\\''")
                context.io.writeStderr("To finish removing the binary, run:\(context.io.eol)  rm '\(escaped)'\(context.io.eol)")
            }
            if !errors.isEmpty {
                throw CLIError(errors.joined(separator: "\n"))
            }
        }
    }

    /// Complete handler registry binding every command in `CLICommands.Commands`.
    public static func boundHandlers() -> [CLIFramework.Runtime.BoundHandler] {
        CLIFramework.Runtime.handlers(
            Commands,
            .branch(
                selfHandler: { runDefault },
                children: [
                    "upgrade": .sync(runUpgrade),
                    "uninstall": .sync(runUninstall),
                    "acp": .sync(runACP),
                    "api": .sync(API.run),
                    "auth": .branch(selfHandler: nil, children: [
                        "list": .sync(Auth.runList),
                        "login": .sync(Auth.runLogin),
                        "logout": .sync(Auth.runLogout),
                        "export": .sync(Auth.runExport),
                        "import": .sync(Auth.runImport),
                        "switch": .sync(Auth.runSwitch),
                    ]),
                    "debug": .branch(selfHandler: nil, children: [
                        "agents": .sync(Debug.runAgents),
                        "config": .sync(Debug.runConfig),
                        "heap-dump": .sync(Debug.runHeapDump),
                        "paths": .sync(Debug.runPaths),
                    ]),
                    "mcp": .branch(selfHandler: nil, children: [
                        "list": .sync(MCP.runList),
                        "add": .sync(MCP.runAdd),
                        "auth": .sync(MCP.runAuth),
                        "logout": .sync(MCP.runLogout),
                    ]),
                    "plugin": .branch(selfHandler: nil, children: [
                        "list": .sync(Plugin.runList),
                        "add": .sync(Plugin.runAdd),
                        "check": .sync(Plugin.runCheck),
                        "update": .sync(Plugin.runUpdate),
                        "remove": .sync(Plugin.runRemove),
                    ]),
                    "models": .sync(runModels),
                    "stats": .sync(Stats.run),
                    "mini": .sync(runMini),
                    "run": .sync(runCommand),
                    "pair": .sync(Pair.run),
                    "reload": .sync(runReload),
                    "session": .branch(selfHandler: nil, children: [
                        "list": .sync(Session.runList),
                        "delete": .sync(Session.runDelete),
                        "export": .sync(Session.runExport),
                        "import": .sync(Session.runImport),
                    ]),
                    "service": .branch(selfHandler: nil, children: [
                        "start": .sync(ServiceCmd.runStart),
                        "restart": .sync(ServiceCmd.runRestart),
                        "status": .sync(ServiceCmd.runStatus),
                        "stop": .sync(ServiceCmd.runStop),
                        "get": .sync(ServiceCmd.runGet),
                        "set": .sync(ServiceCmd.runSet),
                        "unset": .sync(ServiceCmd.runUnset),
                    ]),
                    "serve": .sync(runServe),
                ]
            )
        )
    }
}

// MARK: - Top-Level CLI Entrypoint (`packages/cli/src/index.ts`)

public enum CLIEntrypoint {
    /// Merges loopback hosts into `NO_PROXY` / `no_proxy` matching `packages/cli/src/index.ts`.
    public static func mergedNoProxy(
        upper: String?,
        lower: String?
    ) -> String {
        var seen: Set<String> = []
        var entries: [String] = []
        for source in [upper, lower, "127.0.0.1,localhost,::1"] {
            guard let source else { continue }
            for raw in source.split(separator: ",") {
                let item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !item.isEmpty && seen.insert(item).inserted {
                    entries.append(item)
                }
            }
        }
        return entries.joined(separator: ",")
    }

    /// Executes the OpenCode CLI for `arguments` in the supplied `context`, returning the process exit code.
    public static func run(
        arguments: [String],
        context: CLIContext = CLIContext()
    ) async -> Int32 {
        // Ensure loopback requests bypass HTTP proxies
        let noProxy = mergedNoProxy(
            upper: context.envVariable("NO_PROXY"),
            lower: context.envVariable("no_proxy")
        )
        context.setEnvOverride("NO_PROXY", value: noProxy)
        context.setEnvOverride("no_proxy", value: noProxy)

        // OpenSSH askpass short-circuit (runs outside normal CLI observability)
        if let port = context.envVariable("OPENCODE_SSH_ASKPASS_PORT"), !port.isEmpty {
            return await CLIUtil.SSHAskpass.askpass(context, nil)
        }

        let heapListener = CLIUtil.Heap.listen(context)
        let cpuListener = CLIUtil.CpuProfile.listen(context)
        let deadlineGuard = CLIUtil.ShutdownDeadline.install(CLIUtil.ShutdownDeadline.DEADLINE, context, nil)
        defer {
            heapListener.stop()
            cpuListener.stop()
            deadlineGuard.release()
        }

        do {
            try await CLIFramework.Runtime.run(
                CLICommands.Commands,
                handlers: CLICommands.boundHandlers(),
                options: CLIFramework.Runtime.RunOptions(
                    version: context.version,
                    globalFlags: [CLICommands.PrintLogs]
                ),
                arguments: arguments,
                context: context
            )
            return context.exitCode.value
        } catch let err as CLIError {
            context.io.writeStderr(err.message + context.io.eol)
            return err.exitCode
        } catch {
            context.io.writeStderr(CLIUtil.errorMessage(error) + context.io.eol)
            return 1
        }
    }

    /// Process entrypoint invoked by `Sources/OpenCodeCLI/main.swift`.
    public static func main() async -> Never {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let context = CLIContext(
            io: .system,
            rawArguments: arguments
        )
        let code = await run(arguments: arguments, context: context)
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        exit(code)
        #else
        fatalError("CLI exited with code \(code)")
        #endif
    }
}

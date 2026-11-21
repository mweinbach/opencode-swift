#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Built-In Core Tools Part A (file-diff, read, write, edit, patch, glob, grep, shell)

extension CoreTool {
    /// Dependencies container wiring built-in tools to injectable cross-platform services.
    public struct BuiltinEnvironment: Sendable {
        public let directory: String
        public let projectID: ProjectID
        public let globalPaths: Global.Interface
        public let fileSystem: any OpenCodeFileSystem
        public let environment: any CoreLocation.Environment.Interface
        public let machines: (any Machines.Interface)?
        public let fileAccess: any CoreFilesystem.FileAccess.Interface
        public let fileMutation: any CoreFilesystem.FileMutation.Interface
        public let fileWrite: any CoreFilesystem.FileWrite.Interface
        public let ripgrep: any CoreRipgrep.Interface
        public let formatter: any CoreFormatter.Interface
        public let permission: any CorePermission.Interface
        public let shell: any CoreShell.Interface
        public let shellSelect: any CoreShell.Select.Interface
        public let toolOutput: any CoreToolOutput.Interface
        public let httpTransport: (any HTTPTransport)?
        public let artifact: (any CoreArtifact.Interface)?
        public let flags: any CoreFlag.Interface
        public let webSearch: (any CoreIntegration.WebSearch.Interface)?
        public let form: (any CoreIntegration.Form.Interface)?
        public let session: CoreSession.Service?
        public let sessionMove: CoreSessionMove.Service?
        public let sessionStore: CoreSessionStore.Service?
        public let sessionSearch: (any SessionSearch.Interface)?
        public let skill: (any CoreSkill.Interface)?
        public let automation: (any CoreAutomation.Interface)?
        public let mcp: (any CoreMCP.Registry.Interface)?
        public let worktree: (any CoreWorktree.Interface)?
        public let worktreeStrategies: (any CoreWorktree.Strategies.Interface)?
        public let model: (any CoreModel.Model.Interface)?
        public let provider: (any CoreProvider.Provider.Interface)?
        public let agent: (any CoreAgent.Agent.Interface)?
        public let generate: (any CoreIntegration.Generate.Interface)?
        /// Upstream `flags.resolve(loaded.entries).full_codemode.enabled`, resolved once per registration pass by
        /// `registerAllBuiltins` so the synchronous registrations can read it.
        public var fullCodeMode: Bool = false
        /// Whether the `machines` flag is enabled (`MachineTools.Plugin` registers only then).
        public var machinesEnabled: Bool = false
        /// Whether the `sqlite_fts` flag is enabled (`SessionSearchTools.Plugin` registers only then).
        public var sqliteFts: Bool = false
        /// Whether automations are enabled in config (`AutomationTools.Plugin` registers only then).
        public var automationsEnabled: Bool = true
        /// Whether the `video_generate` flag is on and some video model is available (`VideoGenerateTool` registers
        /// only then). Resolved by `registerAllBuiltins`.
        public var videoGenerate: Bool = false
        public let videoGeneration: (any CoreIntegration.VideoGeneration.Interface)?
        public let blobStore: (any CoreBlobStore.Interface)?
        public let jobs: (any CoreJob.Interface)?
        public let config: (any CoreConfig.Interface)?

        public init(
            directory: String = "/",
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            environment: (any CoreLocation.Environment.Interface)? = nil,
            machines: (any Machines.Interface)? = nil,
            fileAccess: (any CoreFilesystem.FileAccess.Interface)? = nil,
            fileMutation: (any CoreFilesystem.FileMutation.Interface)? = nil,
            fileWrite: (any CoreFilesystem.FileWrite.Interface)? = nil,
            ripgrep: (any CoreRipgrep.Interface)? = nil,
            formatter: (any CoreFormatter.Interface)? = nil,
            permission: any CorePermission.Interface = CorePermission.Service(),
            shell: (any CoreShell.Interface)? = nil,
            shellSelect: any CoreShell.Select.Interface = CoreShell.Select.Service(),
            toolOutput: (any CoreToolOutput.Interface)? = nil,
            httpTransport: (any HTTPTransport)? = URLSessionHTTPTransport.shared,
            artifact: (any CoreArtifact.Interface)? = nil,
            flags: any CoreFlag.Interface = CoreFlag.Service(config: CoreConfig.Test()),
            globalPaths: Global.Interface = Global.make(),
            processes: any AppProcess.Interface = AppProcess.Service(),
            projectID: ProjectID = .global,
            webSearch: (any CoreIntegration.WebSearch.Interface)? = nil,
            form: (any CoreIntegration.Form.Interface)? = nil,
            session: CoreSession.Service? = nil,
            sessionMove: CoreSessionMove.Service? = nil,
            sessionStore: CoreSessionStore.Service? = nil,
            sessionSearch: (any SessionSearch.Interface)? = nil,
            skill: (any CoreSkill.Interface)? = nil,
            automation: (any CoreAutomation.Interface)? = nil,
            mcp: (any CoreMCP.Registry.Interface)? = nil,
            worktree: (any CoreWorktree.Interface)? = nil,
            worktreeStrategies: (any CoreWorktree.Strategies.Interface)? = nil,
            model: (any CoreModel.Model.Interface)? = nil,
            provider: (any CoreProvider.Provider.Interface)? = nil,
            agent: (any CoreAgent.Agent.Interface)? = nil,
            generate: (any CoreIntegration.Generate.Interface)? = nil,
            videoGeneration: (any CoreIntegration.VideoGeneration.Interface)? = nil,
            blobStore: (any CoreBlobStore.Interface)? = nil,
            jobs: (any CoreJob.Interface)? = nil,
            config: (any CoreConfig.Interface)? = nil
        ) {
            let normDir = CoreConfigDiscovery.resolvePath(base: "/", relative: directory)
            let resolvedEnvironment = environment ?? CoreLocation.Environment.local(fileSystem: fileSystem)
            let resolvedAccess = fileAccess ?? CoreFilesystem.FileAccess.Service(
                directory: normDir,
                fileSystem: fileSystem,
                permission: permission,
                home: globalPaths.home,
                environment: resolvedEnvironment,
                flags: flags,
                machines: machines
            )
            let resolvedMutation = fileMutation ?? CoreFilesystem.FileMutation.Service(
                fileSystem: fileSystem,
                access: resolvedAccess
            )
            let resolvedFormatter = formatter ?? CoreFormatter.Service(directory: normDir, processes: processes)
            let resolvedFileWrite = fileWrite ?? CoreFilesystem.FileWrite.Service(
                fileSystem: fileSystem,
                access: resolvedAccess,
                mutation: resolvedMutation,
                permission: permission,
                formatFile: { path in await resolvedFormatter.file(path) }
            )
            let resolvedRipgrep = ripgrep ?? CoreRipgrep.Service(fileSystem: fileSystem)
            let resolvedShell = shell ?? CoreShell.Service(
                directory: normDir,
                projectID: projectID,
                globalPaths: globalPaths,
                fileSystem: fileSystem,
                processes: processes,
                shellSelect: shellSelect,
                environment: resolvedEnvironment
            )
            let resolvedOutput = toolOutput ?? CoreToolOutput.Service(globalPaths: globalPaths, fileSystem: fileSystem)

            self.directory = normDir
            self.projectID = projectID
            self.globalPaths = globalPaths
            self.fileSystem = fileSystem
            self.environment = resolvedEnvironment
            self.machines = machines
            self.fileAccess = resolvedAccess
            self.fileMutation = resolvedMutation
            self.fileWrite = resolvedFileWrite
            self.ripgrep = resolvedRipgrep
            self.formatter = resolvedFormatter
            self.permission = permission
            self.shell = resolvedShell
            self.shellSelect = shellSelect
            self.toolOutput = resolvedOutput
            self.httpTransport = httpTransport
            self.artifact = artifact
            self.flags = flags
            self.webSearch = webSearch
            self.form = form
            self.session = session
            self.sessionMove = sessionMove
            self.sessionStore = sessionStore
            self.sessionSearch = sessionSearch
            self.skill = skill
            self.automation = automation
            self.mcp = mcp
            self.worktree = worktree
            self.worktreeStrategies = worktreeStrategies
            self.model = model
            self.provider = provider
            self.agent = agent
            self.generate = generate
            self.videoGeneration = videoGeneration
            self.blobStore = blobStore
            self.jobs = jobs
            self.config = config
        }
    }

    public struct ToolPluginDescriptor: Sendable {
        public let id: String
        public let register: @Sendable (Editor, BuiltinEnvironment) -> Void

        public init(id: String, register: @escaping @Sendable (Editor, BuiltinEnvironment) -> Void) {
            self.id = id
            self.register = register
        }
    }

    // MARK: - fileDiff (`core/src/tool/plugin/file-diff.ts`)

    /// Computes a unified diff and line addition/deletion counts between `before` and `after`.
    // parity: core/src/tool/plugin/file-diff.ts#fileDiff [status=implemented hash=35838906cbf5]
    public static func fileDiff(
        file: String,
        before: String,
        after: String,
        status: FileDiffSchema.Status = .modified
    ) -> FileDiffSchema.Info {
        CoreFilesystemDiff.compute(file: file, before: before, after: after, status: status)
    }

    // MARK: - ReadTool (`core/src/tool/plugin/read.ts`)

    public enum ReadTool {
        // parity: core/src/tool/plugin/read.ts#name [status=implemented hash=5a4ed57c52b1]
        public static let name: String = "read"

        // parity: core/src/tool/plugin/read.ts#Input [status=implemented hash=48e74f7d934d]
        public struct Input: Equatable, Hashable, Sendable, Codable {
            public let path: String
            public let offset: Int?
            public let limit: Int?

            public init(path: String, offset: Int? = nil, limit: Int? = nil) {
                self.path = path
                self.offset = offset
                self.limit = limit
            }
        }

        public static let inputSchema: AISchema.JsonSchema = [
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string"), "description": .string("File or directory to read")]),
                "offset": .object(["type": .string("integer"), "description": .string("The line or directory entry to start reading from (1-based)")]),
                "limit": .object(["type": .string("integer"), "description": .string("The maximum number of lines or directory entries to read (defaults to and capped at 2000)")]),
            ]),
            "required": .array([.string("path")]),
        ]

        // parity: core/src/tool/plugin/read.ts#toModelContent [status=implemented hash=e62cc56a7dbc]
        public static func toModelContent(
            path: String,
            offset: Int?,
            output: CoreToolOutput.ReadFilesystem.Output
        ) -> ToolSchema.ResultContent {
            switch output {
            case .media(let media):
                let label = media.mime == "application/pdf" ? "PDF read successfully" : "Image read successfully"
                return .parts([
                    .text(ToolSchema.TextContent(text: label)),
                    .file(ToolSchema.FileContent(
                        uri: "data:\(media.mime);base64,\(bytesToBase64(media.bytes))",
                        mime: media.mime,
                        name: path
                    )),
                ])
            case .directory(let dir):
                let start = (offset == nil || offset == 0) ? 1 : offset!
                var lines: [String] = [
                    dir.entries.isEmpty
                        ? "Read directory \(path), 0 entries"
                        : "Read directory \(path), entries \(start)-\(start + dir.entries.count - 1)",
                ]
                lines.append(contentsOf: dir.entries)
                if let next = dir.next {
                    lines.append("[Output truncated. Continue reading with offset: \(next)]")
                }
                return .text(lines.joined(separator: "\n"))
            case .text(let txt):
                let start = txt.offset
                let rawLines: [String] = txt.lineCount == 0
                    ? []
                    : Array(txt.content.split(separator: "\n", omittingEmptySubsequences: false).prefix(txt.lineCount).map(String.init))
                let total = start + rawLines.count - 1
                let pastEnd = offset != nil && start < offset!
                let headerBase = rawLines.isEmpty
                    ? "Read file \(path), 0 lines"
                    : "Read file \(path), lines \(start)-\(total)"
                let pastEndSuffix = pastEnd
                    ? " (offset \(offset!) is past the end; the file has \(total) \(total == 1 ? "line" : "lines"))"
                    : ""
                var lines = [headerBase + pastEndSuffix]
                for (index, line) in rawLines.enumerated() {
                    lines.append("\(start + index): \(line)")
                }
                if let next = txt.next {
                    lines.append("[Output truncated. Continue reading with offset: \(next)]")
                }
                return .text(lines.joined(separator: "\n"))
            }
        }

        /// The tool description; inside Code Mode a read image or PDF is attached to the `execute` result instead of
        /// showing line-numbered text.
        public static func description(codemode: Bool) -> String {
            [
                "Read the contents of a file or directory. Supports text files, images, and PDFs.",
                codemode
                    ? "Reading an image or PDF automatically attaches it to the execute result, even if the program doesn't return or print the media reference."
                    : "Each text line is prefixed by its 1-based line number as <line>: <content>. The prefix is for reference and is not part of the file content. Directory entries are returned one per line.",
                "Use offset and limit to read large files or directories in sections. Prefer one larger read over many small slices, and use grep to find specific content in large files.",
            ].joined(separator: " ")
        }

        // parity: core/src/tool/plugin/read.ts#Plugin [status=adapted hash=5dfa5b9acaf6]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.read") { editor, env in
            editor.add(RegisteredTool(
                name: name,
                description: description(codemode: false),
                inputSchema: inputSchema,
                outputSchema: ["type": .string("object")],
                options: env.fullCodeMode ? ToolSchema.Options(codemode: true, pinned: true) : ToolSchema.Options(codemode: false),
                codemode: env.fullCodeMode ? CodeModeOverrides(description: description(codemode: true)) : nil
            ) { rawInput, context in
                let input = try decodeToolJSON(Input.self, from: rawInput, toolName: name)
                if input.limit == 0 {
                    throw AISchema.ToolFailure(message: "Limit must be a positive integer")
                }
                let requested: CoreFilesystem.FileAccess.Target
                do {
                    requested = try await env.fileAccess.authorizeRead(input.path, context: context, options: nil)
                } catch let err as CorePermission.DeclinedError {
                    throw err
                } catch {
                    throw Runtime.toolFailure("Unable to read \(input.path)")(error)
                }

                let page = CoreToolOutput.ReadFilesystem.PageInput(offset: input.offset, limit: input.limit)
                let readOutput: CoreToolOutput.ReadFilesystem.Output
                var displayPath = input.path
                do {
                    do {
                        readOutput = try await CoreToolOutput.ReadFilesystem.read(
                            files: requested.environment.files,
                            path: requested.absolute,
                            resource: requested.resource,
                            page: page
                        )
                    } catch CoreToolOutput.ReadFilesystem.ReadError.notFound {
                        if let alternate = await alternatePath(for: requested, localID: env.environment.id) {
                            let recovered = try await env.fileAccess.authorizeRead(
                                alternate,
                                context: context,
                                options: CoreFilesystem.FileAccess.ReadOptions(siblingOf: requested)
                            )
                            displayPath = alternate
                            readOutput = try await CoreToolOutput.ReadFilesystem.read(
                                files: recovered.environment.files,
                                path: recovered.absolute,
                                resource: recovered.resource,
                                page: page
                            )
                        } else {
                            let suggestions = await suggestSimilarFiles(
                                for: requested,
                                inputPath: input.path,
                                localID: env.environment.id
                            )
                            let msg = suggestions.isEmpty
                                ? "File not found: \(input.path)"
                                : "File not found: \(input.path)\n\nDid you mean one of these?\n\(suggestions.joined(separator: "\n"))"
                            throw AISchema.ToolFailure(message: msg)
                        }
                    }
                } catch let err as CorePermission.DeclinedError {
                    throw err
                } catch let err as AISchema.ToolFailure {
                    throw err
                } catch let err as CoreToolOutput.ReadFilesystem.BinaryFileError {
                    throw AISchema.ToolFailure(message: err.message)
                } catch let err as CoreToolOutput.ReadFilesystem.MediaIngestLimitError {
                    throw AISchema.ToolFailure(message: err.message)
                } catch let err as CoreToolOutput.ReadFilesystem.PathKindError {
                    throw AISchema.ToolFailure(message: err.message)
                } catch let err as CoreToolOutput.ReadFilesystem.DirectoryOffsetError {
                    throw AISchema.ToolFailure(message: err.message)
                } catch {
                    throw Runtime.toolFailure("Unable to read \(input.path)")(error)
                }

                let structured: JSONValue
                let isTruncated: Bool
                switch readOutput {
                case .text(let t):
                    isTruncated = t.next != nil
                    var obj: [String: JSONValue] = [
                        "type": .string("text"),
                        "content": .string(t.content),
                        "offset": .int(Int64(t.offset)),
                        "lineCount": .int(Int64(t.lineCount)),
                    ]
                    if let next = t.next { obj["next"] = .int(Int64(next)) }
                    structured = .object(obj)
                case .directory(let d):
                    isTruncated = d.next != nil
                    var obj: [String: JSONValue] = [
                        "type": .string("directory"),
                        "entries": .array(d.entries.map { .string($0) }),
                    ]
                    if let next = d.next { obj["next"] = .int(Int64(next)) }
                    structured = .object(obj)
                case .media(let m):
                    isTruncated = false
                    structured = .object([
                        "type": .string("media"),
                        "uri": .string(m.uri),
                        "mime": .string(m.mime),
                        "name": .string(m.name),
                    ])
                }

                return ToolSchema.Result(
                    output: structured,
                    content: toModelContent(path: displayPath, offset: input.offset, output: readOutput),
                    metadata: ["truncated": .bool(isTruncated)]
                )
            })
        }

        private static func canonicalFilename(_ value: String) -> String {
            var out = ""
            out.unicodeScalars.reserveCapacity(value.unicodeScalars.count)
            for scalar in value.precomposedStringWithCanonicalMapping.unicodeScalars {
                switch scalar.value {
                case 0x2018, 0x2019, 0x201A, 0x201B: out.unicodeScalars.append("'")
                case 0x201C, 0x201D, 0x201E, 0x201F: out.unicodeScalars.append("\"")
                case 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212: out.unicodeScalars.append("-")
                case 0x00A0, 0x2002...0x200A, 0x202F, 0x205F, 0x3000: out.unicodeScalars.append(" ")
                default: out.unicodeScalars.append(scalar)
                }
            }
            return out
        }

        private static func alternatePath(
            for target: CoreFilesystem.FileAccess.Target,
            localID: CoreLocation.Environment.ID
        ) async -> String? {
            let remote = target.environment.id != localID
            let folder = remote
                ? CoreFilesystem.FileAccess.posixDirname(target.absolute.rawValue)
                : CoreConfigDiscovery.dirname(target.absolute.rawValue)
            guard let entries = try? await target.environment.files.list(folder) else { return nil }
            let base = canonicalFilename(CoreConfigDiscovery.basename(target.absolute.rawValue))
            let matches = entries.filter { $0.type == .file && canonicalFilename($0.name) == base }
            guard matches.count == 1 else { return nil }
            return remote
                ? CoreFilesystem.FileAccess.posixJoin(folder, matches[0].name)
                : CoreConfigDiscovery.joinPath(folder, matches[0].name)
        }

        private static func suggestSimilarFiles(
            for target: CoreFilesystem.FileAccess.Target,
            inputPath: String,
            localID: CoreLocation.Environment.ID
        ) async -> [String] {
            let remote = target.environment.id != localID
            let folder = remote
                ? CoreFilesystem.FileAccess.posixDirname(target.absolute.rawValue)
                : CoreConfigDiscovery.dirname(target.absolute.rawValue)
            guard let entries = try? await target.environment.files.list(folder) else { return [] }
            let names = entries.map(\.name)
            let requestedRaw = CoreConfigDiscovery.basename(inputPath)
            let name = requestedRaw.lowercased()
            let wanted = stem(name)
            let typos = wanted.count < 3 ? 0 : (wanted.count < 5 ? 1 : 2)
            let inputDir = CoreConfigDiscovery.dirname(inputPath)

            func rank(of candidate: String) -> Int? {
                if candidate == name { return 1 }
                let found = stem(candidate)
                if found == wanted { return 2 }
                if min(found.count, wanted.count) >= 3 &&
                    (candidate.contains(name) || name.contains(candidate) || found.contains(wanted) || wanted.contains(found))
                {
                    return 3
                }
                if typos > 0 && abs(found.count - wanted.count) <= typos && editDistance(found, wanted) <= typos {
                    return 4
                }
                return nil
            }

            let ranked: [(entry: String, rank: Int, distance: Int)] = names.compactMap { entry in
                guard entry != requestedRaw else { return nil }
                let lower = entry.lowercased()
                guard let r = rank(of: lower) else { return nil }
                return (entry: entry, rank: r, distance: editDistance(lower, name))
            }.sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
                return lhs.entry < rhs.entry
            }

            return ranked.prefix(3).map { item in
                inputDir == "." ? item.entry : CoreConfigDiscovery.joinPath(inputDir, item.entry)
            }
        }

        private static func stem(_ name: String) -> String {
            guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
            let s = String(name[..<dot])
            return s.isEmpty ? name : s
        }

        private static func editDistance(_ a: String, _ b: String) -> Int {
            let aChars = Array(a)
            let bChars = Array(b)
            var previous = Array(0...bChars.count)
            for i in 1...max(1, aChars.count) where i <= aChars.count {
                var current = Array(repeating: 0, count: bChars.count + 1)
                current[0] = i
                for j in 1...max(1, bChars.count) where j <= bChars.count {
                    let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                    current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                }
                previous = current
            }
            return previous[bChars.count]
        }
    }

    // MARK: - WriteTool (`core/src/tool/plugin/write.ts`)

    public enum WriteTool {
        // parity: core/src/tool/plugin/write.ts#name [status=implemented hash=6db2bcc94bcb]
        public static let name: String = "write"

        // parity: core/src/tool/plugin/write.ts#Input [status=implemented hash=7009b8f3e6e2]
        public struct Input: Equatable, Hashable, Sendable, Codable {
            public let path: String
            public let content: String

            public init(path: String, content: String) {
                self.path = path
                self.content = content
            }
        }

        // parity: core/src/tool/plugin/write.ts#Output [status=implemented hash=3ddde6b147f4]
        public typealias Output = String

        public static let inputSchema: AISchema.JsonSchema = [
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string"), "description": .string("Path to the file to write to")]),
                "content": .object(["type": .string("string"), "description": .string("Content to write to the file")]),
            ]),
            "required": .array([.string("path"), .string("content")]),
        ]

        // parity: core/src/tool/plugin/write.ts#Plugin [status=adapted hash=3fef41f3de71]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.write") { editor, env in
            editor.add(RegisteredTool(
                name: name,
                description: "Writes a file to the local filesystem, overwriting if one exists.\n\nMissing parent directories are created automatically.\n\nUse this tool to create new files or overwrite existing files. For partial changes, use the edit tool instead.",
                inputSchema: inputSchema,
                outputSchema: ["type": .string("string")],
                options: env.fullCodeMode
                    ? ToolSchema.Options(permission: "edit", codemode: true, pinned: true)
                    : ToolSchema.Options(permission: "edit", codemode: false),
                codemode: env.fullCodeMode
                    ? CodeModeOverrides(description: "Create a new file or overwrite an existing file on the local filesystem, creating missing parent directories automatically. Prefer `edit` for partial changes to existing files.")
                    : nil
            ) { rawInput, context in
                let input = try decodeToolJSON(Input.self, from: rawInput, toolName: name)
                do {
                    let written = try await env.fileWrite.write(
                        CoreFilesystem.FileWrite.WriteInput(path: input.path, content: input.content),
                        context: context
                    )
                    let msg = "\(written.existed ? "Wrote" : "Created") file successfully: \(written.resource)"
                    return ToolSchema.Result(output: .string(msg), content: .text(msg))
                } catch let err as CorePermission.DeclinedError {
                    throw err
                } catch {
                    throw Runtime.toolFailure("Unable to write \(input.path)")(error)
                }
            })
        }
    }

    // MARK: - EditTool (`core/src/tool/plugin/edit.ts`)

    public enum EditTool {
        // parity: core/src/tool/plugin/edit.ts#name [status=implemented hash=b20e3c6061b6]
        public static let name: String = "edit"

        // parity: core/src/tool/plugin/edit.ts#Input [status=implemented hash=ec673face672]
        public struct Input: Equatable, Hashable, Sendable, Codable {
            public let path: String
            public let oldString: String
            public let newString: String
            public let replaceAll: Bool?

            public init(path: String, oldString: String, newString: String, replaceAll: Bool? = nil) {
                self.path = path
                self.oldString = oldString
                self.newString = newString
                self.replaceAll = replaceAll
            }
        }

        // parity: core/src/tool/plugin/edit.ts#Output [status=implemented hash=3ddde6b147f4]
        public typealias Output = String

        public static let inputSchema: AISchema.JsonSchema = [
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string"), "description": .string("File to edit")]),
                "oldString": .object(["type": .string("string"), "description": .string("Exact text to find and replace")]),
                "newString": .object(["type": .string("string"), "description": .string("Text to replace oldString with (must differ from oldString)")]),
                "replaceAll": .object(["type": .string("boolean"), "description": .string("Whether to replace every occurrence of oldString. When false, oldString must match exactly once. Defaults to false.")]),
            ]),
            "required": .array([.string("path"), .string("oldString"), .string("newString")]),
        ]

        /// Upstream `FileMutation.InvalidUtf8Error.message`: decoding would replace every invalid byte with U+FFFD.
        static let invalidUtf8Message =
            "file is not valid UTF-8. It was left unchanged because rewriting it as text would replace every byte that is not UTF-8 with U+FFFD; change it with a tool that preserves its bytes, or convert it to UTF-8 first"

        static func isValidUTF8(_ bytes: [UInt8]) -> Bool {
            String(decoding: bytes, as: UTF8.self).utf8.elementsEqual(bytes)
        }

        // parity: core/src/tool/plugin/edit.ts#Plugin [status=adapted hash=c7949b603e17]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.edit") { editor, env in
            editor.add(RegisteredTool(
                name: name,
                description: "Edit the contents of a file by finding and replacing exact text. If there is no exact match, retries ignoring typographic quote, dash, and space variants, then trailing whitespace on each line. By default oldString must match uniquely unless replaceAll is true.",
                inputSchema: inputSchema,
                outputSchema: ["type": .string("string")],
                options: env.fullCodeMode
                    ? ToolSchema.Options(permission: "edit", codemode: true, pinned: true)
                    : ToolSchema.Options(permission: "edit", codemode: false),
                codemode: env.fullCodeMode
                    ? CodeModeOverrides(description: "Edit a file by replacing `oldString` with `newString` (must differ). Preserve exact indentation without line-number prefixes. Use `\\n` for line breaks; existing LF/CRLF endings are preserved unless `oldString` and `newString` differ only in `\\r`. `oldString` must match once unless `replaceAll` is true; add context to disambiguate.")
                    : nil
            ) { rawInput, context in
                let input = try decodeToolJSON(Input.self, from: rawInput, toolName: name)
                if input.oldString == input.newString {
                    throw AISchema.ToolFailure(message: "No changes to apply: oldString and newString are identical")
                }
                do {
                    return try await env.fileMutation.withLock([CoreFilesystem.FileMutation.LockTarget.path(input.path)]) {
                        let target = try await env.fileWrite.target(input.path, context: context)
                        // Read text that will be rewritten; decoding replaces invalid bytes with U+FFFD, so refuse those files.
                        let current: BomSplitResult
                        do {
                            current = try await CoreFilesystem.FileMutation.readEditableText(
                                files: target.environment.files,
                                target: target.absolute.rawValue
                            )
                        } catch is CoreLocation.Environment.Files.NotFound {
                            throw AISchema.ToolFailure(message: "File not found: \(input.path)")
                        } catch let err as CoreFilesystem.FileMutation.InvalidUtf8Error {
                            throw AISchema.ToolFailure(message: "Unable to edit \(input.path): \(err.message)")
                        } catch let err as CoreLocation.Environment.Files.WrongKind {
                            if err.actual == .directory {
                                throw AISchema.ToolFailure(message: "Path is a directory, not a file: \(input.path)")
                            }
                            throw Runtime.toolFailure("Unable to edit \(input.path)")(err)
                        }

                        let source = current.text
                        let nextText: String
                        let matchCount: Int
                        if input.oldString.isEmpty {
                            nextText = input.newString
                            matchCount = 1
                        } else {
                            let applied = try applyEdit(
                                source: source,
                                oldString: input.oldString,
                                newString: input.newString,
                                replaceAll: input.replaceAll ?? false
                            )
                            nextText = applied.result
                            matchCount = applied.count
                        }

                        let preview = CoreTool.fileDiff(file: target.resource, before: source, after: nextText, status: .modified)
                        try await env.fileWrite.authorize(target, context: context, preview: preview)

                        let written = try await env.fileWrite.commit(target, content: nextText)
                        let finalAfter = written.formatted ?? nextText
                        let finalDiff = CoreTool.fileDiff(file: target.resource, before: source, after: finalAfter, status: .modified)
                        let msg = "Edited \(target.resource) (\(matchCount) replacement\(matchCount == 1 ? "" : "s"))"
                        var meta: [String: JSONValue] = ["replacements": .int(Int64(matchCount))]
                        if let encoded = try? JSONEncoder().encode([finalDiff]),
                           let jsonVal = try? JSONDecoder().decode(JSONValue.self, from: encoded)
                        {
                            meta["files"] = jsonVal
                        }
                        return ToolSchema.Result(output: .string(msg), content: .text(msg), metadata: meta)
                    }
                } catch let err as CorePermission.DeclinedError {
                    throw err
                } catch let err as AISchema.ToolFailure {
                    throw err
                } catch {
                    throw Runtime.toolFailure("Unable to edit \(input.path)")(error)
                }
            })
        }

        private static func normalizeForMatch(_ value: String) -> String {
            var out = ""
            out.unicodeScalars.reserveCapacity(value.unicodeScalars.count)
            for scalar in value.unicodeScalars {
                switch scalar.value {
                case 0x2018, 0x2019, 0x201A, 0x201B: out.unicodeScalars.append("'")
                case 0x201C, 0x201D, 0x201E, 0x201F: out.unicodeScalars.append("\"")
                case 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212: out.unicodeScalars.append("-")
                case 0x00A0, 0x2002...0x200A, 0x202F, 0x205F, 0x3000: out.unicodeScalars.append(" ")
                default: out.unicodeScalars.append(scalar)
                }
            }
            return out
        }

        private static func applyEdit(
            source: String,
            oldString: String,
            newString: String,
            replaceAll: Bool
        ) throws -> (result: String, count: Int) {
            let usesCRLF = source.contains("\r\n") && !oldString.contains("\r\n")
            let lfSource = source.replacing("\r\n", with: "\n")
            let lfOld = oldString.replacing("\r\n", with: "\n")
            let lfNew = newString.replacing("\r\n", with: "\n")

            // Tier 1: exact match on LF view
            var ranges = findAllRanges(in: lfSource, of: lfOld)

            // Tier 2: typographic quote/dash/space normalization
            if ranges.isEmpty {
                let normSrc = normalizeForMatch(lfSource)
                let normOld = normalizeForMatch(lfOld)
                let normRanges = findAllRanges(in: normSrc, of: normOld)
                if !normRanges.isEmpty {
                    let srcChars = Array(lfSource)
                    let normChars = Array(normSrc)
                    if srcChars.count == normChars.count {
                        ranges = normRanges.map { r in
                            let startOff = normSrc.distance(from: normSrc.startIndex, to: r.lowerBound)
                            let endOff = normSrc.distance(from: normSrc.startIndex, to: r.upperBound)
                            return lfSource.index(lfSource.startIndex, offsetBy: startOff)..<lfSource.index(lfSource.startIndex, offsetBy: endOff)
                        }
                    }
                }
            }

            // Tier 3: line-by-line trailing whitespace trimmed + normalized
            if ranges.isEmpty {
                ranges = findLineTrimmedRanges(in: lfSource, matching: lfOld)
            }

            if ranges.isEmpty {
                throw AISchema.ToolFailure(message: "oldString not found in content")
            }
            if !replaceAll && ranges.count > 1 {
                throw AISchema.ToolFailure(
                    message: "Found \(ranges.count) matches for oldString. Provide more surrounding context to make it unique or set replaceAll to true."
                )
            }

            var updated = lfSource
            let toReplace = replaceAll ? ranges : [ranges[0]]
            for range in toReplace.reversed() {
                updated.replaceSubrange(range, with: lfNew)
            }
            let finalText = usesCRLF ? updated.replacing("\n", with: "\r\n") : updated
            return (finalText, toReplace.count)
        }

        private static func findAllRanges(in text: String, of needle: String) -> [Range<String.Index>] {
            guard !needle.isEmpty else { return [] }
            var out: [Range<String.Index>] = []
            var cursor = text.startIndex
            while cursor < text.endIndex, let r = text.range(of: needle, range: cursor..<text.endIndex) {
                out.append(r)
                cursor = r.upperBound
            }
            return out
        }

        private static func findLineTrimmedRanges(in source: String, matching search: String) -> [Range<String.Index>] {
            let trailingNL = search.hasSuffix("\n")
            var expected = search.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if trailingNL && !expected.isEmpty { expected.removeLast() }
            guard !expected.isEmpty else { return [] }

            struct LineSlice {
                let start: String.Index
                let contentEnd: String.Index
                let fullEnd: String.Index
                let text: String
                let hasNewline: Bool
            }

            var lines: [LineSlice] = []
            var idx = source.startIndex
            while idx < source.endIndex {
                if let nl = source[idx...].firstIndex(of: "\n") {
                    let next = source.index(after: nl)
                    lines.append(LineSlice(start: idx, contentEnd: nl, fullEnd: next, text: String(source[idx..<nl]), hasNewline: true))
                    idx = next
                } else {
                    lines.append(LineSlice(start: idx, contentEnd: source.endIndex, fullEnd: source.endIndex, text: String(source[idx...]), hasNewline: false))
                    break
                }
            }

            func trimEnd(_ s: String) -> String {
                var end = s.endIndex
                while end > s.startIndex {
                    let prev = s.index(before: end)
                    if s[prev] == " " || s[prev] == "\t" { end = prev } else { break }
                }
                return String(s[..<end])
            }

            let normExpected = expected.map { normalizeForMatch(trimEnd($0)) }
            var matches: [Range<String.Index>] = []
            var i = 0
            while i + expected.count <= lines.count {
                var ok = true
                for k in 0..<expected.count {
                    if normalizeForMatch(trimEnd(lines[i + k].text)) != normExpected[k] {
                        ok = false
                        break
                    }
                }
                if ok {
                    let last = lines[i + expected.count - 1]
                    if !trailingNL || last.hasNewline {
                        let end = trailingNL ? last.fullEnd : last.contentEnd
                        matches.append(lines[i].start..<end)
                        i += expected.count
                        continue
                    }
                }
                i += 1
            }
            return matches
        }
    }

    // MARK: - PatchTool (`core/src/tool/plugin/patch.ts`)

    public enum PatchTool {
        // parity: core/src/tool/plugin/patch.ts#name [status=implemented hash=8f409e0bcf21]
        public static let name: String = "patch"

        // parity: core/src/tool/plugin/patch.ts#Input [status=implemented hash=60946eabb601]
        public struct Input: Equatable, Hashable, Sendable, Codable {
            public let patchText: String

            public init(patchText: String) {
                self.patchText = patchText
            }
        }

        // parity: core/src/tool/plugin/patch.ts#Output [status=implemented hash=95ff2cf55271]
        public typealias Output = [String: JSONValue]

        public static let inputSchema: AISchema.JsonSchema = [
            "type": .string("object"),
            "properties": .object([
                "patchText": .object(["type": .string("string"), "description": .string("The full patch text that describes all changes to be made")]),
            ]),
            "required": .array([.string("patchText")]),
        ]

        private enum PreparedChange: Sendable {
            case add(target: CoreFilesystem.FileAccess.Target, content: String, before: String, after: String)
            case delete(target: CoreFilesystem.FileAccess.Target, before: String)
            case update(
                target: CoreFilesystem.FileAccess.Target,
                moveTarget: CoreFilesystem.FileAccess.Target?,
                content: String,
                before: String,
                after: String
            )

            var primaryTarget: CoreFilesystem.FileAccess.Target {
                switch self {
                case .add(let t, _, _, _): return t
                case .delete(let t, _): return t
                case .update(let t, _, _, _, _): return t
                }
            }
        }

        // parity: core/src/tool/plugin/patch.ts#Plugin [status=adapted hash=4a68fd40de12]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.patch") { editor, env in
            // Which editing tools a model sees (patch vs edit/write) is `ModelPolicy.modelTools`, not a session hook.
            editor.add(RegisteredTool(
                name: name,
                description: "Apply a multi-file patch in `*** Begin Patch` / `*** End Patch` format supporting `*** Add File:`, `*** Update File:` (with optional `*** Move to:`), and `*** Delete File:` hunks.",
                inputSchema: inputSchema,
                outputSchema: ["type": .string("object")],
                options: env.fullCodeMode
                    ? ToolSchema.Options(permission: "edit", codemode: true, pinned: true)
                    : ToolSchema.Options(permission: "edit", codemode: false),
                codemode: env.fullCodeMode
                    ? CodeModeOverrides(description: "Apply multi-file edits inside `*** Begin Patch` ... `*** End Patch`. Start each operation with `*** Add File: <path>` (every content line prefixed with `+`), `*** Delete File: <path>`, or `*** Update File: <path>` (optional `*** Move to: <path>`, then `@@ [context]` hunks with space/`-`/`+` line prefixes).")
                    : nil
            ) { rawInput, context in
                let input = try decodeToolJSON(Input.self, from: rawInput, toolName: name)
                guard !input.patchText.isEmpty else {
                    throw AISchema.ToolFailure(message: "patchText is required")
                }
                let hunks: [Patch.Hunk]
                switch Patch.parse(input.patchText) {
                case .failure(let err):
                    throw AISchema.ToolFailure(message: "patch verification failed: \(err.message)")
                case .success(let parsed):
                    hunks = parsed
                }
                if hunks.isEmpty {
                    throw AISchema.ToolFailure(message: "patch rejected: empty patch")
                }

                var lockTargets: [CoreFilesystem.FileMutation.LockTarget] = []
                for hunk in hunks {
                    switch hunk {
                    case .add(let p, _), .delete(let p):
                        lockTargets.append(.path(p))
                    case .update(let p, let movePath, _):
                        lockTargets.append(.path(p))
                        if let movePath {
                            lockTargets.append(.path(movePath))
                        }
                    }
                }

                do {
                    return try await env.fileMutation.withLock(lockTargets) {
                        var prepared: [PreparedChange] = []
                        var virtualUpdates: [String: (target: CoreFilesystem.FileAccess.Target, content: String?)] = [:]

                        func resolveTarget(_ path: String) async throws -> CoreFilesystem.FileAccess.Target {
                            let t = try await env.fileAccess.resolve(CoreFilesystem.FileAccess.ResolveInput(path: path, kind: .file))
                            if let ext = t.externalDirectory {
                                try await env.fileAccess.authorizeExternal(
                                    [t],
                                    context: context,
                                    metadata: [
                                        "filepath": .string(t.absolute.rawValue),
                                        "parentDir": .string(ext.directory.rawValue),
                                    ]
                                )
                            }
                            return t
                        }

                        for hunk in hunks {
                            switch hunk {
                            case .add(let path, let rawContents):
                                let target = try await resolveTarget(path)
                                let fileKey = CoreFilesystem.FileAccess.key(target)
                                let content = (rawContents.isEmpty || rawContents.hasSuffix("\n")) ? rawContents : "\(rawContents)\n"
                                let after = Bom.split(content).text
                                prepared.append(.add(target: target, content: content, before: "", after: after))
                                virtualUpdates[fileKey] = (target: target, content: content)

                            case .delete(let path):
                                let target = try await resolveTarget(path)
                                let fileKey = CoreFilesystem.FileAccess.key(target)
                                let before: String
                                if let tracked = virtualUpdates[fileKey] {
                                    guard let existing = tracked.content else {
                                        throw AISchema.ToolFailure(message: "patch verification failed: Failed to delete \(target.resource): file does not exist")
                                    }
                                    before = Bom.split(existing).text
                                } else {
                                    do {
                                        let bytes = try await target.environment.files.read(target.absolute.rawValue, range: nil).bytes
                                        before = Bom.decodeBytes(bytes).text
                                    } catch {
                                        if let machine = CoreSessionErrorMapping.machineMessage(error) {
                                            throw AISchema.ToolFailure(message: machine, error: .string(String(describing: error)), cause: error)
                                        }
                                        throw AISchema.ToolFailure(
                                            message: "patch verification failed: Failed to delete \(target.resource): \(error)",
                                            cause: error
                                        )
                                    }
                                }
                                prepared.append(.delete(target: target, before: before))
                                virtualUpdates[fileKey] = (target: target, content: nil)

                            case .update(let path, let movePath, let chunks):
                                let target = try await resolveTarget(path)
                                let fileKey = CoreFilesystem.FileAccess.key(target)
                                let original: String
                                if let tracked = virtualUpdates[fileKey] {
                                    guard let existing = tracked.content else {
                                        throw AISchema.ToolFailure(message: "patch verification failed: Failed to read file to update \(target.absolute.rawValue): file does not exist")
                                    }
                                    original = existing
                                } else {
                                    do {
                                        let read = try await CoreFilesystem.FileMutation.readEditableText(
                                            files: target.environment.files,
                                            target: target.absolute.rawValue
                                        )
                                        original = Bom.join(read.text, bom: read.bom)
                                    } catch {
                                        if let machine = CoreSessionErrorMapping.machineMessage(error) {
                                            throw AISchema.ToolFailure(message: machine, error: .string(String(describing: error)), cause: error)
                                        }
                                        throw AISchema.ToolFailure(
                                            message: "patch verification failed: Failed to read file to update \(target.absolute.rawValue): \(error)",
                                            cause: error
                                        )
                                    }
                                }
                                let before = Bom.split(original).text
                                let derived: Patch.FileUpdate
                                do {
                                    derived = try Patch.derive(path: path, chunks: chunks, original: original)
                                } catch {
                                    throw AISchema.ToolFailure(message: "patch verification failed: \(error)")
                                }
                                let resolvedMove = try await movePath.asyncMap { try await resolveTarget($0) }
                                let moveTarget = resolvedMove.flatMap { CoreFilesystem.FileAccess.key($0) != fileKey ? $0 : nil }
                                let next = Patch.joinBom(derived.content, bom: derived.bom)
                                prepared.append(.update(
                                    target: target,
                                    moveTarget: moveTarget,
                                    content: next,
                                    before: before,
                                    after: derived.content
                                ))
                                if let moveTarget {
                                    virtualUpdates[fileKey] = (target: target, content: nil)
                                    virtualUpdates[CoreFilesystem.FileAccess.key(moveTarget)] = (target: moveTarget, content: next)
                                } else {
                                    virtualUpdates[fileKey] = (target: target, content: next)
                                }
                            }
                        }

                        let previewDiffs = prepared.map { Self.makeDiff($0) }
                        var allTargets: [CoreFilesystem.FileAccess.Target] = []
                        var allResources: [String] = []
                        var seenRes: Set<String> = []
                        for change in prepared {
                            let primary = change.primaryTarget
                            allTargets.append(primary)
                            if seenRes.insert(primary.resource).inserted { allResources.append(primary.resource) }
                            if case .update(_, let move?, _, _, _) = change {
                                allTargets.append(move)
                                if seenRes.insert(move.resource).inserted {
                                    allResources.append(move.resource)
                                }
                            }
                        }
                        var savePatterns: [String] = []
                        var seenSave: Set<String> = []
                        for target in allTargets {
                            let pattern = CoreFilesystem.FileAccess.always(target)
                            if seenSave.insert(pattern).inserted { savePatterns.append(pattern) }
                        }

                        let inv = CorePermission.invocation(context)
                        var permMeta: [String: JSONValue] = [
                            "filepath": .string(allResources.joined(separator: ", ")),
                            "diff": .string(previewDiffs.map { "\($0.patch)\n" }.joined()),
                        ]
                        if let encoded = try? JSONEncoder().encode(previewDiffs),
                           let val = try? JSONDecoder().decode(JSONValue.self, from: encoded)
                        {
                            permMeta["files"] = val
                        }
                        try await env.permission.assert(CorePermission.AssertInput(
                            sessionID: inv.sessionID,
                            agent: inv.agent,
                            action: "edit",
                            resources: allResources,
                            save: savePatterns,
                            metadata: permMeta,
                            source: inv.source
                        ))

                        for change in prepared {
                            switch change {
                            case .add(let target, let content, _, _):
                                try await target.environment.files.write(target.absolute.rawValue, bytes: Array(content.utf8))
                            case .delete(let target, _):
                                try await target.environment.files.remove(target.absolute.rawValue)
                            case .update(let target, let moveTarget, let content, _, _):
                                if let moveTarget {
                                    let recased: Bool
                                    if moveTarget.environment.id == target.environment.id,
                                       moveTarget.absolute.rawValue.lowercased() == target.absolute.rawValue.lowercased(),
                                       let srcStat = try? await target.environment.files.stat(target.absolute.rawValue),
                                       srcStat.type == .file,
                                       (try? await moveTarget.environment.files.stat(moveTarget.absolute.rawValue)) != nil
                                    {
                                        recased = true
                                    } else {
                                        recased = false
                                    }
                                    if recased {
                                        try await target.environment.files.write(target.absolute.rawValue, bytes: Array(content.utf8))
                                        try await target.environment.files.move(from: target.absolute.rawValue, to: moveTarget.absolute.rawValue)
                                    } else {
                                        try await moveTarget.environment.files.write(moveTarget.absolute.rawValue, bytes: Array(content.utf8))
                                        try await target.environment.files.remove(target.absolute.rawValue)
                                    }
                                } else {
                                    try await target.environment.files.write(target.absolute.rawValue, bytes: Array(content.utf8))
                                }
                            }
                        }

                        // Format updated targets (remote environments are skipped by `env.formatter.file`).
                        for (_, update) in virtualUpdates where update.content != nil {
                            if await env.formatter.file(update.target) {
                                let bytes = try await update.target.environment.files.read(update.target.absolute.rawValue, range: nil).bytes
                                let currentBom = Bom.decodeBytes(bytes).bom
                                _ = try await CoreFilesystem.FileMutation.syncTextBom(
                                    fileSystem: CoreFilesystem.FileMutation.fileSystem(for: update.target.environment, local: env.fileSystem),
                                    target: update.target.absolute.rawValue,
                                    bom: currentBom
                                )
                            }
                        }

                        let summaryLines = ["Success. Updated the following files:"] + previewDiffs.map { file in
                            let prefix: String
                            switch file.status {
                            case .added: prefix = "A"
                            case .deleted: prefix = "D"
                            case .modified: prefix = "M"
                            }
                            return "\(prefix) \(file.file)"
                        }
                        var resultMeta: [String: JSONValue] = [:]
                        if let encoded = try? JSONEncoder().encode(previewDiffs),
                           let val = try? JSONDecoder().decode(JSONValue.self, from: encoded)
                        {
                            resultMeta["files"] = val
                        }
                        return ToolSchema.Result(
                            output: .object([:]),
                            content: .text(summaryLines.joined(separator: "\n")),
                            metadata: resultMeta
                        )
                    }
                } catch let err as CorePermission.DeclinedError {
                    throw err
                } catch let err as AISchema.ToolFailure {
                    throw err
                } catch {
                    throw Runtime.toolFailure("Unable to apply patch")(error)
                }
            })
        }

        private static func makeDiff(_ change: PreparedChange) -> FileDiffSchema.Info {
            switch change {
            case .add(let target, _, let before, let after):
                return CoreTool.fileDiff(file: target.resource, before: before, after: after, status: .added)
            case .delete(let target, let before):
                return CoreTool.fileDiff(file: target.resource, before: before, after: "", status: .deleted)
            case .update(let target, let moveTarget, _, let before, let after):
                let name = (moveTarget ?? target).resource
                return CoreTool.fileDiff(file: name, before: before, after: after, status: .modified)
            }
        }
    }

    // MARK: - GlobTool (`core/src/tool/plugin/glob.ts`)

    public enum GlobTool {
        // parity: core/src/tool/plugin/glob.ts#name [status=implemented hash=dc4782538050]
        public static let name: String = "glob"

        // parity: core/src/tool/plugin/glob.ts#Input [status=implemented hash=f2ba2b1689cb]
        public struct Input: Equatable, Hashable, Sendable, Codable {
            public let pattern: String
            public let path: String?
            public let hidden: Bool?
            public let limit: Int?

            public init(pattern: String, path: String? = nil, hidden: Bool? = nil, limit: Int? = nil) {
                self.pattern = pattern
                self.path = path
                self.hidden = hidden
                self.limit = limit
            }
        }

        // parity: core/src/tool/plugin/glob.ts#Output [status=implemented hash=9aa2d539ea2e]
        public typealias Output = [FileSystemSchema.Entry]

        public static let inputSchema: AISchema.JsonSchema = [
            "type": .string("object"),
            "properties": .object([
                "pattern": .object(["type": .string("string"), "description": .string("Glob pattern to match files against")]),
                "path": .object(["type": .string("string"), "description": .string("Directory to search. Defaults to the current working directory.")]),
                "hidden": .object(["type": .string("boolean"), "description": .string("Include hidden files and directories (default: false).")]),
                "limit": .object(["type": .string("integer"), "description": .string("Maximum number of matching files to return (default: 100)")]),
            ]),
            "required": .array([.string("pattern")]),
        ]

        // parity: core/src/tool/plugin/glob.ts#toModelContent [status=implemented hash=a5d60a69cb87]
        public static func toModelContent(_ entries: [FileSystemSchema.Entry], truncated: Bool = false) -> String {
            var lines = entries.isEmpty ? ["No files found"] : entries.map(\.path.rawValue)
            if truncated {
                lines.append("")
                lines.append("(Results are truncated: showing first \(entries.count) results. Consider using a more specific path or pattern.)")
            }
            return lines.joined(separator: "\n")
        }

        // parity: core/src/tool/plugin/glob.ts#Plugin [status=adapted hash=15a88bf8fa14]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.glob") { editor, env in
            // Registered whatever full_codemode says; `ModelPolicy.modelTools` hides it under full Code Mode.
            editor.add(RegisteredTool(
                name: name,
                description: "Search file paths using a glob pattern (examples: \"**/*.ts\", \"src/**/*.tsx\").",
                inputSchema: inputSchema,
                outputSchema: ["type": .string("array")],
                options: ToolSchema.Options(codemode: false)
            ) { rawInput, context in
                let input = try decodeToolJSON(Input.self, from: rawInput, toolName: name)
                let searchPath = (input.path == "undefined" || input.path == "null") ? nil : input.path
                let target: CoreFilesystem.FileAccess.Target
                do {
                    target = try await env.fileAccess.resolve(
                        CoreFilesystem.FileAccess.ResolveInput(path: searchPath ?? ".", kind: .directory)
                    )
                } catch {
                    throw Runtime.toolFailure("Unable to find files matching \(input.pattern)")(error)
                }
                if target.environment.id != env.environment.id {
                    throw AISchema.ToolFailure(message: "Search is not available on \(target.environment.id.rawValue) yet.")
                }
                try await env.fileAccess.authorizeExternal([target], context: context, metadata: nil)
                let inv = CorePermission.invocation(context)
                try await env.permission.assert(CorePermission.AssertInput(
                    sessionID: inv.sessionID,
                    agent: inv.agent,
                    action: name,
                    resources: [input.pattern],
                    save: ["*"],
                    metadata: ["root": .string(searchPath ?? ".")],
                    source: inv.source
                ))
                let pathKind = try await CoreToolOutput.Search.pathType(
                    fileSystem: env.fileSystem,
                    absolute: target.absolute.rawValue,
                    display: searchPath ?? "."
                )
                guard pathKind == .directory else {
                    throw AISchema.ToolFailure(message: "Search path is not a directory: \(searchPath ?? ".")")
                }
                let maxResults = input.limit ?? CoreFilesystem.DEFAULT_SEARCH_LIMIT
                let bounded: CoreToolOutput.Search.BoundedResult<FileSystemSchema.Entry>
                do {
                    bounded = try await CoreToolOutput.Search.bounded(limit: maxResults) { lim in
                        try await env.ripgrep.glob(CoreRipgrep.GlobInput(
                            cwd: target.absolute.rawValue,
                            pattern: input.pattern,
                            limit: lim,
                            hidden: input.hidden
                        ))
                    }
                } catch let err as CoreRipgrep.InvalidGlobError {
                    throw AISchema.ToolFailure(message: "Invalid glob in pattern \(err.message)")
                } catch {
                    throw AISchema.ToolFailure(message: "Unable to find files matching \(input.pattern): \(error)")
                }

                let relEntries = bounded.items.map { entry -> FileSystemSchema.Entry in
                    let abs = CoreConfigDiscovery.resolvePath(base: target.absolute.rawValue, relative: entry.path.rawValue)
                    let rel = FSPathUtil.posixRelative(from: env.directory, to: abs)
                    return FileSystemSchema.Entry(path: SchemaPrimitive.RelativePath(rawValue: rel), type: entry.type)
                }
                let absEntries = relEntries.map { entry -> FileSystemSchema.Entry in
                    let abs = CoreConfigDiscovery.resolvePath(base: env.directory, relative: entry.path.rawValue)
                    return FileSystemSchema.Entry(path: SchemaPrimitive.RelativePath(rawValue: abs), type: entry.type)
                }
                let encodedOut = (try? JSONEncoder().encode(relEntries)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .array([])
                return ToolSchema.Result(
                    output: encodedOut,
                    content: .text(toModelContent(absEntries, truncated: bounded.truncated)),
                    metadata: [
                        "count": .int(Int64(relEntries.count)),
                        "truncated": .bool(bounded.truncated),
                    ]
                )
            })
        }
    }

    // MARK: - GrepTool (`core/src/tool/plugin/grep.ts`)

    public enum GrepTool {
        // parity: core/src/tool/plugin/grep.ts#name [status=implemented hash=3a0156dd2d23]
        public static let name: String = "grep"

        // parity: core/src/tool/plugin/grep.ts#Input [status=implemented hash=3cdbcc04052c]
        public struct Input: Equatable, Hashable, Sendable, Codable {
            public let pattern: String
            public let path: String?
            public let include: String?
            public let literal: Bool?
            public let caseSensitive: Bool?
            public let limit: Int?

            public init(
                pattern: String,
                path: String? = nil,
                include: String? = nil,
                literal: Bool? = nil,
                caseSensitive: Bool? = nil,
                limit: Int? = nil
            ) {
                self.pattern = pattern
                self.path = path
                self.include = include
                self.literal = literal
                self.caseSensitive = caseSensitive
                self.limit = limit
            }
        }

        // parity: core/src/tool/plugin/grep.ts#Output [status=implemented hash=f73368c87e76]
        public typealias Output = [FileSystemSchema.Match]

        public static let inputSchema: AISchema.JsonSchema = [
            "type": .string("object"),
            "properties": .object([
                "pattern": .object(["type": .string("string"), "description": .string("Regular expression or literal text to match in file contents.")]),
                "path": .object(["type": .string("string"), "description": .string("File or directory to search. Defaults to the current working directory.")]),
                "include": .object(["type": .string("string"), "description": .string("Glob pattern to filter files (for example, \"*.js\" or \"*.{ts,tsx}\")")]),
                "literal": .object(["type": .string("boolean"), "description": .string("Treat `pattern` as exact text instead of a regular expression (default: false).")]),
                "caseSensitive": .object(["type": .string("boolean"), "description": .string("Use case-sensitive matching (default: true).")]),
                "limit": .object(["type": .string("integer"), "description": .string("Maximum number of matching lines to return (default: 100)")]),
            ]),
            "required": .array([.string("pattern")]),
        ]

        // parity: core/src/tool/plugin/grep.ts#toModelContent [status=implemented hash=6c7f53009a11]
        public static func toModelContent(_ matches: [FileSystemSchema.Match], truncated: Bool = false) -> String {
            var lines = matches.isEmpty ? ["No matches found"] : ["Found \(matches.count) matches"]
            var current = ""
            for match in matches {
                if current != match.entry.path.rawValue {
                    if !current.isEmpty { lines.append("") }
                    current = match.entry.path.rawValue
                    lines.append("\(current):")
                }
                lines.append("  Line \(match.line.rawValue): \(match.text)")
            }
            if truncated {
                lines.append("")
                lines.append("(Results are truncated: showing first \(matches.count) results. Consider using a more specific path or pattern.)")
            }
            return lines.joined(separator: "\n")
        }

        // parity: core/src/tool/plugin/grep.ts#Plugin [status=adapted hash=4a7c569308c7]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.grep") { editor, env in
            // Registered whatever full_codemode says; `ModelPolicy.modelTools` hides it under full Code Mode.
            editor.add(RegisteredTool(
                name: name,
                description: "Search file contents using ripgrep's regular expression syntax or literal text matching. Use it to locate specific code, symbols, or text patterns, and narrow searches with `path` or `include`. Returns matching file paths, line numbers, and line previews.",
                inputSchema: inputSchema,
                outputSchema: ["type": .string("array")],
                options: ToolSchema.Options(codemode: false)
            ) { rawInput, context in
                let input = try decodeToolJSON(Input.self, from: rawInput, toolName: name)
                guard !input.pattern.isEmpty else {
                    throw AISchema.ToolFailure(message: "Pattern must not be empty")
                }
                let target: CoreFilesystem.FileAccess.Target
                do {
                    target = try await env.fileAccess.resolve(
                        CoreFilesystem.FileAccess.ResolveInput(path: input.path ?? ".")
                    )
                } catch {
                    throw Runtime.toolFailure("Unable to grep for \(input.pattern)")(error)
                }
                if target.environment.id != env.environment.id {
                    throw AISchema.ToolFailure(message: "Search is not available on \(target.environment.id.rawValue) yet.")
                }
                try await env.fileAccess.authorizeExternal([target], context: context, metadata: nil)
                let inv = CorePermission.invocation(context)
                try await env.permission.assert(CorePermission.AssertInput(
                    sessionID: inv.sessionID,
                    agent: inv.agent,
                    action: name,
                    resources: [input.pattern],
                    save: ["*"],
                    metadata: ["root": .string(".")],
                    source: inv.source
                ))
                let kind = try await CoreToolOutput.Search.pathType(
                    fileSystem: env.fileSystem,
                    absolute: target.absolute.rawValue,
                    display: input.path ?? "."
                )
                let cwd = kind == .directory ? target.absolute.rawValue : CoreConfigDiscovery.dirname(target.absolute.rawValue)
                let singleFile = kind == .file ? CoreConfigDiscovery.basename(target.absolute.rawValue) : nil
                let maxResults = input.limit ?? CoreFilesystem.DEFAULT_SEARCH_LIMIT

                let bounded: CoreToolOutput.Search.BoundedResult<FileSystemSchema.Match>
                do {
                    bounded = try await CoreToolOutput.Search.bounded(limit: maxResults) { lim in
                        try await env.ripgrep.grep(CoreRipgrep.GrepInput(
                            cwd: cwd,
                            pattern: input.pattern,
                            file: singleFile,
                            include: input.include,
                            literal: input.literal,
                            caseSensitive: input.caseSensitive,
                            limit: lim
                        ))
                    }
                } catch let err as CoreRipgrep.InvalidGlobError {
                    throw AISchema.ToolFailure(message: "Invalid glob in include \(err.message)")
                } catch let err as CoreRipgrep.InvalidPatternError {
                    throw AISchema.ToolFailure(message: "Invalid regex pattern: \(err.message)")
                } catch {
                    throw AISchema.ToolFailure(message: "Unable to grep for \(input.pattern): \(error)")
                }

                let relMatches = bounded.items.map { m -> FileSystemSchema.Match in
                    let abs = CoreConfigDiscovery.resolvePath(base: cwd, relative: m.entry.path.rawValue)
                    let rel = FSPathUtil.posixRelative(from: env.directory, to: abs)
                    return FileSystemSchema.Match(
                        entry: FileSystemSchema.Entry(path: SchemaPrimitive.RelativePath(rawValue: rel), type: m.entry.type),
                        line: m.line,
                        offset: m.offset,
                        text: m.text,
                        submatches: m.submatches
                    )
                }
                let absMatches = relMatches.map { m -> FileSystemSchema.Match in
                    let abs = CoreConfigDiscovery.resolvePath(base: env.directory, relative: m.entry.path.rawValue)
                    return FileSystemSchema.Match(
                        entry: FileSystemSchema.Entry(path: SchemaPrimitive.RelativePath(rawValue: abs), type: m.entry.type),
                        line: m.line,
                        offset: m.offset,
                        text: m.text,
                        submatches: m.submatches
                    )
                }
                let encodedOut = (try? JSONEncoder().encode(relMatches)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .array([])
                return ToolSchema.Result(
                    output: encodedOut,
                    content: .text(toModelContent(absMatches, truncated: bounded.truncated)),
                    metadata: [
                        "matches": .int(Int64(relMatches.count)),
                        "truncated": .bool(bounded.truncated),
                    ]
                )
            })
        }
    }

    // MARK: - ShellTool (`core/src/tool/plugin/shell.ts`)

    public enum ShellTool {
        // parity: core/src/tool/plugin/shell.ts#name [status=implemented hash=4cb375ae7855]
        public static let name: String = "shell"

        // parity: core/src/tool/plugin/shell.ts#DEFAULT_TIMEOUT_MS [status=implemented hash=efc6d7daaa35]
        public static let DEFAULT_TIMEOUT_MS: Int = 2 * 60 * 1_000

        /// The foreground timeout a call from inside Code Mode gets by default.
        public static let CODE_MODE_TIMEOUT_MS: Int = 10 * 60 * 1_000

        /// The tool description. `shell` names the shell commands run with; Code Mode has no background parameter.
        public static func description(shell: String? = nil, codeMode: Bool = false) -> String {
            var parts = ["Execute a shell command and return its output."]
            if let shell { parts.append("Commands run on \(osName) using \(shell).") }
            parts.append(contentsOf: [
                "Quote file paths containing spaces or special characters.",
                "Prefer dedicated tools over shell commands when possible.",
                "When output is large, the full result is saved to a file and a truncated preview is returned.",
                "Rely on automatic truncation unless filtering the output is more useful.",
                "Commands still running after their timeout move to the background.",
            ])
            if !codeMode { parts.append("Background commands return immediately, and you will be notified when they complete.") }
            parts.append("The current session ID is available in the OPENCODE_SESSION_ID environment variable.")
            return parts.joined(separator: " ")
        }

        private static let osName: String = {
            #if os(macOS)
            return "macOS"
            #elseif os(Windows)
            return "Windows"
            #elseif os(Linux)
            return "Linux"
            #else
            return "this platform"
            #endif
        }()

        private static func timeoutDescription(_ foreground: Int) -> String {
            "Optional timeout in milliseconds (default \(foreground)). When it expires, a foreground command moves to the background and a background command is stopped."
        }

        private static let workdirDescription =
            "Working directory to execute the command in. Defaults to the current working directory. When possible, avoid changing directories in the command and set the working directory here instead."

        /// Code Mode input: the direct input without `background`, with the Code Mode default timeout.
        public static let codeModeInputSchema: AISchema.JsonSchema = [
            "type": .string("object"),
            "properties": .object([
                "command": .object(["type": .string("string"), "description": .string("Shell command string to execute")]),
                "workdir": .object(["type": .string("string"), "description": .string(workdirDescription)]),
                "timeout": .object(["type": .string("integer"), "minimum": .int(0), "description": .string(timeoutDescription(CODE_MODE_TIMEOUT_MS))]),
            ]),
            "required": .array([.string("command")]),
        ]

        private static let backgroundInstruction =
            "You will be notified automatically when the command finishes. The notification will include the command's output. Unless the user explicitly asks otherwise, DO NOT poll for completion, even if you need the final result to continue."

        // parity: core/src/tool/plugin/shell.ts#Input [status=implemented hash=5f3c2fd0a542]
        public struct Input: Equatable, Hashable, Sendable, Codable {
            public let command: String
            public let workdir: String?
            public let timeout: Int?
            public let background: Bool?

            public init(command: String, workdir: String? = nil, timeout: Int? = nil, background: Bool? = nil) {
                self.command = command
                self.workdir = workdir
                self.timeout = timeout
                self.background = background
            }
        }

        public static let inputSchema: AISchema.JsonSchema = [
            "type": .string("object"),
            "properties": .object([
                "command": .object(["type": .string("string"), "description": .string("Shell command string to execute")]),
                "workdir": .object(["type": .string("string"), "description": .string(workdirDescription)]),
                "timeout": .object(["type": .string("integer"), "minimum": .int(0), "description": .string(timeoutDescription(DEFAULT_TIMEOUT_MS))]),
                "background": .object(["type": .string("boolean"), "description": .string("Run the command in the background and return immediately (useful for dev servers and long-running builds). You do not need to use '&' at the end of the command when using this parameter. You will be notified when it completes. DO NOT poll for completion.")]),
            ]),
            "required": .array([.string("command")]),
        ]

        // parity: core/src/tool/plugin/shell.ts#backgroundToolResult [status=implemented hash=60ebf03e0320]
        public static func backgroundToolResult(_ info: ShellSchema.Info) -> ToolSchema.Result<JSONValue> {
            var lines = ["Command moved to the background (shell ID: \(info.id.rawValue))."]
            if let pid = info.pid { lines.append("PID: \(pid.rawValue)") }
            lines.append("Output is streaming to: \(info.file)")
            let bgText = lines.joined(separator: "\n")
            var meta: [String: JSONValue] = [
                "shellID": .string(info.id.rawValue),
                "status": .string("running"),
                "truncated": .bool(false),
            ]
            if let pid = info.pid { meta["pid"] = .int(Int64(pid.rawValue)) }
            return ToolSchema.Result(
                output: .object([
                    "shellID": .string(info.id.rawValue),
                    "exitCode": .null,
                    "output": .string(bgText),
                    "outputPath": .string(info.file),
                    "wallTimeSeconds": .double(0),
                ]),
                content: .parts([
                    .text(ToolSchema.TextContent(text: bgText)),
                    .text(ToolSchema.TextContent(text: backgroundInstruction)),
                ]),
                metadata: meta
            )
        }

        // parity: core/src/tool/plugin/shell.ts#reattach [status=adapted hash=01f929ee0d50]
        public static func reattach(
            shell: any CoreShell.Interface,
            info: ShellSchema.Info,
            onCompleted: @escaping @Sendable (CoreShell.ResultHelper.NotificationPayload) async -> Void
        ) async {
            let finalRes = await shell.result(info, waitMs: nil)
            let summary = CoreShell.ResultHelper.output(finalRes)
            let payload = CoreShell.ResultHelper.notification(CoreShell.ResultHelper.NotificationInput(
                shellID: info.id.rawValue,
                command: info.command,
                state: finalRes.info.status == .killed ? "cancelled" : "completed",
                text: summary.output,
                output: summary
            ))
            await onCompleted(payload)
        }

        // parity: core/src/tool/plugin/shell.ts#Plugin [status=adapted hash=886a8bba5686]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.shell") { editor, env in
            // With full_codemode, shell is allowed in Code Mode and pinned so the catalog always lists it.
            editor.add(RegisteredTool(
                name: name,
                description: description(),
                inputSchema: inputSchema,
                outputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "output": .object(["type": .string("string")]),
                        "exitCode": .object(["type": .array([.string("number"), .string("null")])]),
                        "signal": .object(["type": .string("string")]),
                        "outputPath": .object(["type": .string("string")]),
                        "shellID": .object(["type": .string("string")]),
                        "pid": .object(["type": .string("integer")]),
                        "killed": .object([
                            "type": .string("string"),
                            "description": .string("Why the command ended without an exit code, when the reason is known: the machine's worker restarted or lost the process, or the local process daemon stopped"),
                        ]),
                        "wallTimeSeconds": .object(["type": .string("number")]),
                    ]),
                ],
                options: env.fullCodeMode ? ToolSchema.Options(codemode: true, pinned: true) : ToolSchema.Options(codemode: false),
                codemode: env.fullCodeMode
                    ? CodeModeOverrides(description: description(codeMode: true), input: codeModeInputSchema)
                    : nil
            ) { rawInput, context in
                let input = try decodeToolJSON(Input.self, from: rawInput, toolName: name)
                let shellBin = await env.shellSelect.resolve(CoreShell.Select.ResolveInput(priority: .compat))
                // Code Mode input has no background parameter.
                let background = input.background == true && !Runtime.inCodeMode
                // A foreground timeout of 0 falls back to the default, so a call can't block until the command exits.
                let foreground = (input.timeout ?? 0) != 0
                    ? input.timeout!
                    : (Runtime.inCodeMode ? CODE_MODE_TIMEOUT_MS : DEFAULT_TIMEOUT_MS)
                let timeoutMs = background ? (input.timeout ?? 0) : foreground
                // The same default `Shell.create` gives the hooks, so the hook can tell whether one moved it.
                let cwd = input.workdir ?? env.directory
                let info: ShellSchema.Info
                do {
                    let initialTarget = try await env.fileAccess.resolve(
                        CoreFilesystem.FileAccess.ResolveInput(path: cwd, kind: .directory)
                    )
                    info = try await env.shell.create(
                        CoreShell.CreateRequest(
                            command: input.command,
                            cwd: cwd,
                            timeout: timeoutMs,
                            shell: shellBin,
                            metadata: ["sessionID": .string(context.sessionID.rawValue)],
                            toolCall: CoreShell.ToolCall(
                                sessionID: context.sessionID.rawValue,
                                assistantMessageID: context.messageID,
                                callID: context.id.rawValue
                            ),
                            waited: !background,
                            environment: initialTarget.environment
                        )
                    ) { invocation in
                        let target: CoreFilesystem.FileAccess.Target
                        if invocation.cwd == cwd {
                            target = initialTarget
                        } else {
                            let base = initialTarget.environment.id == env.environment.id
                                ? CoreFilesystem.FileAccess.Place(absolute: env.directory, environment: env.environment.id)
                                : initialTarget.place
                            target = try await env.fileAccess.resolve(
                                CoreFilesystem.FileAccess.ResolveInput(path: invocation.cwd, kind: .directory, base: base)
                            )
                        }
                        invocation.cwd = target.absolute.rawValue
                        invocation.env["AGENT"] = "1"
                        invocation.env["OPENCODE"] = "1"
                        invocation.env["AI_AGENT"] = "opencode"
                        invocation.env["OPENCODE_SESSION_ID"] = context.sessionID.rawValue

                        let requests = try await CoreShellPermissions.requests(
                            access: env.fileAccess,
                            input: CoreShellPermissions.RequestInput(
                                command: invocation.command,
                                program: invocation.shell,
                                target: target,
                                local: target.environment.id == env.environment.id
                            )
                        )
                        let inv = CorePermission.invocation(context)
                        for request in requests {
                            try await env.permission.assert(CorePermission.AssertInput(
                                sessionID: inv.sessionID,
                                agent: inv.agent,
                                action: request.action,
                                resources: request.resources,
                                save: request.save,
                                source: inv.source
                            ))
                        }
                        // Approval can outlive the directory, so validate immediately before spawning.
                        let workdirType: CoreLocation.Environment.Files.FileType
                        do {
                            workdirType = try await CoreLocation.Environment.Files.typeFollowing(
                                target.environment.files,
                                path: target.absolute.rawValue
                            )
                        } catch is CoreLocation.Environment.Files.NotFound {
                            let message = target.machine.map {
                                "Working directory does not exist on \($0.rawValue): \(target.absolute.rawValue)"
                            } ?? "Working directory does not exist: \(target.absolute.rawValue)"
                            throw AISchema.ToolFailure(message: message)
                        }
                        guard workdirType == .directory else {
                            throw AISchema.ToolFailure(message: "Working directory is not a directory: \(target.absolute.rawValue)")
                        }
                    }
                } catch let err as CorePermission.DeclinedError {
                    throw err
                } catch let err as AISchema.ToolFailure {
                    throw err
                } catch {
                    throw Runtime.toolFailure("Unable to execute command: \(input.command)")(error)
                }

                await context.progress(["shellID": .string(info.id.rawValue)])

                if background {
                    return backgroundToolResult(info)
                }

                let res = await env.shell.result(info, waitMs: nil)
                let summary = CoreShell.ResultHelper.output(res)
                let endMs = res.info.time.completed ?? Double(Flock.currentEpochMs())
                let wall = max(0, endMs - res.info.time.started) / 1_000.0
                var outObj: [String: JSONValue] = [
                    "output": .string(summary.output),
                    "exitCode": summary.exit.map { .double($0) } ?? .null,
                    "wallTimeSeconds": .double(wall),
                ]
                if let sig = summary.signal { outObj["signal"] = .string(sig) }
                if let killed = summary.killed { outObj["killed"] = .string(killed) }
                if summary.truncated { outObj["outputPath"] = .string(res.info.file) }

                var messages: [ToolSchema.Content] = []
                if !summary.output.isEmpty {
                    messages.append(.text(ToolSchema.TextContent(text: summary.output)))
                }
                if let notice = CoreShell.ResultHelper.notice(summary, timeoutMs: timeoutMs) {
                    messages.append(.text(ToolSchema.TextContent(text: notice)))
                }
                var meta = CoreShell.ResultHelper.metadata(summary)
                meta["status"] = .string("completed")
                return ToolSchema.Result(
                    output: .object(outObj),
                    content: .parts(messages),
                    metadata: meta
                )
            })
        }
    }

    internal static func decodeToolJSON<T: Decodable>(
        _ type: T.Type,
        from value: JSONValue,
        toolName: String
    ) throws -> T {
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AISchema.ToolFailure(message: "Invalid arguments for tool \"\(toolName)\": \(error)")
        }
    }

    internal static func encodeToolJSON<T: Encodable>(_ value: T, fallback: JSONValue = .object([:])) -> JSONValue {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? fallback
    }

    /// Formats Unix epoch milliseconds as UTC ISO-8601 (`YYYY-MM-DDTHH:MM:SS.sssZ`) using pure arithmetic.
    internal static func formatToolISO8601UTC(epochMillis: Int64) -> String {
        let totalSeconds = epochMillis >= 0 ? epochMillis / 1_000 : ((epochMillis - 999) / 1_000)
        let millis = Int(epochMillis - totalSeconds * 1_000)
        let days = totalSeconds >= 0 ? totalSeconds / 86_400 : ((totalSeconds - 86_399) / 86_400)
        let daySeconds = Int(totalSeconds - days * 86_400)
        let hour = daySeconds / 3_600
        let minute = (daySeconds % 3_600) / 60
        let second = daySeconds % 60

        // Howard Hinnant civil-from-days algorithm
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = Int(doy - (153 * mp + 2) / 5 + 1)
        let month = Int(mp + (mp < 10 ? 3 : -9))
        let year = Int(y + (month <= 2 ? 1 : 0))

        func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        func pad3(_ n: Int) -> String { n < 10 ? "00\(n)" : (n < 100 ? "0\(n)" : "\(n)") }
        func pad4(_ n: Int) -> String {
            let s = "\(n)"
            return s.count >= 4 ? s : String(repeating: "0", count: 4 - s.count) + s
        }
        return "\(pad4(year))-\(pad2(month))-\(pad2(day))T\(pad2(hour)):\(pad2(minute)):\(pad2(second)).\(pad3(millis))Z"
    }
}

private extension Optional {
    func asyncMap<U>(_ transform: (Wrapped) async throws -> U) async rethrows -> U? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}

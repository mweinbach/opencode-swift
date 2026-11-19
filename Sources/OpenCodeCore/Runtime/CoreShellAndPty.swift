#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - CoreShell (`core/src/shell/*` + `core/src/shell.ts`)

public enum CoreShell {
    // MARK: - Shell Scanner (`core/src/shell/scan.ts`)

    public enum Scan {
        // parity: core/src/shell/scan.ts#OpaqueReason [status=implemented hash=b4353bfd628a]
        public enum OpaqueReason: String, Equatable, Hashable, Sendable, Codable {
            case commandSubstitution = "command-substitution"
            case compoundCommand = "compound-command"
            case dynamicCommandName = "dynamic-command-name"
            case dynamicExecution = "dynamic-execution"
            case heredoc
            case invalidRedirect = "invalid-redirect"
            case invalidStructure = "invalid-structure"
            case unsupportedEscape = "unsupported-escape"
            case unterminatedEscape = "unterminated-escape"
            case unterminatedQuote = "unterminated-quote"
        }

        public struct Command: Equatable, Hashable, Sendable {
            public let resource: String
            public let words: [String]
            public let rawWords: [String]
            public let declaration: Bool

            public init(resource: String, words: [String], rawWords: [String], declaration: Bool = false) {
                self.resource = resource
                self.words = words
                self.rawWords = rawWords
                self.declaration = declaration
            }
        }

        // parity: core/src/shell/scan.ts#Result [status=implemented hash=28c825e178d8]
        public enum Result: Equatable, Hashable, Sendable {
            case scanned(commands: [Command])
            case opaque(reason: OpaqueReason)
        }

        private static let declarations: Set<String> = [
            "declare", "typeset", "export", "readonly", "local", "unset", "unsetenv",
        ]

        /// Portable shell scanner tokenizing pipelines/lists (`&&`, `||`, `;`, `|`, `\n`), quotes, and escapes.
        public static func scan(_ command: String) -> Result {
            if command.count > 64 * 1024 {
                return .opaque(reason: .invalidStructure)
            }
            var commands: [Command] = []
            var words: [String] = []
            var rawWords: [String] = []
            var current = ""
            var currentRaw = ""
            var hasToken = false

            let chars = Array(command)
            var i = 0

            func flushWord() {
                if hasToken {
                    words.append(current)
                    rawWords.append(currentRaw)
                    current = ""
                    currentRaw = ""
                    hasToken = false
                }
            }

            func flushCommand() {
                flushWord()
                guard !words.isEmpty else { return }
                let resource = rawWords.joined(separator: " ")
                let isDecl = declarations.contains(words[0])
                commands.append(Command(resource: resource, words: words, rawWords: rawWords, declaration: isDecl))
                words.removeAll(keepingCapacity: true)
                rawWords.removeAll(keepingCapacity: true)
            }

            while i < chars.count {
                let c = chars[i]
                if c == " " || c == "\t" {
                    flushWord()
                    i += 1
                    continue
                }
                if c == "#" && !hasToken {
                    while i < chars.count && chars[i] != "\n" { i += 1 }
                    continue
                }
                if c == "\n" || c == ";" {
                    flushCommand()
                    i += 1
                    continue
                }
                if c == "|" || c == "&" {
                    flushCommand()
                    if i + 1 < chars.count && (chars[i + 1] == c || (c == "|" && chars[i + 1] == "&")) {
                        i += 2
                    } else {
                        i += 1
                    }
                    continue
                }
                if c == "'" {
                    hasToken = true
                    currentRaw.append(c)
                    i += 1
                    var closed = false
                    while i < chars.count {
                        let q = chars[i]
                        currentRaw.append(q)
                        i += 1
                        if q == "'" {
                            closed = true
                            break
                        }
                        current.append(q)
                    }
                    if !closed { return .opaque(reason: .unterminatedQuote) }
                    continue
                }
                if c == "\"" {
                    hasToken = true
                    currentRaw.append(c)
                    i += 1
                    var closed = false
                    while i < chars.count {
                        let q = chars[i]
                        currentRaw.append(q)
                        i += 1
                        if q == "\\" && i < chars.count {
                            let next = chars[i]
                            currentRaw.append(next)
                            current.append(next)
                            i += 1
                            continue
                        }
                        if q == "\"" {
                            closed = true
                            break
                        }
                        current.append(q)
                    }
                    if !closed { return .opaque(reason: .unterminatedQuote) }
                    continue
                }
                if c == "\\" {
                    guard i + 1 < chars.count else {
                        return .opaque(reason: .unterminatedEscape)
                    }
                    hasToken = true
                    let next = chars[i + 1]
                    currentRaw.append(c)
                    currentRaw.append(next)
                    if next != "\n" { current.append(next) }
                    i += 2
                    continue
                }
                if c == "`" {
                    return .opaque(reason: .commandSubstitution)
                }
                if c == "$" && i + 1 < chars.count && chars[i + 1] == "(" {
                    return .opaque(reason: .commandSubstitution)
                }
                if c == "<" && i + 1 < chars.count && chars[i + 1] == "<" {
                    return .opaque(reason: .heredoc)
                }
                hasToken = true
                current.append(c)
                currentRaw.append(c)
                i += 1
            }
            flushCommand()
            return .scanned(commands: commands)
        }
    }

    // MARK: - Shell Permission Parser (`core/src/shell/parse.ts`)

    public enum Parse {
        public struct CommandPermission: Equatable, Hashable, Sendable, Codable {
            public let resource: String
            public let save: String

            public init(resource: String, save: String) {
                self.resource = resource
                self.save = save
            }
        }

        // parity: core/src/shell/parse.ts#Result [status=implemented hash=5523f6eb5327]
        public struct Result: Equatable, Hashable, Sendable, Codable {
            public let commands: [CommandPermission]
            public let directories: [String]

            public init(commands: [CommandPermission], directories: [String]) {
                self.commands = commands
                self.directories = directories
            }
        }

        private static let arity: [String: Int] = [
            "cat": 1, "cd": 1, "chmod": 1, "chown": 1, "cp": 1, "echo": 1, "env": 1, "export": 1,
            "grep": 1, "kill": 1, "killall": 1, "ln": 1, "ls": 1, "mkdir": 1, "mv": 1, "ps": 1,
            "pwd": 1, "rm": 1, "rmdir": 1, "sleep": 1, "source": 1, "tail": 1, "touch": 1, "unset": 1, "which": 1,
            "aws": 3, "az": 3, "bazel": 2, "brew": 2, "bun": 2, "bun run": 3, "bun x": 3,
            "cargo": 2, "cargo add": 3, "cargo run": 3, "docker": 2, "docker compose": 3,
            "gh": 3, "git": 2, "git config": 3, "git remote": 3, "git stash": 3,
            "go": 2, "kubectl": 2, "make": 2, "npm": 2, "npm run": 3, "npx": 2,
            "pnpm": 2, "pnpm run": 3, "python": 2, "swift": 2, "terraform": 2, "yarn": 2, "yarn run": 3,
        ]
        private static let cwdBuiltins: Set<String> = ["cd", "chdir", "popd", "pushd", "push-location", "set-location"]

        /// Scans a shell command into permission resources, save patterns, and directory operands (`cd ...`).
        // parity: core/src/shell/parse.ts#scan [status=implemented hash=287327e35c22]
        public static func scan(command: String, shell: String, cwd: String) throws -> Result {
            _ = shell
            let scanned = Scan.scan(command)
            switch scanned {
            case .opaque(let reason):
                throw AppProcess.AppProcessError(
                    command: command,
                    causeMessage: "Portable shell scanner cannot analyze command: \(reason.rawValue)"
                )
            case .scanned(let items):
                var commands: [CommandPermission] = []
                var directories: [String] = []
                for item in items where !item.declaration {
                    guard !item.words.isEmpty else { continue }
                    let head = item.words[0]
                    if cwdBuiltins.contains(head.lowercased()), item.words.count >= 2 {
                        let arg = item.words[1]
                        if !arg.isEmpty && arg != "-" {
                            directories.append(CoreFilesystem.FileAccess.resolvePath(directory: cwd, input: arg))
                        }
                    }
                    let prefixLen = prefixArity(for: item.words)
                    let prefixTokens = Array(item.words.prefix(prefixLen))
                    let save = item.words.count > prefixLen
                        ? "\(prefixTokens.joined(separator: " ")) *"
                        : item.resource
                    commands.append(CommandPermission(resource: item.resource, save: save))
                }
                return Result(commands: commands, directories: directories)
            }
        }

        private static func prefixArity(for words: [String]) -> Int {
            for len in stride(from: min(3, words.count), through: 1, by: -1) {
                let key = words.prefix(len).joined(separator: " ")
                if let n = arity[key] { return n }
            }
            return 1
        }
    }

    // MARK: - Shell Result Formatting (`core/src/shell/result.ts`)

    public enum ResultHelper {
        public struct Capture: Equatable, Hashable, Sendable, Codable {
            public let output: String
            public let truncated: Bool
            public let killed: String?

            public init(output: String, truncated: Bool, killed: String? = nil) {
                self.output = output
                self.truncated = truncated
                self.killed = killed
            }
        }

        // parity: core/src/shell/result.ts#Result [status=implemented hash=cb2c7585cf44]
        public struct Result: Equatable, Hashable, Sendable, Codable {
            public let info: ShellSchema.Info
            public let capture: Capture?

            public init(info: ShellSchema.Info, capture: Capture? = nil) {
                self.info = info
                self.capture = capture
            }
        }

        public struct OutputSummary: Equatable, Hashable, Sendable, Codable {
            public let output: String
            public let truncated: Bool
            public let exit: Double?
            public let signal: String?
            public let timeout: Bool?
            public let killed: String?

            public init(
                output: String,
                truncated: Bool,
                exit: Double? = nil,
                signal: String? = nil,
                timeout: Bool? = nil,
                killed: String? = nil
            ) {
                self.output = output
                self.truncated = truncated
                self.exit = exit
                self.signal = signal
                self.timeout = timeout
                self.killed = killed
            }
        }

        public struct InterruptedSummary: Equatable, Hashable, Sendable, Codable {
            public let output: String
            public let notice: String
            public let message: String

            public init(output: String, notice: String, message: String) {
                self.output = output
                self.notice = notice
                self.message = message
            }
        }

        public struct NotificationPayload: Equatable, Hashable, Sendable, Codable {
            public let text: String
            public let metadata: [String: JSONValue]

            public init(text: String, metadata: [String: JSONValue]) {
                self.text = text
                self.metadata = metadata
            }
        }

        private static let missingText = "Shell command output is no longer available."

        // parity: core/src/shell/result.ts#unavailable [status=implemented hash=d098723b8fc8]
        public static let unavailable = ShellSchema.Output(
            output: missingText,
            cursor: SchemaPrimitive.NonNegativeInt(rawValue: missingText.utf8.count) ?? .zero,
            size: SchemaPrimitive.NonNegativeInt(rawValue: missingText.utf8.count) ?? .zero,
            truncated: false
        )

        // parity: core/src/shell/result.ts#output [status=implemented hash=8d7cfb881199]
        public static func output(_ result: Result) -> OutputSummary {
            OutputSummary(
                output: result.capture?.output ?? unavailable.output,
                truncated: result.capture?.truncated ?? false,
                exit: result.info.exit,
                signal: result.info.signal,
                timeout: result.info.status == .timeout ? true : nil,
                killed: result.capture?.killed
            )
        }

        // parity: core/src/shell/result.ts#interrupted [status=implemented hash=73d52d708a31]
        public static func interrupted(_ result: Result) -> InterruptedSummary {
            let stopping = result.info.status == .running ? "; it is still being stopped" : ""
            let stopped = "Command interrupted by the user (shell ID: \(result.info.id.rawValue))\(stopping)."
            let outText: String
            let noticeText: String
            if let capture = result.capture {
                if capture.truncated {
                    outText = capture.output
                    noticeText = stopped
                } else if capture.output == "(no output)" {
                    outText = ""
                    noticeText = "[no output; output file: \(result.info.file)]\n\n\(stopped)"
                } else {
                    outText = capture.output.hasSuffix("\n") ? String(capture.output.dropLast()) : capture.output
                    noticeText = "[full output saved to \(result.info.file)]\n\n\(stopped)"
                }
            } else {
                outText = unavailable.output
                noticeText = stopped
            }
            let message = outText.isEmpty ? noticeText : "\(outText)\n\n\(noticeText)"
            return InterruptedSummary(output: outText, notice: noticeText, message: message)
        }

        private static let signalNumbers: [String: Int] = [
            "SIGHUP": 1, "SIGINT": 2, "SIGQUIT": 3, "SIGILL": 4, "SIGTRAP": 5, "SIGABRT": 6,
            "SIGKILL": 9, "SIGSEGV": 11, "SIGPIPE": 13, "SIGALRM": 14, "SIGTERM": 15,
        ]

        private static func formatExitCode(exit: Double?, signal: String?) -> String {
            if let exit { return exit == exit.rounded() ? String(Int(exit)) : String(exit) }
            if let signal, let num = signalNumbers[signal] {
                return "\(128 + num) (\(signal))"
            }
            return "unknown"
        }

        // parity: core/src/shell/result.ts#notice [status=implemented hash=ce84bd53dc3c]
        public static func notice(_ output: OutputSummary, timeoutMs: Int? = nil) -> String? {
            if let killed = output.killed { return killed }
            if output.timeout == true {
                let dur = timeoutMs.map { " after \(Double($0) / 1_000.0) seconds" } ?? ""
                return "Command timed out\(dur). If it needs longer and isn't waiting for input, rerun with a larger timeout.\nExit code: \(formatExitCode(exit: output.exit, signal: output.signal))"
            }
            if output.signal != nil || (output.exit != nil && output.exit != 0) {
                return "Exit code: \(formatExitCode(exit: output.exit, signal: output.signal))"
            }
            return nil
        }

        // parity: core/src/shell/result.ts#metadata [status=implemented hash=c5ab40d8e401]
        public static func metadata(_ output: OutputSummary) -> [String: JSONValue] {
            var map: [String: JSONValue] = ["truncated": .bool(output.truncated)]
            if let exit = output.exit { map["exit"] = .double(exit) }
            if let signal = output.signal { map["signal"] = .string(signal) }
            if let timeout = output.timeout { map["timeout"] = .bool(timeout) }
            if output.killed != nil { map["killed"] = .bool(true) }
            return map
        }

        public struct NotificationInput: Equatable, Sendable {
            public let shellID: String
            public let jobID: String?
            public let command: String
            public let state: String
            public let text: String
            public let output: OutputSummary?

            public init(
                shellID: String,
                jobID: String? = nil,
                command: String,
                state: String,
                text: String,
                output: OutputSummary? = nil
            ) {
                self.shellID = shellID
                self.jobID = jobID
                self.command = command
                self.state = state
                self.text = text
                self.output = output
            }
        }

        // parity: core/src/shell/result.ts#notification [status=implemented hash=8e43adf58eb9]
        public static func notification(_ input: NotificationInput) -> NotificationPayload {
            var meta: [String: JSONValue] = [
                "source": .string("shell"),
                "shellID": .string(input.shellID),
                "state": .string(input.state),
            ]
            if let jobID = input.jobID { meta["jobID"] = .string(jobID) }
            if let out = input.output {
                for (k, v) in metadata(out) { meta[k] = v }
            }
            let text = "<shell id=\"\(input.jobID ?? input.shellID)\" state=\"\(input.state)\" command=\"\(input.command)\">\n\(input.text)\n</shell>"
            return NotificationPayload(text: text, metadata: meta)
        }

        // parity: core/src/shell/result.ts#userNotification [status=implemented hash=5575891b542a]
        public static func userNotification(_ result: Result) -> NotificationPayload {
            let captured = output(result)
            let status: String?
            if result.info.status == .killed {
                status = "Cancelled"
            } else if captured.exit == 0 {
                status = nil
            } else {
                status = notice(captured) ?? "Exit code: unknown"
            }
            let parts = [captured.output, status ?? ""].filter { !$0.isEmpty }
            let msg = notification(NotificationInput(
                shellID: result.info.id.rawValue,
                command: result.info.command,
                state: result.info.status == .killed ? "cancelled" : "completed",
                text: parts.joined(separator: "\n\n"),
                output: captured
            ))
            return NotificationPayload(
                text: "The following shell command was executed by the user:\n\(msg.text)",
                metadata: msg.metadata
            )
        }
    }

    // MARK: - Shell Selection (`core/src/shell/select.ts`)

    public enum Select {
        private struct ShellMeta {
            let deny: Bool
            let login: Bool
            let ps: Bool
        }

        private static let metaTable: [String: ShellMeta] = [
            "bash": ShellMeta(deny: false, login: true, ps: false),
            "dash": ShellMeta(deny: false, login: true, ps: false),
            "fish": ShellMeta(deny: true, login: true, ps: false),
            "ksh": ShellMeta(deny: false, login: true, ps: false),
            "nu": ShellMeta(deny: true, login: false, ps: false),
            "powershell": ShellMeta(deny: false, login: false, ps: true),
            "pwsh": ShellMeta(deny: false, login: false, ps: true),
            "sh": ShellMeta(deny: false, login: true, ps: false),
            "zsh": ShellMeta(deny: false, login: true, ps: false),
        ]

        // parity: core/src/shell/select.ts#Item [status=implemented hash=c66a403c51bf]
        public struct Item: Equatable, Hashable, Sendable, Codable {
            public let path: String
            public let name: String
            public let acceptable: Bool

            public init(path: String, name: String, acceptable: Bool) {
                self.path = path
                self.name = name
                self.acceptable = acceptable
            }
        }

        // parity: core/src/shell/select.ts#Options [status=implemented hash=acdbb17d0890]
        public struct Options: Equatable, Hashable, Sendable, Codable {
            public let gitbash: String?

            public init(gitbash: String? = nil) {
                self.gitbash = gitbash
            }
        }

        // parity: core/src/shell/select.ts#Editor [status=adapted hash=467580a73728]
        public final class Editor: @unchecked Sendable {
            public private(set) var shell: String?

            public init(shell: String? = nil) {
                self.shell = shell
            }

            public func configure(_ shell: String) {
                self.shell = shell
            }
        }

        // parity: core/src/shell/select.ts#ResolveInput [status=implemented hash=3f89bf8485b5]
        public struct ResolveInput: Equatable, Hashable, Sendable, Codable {
            public enum Priority: String, Equatable, Hashable, Sendable, Codable {
                case config
                case compat
            }

            public let priority: Priority

            public init(priority: Priority) {
                self.priority = priority
            }
        }

        // parity: core/src/shell/select.ts#Interface [status=adapted hash=d59188bddd87]
        public protocol Interface: Sendable {
            func transform(_ fn: @escaping @Sendable (Editor) -> Void) async -> CoreFilesystem.LocationWatcherPolicy.Registration
            func reload() async
            func resolve(_ input: ResolveInput) async -> String
            func list() async -> [Item]
        }

        // parity: core/src/shell/select.ts#gitbash [status=implemented hash=01cdf21bada6]
        public static func gitbash(_ options: Options? = nil, platform: PlatformOS = Platform.current) -> String? {
            guard platform == .windows else { return nil }
            if let explicit = options?.gitbash, !explicit.isEmpty { return explicit }
            return nil
        }

        // parity: core/src/shell/select.ts#name [status=implemented hash=fac2d7110a10]
        public static func name(_ file: String) -> String {
            let base = CoreConfigDiscovery.basename(file)
            let lowered = base.lowercased()
            if lowered.hasSuffix(".exe") {
                return String(lowered.dropLast(4))
            }
            return lowered
        }

        // parity: core/src/shell/select.ts#login [status=implemented hash=0f3a2685f26d]
        public static func login(_ file: String) -> Bool {
            metaTable[name(file)]?.login == true
        }

        // parity: core/src/shell/select.ts#ps [status=implemented hash=25385bed7349]
        public static func ps(_ file: String) -> Bool {
            metaTable[name(file)]?.ps == true
        }

        /// Builds command-execution arguments for the selected shell (`zsh` disables `nomatch`, PowerShell uses `-Command`, `cmd` uses `/c`).
        // parity: core/src/shell/select.ts#args [status=implemented hash=6b5cde15d369]
        public static func args(_ file: String, command: String) -> [String] {
            let n = name(file)
            if n == "cmd" { return ["/c", command] }
            if ps(file) { return ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command] }
            if n == "zsh" { return ["+o", "nomatch", "-c", command] }
            return ["-c", command]
        }

        private static func isCompatible(_ file: String) -> Bool {
            metaTable[name(file)]?.deny != true
        }

        private static func fallback(platform: PlatformOS = Platform.current) -> String {
            switch platform {
            case .macOS: return "/bin/zsh"
            case .windows: return "cmd.exe"
            default: return "/bin/sh"
            }
        }

        // parity: core/src/shell/select.ts#environment [status=implemented hash=3adcd2f75d35]
        public static func environment(
            compatible: Bool = false,
            env: any EnvironmentProviding = SystemEnvironment.shared,
            platform: PlatformOS = Platform.current
        ) -> String {
            if let shell = env.variable("SHELL"), !shell.isEmpty, (!compatible || isCompatible(shell)) {
                return shell
            }
            return fallback(platform: platform)
        }

        // parity: core/src/shell/select.ts#resolve [status=implemented hash=fd56986eb10c]
        public static func resolve(
            _ input: ResolveInput,
            configShell: String? = nil,
            options: Options? = nil,
            env: any EnvironmentProviding = SystemEnvironment.shared,
            platform: PlatformOS = Platform.current
        ) -> String {
            let compat = input.priority == .compat
            if let configShell, !configShell.isEmpty, (!compat || isCompatible(configShell)) {
                return configShell
            }
            if let gb = gitbash(options, platform: platform) {
                return gb
            }
            return environment(compatible: compat, env: env, platform: platform)
        }

        // parity: core/src/shell/select.ts#list [status=implemented hash=42e327fcce38]
        public static func list(
            options: Options? = nil,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            platform: PlatformOS = Platform.current
        ) async -> [Item] {
            if platform == .windows {
                var candidates: [String] = []
                if let gb = gitbash(options, platform: platform) { candidates.append(gb) }
                candidates.append("cmd.exe")
                return candidates.map { Item(path: $0, name: name($0), acceptable: isCompatible($0)) }
            }
            let rawLines: [String]
            if let bytes = try? await fileSystem.readFile(at: "/etc/shells") {
                let text = String(decoding: bytes, as: UTF8.self)
                rawLines = text.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            } else {
                rawLines = ["/bin/bash", "/bin/zsh", "/bin/sh"]
            }
            var seen: Set<String> = []
            var items: [Item] = []
            for path in rawLines where seen.insert(path).inserted {
                if await fileSystem.exists(at: path) {
                    items.append(Item(path: path, name: name(path), acceptable: isCompatible(path)))
                }
            }
            return items
        }

        // parity: core/src/shell/select.ts#Service [status=adapted hash=25c81d0a00bd]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/ShellSelect"

            private struct State: Sendable {
                var transforms: [UInt64: @Sendable (Editor) -> Void] = [:]
                var order: [UInt64] = []
                var configuredShell: String? = nil
                var nextID: UInt64 = 1
            }

            private let options: Options?
            private let fileSystem: any OpenCodeFileSystem
            private let env: any EnvironmentProviding
            private let state = Mutex(State())

            public init(
                options: Options? = nil,
                fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
                env: any EnvironmentProviding = SystemEnvironment.shared
            ) {
                self.options = options
                self.fileSystem = fileSystem
                self.env = env
            }

            public func transform(
                _ fn: @escaping @Sendable (Editor) -> Void
            ) async -> CoreFilesystem.LocationWatcherPolicy.Registration {
                let id = state.withLock { s -> UInt64 in
                    let id = s.nextID
                    s.nextID &+= 1
                    s.transforms[id] = fn
                    s.order.append(id)
                    return id
                }
                await reload()
                return CoreFilesystem.LocationWatcherPolicy.Registration { [weak self] in
                    self?.state.withLock { s in
                        _ = s.transforms.removeValue(forKey: id)
                        s.order.removeAll { $0 == id }
                    }
                }
            }

            public func reload() async {
                state.withLock { s in
                    let editor = Editor()
                    for id in s.order { s.transforms[id]?(editor) }
                    s.configuredShell = editor.shell
                }
            }

            public func resolve(_ input: ResolveInput) async -> String {
                let configShell = state.withLock { $0.configuredShell }
                return Select.resolve(input, configShell: configShell, options: options, env: env)
            }

            public func list() async -> [Item] {
                await Select.list(options: options, fileSystem: fileSystem)
            }
        }

        // parity: core/src/shell/select.ts#configured [status=adapted hash=327a57bed767]
        public static func configured(_ options: Options? = nil) -> LayerNode.Provider {
            AppNode.makeLocationNode(
                Service.serviceKey,
                LayerNode.ExecutableLayer { deps, _ in
                    let fsUtil = deps.get(FSUtil.Service.serviceKey, as: FSUtil.Service.self)
                    let svc = Service(options: options, fileSystem: fsUtil?.fileSystem ?? LocalFileSystem.shared)
                    return LayerNode.Output([Service.serviceKey: svc as any Interface])
                },
                [FSUtil.node]
            )
        }

        // parity: core/src/shell/select.ts#node [status=adapted hash=aea3814ebc3b]
        public static let node: LayerNode.Provider = configured()
    }

    // MARK: - Core Shell Execution Service (`core/src/shell.ts`)

    // parity: core/src/shell.ts#NotFoundError [status=implemented hash=11702508e949]
    public struct NotFoundError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "Shell.NotFoundError"
        public let id: ShellSchema.ID

        public init(id: ShellSchema.ID) {
            self.id = id
        }

        public var description: String { "Shell command not found: \(id.rawValue)" }
    }

    /// 7 days retention in milliseconds.
    // parity: core/src/shell.ts#RETENTION [status=implemented hash=0e2a7fe20d74]
    public static let RETENTION: Int64 = 7 * 24 * 60 * 60 * 1_000

    // parity: core/src/shell.ts#DIRECTORY [status=implemented hash=0cfdf5770bfa]
    public static let DIRECTORY: String = "shell"

    // parity: core/src/shell.ts#StopReason [status=implemented hash=b6067a4c770e]
    public enum StopReason: String, Equatable, Hashable, Sendable, Codable {
        case timeout
        case killed
    }

    // parity: core/src/shell.ts#ToolCall [status=implemented hash=1e6578da75d5]
    public struct ToolCall: Equatable, Hashable, Sendable, Codable {
        public let sessionID: String
        public let assistantMessageID: String
        public let callID: String

        public init(sessionID: String, assistantMessageID: String, callID: String) {
            self.sessionID = sessionID
            self.assistantMessageID = assistantMessageID
            self.callID = callID
        }
    }

    public struct CreateBeforeInvocation: Sendable {
        public var command: String
        public var cwd: String
        public var shell: String
        public var timeout: Int
        public var env: [String: String]

        public init(command: String, cwd: String, shell: String, timeout: Int, env: [String: String]) {
            self.command = command
            self.cwd = cwd
            self.shell = shell
            self.timeout = timeout
            self.env = env
        }
    }

    public struct CreateRequest: Sendable {
        public let command: String
        public let cwd: String?
        public let timeout: Int?
        public let shell: String?
        public let metadata: ShellSchema.Metadata
        public let toolCall: ToolCall?
        public let waited: Bool

        public init(
            command: String,
            cwd: String? = nil,
            timeout: Int? = nil,
            shell: String? = nil,
            metadata: ShellSchema.Metadata = [:],
            toolCall: ToolCall? = nil,
            waited: Bool = true
        ) {
            self.command = command
            self.cwd = cwd
            self.timeout = timeout
            self.shell = shell
            self.metadata = metadata
            self.toolCall = toolCall
            self.waited = waited
        }
    }

    // parity: core/src/shell.ts#DaemonInterface [status=adapted hash=26b0a3d0c586]
    public protocol DaemonInterface: Sendable {
        func watch(_ task: @escaping @Sendable () async -> Void) async
        func handoffPrepared() -> Bool
    }

    // parity: core/src/shell.ts#Daemon [status=adapted hash=32670c6dddf1]
    public final class Daemon: DaemonInterface, Sendable {
        public static let serviceKey = "@opencode/Shell/Daemon"

        private let handoffFlag = Mutex(false)

        public init() {}

        public func setHandoffPrepared(_ value: Bool) {
            handoffFlag.withLock { $0 = value }
        }

        public func handoffPrepared() -> Bool {
            handoffFlag.withLock { $0 }
        }

        public func watch(_ task: @escaping @Sendable () async -> Void) async {
            Task { await task() }
        }
    }

    // parity: core/src/shell.ts#Interface [status=adapted hash=e5f19acb76f0]
    public protocol Interface: Sendable {
        func create(
            _ input: CreateRequest,
            before: (@Sendable (inout CreateBeforeInvocation) async throws -> Void)?
        ) async throws -> ShellSchema.Info
        func list() async -> [ShellSchema.Info]
        func get(_ id: ShellSchema.ID) async throws -> ShellSchema.Info
        func wait(_ id: ShellSchema.ID) async throws -> ShellSchema.Info
        func result(_ started: ShellSchema.Info, waitMs: Int?) async -> ResultHelper.Result
        func timeout(_ id: ShellSchema.ID, durationMs: Int) async throws -> ShellSchema.Info
        func stop(_ id: ShellSchema.ID, reason: StopReason) async throws -> ShellSchema.Info
        func byToolCall(_ call: ToolCall) async -> ShellSchema.Info?
        func output(_ id: ShellSchema.ID, input: ShellSchema.OutputInput?) async throws -> ShellSchema.Output
        func remove(_ id: ShellSchema.ID) async throws
        func watch(_ task: @escaping @Sendable () async -> Void) async
        func handoffPrepared() -> Bool
    }

    // parity: core/src/shell.ts#Service [status=adapted hash=bb6973e9eba9]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/Shell"

        private final class Entry: @unchecked Sendable {
            let lock = Mutex<Int>(0)
            var info: ShellSchema.Info
            var toolCall: ToolCall?
            var task: Task<Void, Never>?
            var waiters: [CheckedContinuation<ShellSchema.Info, any Swift.Error>] = []
            var terminated: Bool = false

            init(info: ShellSchema.Info, toolCall: ToolCall?) {
                self.info = info
                self.toolCall = toolCall
            }
        }

        public let directory: String
        public let projectID: ProjectID
        private let globalPaths: Global.Interface
        private let fileSystem: any OpenCodeFileSystem
        private let processes: any AppProcess.Interface
        private let shellSelect: any Select.Interface
        private let daemon: any DaemonInterface
        private let state = Mutex<[ShellSchema.ID: Entry]>([:])

        public init(
            directory: String = "/",
            projectID: ProjectID = .global,
            globalPaths: Global.Interface = Global.make(),
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            processes: any AppProcess.Interface = AppProcess.Service(),
            shellSelect: any Select.Interface = Select.Service(),
            daemon: any DaemonInterface = Daemon()
        ) {
            self.directory = directory
            self.projectID = projectID
            self.globalPaths = globalPaths
            self.fileSystem = fileSystem
            self.processes = processes
            self.shellSelect = shellSelect
            self.daemon = daemon
        }

        public func create(
            _ input: CreateRequest,
            before: (@Sendable (inout CreateBeforeInvocation) async throws -> Void)? = nil
        ) async throws -> ShellSchema.Info {
            let resolvedShell: String
            if let s = input.shell {
                resolvedShell = s
            } else {
                resolvedShell = await shellSelect.resolve(Select.ResolveInput(priority: .compat))
            }
            var invocation = CreateBeforeInvocation(
                command: input.command,
                cwd: input.cwd ?? directory,
                shell: resolvedShell,
                timeout: input.timeout ?? 0,
                env: [:]
            )
            if let before {
                try await before(&invocation)
            }

            let id = ShellSchema.ID.create()
            let outputDir = CoreConfigDiscovery.joinPath(
                CoreConfigDiscovery.joinPath(globalPaths.data, CoreShell.DIRECTORY),
                projectID.rawValue
            )
            let outputFile = CoreConfigDiscovery.joinPath(outputDir, "\(id.rawValue).out")
            try await fileSystem.writeFile([], to: outputFile, createDirectories: true)

            let startedAt = Double(Flock.currentEpochMs())
            let initialInfo = ShellSchema.Info(
                id: id,
                status: .running,
                command: invocation.command,
                cwd: invocation.cwd,
                shell: invocation.shell,
                file: outputFile,
                pid: nil,
                exit: nil,
                signal: nil,
                metadata: input.metadata,
                time: ShellSchema.Time(started: startedAt, completed: nil)
            )
            let entry = Entry(info: initialInfo, toolCall: input.toolCall)
            state.withLock { $0[id] = entry }

            let procService = self.processes
            let fs = self.fileSystem
            let finalInvocation = invocation
            let runnerTask = Task {
                let spec = ProcessSpec(
                    executable: finalInvocation.shell,
                    arguments: Select.args(finalInvocation.shell, command: finalInvocation.command),
                    workingDirectory: finalInvocation.cwd,
                    environment: finalInvocation.env.isEmpty ? nil : finalInvocation.env
                )
                do {
                    let runResult = try await procService.run(spec, options: AppProcess.RunOptions(combineOutput: true))
                    let combined = runResult.output ?? (runResult.stdout + runResult.stderr)
                    try? await fs.writeFile(combined, to: outputFile, createDirectories: true)
                    let completedAt = Double(Flock.currentEpochMs())
                    let finishedInfo = ShellSchema.Info(
                        id: id,
                        status: .exited,
                        command: finalInvocation.command,
                        cwd: finalInvocation.cwd,
                        shell: finalInvocation.shell,
                        file: outputFile,
                        pid: nil,
                        exit: Double(runResult.exitCode),
                        signal: nil,
                        metadata: input.metadata,
                        time: ShellSchema.Time(started: startedAt, completed: completedAt)
                    )
                    Self.completeEntry(entry, with: finishedInfo)
                } catch {
                    let msg = String(describing: error)
                    try? await fs.writeFile(Array(msg.utf8), to: outputFile, createDirectories: true)
                    let completedAt = Double(Flock.currentEpochMs())
                    let finishedInfo = ShellSchema.Info(
                        id: id,
                        status: .exited,
                        command: finalInvocation.command,
                        cwd: finalInvocation.cwd,
                        shell: finalInvocation.shell,
                        file: outputFile,
                        pid: nil,
                        exit: 1,
                        signal: nil,
                        metadata: input.metadata,
                        time: ShellSchema.Time(started: startedAt, completed: completedAt)
                    )
                    Self.completeEntry(entry, with: finishedInfo)
                }
            }
            entry.lock.withLock { _ in entry.task = runnerTask }
            return initialInfo
        }

        public func list() async -> [ShellSchema.Info] {
            state.withLock { map in
                map.values.compactMap { entry in
                    entry.lock.withLock { _ in
                        entry.info.status == .running ? entry.info : nil
                    }
                }
            }
        }

        public func get(_ id: ShellSchema.ID) async throws -> ShellSchema.Info {
            guard let entry = state.withLock({ $0[id] }) else {
                throw NotFoundError(id: id)
            }
            return entry.lock.withLock { _ in entry.info }
        }

        public func wait(_ id: ShellSchema.ID) async throws -> ShellSchema.Info {
            guard let entry = state.withLock({ $0[id] }) else {
                throw NotFoundError(id: id)
            }
            return try await withCheckedThrowingContinuation { cont in
                let immediate: ShellSchema.Info? = entry.lock.withLock { _ in
                    if entry.terminated { return entry.info }
                    entry.waiters.append(cont)
                    return nil
                }
                if let immediate {
                    cont.resume(returning: immediate)
                }
            }
        }

        public func result(_ started: ShellSchema.Info, waitMs: Int? = nil) async -> ResultHelper.Result {
            let finalInfo: ShellSchema.Info
            if let waitMs, waitMs >= 0 {
                finalInfo = (try? await get(started.id)) ?? started
            } else {
                finalInfo = (try? await wait(started.id)) ?? started
            }
            guard let bytes = try? await fileSystem.readFile(at: finalInfo.file) else {
                return ResultHelper.Result(info: finalInfo, capture: nil)
            }
            let rawText = String(decoding: bytes, as: UTF8.self)
            let display = rawText.isEmpty ? "(no output)" : rawText
            let truncated = bytes.count > 50 * 1024
            let preview = truncated ? TextBoundary.utf8Tail(bytes, limit: 50 * 1024) : display
            return ResultHelper.Result(
                info: finalInfo,
                capture: ResultHelper.Capture(output: preview, truncated: truncated)
            )
        }

        public func timeout(_ id: ShellSchema.ID, durationMs: Int) async throws -> ShellSchema.Info {
            _ = durationMs
            return try await get(id)
        }

        public func stop(_ id: ShellSchema.ID, reason: StopReason) async throws -> ShellSchema.Info {
            guard let entry = state.withLock({ $0[id] }) else {
                throw NotFoundError(id: id)
            }
            let current = entry.lock.withLock { _ -> (ShellSchema.Info, Task<Void, Never>?) in
                (entry.info, entry.task)
            }
            if current.0.status != .running { return current.0 }
            current.1?.cancel()
            let updated = ShellSchema.Info(
                id: current.0.id,
                status: reason == .timeout ? .timeout : .killed,
                command: current.0.command,
                cwd: current.0.cwd,
                shell: current.0.shell,
                file: current.0.file,
                pid: current.0.pid,
                exit: nil,
                signal: "SIGKILL",
                metadata: current.0.metadata,
                time: ShellSchema.Time(started: current.0.time.started, completed: Double(Flock.currentEpochMs()))
            )
            Self.completeEntry(entry, with: updated)
            return updated
        }

        public func byToolCall(_ call: ToolCall) async -> ShellSchema.Info? {
            state.withLock { map in
                for entry in map.values {
                    let match: ShellSchema.Info? = entry.lock.withLock { _ in
                        entry.toolCall == call ? entry.info : nil
                    }
                    if let match { return match }
                }
                return nil
            }
        }

        public func output(_ id: ShellSchema.ID, input: ShellSchema.OutputInput? = nil) async throws -> ShellSchema.Output {
            let info = try await get(id)
            guard let bytes = try? await fileSystem.readFile(at: info.file) else {
                return ResultHelper.unavailable
            }
            let totalSize = bytes.count
            let cursor = min(totalSize, max(0, input?.cursor?.rawValue ?? 0))
            let limit = input?.limit?.rawValue ?? (totalSize - cursor)
            let end = min(totalSize, cursor + max(0, limit))
            let slice = Array(bytes[cursor..<end])
            let text = String(decoding: slice, as: UTF8.self)
            return ShellSchema.Output(
                output: text,
                cursor: SchemaPrimitive.NonNegativeInt(rawValue: end) ?? .zero,
                size: SchemaPrimitive.NonNegativeInt(rawValue: totalSize) ?? .zero,
                truncated: end < totalSize
            )
        }

        public func remove(_ id: ShellSchema.ID) async throws {
            let removed = state.withLock { $0.removeValue(forKey: id) }
            guard let entry = removed else { throw NotFoundError(id: id) }
            let waiters: [CheckedContinuation<ShellSchema.Info, any Swift.Error>] = entry.lock.withLock { _ in
                entry.task?.cancel()
                let w = entry.waiters
                entry.waiters.removeAll()
                return w
            }
            for w in waiters { w.resume(throwing: NotFoundError(id: id)) }
        }

        public func watch(_ task: @escaping @Sendable () async -> Void) async {
            await daemon.watch(task)
        }

        public func handoffPrepared() -> Bool {
            daemon.handoffPrepared()
        }

        private static func completeEntry(_ entry: Entry, with info: ShellSchema.Info) {
            let waiters: [CheckedContinuation<ShellSchema.Info, any Swift.Error>] = entry.lock.withLock { _ in
                if entry.terminated { return [] }
                entry.info = info
                entry.terminated = true
                let w = entry.waiters
                entry.waiters.removeAll()
                return w
            }
            for w in waiters { w.resume(returning: info) }
        }
    }

    /// Cleans up expired `sh_*.out` files older than `RETENTION`.
    // parity: core/src/shell.ts#cleanup [status=implemented hash=9758b3a6552f]
    public static func cleanup(
        globalPaths: Global.Interface = Global.make(),
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        nowMs: Int64 = Flock.currentEpochMs()
    ) async {
        let baseDir = CoreConfigDiscovery.joinPath(globalPaths.data, DIRECTORY)
        guard let projects = try? await fileSystem.readDirectory(at: baseDir) else { return }
        var expiredCandidates: [String] = []
        for project in projects {
            let pDir = CoreConfigDiscovery.joinPath(baseDir, project)
            guard let files = try? await fileSystem.readDirectory(at: pDir) else { continue }
            for name in files where name.hasPrefix("sh_") && name.hasSuffix(".out") {
                expiredCandidates.append(CoreConfigDiscovery.joinPath(pDir, name))
            }
        }
        await CoreFilesystem.FileRetention.cleanup(
            fileSystem: fileSystem,
            files: expiredCandidates,
            retentionMs: RETENTION,
            nowMs: nowMs
        )
    }

    // parity: core/src/shell.ts#daemonNode [status=adapted hash=9e82fe7a5c1c]
    public static let daemonNode: LayerNode.Provider = AppNode.makeGlobalNode(
        Daemon.serviceKey,
        LayerNode.ExecutableLayer.succeed(key: Daemon.serviceKey, value: Daemon() as any DaemonInterface),
        []
    )

    // parity: core/src/shell.ts#node [status=adapted hash=1edae422e8e6]
    public static let node: LayerNode.Provider = AppNode.makeLocationNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            let dir = deps.get("@opencode/Location.directory", as: String.self) ?? "/"
            let global = deps.get(Global.Service.serviceKey, as: Global.Service.self)?.paths ?? Global.make()
            let fsUtil = deps.get(FSUtil.Service.serviceKey, as: FSUtil.Service.self)
            let proc = deps.get(AppProcess.Service.serviceKey, as: (any AppProcess.Interface).self) ?? AppProcess.Service()
            let select = deps.get(Select.Service.serviceKey, as: (any Select.Interface).self) ?? Select.Service()
            let daemon = deps.get(Daemon.serviceKey, as: (any DaemonInterface).self) ?? Daemon()
            let svc = Service(
                directory: dir,
                globalPaths: global,
                fileSystem: fsUtil?.fileSystem ?? LocalFileSystem.shared,
                processes: proc,
                shellSelect: select,
                daemon: daemon
            )
            return LayerNode.Output([Service.serviceKey: svc as any Interface])
        },
        [FSUtil.node, Global.node, AppProcess.node, Select.node, daemonNode]
    )
}

// MARK: - CorePty (`core/src/pty/*`, `core/src/pty.ts`, `core/src/persistent-pty/*`)

public enum CorePty {

    // MARK: - PTY Wire Protocol (`core/src/pty/protocol.ts`)

    public enum WireProtocol {
        // parity: core/src/pty/protocol.ts#REPLAY_CHUNK [status=implemented hash=ca531d5d35ed]
        public static let REPLAY_CHUNK: Int = 64 * 1024

        /// Encodes a control frame: leading `0x00` byte followed by UTF-8 JSON `{"cursor":<n>}`.
        // parity: core/src/pty/protocol.ts#metaFrame [status=implemented hash=1c1400ab0ff0]
        public static func metaFrame(cursor: Int) -> [UInt8] {
            let json = "{\"cursor\":\(cursor)}"
            var out: [UInt8] = [0]
            out.append(contentsOf: json.utf8)
            return out
        }

        /// Splits terminal replay output into bounded `REPLAY_CHUNK`-sized string slices.
        // parity: core/src/pty/protocol.ts#chunks [status=implemented hash=7158b79edb6c]
        public static func chunks(_ data: String) -> [String] {
            if data.isEmpty { return [] }
            let units = Array(data.utf16)
            var out: [String] = []
            var i = 0
            while i < units.count {
                let end = min(units.count, i + REPLAY_CHUNK)
                out.append(String(decoding: units[i..<end], as: UTF16.self))
                i = end
            }
            return out
        }

        /// Decodes an inbound client string or UTF-8 byte frame; returns `nil` on invalid UTF-8 bytes.
        // parity: core/src/pty/protocol.ts#decodeInput [status=implemented hash=2a26c9f955d5]
        public static func decodeInput(_ message: String) -> String {
            message
        }

        public static func decodeInput(_ bytes: [UInt8]) -> String? {
            String(bytes: bytes, encoding: .utf8)
        }
    }

    // MARK: - PTY Process Abstraction (`core/src/pty/pty.ts` & `pty.workerd.ts`)

    public enum Runtime {
        // parity: core/src/pty/pty.ts#Disp [status=implemented hash=9cf71d2bb445]
        public struct Disp: Sendable {
            private let disposeImpl: @Sendable () -> Void

            public init(dispose: @escaping @Sendable () -> Void) {
                self.disposeImpl = dispose
            }

            public func dispose() { disposeImpl() }
        }

        // parity: core/src/pty/pty.ts#Exit [status=implemented hash=fadcf9ae6f55]
        public struct Exit: Equatable, Hashable, Sendable, Codable {
            public let exitCode: Int
            public let signal: String?

            public init(exitCode: Int, signal: String? = nil) {
                self.exitCode = exitCode
                self.signal = signal
            }
        }

        // parity: core/src/pty/pty.ts#Opts [status=implemented hash=684a2dfda055]
        public struct Opts: Equatable, Hashable, Sendable, Codable {
            public let name: String
            public let cols: Int?
            public let rows: Int?
            public let cwd: String?
            public let env: [String: String]?

            public init(
                name: String,
                cols: Int? = nil,
                rows: Int? = nil,
                cwd: String? = nil,
                env: [String: String]? = nil
            ) {
                self.name = name
                self.cols = cols
                self.rows = rows
                self.cwd = cwd
                self.env = env
            }
        }

        // parity: core/src/pty/pty.ts#Proc [status=adapted hash=9653c7527b3f]
        public protocol Proc: Sendable {
            var pid: Int { get }
            func onData(_ listener: @escaping @Sendable (String) -> Void) -> Disp
            func onExit(_ listener: @escaping @Sendable (Exit) -> Void) -> Disp
            func write(_ data: String)
            func resize(cols: Int, rows: Int)
            func kill(signal: String?)
        }
    }

    public enum Workerd {
        public struct UnsupportedError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
            public let description = "Pseudo-terminals are unavailable on the workerd runtime"
            public init() {}
        }

        // parity: core/src/pty/pty.workerd.ts#spawn [status=adapted hash=f2ed2b55bbc6]
        public static func spawn() throws -> any Runtime.Proc {
            throw UnsupportedError()
        }
    }

    // MARK: - PTY Connect Tickets (`core/src/pty/ticket.ts`)

    public enum Ticket {
        public static let defaultTtlMs: Int64 = 60_000
        private static let capacity: Int = 10_000

        // parity: core/src/pty/ticket.ts#ConnectToken [status=implemented hash=77110e49863b]
        public typealias ConnectToken = PtyTicketSchema.ConnectToken

        // parity: core/src/pty/ticket.ts#Target [status=implemented hash=f793376c14cf]
        public enum Target: Equatable, Hashable, Sendable, Codable {
            case pty(PtySchema.ID)
            case mcpClient(String)

            public var key: String {
                switch self {
                case .pty(let id): return "pty:\(id.rawValue)"
                case .mcpClient(let client): return "mcp:\(client)"
                }
            }
        }

        // parity: core/src/pty/ticket.ts#Scope [status=implemented hash=4c1d8faf0af4]
        public struct Scope: Equatable, Hashable, Sendable, Codable {
            public let target: Target
            public let directory: String?
            public let workspaceID: WorkspaceID?

            public init(target: Target, directory: String? = nil, workspaceID: WorkspaceID? = nil) {
                self.target = target
                self.directory = directory
                self.workspaceID = workspaceID
            }
        }

        // parity: core/src/pty/ticket.ts#Interface [status=adapted hash=c311dbec9b22]
        public protocol Interface: Sendable {
            func issue(_ scope: Scope) async -> ConnectToken
            func consume(ticket: String, scope: Scope) async -> Bool
        }

        // parity: core/src/pty/ticket.ts#Service [status=adapted hash=87afc8082152]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/PtyTicket"

            private struct Stored: Equatable, Sendable {
                let targetKey: String
                let directory: String?
                let workspaceID: WorkspaceID?
                let expiresAtMs: Int64
            }

            private let ttlMs: Int64
            private let expiresInSeconds: Int
            private let nowMs: @Sendable () -> Int64
            private let store = Mutex<[String: Stored]>([:])

            public init(
                ttlMs: Int64 = Ticket.defaultTtlMs,
                nowMs: @escaping @Sendable () -> Int64 = { Flock.currentEpochMs() }
            ) {
                self.ttlMs = ttlMs
                self.expiresInSeconds = max(1, Int((Double(ttlMs) / 1_000.0).rounded()))
                self.nowMs = nowMs
            }

            public func issue(_ scope: Scope) async -> ConnectToken {
                let ticket = uuid()
                let now = nowMs()
                let record = Stored(
                    targetKey: scope.target.key,
                    directory: scope.directory,
                    workspaceID: scope.workspaceID,
                    expiresAtMs: now + ttlMs
                )
                store.withLock { map in
                    if map.count >= Ticket.capacity {
                        map = map.filter { $0.value.expiresAtMs > now }
                    }
                    map[ticket] = record
                }
                return ConnectToken(
                    ticket: ticket,
                    expiresIn: SchemaPrimitive.PositiveInt(rawValue: expiresInSeconds) ?? SchemaPrimitive.PositiveInt(rawValue: 1)!
                )
            }

            public func consume(ticket: String, scope: Scope) async -> Bool {
                let now = nowMs()
                return store.withLock { map in
                    guard let existing = map[ticket] else { return false }
                    if existing.expiresAtMs <= now {
                        map.removeValue(forKey: ticket)
                        return false
                    }
                    guard existing.targetKey == scope.target.key,
                          existing.directory == scope.directory,
                          existing.workspaceID == scope.workspaceID else {
                        return false
                    }
                    map.removeValue(forKey: ticket)
                    return true
                }
            }
        }

        // parity: core/src/pty/ticket.ts#make [status=implemented hash=42d13716857c]
        public static func make(
            ttlMs: Int64 = defaultTtlMs,
            nowMs: @escaping @Sendable () -> Int64 = { Flock.currentEpochMs() }
        ) -> Service {
            Service(ttlMs: ttlMs, nowMs: nowMs)
        }

        // parity: core/src/pty/ticket.ts#node [status=adapted hash=0690353164c9]
        public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer.succeed(key: Service.serviceKey, value: make() as any Interface),
            []
        )
    }

    // MARK: - Location-Scoped PTY Service (`core/src/pty.ts`)

    // parity: core/src/pty.ts#ID [status=implemented hash=42269ab17642]
    public typealias ID = PtySchema.ID

    // parity: core/src/pty.ts#Info [status=implemented hash=7c22213d6d3e]
    public typealias Info = PtySchema.Info

    // parity: core/src/pty.ts#CreateInput [status=implemented hash=af8b976666b1]
    public typealias CreateInput = PtySchema.CreateInput

    // parity: core/src/pty.ts#UpdateInput [status=implemented hash=93e8a324c8c9]
    public typealias UpdateInput = PtySchema.UpdateInput

    // parity: core/src/pty.ts#AttachInput [status=implemented hash=94281e289c6c]
    public struct AttachInput: Sendable {
        public let cursor: Int?
        public let onData: @Sendable (String) -> Void
        public let onEnd: @Sendable (Int?) -> Void

        public init(
            cursor: Int? = nil,
            onData: @escaping @Sendable (String) -> Void,
            onEnd: @escaping @Sendable (Int?) -> Void
        ) {
            self.cursor = cursor
            self.onData = onData
            self.onEnd = onEnd
        }
    }

    // parity: core/src/pty.ts#Attachment [status=implemented hash=409a1305d0de]
    public struct Attachment: Sendable {
        public let replay: String
        public let cursor: Int
        public let write: @Sendable (String) -> Void
        public let activate: @Sendable () -> Void
        public let detach: @Sendable () -> Void

        public init(
            replay: String,
            cursor: Int,
            write: @escaping @Sendable (String) -> Void,
            activate: @escaping @Sendable () -> Void,
            detach: @escaping @Sendable () -> Void
        ) {
            self.replay = replay
            self.cursor = cursor
            self.write = write
            self.activate = activate
            self.detach = detach
        }
    }

    // parity: core/src/pty.ts#NotFoundError [status=implemented hash=6bbcd6ccf736]
    public struct NotFoundError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "Pty.NotFoundError"
        public let ptyID: ID

        public init(ptyID: ID) {
            self.ptyID = ptyID
        }

        public var description: String { "PTY session not found: \(ptyID.rawValue)" }
    }

    // parity: core/src/pty.ts#ExitedError [status=implemented hash=bf0b20272b47]
    public struct ExitedError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "Pty.ExitedError"
        public let ptyID: ID

        public init(ptyID: ID) {
            self.ptyID = ptyID
        }

        public var description: String { "PTY session already exited: \(ptyID.rawValue)" }
    }

    // parity: core/src/pty.ts#Interface [status=adapted hash=b41b65561fde]
    public protocol Interface: Sendable {
        func list() async -> [Info]
        func get(_ id: ID) async throws -> Info
        func create(_ input: CreateInput) async throws -> Info
        func update(_ id: ID, input: UpdateInput) async throws -> Info
        func remove(_ id: ID) async throws
        func write(_ id: ID, data: String) async throws
        func attach(_ id: ID, input: AttachInput) async throws -> Attachment
    }

    /// Location-scoped PTY manager integrated directly with `OpenCodePlatform.ProcessDaemon.TerminalService`.
    // parity: core/src/pty.ts#Service [status=adapted hash=e21f3642d991]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/Pty"

        private static let bufferLimit = 2 * 1024 * 1024

        private final class Subscriber: @unchecked Sendable {
            let onData: @Sendable (String) -> Void
            let onEnd: @Sendable (Int?) -> Void
            var active = false
            var detached = false
            var pending: [String] = []
            var endExitCode: Int?? = nil

            init(onData: @escaping @Sendable (String) -> Void, onEnd: @escaping @Sendable (Int?) -> Void) {
                self.onData = onData
                self.onEnd = onEnd
            }
        }

        private final class Session: @unchecked Sendable {
            let daemonID: ProcessDaemon.TerminalId
            var info: Info
            var buffer: String = ""
            var cursor: Int = 0
            var subscribers: [UInt64: Subscriber] = [:]
            var nextSubID: UInt64 = 1

            init(daemonID: ProcessDaemon.TerminalId, info: Info) {
                self.daemonID = daemonID
                self.info = info
            }
        }

        public let directory: String
        private let terminalService: ProcessDaemon.TerminalService
        private let shellSelect: any CoreShell.Select.Interface
        private let state = Mutex<[ID: Session]>([:])

        public init(
            directory: String = "/",
            backend: ProcessDaemon.BackendMode = .simulated(onWrite: nil),
            shellSelect: any CoreShell.Select.Interface = CoreShell.Select.Service()
        ) {
            self.directory = directory
            self.terminalService = ProcessDaemon.TerminalService.new(backend: backend)
            self.shellSelect = shellSelect
        }

        public func list() async -> [Info] {
            state.withLock { Array($0.values.map(\.info)) }
        }

        public func get(_ id: ID) async throws -> Info {
            guard let info = state.withLock({ $0[id]?.info }) else {
                throw NotFoundError(ptyID: id)
            }
            return info
        }

        public func create(_ input: CreateInput = CreateInput()) async throws -> Info {
            let id = ID.create()
            let cmd: String
            if let explicit = input.command, !explicit.isEmpty {
                cmd = explicit
            } else {
                cmd = await shellSelect.resolve(CoreShell.Select.ResolveInput(priority: .config))
            }
            var args = input.args ?? []
            if CoreShell.Select.login(cmd) && !args.contains("-l") {
                args.append("-l")
            }
            let cwd = input.cwd ?? directory
            var env = input.env ?? [:]
            env["TERM"] = "xterm-256color"
            env["OPENCODE_TERMINAL"] = "1"
            let title = input.title ?? "Terminal \(String(id.rawValue.suffix(4)))"

            let procInfo = try terminalService.create_pty(ProcessDaemon.CreatePty(
                program: cmd,
                args: args,
                cwd: cwd,
                env: env,
                groupId: id.rawValue,
                title: title
            ))

            let info = Info(
                id: id,
                title: title,
                command: cmd,
                args: args,
                cwd: cwd,
                status: .running,
                pid: SchemaPrimitive.NonNegativeInt(rawValue: Int(procInfo.pid ?? 0)) ?? .zero,
                exitCode: nil
            )
            let session = Session(daemonID: procInfo.id, info: info)
            state.withLock { $0[id] = session }
            return info
        }

        public func update(_ id: ID, input: UpdateInput) async throws -> Info {
            let (daemonID, updated): (ProcessDaemon.TerminalId, Info) = try state.withLock { map in
                guard let session = map[id] else { throw NotFoundError(ptyID: id) }
                let nextTitle = input.title ?? session.info.title
                let nextInfo = Info(
                    id: session.info.id,
                    title: nextTitle,
                    command: session.info.command,
                    args: session.info.args,
                    cwd: session.info.cwd,
                    status: session.info.status,
                    pid: session.info.pid,
                    exitCode: session.info.exitCode
                )
                session.info = nextInfo
                return (session.daemonID, nextInfo)
            }
            if let title = input.title {
                try? terminalService.rename(id: daemonID, title: title)
            }
            if let size = input.size {
                try? terminalService.resize(id: daemonID, cols: UInt16(size.cols.rawValue), rows: UInt16(size.rows.rawValue))
            }
            return updated
        }

        public func remove(_ id: ID) async throws {
            let (daemonID, subs): (ProcessDaemon.TerminalId, [Subscriber]) = try state.withLock { map in
                guard let session = map.removeValue(forKey: id) else { throw NotFoundError(ptyID: id) }
                let s = Array(session.subscribers.values)
                session.subscribers.removeAll()
                return (session.daemonID, s)
            }
            try? terminalService.terminate(daemonID)
            for sub in subs {
                if sub.active && !sub.detached { sub.onEnd(nil) }
            }
        }

        public func write(_ id: ID, data: String) async throws {
            let daemonID: ProcessDaemon.TerminalId = try state.withLock { map in
                guard let session = map[id] else { throw NotFoundError(ptyID: id) }
                return session.daemonID
            }
            try terminalService.write(id: daemonID, bytes: Array(data.utf8))
            // Sync replay buffer from daemon output (for immediate simulated echo visibility).
            syncBufferFromDaemon(id: id, daemonID: daemonID)
        }

        public func attach(_ id: ID, input: AttachInput) async throws -> Attachment {
            let (daemonID, replay, endCursor, subID): (ProcessDaemon.TerminalId, String, Int, UInt64) = try state.withLock { map in
                guard let session = map[id] else { throw NotFoundError(ptyID: id) }
                if session.info.status != .running { throw ExitedError(ptyID: id) }
                let sub = Subscriber(onData: input.onData, onEnd: input.onEnd)
                let token = session.nextSubID
                session.nextSubID &+= 1
                session.subscribers[token] = sub

                let end = session.cursor
                let from: Int
                if input.cursor == -1 {
                    from = end
                } else if let c = input.cursor {
                    from = max(0, c)
                } else {
                    from = 0
                }
                let startInBuf = max(0, from - (end - session.buffer.utf16.count))
                let bufUnits = Array(session.buffer.utf16)
                let slice = startInBuf < bufUnits.count
                    ? String(decoding: bufUnits[startInBuf...], as: UTF16.self)
                    : ""
                return (session.daemonID, slice, end, token)
            }

            return Attachment(
                replay: replay,
                cursor: endCursor,
                write: { [weak self] data in
                    guard let self else { return }
                    try? self.terminalService.write(id: daemonID, bytes: Array(data.utf8))
                    self.syncBufferFromDaemon(id: id, daemonID: daemonID)
                },
                activate: { [weak self] in
                    guard let self else { return }
                    let (pending, endCode): ([String], Int??) = self.state.withLock { map in
                        guard let session = map[id], let sub = session.subscribers[subID] else { return ([], nil) }
                        if sub.active || sub.detached { return ([], nil) }
                        sub.active = true
                        let p = sub.pending
                        sub.pending.removeAll()
                        let e = sub.endExitCode
                        return (p, e)
                    }
                    for chunk in pending { input.onData(chunk) }
                    if let code = endCode { input.onEnd(code) }
                },
                detach: { [weak self] in
                    self?.state.withLock { map in
                        if let session = map[id], let sub = session.subscribers.removeValue(forKey: subID) {
                            sub.detached = true
                            sub.pending.removeAll()
                        }
                    }
                }
            )
        }

        private func syncBufferFromDaemon(id: ID, daemonID: ProcessDaemon.TerminalId) {
            let currentCursor = state.withLock { $0[id]?.cursor ?? 0 }
            guard let rep = try? terminalService.replay(id: daemonID, offset: UInt64(currentCursor)),
                  !rep.bytes.isEmpty
            else {
                return
            }
            let chunk = String(decoding: rep.bytes, as: UTF8.self)
            let activeSubs: [Subscriber] = state.withLock { map in
                guard let session = map[id] else { return [] }
                session.cursor = Int(rep.endOffset)
                session.buffer += chunk
                if session.buffer.count > Self.bufferLimit {
                    session.buffer = String(session.buffer.suffix(Self.bufferLimit))
                }
                var active: [Subscriber] = []
                for sub in session.subscribers.values {
                    if sub.detached { continue }
                    if sub.active {
                        active.append(sub)
                    } else {
                        sub.pending.append(chunk)
                    }
                }
                return active
            }
            for sub in activeSubs {
                sub.onData(chunk)
            }
        }
    }

    // parity: core/src/pty.ts#node [status=adapted hash=9a07b38bb101]
    public static let node: LayerNode.Provider = AppNode.makeLocationNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            let dir = deps.get("@opencode/Location.directory", as: String.self) ?? "/"
            let select = deps.get(CoreShell.Select.Service.serviceKey, as: (any CoreShell.Select.Interface).self)
                ?? CoreShell.Select.Service()
            let svc = Service(directory: dir, shellSelect: select)
            return LayerNode.Output([Service.serviceKey: svc as any Interface])
        },
        [CoreShell.Select.node]
    )

    // MARK: - Persistent PTY Binaries (`core/src/persistent-pty/binary.{bun,node,workerd}.ts`)

    public enum PersistentBinaryBun {
        // parity: core/src/persistent-pty/binary.bun.ts#available [status=adapted hash=1ee00affb6af]
        public static let available: Bool = true

        // parity: core/src/persistent-pty/binary.bun.ts#resolveBinary [status=adapted hash=d73cf78fda5f]
        public static func resolveBinary(
            bin: String,
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) async -> String {
            if let override = environment.variable("OPENCODE_PTY_BIN"), !override.isEmpty {
                return override
            }
            let exe = Platform.current == .windows ? "opencode-pty.exe" : "opencode-pty"
            return CoreConfigDiscovery.joinPath(bin, exe)
        }
    }

    public enum PersistentBinaryNode {
        // parity: core/src/persistent-pty/binary.node.ts#available [status=adapted hash=1ee00affb6af]
        public static let available: Bool = true

        // parity: core/src/persistent-pty/binary.node.ts#resolveBinary [status=adapted hash=25d86687fa0b]
        public static func resolveBinary(
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) async -> String {
            if let override = environment.variable("OPENCODE_PTY_BIN"), !override.isEmpty {
                return override
            }
            return "opencode-pty"
        }
    }

    public enum PersistentBinaryWorkerd {
        // parity: core/src/persistent-pty/binary.workerd.ts#available [status=implemented hash=b89ffcc92537]
        public static let available: Bool = false

        // parity: core/src/persistent-pty/binary.workerd.ts#resolveBinary [status=implemented hash=1e12dd34a1e5]
        public static func resolveBinary() async throws -> String {
            throw Persistent.UnavailableError(message: "Persistent PTY daemon is unavailable on workerd")
        }
    }

    // MARK: - Persistent PTY Daemon Transport (`core/src/persistent-pty/daemon.ts`)

    public enum PersistentDaemon {
        // parity: core/src/persistent-pty/daemon.ts#Metadata [status=implemented hash=1a80e9f0220c]
        public typealias Metadata = [String: JSONValue]

        // parity: core/src/persistent-pty/daemon.ts#ProcessInfo [status=implemented hash=ecf7d912fce9]
        public typealias ProcessInfo = ProcessDaemon.ProcessInfo

        // parity: core/src/persistent-pty/daemon.ts#Signal [status=implemented hash=f2920e0faffd]
        public typealias Signal = ProcessDaemon.ProcessSignal

        // parity: core/src/persistent-pty/daemon.ts#WireResponse [status=implemented hash=103df49e9daf]
        public typealias WireResponse = ProcessDaemon.Response

        // parity: core/src/persistent-pty/daemon.ts#Exited [status=implemented hash=25e7ad2653c3]
        public typealias Exited = ProcessDaemon.ProcessExit

        // parity: core/src/persistent-pty/daemon.ts#Role [status=implemented hash=d82b7305bc66]
        public typealias Role = ProcessDaemon.AttachmentRole

        // parity: core/src/persistent-pty/daemon.ts#StreamEvent [status=implemented hash=4050d49d2d4d]
        public typealias StreamEvent = ProcessDaemon.StreamEvent

        // parity: core/src/persistent-pty/daemon.ts#SubscribeInput [status=implemented hash=49932216e136]
        public struct SubscribeInput: Sendable {
            public let cursor: UInt64
            public let attachmentID: String
            public let role: Role
            public let takeover: Bool
            public let onEvent: @Sendable (StreamEvent) -> Void
            public let onEnd: @Sendable () -> Void

            public init(
                cursor: UInt64 = 0,
                attachmentID: String,
                role: Role = .controller,
                takeover: Bool = false,
                onEvent: @escaping @Sendable (StreamEvent) -> Void,
                onEnd: @escaping @Sendable () -> Void
            ) {
                self.cursor = cursor
                self.attachmentID = attachmentID
                self.role = role
                self.takeover = takeover
                self.onEvent = onEvent
                self.onEnd = onEnd
            }
        }

        // parity: core/src/persistent-pty/daemon.ts#DaemonAttachment [status=implemented hash=f9f2c55d5a45]
        public struct DaemonAttachment: Sendable {
            public let terminal: ProcessInfo
            public let role: Role
            public let generation: UInt64
            public let replay: ProcessDaemon.RawReplay
            public let activate: @Sendable () -> Void
            public let detach: @Sendable () -> Void

            public init(
                terminal: ProcessInfo,
                role: Role,
                generation: UInt64,
                replay: ProcessDaemon.RawReplay,
                activate: @escaping @Sendable () -> Void,
                detach: @escaping @Sendable () -> Void
            ) {
                self.terminal = terminal
                self.role = role
                self.generation = generation
                self.replay = replay
                self.activate = activate
                self.detach = detach
            }
        }

        // parity: core/src/persistent-pty/daemon.ts#DaemonError [status=implemented hash=69c7fc08e599]
        public struct DaemonError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
            public enum Kind: String, Equatable, Hashable, Sendable, Codable {
                case connect
                case response
                case registration
                case `protocol`
                case spawn
                case request
            }

            public static let tag = "PersistentPty.DaemonError"
            public let kind: Kind
            public let message: String
            public let pid: Int?

            public init(kind: Kind, message: String, pid: Int? = nil) {
                self.kind = kind
                self.message = message
                self.pid = pid
            }

            public var description: String { "PersistentPty.DaemonError(\(kind.rawValue)): \(message)" }
        }

        // parity: core/src/persistent-pty/daemon.ts#DaemonTransport [status=adapted hash=2ad838c9423b]
        public protocol DaemonTransport: Sendable {
            var service: ProcessDaemon.TerminalService { get }
            func shutdown() async throws
            func handoff() async throws -> PersistentPtySchema.Handoff?
            func subscribe(id: ProcessDaemon.TerminalId, input: SubscribeInput) async throws -> DaemonAttachment
        }

        public final class InProcessDaemonTransport: DaemonTransport, Sendable {
            public let service: ProcessDaemon.TerminalService
            public let directory: String
            private let instanceID: String

            public init(
                directory: String,
                backend: ProcessDaemon.BackendMode = .simulated(onWrite: nil)
            ) {
                self.directory = directory
                self.service = ProcessDaemon.TerminalService.new(backend: backend)
                self.instanceID = uuid()
            }

            public func shutdown() async throws {
                service.shutdown()
            }

            public func handoff() async throws -> PersistentPtySchema.Handoff? {
                PersistentPtySchema.Handoff(
                    directory: directory,
                    instanceID: instanceID,
                    ticket: uuid(),
                    expiresAt: Double(Flock.currentEpochMs() + 30_000)
                )
            }

            public func subscribe(
                id: ProcessDaemon.TerminalId,
                input: SubscribeInput
            ) async throws -> DaemonAttachment {
                let attachment: ProcessDaemon.TerminalAttachment
                do {
                    attachment = try service.attach(
                        id: id,
                        offset: input.cursor,
                        attachmentId: input.attachmentID,
                        role: input.role,
                        takeover: input.takeover
                    )
                } catch {
                    throw DaemonError(kind: .request, message: String(describing: error))
                }
                return DaemonAttachment(
                    terminal: attachment.process,
                    role: attachment.role,
                    generation: attachment.generation,
                    replay: attachment.replay,
                    activate: {
                        for ev in attachment.drainEvents() {
                            input.onEvent(ev)
                        }
                    },
                    detach: {
                        attachment.detach()
                        input.onEnd()
                    }
                )
            }
        }

        // parity: core/src/persistent-pty/daemon.ts#makeDaemonTransport [status=adapted hash=499f69b971bb]
        public static func makeDaemonTransport(
            root: String,
            backend: ProcessDaemon.BackendMode = .simulated(onWrite: nil)
        ) -> any DaemonTransport {
            InProcessDaemonTransport(directory: root, backend: backend)
        }
    }

    // MARK: - Persistent PTY Service (`core/src/persistent-pty/index.ts`)

    public enum Persistent {
        // parity: core/src/persistent-pty/index.ts#Options [status=implemented hash=cb026121f7e6]
        public struct Options: Equatable, Hashable, Sendable, Codable {
            public let handoff: PersistentPtySchema.Handoff?
            public let root: String?

            public init(handoff: PersistentPtySchema.Handoff? = nil, root: String? = nil) {
                self.handoff = handoff
                self.root = root
            }
        }

        // parity: core/src/persistent-pty/index.ts#Info [status=implemented hash=ab5fb54c5ece]
        public typealias Info = PersistentPtySchema.Info

        // parity: core/src/persistent-pty/index.ts#Snapshot [status=implemented hash=1413258c02fb]
        public typealias Snapshot = PersistentPtySchema.Snapshot

        // parity: core/src/persistent-pty/index.ts#Attachment [status=implemented hash=08f6cc2ea053]
        public struct Attachment: Sendable {
            public let info: Info
            public let role: PersistentDaemon.Role
            public let generation: UInt64
            public let replay: ProcessDaemon.RawReplay
            public let activate: @Sendable () -> Void
            public let detach: @Sendable () -> Void

            public init(
                info: Info,
                role: PersistentDaemon.Role,
                generation: UInt64,
                replay: ProcessDaemon.RawReplay,
                activate: @escaping @Sendable () -> Void,
                detach: @escaping @Sendable () -> Void
            ) {
                self.info = info
                self.role = role
                self.generation = generation
                self.replay = replay
                self.activate = activate
                self.detach = detach
            }
        }

        // parity: core/src/persistent-pty/index.ts#UnavailableError [status=implemented hash=4b837ca153d4]
        public struct UnavailableError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
            public static let tag = "PersistentPty.UnavailableError"
            public let message: String

            public init(message: String) { self.message = message }
            public var description: String { message }
        }

        // parity: core/src/persistent-pty/index.ts#RequestError [status=implemented hash=a8df123e75af]
        public struct RequestError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
            public static let tag = "PersistentPty.RequestError"
            public let message: String

            public init(message: String) { self.message = message }
            public var description: String { message }
        }

        // parity: core/src/persistent-pty/index.ts#NotFoundError [status=implemented hash=8f433fa428e3]
        public struct NotFoundError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
            public static let tag = "PersistentPty.NotFoundError"
            public let ptyID: PtySchema.ID

            public init(ptyID: PtySchema.ID) { self.ptyID = ptyID }
            public var description: String { "Persistent PTY not found: \(ptyID.rawValue)" }
        }

        // parity: core/src/persistent-pty/index.ts#ProcessNotFoundError [status=implemented hash=f947cb49fe5c]
        public struct ProcessNotFoundError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
            public static let tag = "PersistentPty.ProcessNotFoundError"
            public let processID: UInt64

            public init(processID: UInt64) { self.processID = processID }
            public var description: String { "Persistent pipe process not found: \(processID)" }
        }

        // parity: core/src/persistent-pty/index.ts#InvalidCwdError [status=implemented hash=b6be32fbe9b5]
        public struct InvalidCwdError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
            public static let tag = "PersistentPty.InvalidCwdError"
            public let cwd: String
            public let message: String

            public init(cwd: String, message: String) {
                self.cwd = cwd
                self.message = message
            }

            public var description: String { message }
        }

        // parity: core/src/persistent-pty/index.ts#PipeInfo [status=implemented hash=deac0299385c]
        public struct PipeInfo: Equatable, Sendable {
            public let id: UInt64
            public let pid: UInt32?
            public let command: [String]
            public let cwd: String
            public let groupID: String
            public let lifecycle: ProcessDaemon.TerminalLifecycle
            public let outputTail: UInt64
            public let outputLines: UInt64
            public let outputPath: String
            public let outputError: String?
            public let metadata: ProcessDaemon.PipeMetadata
            public let startedAt: UInt64
            public let exitedAt: UInt64?

            public init(
                id: UInt64,
                pid: UInt32?,
                command: [String],
                cwd: String,
                groupID: String,
                lifecycle: ProcessDaemon.TerminalLifecycle,
                outputTail: UInt64,
                outputLines: UInt64,
                outputPath: String,
                outputError: String?,
                metadata: ProcessDaemon.PipeMetadata,
                startedAt: UInt64,
                exitedAt: UInt64?
            ) {
                self.id = id
                self.pid = pid
                self.command = command
                self.cwd = cwd
                self.groupID = groupID
                self.lifecycle = lifecycle
                self.outputTail = outputTail
                self.outputLines = outputLines
                self.outputPath = outputPath
                self.outputError = outputError
                self.metadata = metadata
                self.startedAt = startedAt
                self.exitedAt = exitedAt
            }
        }

        // parity: core/src/persistent-pty/index.ts#PipeExit [status=implemented hash=fd18d0c3d49b]
        public struct PipeExit: Equatable, Hashable, Sendable, Codable {
            public let exitCode: UInt32?
            public let signal: String?
            public let finalOffset: UInt64
            public let outputLines: UInt64
            public let outputError: String?
            public let exitedAt: UInt64

            public init(
                exitCode: UInt32?,
                signal: String?,
                finalOffset: UInt64,
                outputLines: UInt64,
                outputError: String?,
                exitedAt: UInt64
            ) {
                self.exitCode = exitCode
                self.signal = signal
                self.finalOffset = finalOffset
                self.outputLines = outputLines
                self.outputError = outputError
                self.exitedAt = exitedAt
            }
        }

        // parity: core/src/persistent-pty/index.ts#CreatePipeInput [status=implemented hash=a4a086393846]
        public struct CreatePipeInput: Equatable, Sendable {
            public let program: String
            public let args: [String]
            public let cwd: String
            public let env: [String: String]
            public let groupID: String
            public let outputPath: String
            public let metadata: ProcessDaemon.PipeMetadata

            public init(
                program: String,
                args: [String] = [],
                cwd: String,
                env: [String: String] = [:],
                groupID: String,
                outputPath: String,
                metadata: ProcessDaemon.PipeMetadata = [:]
            ) {
                self.program = program
                self.args = args
                self.cwd = cwd
                self.env = env
                self.groupID = groupID
                self.outputPath = outputPath
                self.metadata = metadata
            }
        }

        public struct CreateTerminalInput: Equatable, Hashable, Sendable {
            public let command: String?
            public let args: [String]
            public let cwd: String?
            public let title: String
            public let env: [String: String]
            public let cols: UInt16?
            public let rows: UInt16?

            public init(
                command: String? = nil,
                args: [String] = [],
                cwd: String? = nil,
                title: String,
                env: [String: String] = [:],
                cols: UInt16? = nil,
                rows: UInt16? = nil
            ) {
                self.command = command
                self.args = args
                self.cwd = cwd
                self.title = title
                self.env = env
                self.cols = cols
                self.rows = rows
            }
        }

        // parity: core/src/persistent-pty/index.ts#Interface [status=adapted hash=0a27f78cb157]
        public protocol Interface: Sendable {
            func list(sessionID: SessionID?) async throws -> [Info]
            func get(_ id: PtySchema.ID) async throws -> Info
            func create(sessionID: SessionID, input: CreateTerminalInput) async throws -> Info
            func write(_ id: PtySchema.ID, data: String, attachmentID: String?) async throws
            func resize(_ id: PtySchema.ID, cols: UInt16, rows: UInt16, attachmentID: String?) async throws
            func control(_ id: PtySchema.ID, attachmentID: String, cols: UInt16, rows: UInt16) async throws
            func input(_ id: PtySchema.ID, attachmentID: String, cols: UInt16, rows: UInt16, data: [UInt8]) async throws
            func rename(_ id: PtySchema.ID, title: String?) async throws -> Info
            func snapshot(_ id: PtySchema.ID) async throws -> Snapshot
            func read(sessionID: SessionID, lines: Int?) async throws -> PersistentPtySchema.ReadResult?
            func remove(_ id: PtySchema.ID) async throws
            func shutdown() async throws
            func handoff() async throws -> PersistentPtySchema.Handoff?
            func handoffPrepared() -> Bool
            func attach(_ id: PtySchema.ID, input: PersistentDaemon.SubscribeInput) async throws -> Attachment
            func createPipe(_ input: CreatePipeInput) async throws -> PipeInfo
            func waitPipe(_ id: UInt64) async throws -> PipeExit
            func getPipe(_ id: UInt64) async throws -> PipeInfo
            func signalPipe(_ id: UInt64, signal: PersistentDaemon.Signal) async throws
            func setPipeMetadata(_ id: UInt64, metadata: ProcessDaemon.PipeMetadata) async throws
            func terminatePipe(_ id: UInt64) async throws
            func listPipes() async throws -> [PipeInfo]
        }

        // parity: core/src/persistent-pty/index.ts#Service [status=adapted hash=3d8359ee5e94]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/PersistentPty"

            private struct State: Sendable {
                var currentBySession: [SessionID: PtySchema.ID] = [:]
                var handoffExpiresAtMs: Double = 0
            }

            private let transport: any PersistentDaemon.DaemonTransport
            private let state = Mutex(State())

            public init(
                options: Options? = nil,
                backend: ProcessDaemon.BackendMode = .simulated(onWrite: nil)
            ) {
                let root = options?.root ?? CoreConfigDiscovery.joinPath(Global.Path.state, "pty")
                self.transport = PersistentDaemon.makeDaemonTransport(root: root, backend: backend)
            }

            public func list(sessionID: SessionID? = nil) async throws -> [Info] {
                let procs: [ProcessDaemon.ProcessInfo]
                do {
                    procs = try transport.service.list(.pty)
                } catch {
                    throw UnavailableError(message: String(describing: error))
                }
                let infos = procs.compactMap(Self.toInfo)
                if let sessionID {
                    return infos.filter { $0.sessionID == sessionID }
                }
                return infos
            }

            public func get(_ id: PtySchema.ID) async throws -> Info {
                guard let numericID = Self.parseID(id) else {
                    throw NotFoundError(ptyID: id)
                }
                let proc: ProcessDaemon.ProcessInfo
                do {
                    proc = try transport.service.get(numericID)
                } catch {
                    throw NotFoundError(ptyID: id)
                }
                guard let info = Self.toInfo(proc) else {
                    throw NotFoundError(ptyID: id)
                }
                return info
            }

            public func create(sessionID: SessionID, input: CreateTerminalInput) async throws -> Info {
                let program = input.command ?? CoreShell.Select.environment()
                let cwd = input.cwd ?? "/"
                let proc: ProcessDaemon.ProcessInfo
                do {
                    proc = try transport.service.create_pty(ProcessDaemon.CreatePty(
                        program: program,
                        args: input.args,
                        cwd: cwd,
                        env: input.env,
                        groupId: sessionID.rawValue,
                        title: input.title,
                        cols: input.cols ?? ProcessDaemon.defaultCols,
                        rows: input.rows ?? ProcessDaemon.defaultRows
                    ))
                } catch {
                    throw UnavailableError(message: String(describing: error))
                }
                guard let info = Self.toInfo(proc) else {
                    throw UnavailableError(message: "Failed to decode created persistent PTY")
                }
                state.withLock { $0.currentBySession[sessionID] = info.id }
                return info
            }

            public func write(_ id: PtySchema.ID, data: String, attachmentID: String? = nil) async throws {
                let info = try await get(id)
                _ = info
                let numericID = try requireNumericID(id)
                do {
                    try transport.service.write_for(id: numericID, attachmentId: attachmentID, bytes: Array(data.utf8))
                } catch {
                    throw UnavailableError(message: String(describing: error))
                }
            }

            public func resize(_ id: PtySchema.ID, cols: UInt16, rows: UInt16, attachmentID: String? = nil) async throws {
                let info = try await get(id)
                let numericID = try requireNumericID(id)
                do {
                    try transport.service.resize_for(id: numericID, attachmentId: attachmentID, cols: cols, rows: rows)
                    state.withLock { $0.currentBySession[info.sessionID] = id }
                } catch {
                    throw UnavailableError(message: String(describing: error))
                }
            }

            public func control(_ id: PtySchema.ID, attachmentID: String, cols: UInt16, rows: UInt16) async throws {
                let info = try await get(id)
                let numericID = try requireNumericID(id)
                do {
                    try transport.service.control(id: numericID, attachmentId: attachmentID, cols: cols, rows: rows)
                    state.withLock { $0.currentBySession[info.sessionID] = id }
                } catch {
                    throw UnavailableError(message: String(describing: error))
                }
            }

            public func input(
                _ id: PtySchema.ID,
                attachmentID: String,
                cols: UInt16,
                rows: UInt16,
                data: [UInt8]
            ) async throws {
                let info = try await get(id)
                let numericID = try requireNumericID(id)
                do {
                    try transport.service.input(id: numericID, attachmentId: attachmentID, cols: cols, rows: rows, bytes: data)
                    state.withLock { $0.currentBySession[info.sessionID] = id }
                } catch {
                    throw UnavailableError(message: String(describing: error))
                }
            }

            public func rename(_ id: PtySchema.ID, title: String?) async throws -> Info {
                _ = try await get(id)
                let numericID = try requireNumericID(id)
                do {
                    try transport.service.rename(id: numericID, title: title)
                } catch {
                    throw UnavailableError(message: String(describing: error))
                }
                return try await get(id)
            }

            public func snapshot(_ id: PtySchema.ID) async throws -> Snapshot {
                _ = try await get(id)
                let numericID = try requireNumericID(id)
                let snap: ProcessDaemon.TerminalSnapshot
                do {
                    snap = try transport.service.snapshot(numericID)
                } catch {
                    throw UnavailableError(message: String(describing: error))
                }
                guard let info = Self.toInfo(snap.info) else {
                    throw UnavailableError(message: "Invalid PTY snapshot")
                }
                return Snapshot(
                    info: info,
                    text: snap.text,
                    checkpoint: snap.checkpoint,
                    cursor: PersistentPtySchema.Cursor(
                        x: SchemaPrimitive.NonNegativeInt(rawValue: Int(snap.cursorX)) ?? .zero,
                        y: SchemaPrimitive.NonNegativeInt(rawValue: Int(snap.cursorY)) ?? .zero
                    )
                )
            }

            public func read(sessionID: SessionID, lines: Int? = nil) async throws -> PersistentPtySchema.ReadResult? {
                if let lines, PersistentPtySchema.ReadLines(rawValue: lines) == nil {
                    throw UnavailableError(message: "lines must be an integer between 1 and 65535")
                }
                guard let id = state.withLock({ $0.currentBySession[sessionID] }) else {
                    return nil
                }
                guard let terminal = try? await get(id), terminal.sessionID == sessionID else {
                    state.withLock { s in
                        if s.currentBySession[sessionID] == id {
                            s.currentBySession.removeValue(forKey: sessionID)
                        }
                    }
                    return nil
                }
                let numericID = try requireNumericID(id)
                let rows: ProcessDaemon.TerminalRows
                do {
                    rows = try transport.service.read_rows(id: numericID, rows: lines.map { UInt16($0) })
                } catch {
                    throw UnavailableError(message: String(describing: error))
                }
                guard let info = Self.toInfo(rows.process) else { return nil }
                return PersistentPtySchema.ReadResult(
                    ptyID: info.id,
                    title: info.title,
                    cwd: info.cwd,
                    foregroundProcess: info.foregroundProcess,
                    screen: PersistentPtySchema.ReadResult.Screen(
                        text: rows.lines.joined(separator: "\n"),
                        cols: info.size.cols,
                        rows: info.size.rows,
                        cursor: PersistentPtySchema.Cursor(
                            x: SchemaPrimitive.NonNegativeInt(rawValue: Int(rows.cursorX)) ?? .zero,
                            y: SchemaPrimitive.NonNegativeInt(rawValue: Int(rows.cursorY)) ?? .zero
                        )
                    )
                )
            }

            public func remove(_ id: PtySchema.ID) async throws {
                let terminal = try await get(id)
                let numericID = try requireNumericID(id)
                do {
                    try transport.service.terminate(numericID)
                } catch {
                    throw UnavailableError(message: String(describing: error))
                }
                state.withLock { s in
                    if s.currentBySession[terminal.sessionID] == id {
                        s.currentBySession.removeValue(forKey: terminal.sessionID)
                    }
                }
            }

            public func shutdown() async throws {
                state.withLock { s in
                    s.handoffExpiresAtMs = 0
                    s.currentBySession.removeAll()
                }
                do {
                    try await transport.shutdown()
                } catch {
                    throw UnavailableError(message: String(describing: error))
                }
            }

            public func handoff() async throws -> PersistentPtySchema.Handoff? {
                let prepared: PersistentPtySchema.Handoff?
                do {
                    prepared = try await transport.handoff()
                } catch {
                    throw UnavailableError(message: String(describing: error))
                }
                if let prepared {
                    state.withLock { $0.handoffExpiresAtMs = prepared.expiresAt }
                }
                return prepared
            }

            public func handoffPrepared() -> Bool {
                let exp = state.withLock { $0.handoffExpiresAtMs }
                return Double(Flock.currentEpochMs()) < exp
            }

            public func attach(_ id: PtySchema.ID, input: PersistentDaemon.SubscribeInput) async throws -> Attachment {
                _ = try await get(id)
                let numericID = try requireNumericID(id)
                let daemonAtt: PersistentDaemon.DaemonAttachment
                do {
                    daemonAtt = try await transport.subscribe(id: numericID, input: input)
                } catch {
                    throw UnavailableError(message: String(describing: error))
                }
                guard let info = Self.toInfo(daemonAtt.terminal) else {
                    throw UnavailableError(message: "Attached process is not a PTY")
                }
                if daemonAtt.role == .controller {
                    state.withLock { $0.currentBySession[info.sessionID] = id }
                }
                return Attachment(
                    info: info,
                    role: daemonAtt.role,
                    generation: daemonAtt.generation,
                    replay: daemonAtt.replay,
                    activate: daemonAtt.activate,
                    detach: daemonAtt.detach
                )
            }

            public func createPipe(_ input: CreatePipeInput) async throws -> PipeInfo {
                let proc: ProcessDaemon.ProcessInfo
                do {
                    proc = try transport.service.create_pipe(ProcessDaemon.CreatePipe(
                        program: input.program,
                        args: input.args,
                        cwd: input.cwd,
                        env: input.env,
                        groupId: input.groupID,
                        outputPath: input.outputPath,
                        metadata: input.metadata
                    ))
                } catch {
                    throw RequestError(message: String(describing: error))
                }
                guard let pipeInfo = Self.toPipeInfo(proc) else {
                    throw RequestError(message: "Created process is not a pipe")
                }
                return pipeInfo
            }

            public func waitPipe(_ id: UInt64) async throws -> PipeExit {
                let exit: ProcessDaemon.ProcessExit
                do {
                    let waiter = try transport.service.wait(id)
                    exit = try waiter.recv()
                } catch {
                    throw RequestError(message: String(describing: error))
                }
                return PipeExit(
                    exitCode: exit.exitCode,
                    signal: exit.signal,
                    finalOffset: exit.finalOffset,
                    outputLines: exit.outputLines ?? 0,
                    outputError: exit.outputError,
                    exitedAt: exit.exitedAt
                )
            }

            public func getPipe(_ id: UInt64) async throws -> PipeInfo {
                let proc: ProcessDaemon.ProcessInfo
                do {
                    proc = try transport.service.get(id)
                } catch {
                    throw ProcessNotFoundError(processID: id)
                }
                guard proc.mode == .pipe, let info = Self.toPipeInfo(proc) else {
                    throw ProcessNotFoundError(processID: id)
                }
                return info
            }

            public func signalPipe(_ id: UInt64, signal: PersistentDaemon.Signal) async throws {
                do {
                    try transport.service.signal(id: id, signal: signal)
                } catch {
                    throw RequestError(message: String(describing: error))
                }
            }

            public func setPipeMetadata(_ id: UInt64, metadata: ProcessDaemon.PipeMetadata) async throws {
                do {
                    try transport.service.set_metadata(id: id, metadata: metadata)
                } catch {
                    throw RequestError(message: String(describing: error))
                }
            }

            public func terminatePipe(_ id: UInt64) async throws {
                do {
                    try transport.service.terminate(id)
                } catch {
                    throw RequestError(message: String(describing: error))
                }
            }

            public func listPipes() async throws -> [PipeInfo] {
                let procs: [ProcessDaemon.ProcessInfo]
                do {
                    procs = try transport.service.list(.pipe)
                } catch {
                    throw RequestError(message: String(describing: error))
                }
                return procs.compactMap(Self.toPipeInfo)
            }

            private func requireNumericID(_ id: PtySchema.ID) throws -> ProcessDaemon.TerminalId {
                guard let numeric = Self.parseID(id) else {
                    throw NotFoundError(ptyID: id)
                }
                return numeric
            }

            private static func toID(_ value: ProcessDaemon.TerminalId) -> PtySchema.ID {
                PtySchema.ID(rawValue: "pty_persistent_\(value)")!
            }

            private static func parseID(_ id: PtySchema.ID) -> ProcessDaemon.TerminalId? {
                guard id.rawValue.hasPrefix("pty_persistent_") else { return nil }
                return UInt64(id.rawValue.dropFirst("pty_persistent_".count))
            }

            private static func toInfo(_ value: ProcessDaemon.ProcessInfo) -> Info? {
                guard let pty = value.pty else { return nil }
                let status: PtySchema.Status
                let exitCode: SchemaPrimitive.NonNegativeInt?
                switch value.lifecycle {
                case .running:
                    status = .running
                    exitCode = nil
                case .exited(let code, _):
                    status = .exited
                    exitCode = code.flatMap { SchemaPrimitive.NonNegativeInt(rawValue: Int($0)) }
                case .failed:
                    status = .exited
                    exitCode = nil
                }
                let sessionID = SessionID(rawValue: value.groupId) ?? SessionID(rawValue: "ses_\(value.groupId)")!
                return Info(
                    id: toID(value.id),
                    title: pty.title,
                    command: value.command.first ?? "",
                    args: Array(value.command.dropFirst()),
                    cwd: value.cwd,
                    status: status,
                    pid: SchemaPrimitive.NonNegativeInt(rawValue: Int(value.pid ?? 0)) ?? .zero,
                    exitCode: exitCode,
                    sessionID: sessionID,
                    userTitle: pty.userTitle,
                    foregroundProcess: pty.foregroundProcess,
                    size: PersistentPtySchema.Size(
                        cols: SchemaPrimitive.PositiveInt(rawValue: max(1, Int(pty.cols)))!,
                        rows: SchemaPrimitive.PositiveInt(rawValue: max(1, Int(pty.rows)))!
                    ),
                    output: PersistentPtySchema.OutputRange(
                        head: SchemaPrimitive.NonNegativeInt(rawValue: Int(value.outputHead)) ?? .zero,
                        tail: SchemaPrimitive.NonNegativeInt(rawValue: Int(value.outputTail)) ?? .zero
                    )
                )
            }

            private static func toPipeInfo(_ value: ProcessDaemon.ProcessInfo) -> PipeInfo? {
                guard let pipe = value.pipe else { return nil }
                return PipeInfo(
                    id: value.id,
                    pid: value.pid,
                    command: value.command,
                    cwd: value.cwd,
                    groupID: value.groupId,
                    lifecycle: value.lifecycle,
                    outputTail: value.outputTail,
                    outputLines: pipe.outputLines,
                    outputPath: pipe.outputPath,
                    outputError: pipe.outputError,
                    metadata: pipe.metadata,
                    startedAt: value.startedAt,
                    exitedAt: value.exitedAt
                )
            }
        }

        // parity: core/src/persistent-pty/index.ts#layer [status=adapted hash=51442fff3128]
        public static let layer: LayerNode.ExecutableLayer = layerWith(Options())

        // parity: core/src/persistent-pty/index.ts#layerWith [status=adapted hash=92c656d51c05]
        public static func layerWith(_ options: Options) -> LayerNode.ExecutableLayer {
            LayerNode.ExecutableLayer { _, _ in
                LayerNode.Output([Service.serviceKey: Service(options: options) as any Interface])
            }
        }

        // parity: core/src/persistent-pty/index.ts#configured [status=adapted hash=f70ed791c2ee]
        public static func configured(_ options: Options? = nil) -> LayerNode.Provider {
            AppNode.makeGlobalNode(
                Service.serviceKey,
                options.map(layerWith) ?? layer,
                [Global.node]
            )
        }

        // parity: core/src/persistent-pty/index.ts#node [status=adapted hash=aea3814ebc3b]
        public static let node: LayerNode.Provider = configured()
    }
}

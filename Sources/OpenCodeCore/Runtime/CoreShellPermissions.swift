import OpenCodeSchema

// MARK: - Shell Permissions (`core/src/shell/permissions.ts`)

public enum CoreShellPermissions {
    // parity: core/src/shell/permissions.ts#UnverifiableError [status=implemented hash=1fd11677dd5b]
    public struct UnverifiableError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "ShellPermissions.UnverifiableError"
        public let reason: String

        public init(reason: String) {
            self.reason = reason
        }

        // parity: core/src/shell/permissions.ts#UnverifiableError.message [status=implemented hash=a476648a3022]
        public var message: String {
            "Portable shell scanner cannot analyze command: \(reason). A shell deny rule is configured and the command cannot be checked against it; rewrite it without eval or other dynamic execution."
        }

        public var description: String { message }
    }

    public struct RequestInput: Sendable {
        public let command: String
        public let program: String
        public let target: CoreFilesystem.FileAccess.Target
        public let once: Bool
        /// The agent's and session's rules, read only for a command the scanner can't analyze.
        public let rules: @Sendable () async throws -> CorePermission.Ruleset

        public init(
            command: String,
            program: String,
            target: CoreFilesystem.FileAccess.Target,
            once: Bool = false,
            rules: @escaping @Sendable () async throws -> CorePermission.Ruleset = { [] }
        ) {
            self.command = command
            self.program = program
            self.target = target
            self.once = once
            self.rules = rules
        }

        /// Compatibility initializer for callers still passing `local:` while migrating to `rules:`.
        public init(
            command: String,
            program: String,
            target: CoreFilesystem.FileAccess.Target,
            local: Bool,
            once: Bool = false,
            rules: @escaping @Sendable () async throws -> CorePermission.Ruleset = { [] }
        ) {
            _ = local
            self.command = command
            self.program = program
            self.target = target
            self.once = once
            self.rules = rules
        }
    }

    /// Scans `input.command` for external directories and shell subcommands and returns the ordered
    /// permission requests (`external_directory`, then `shell`). When `once` is true, `save` patterns are
    /// omitted and even a command with no parsed subcommands still produces a `shell` request for the raw command.
    /// When the scanner cannot analyze the command, throws `UnverifiableError` if any rule denies `shell`, or asks
    /// for `external_directory: ["*"]` and the exact `shell` command without saving.
    // parity: core/src/shell/permissions.ts#requests [status=implemented hash=4f86670e758a]
    public static func requests(
        access: any CoreFilesystem.FileAccess.Interface,
        input: RequestInput
    ) async throws -> [CoreFilesystem.FileAccess.PermissionRequest] {
        let parsed: CoreShell.Parse.Result
        do {
            parsed = try CoreShell.Parse.scan(
                command: input.command,
                shell: input.program,
                cwd: input.target.absolute.rawValue,
                home: input.target.machine == nil ? .server : .unknown
            )
        } catch let opaque as CoreShell.Parse.OpaqueError {
            // A deny pattern can't be matched against subcommands the scanner couldn't find.
            let rules = try await input.rules()
            if rules.contains(where: { $0.effect == .deny && CorePermissionWildcard.match("shell", pattern: $0.action) }) {
                throw UnverifiableError(reason: opaque.reason)
            }
            // An unanalyzed command may reach any directory, so only rules allowing every directory settle it, and
            // approval is never saved as a pattern.
            return [
                CoreFilesystem.FileAccess.PermissionRequest(
                    action: "external_directory",
                    resources: ["*"],
                    save: nil
                ),
                CoreFilesystem.FileAccess.PermissionRequest(
                    action: "shell",
                    resources: [input.command],
                    save: nil,
                    metadata: ["reason": .string(opaque.reason)]
                ),
            ]
        }
        // Directory arguments are relative to the command's working directory on the same machine.
        var directories: [CoreFilesystem.FileAccess.Target] = []
        directories.reserveCapacity(parsed.directories.count)
        for directory in parsed.directories {
            let resolved = try await access.resolve(
                CoreFilesystem.FileAccess.ResolveInput(
                    path: directory,
                    kind: .directory,
                    base: input.target.place
                )
            )
            directories.append(resolved)
        }
        let external = CoreFilesystem.FileAccess.externalDirectoryRequest([input.target] + directories)
        let command: CoreFilesystem.FileAccess.PermissionRequest? =
            (!parsed.commands.isEmpty || input.once)
            ? CoreFilesystem.FileAccess.PermissionRequest(
                action: "shell",
                resources: !parsed.commands.isEmpty ? parsed.commands.map(\.resource) : [input.command],
                save: parsed.commands.map(\.save)
            )
            : nil
        return [external, command].compactMap { req in
            guard let req else { return nil }
            return CoreFilesystem.FileAccess.PermissionRequest(
                action: req.action,
                resources: req.resources,
                save: input.once ? nil : req.save,
                metadata: req.metadata
            )
        }
    }
}

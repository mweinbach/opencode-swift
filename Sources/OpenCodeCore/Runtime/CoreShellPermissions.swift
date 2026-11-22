import OpenCodeSchema

// MARK: - Shell Permissions (`core/src/shell/permissions.ts`)

public enum CoreShellPermissions {
    public struct RequestInput: Sendable {
        public let command: String
        public let program: String
        public let target: CoreFilesystem.FileAccess.Target
        public let local: Bool
        public let once: Bool
        /// The agent's and session's rules, read only for a command the scanner can't analyze.
        public let rules: (@Sendable () async throws -> PermissionSchema.Ruleset)?

        public init(
            command: String,
            program: String,
            target: CoreFilesystem.FileAccess.Target,
            local: Bool = true,
            once: Bool = false,
            rules: (@Sendable () async throws -> PermissionSchema.Ruleset)? = nil
        ) {
            self.command = command
            self.program = program
            self.target = target
            self.local = local
            self.once = once
            self.rules = rules
        }
    }

    /// Scans `input.command` for external directories and shell subcommands and returns the ordered
    /// permission requests (`external_directory`, then `shell`). When `once` is true, `save` patterns are
    /// omitted and even a command with no parsed subcommands still produces a `shell` request for the raw command.
    // parity: core/src/shell/permissions.ts#requests [status=implemented hash=fd0e62480425]
    public static func requests(
        access: any CoreFilesystem.FileAccess.Interface,
        input: RequestInput
    ) async throws -> [CoreFilesystem.FileAccess.PermissionRequest] {
        let parsed = try CoreShell.Parse.scan(
            command: input.command,
            shell: input.program,
            cwd: input.target.absolute.rawValue,
            home: input.local ? .server : .unknown
        )
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
                save: input.once ? nil : req.save
            )
        }
    }
}

/// Pure Swift 6.2 project, workspace, worktree, location, VCS, filesystem, PTY, shell, job, automation, and integration schemas.
/// Ports `packages/schema/src/{integration-id,project,workspace,worktree,location,vcs,filesystem,pty,pty-ticket,persistent-pty,shell,job,automation,integration}.ts`.
/// 100% pure Swift standard library (zero OS imports, zero Foundation imports).

// MARK: - src/integration-id.ts

/// Branded Integration identifier.
// parity: schema/src/integration-id.ts#IntegrationID [status=implemented hash=33a71751cdab]
public struct IntegrationID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Branded Integration method identifier.
// parity: schema/src/integration-id.ts#IntegrationMethodID [status=implemented hash=adc1bf268738]
public struct IntegrationMethodID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - src/project.ts

public enum ProjectSchema {
    // parity: schema/src/project.ts#ID [status=implemented hash=a552ef8329c5]
    public typealias ID = ProjectID

    /// VCS provider identifier matching `^[a-z][a-z0-9._-]*$`.
    // parity: schema/src/project.ts#Vcs [status=implemented hash=74bdc69a10e2]
    public struct Vcs: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            guard SchemaPrimitive.isProjectVcs(rawValue) else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: String) throws(SchemaPrimitive.ValidationError) {
            guard SchemaPrimitive.isProjectVcs(value) else {
                throw .invalidFormat(expected: "^[a-z][a-z0-9._-]*$", actual: value)
            }
            self.rawValue = value
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard SchemaPrimitive.isProjectVcs(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid Project.Vcs '\(value)'"
                )
            }
            self.rawValue = value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/project.ts#Current [status=implemented hash=810bab5cede5]
    public struct Current: Equatable, Hashable, Sendable, Codable {
        public let id: ID
        public let directory: SchemaPrimitive.AbsolutePath
        public let canonical: SchemaPrimitive.AbsolutePath

        public init(
            id: ID,
            directory: SchemaPrimitive.AbsolutePath,
            canonical: SchemaPrimitive.AbsolutePath
        ) {
            self.id = id
            self.directory = directory
            self.canonical = canonical
        }
    }

    // parity: schema/src/project.ts#Icon [status=implemented hash=60bb55df6630]
    public struct Icon: Equatable, Hashable, Sendable, Codable {
        public let url: String?
        public let override: String?
        public let color: String?

        public init(url: String? = nil, override: String? = nil, color: String? = nil) {
            self.url = url
            self.override = override
            self.color = color
        }
    }

    // parity: schema/src/project.ts#Commands [status=implemented hash=6dbc46c8ae6d]
    public struct Commands: Equatable, Hashable, Sendable, Codable {
        public let start: String?

        public init(start: String? = nil) {
            self.start = start
        }
    }

    // parity: schema/src/project.ts#Time [status=implemented hash=9f2d29cbaa25]
    public struct Time: Equatable, Hashable, Sendable, Codable {
        public let created: SchemaPrimitive.NonNegativeInt
        public let updated: SchemaPrimitive.NonNegativeInt
        public let active: SchemaPrimitive.NonNegativeInt
        public let archived: SchemaPrimitive.NonNegativeInt?

        public init(
            created: SchemaPrimitive.NonNegativeInt,
            updated: SchemaPrimitive.NonNegativeInt,
            active: SchemaPrimitive.NonNegativeInt,
            archived: SchemaPrimitive.NonNegativeInt? = nil
        ) {
            self.created = created
            self.updated = updated
            self.active = active
            self.archived = archived
        }
    }

    // parity: schema/src/project.ts#Info [status=implemented hash=a7cb3ae630d6]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let id: ID
        public let canonical: SchemaPrimitive.AbsolutePath
        public let vcs: Vcs?
        public let name: String?
        public let icon: Icon?
        public let commands: Commands?
        public let time: Time
        public let sandboxes: [String]

        public init(
            id: ID,
            canonical: SchemaPrimitive.AbsolutePath,
            vcs: Vcs? = nil,
            name: String? = nil,
            icon: Icon? = nil,
            commands: Commands? = nil,
            time: Time,
            sandboxes: [String]
        ) {
            self.id = id
            self.canonical = canonical
            self.vcs = vcs
            self.name = name
            self.icon = icon
            self.commands = commands
            self.time = time
            self.sandboxes = sandboxes
        }
    }

    // parity: schema/src/project.ts#UpdateInput [status=implemented hash=428dc8a568b9]
    public struct UpdateInput: Equatable, Hashable, Sendable, Codable {
        public let projectID: ID
        public let canonical: SchemaPrimitive.AbsolutePath?
        public let name: String?
        public let icon: Icon?
        public let commands: Commands?

        public init(
            projectID: ID,
            canonical: SchemaPrimitive.AbsolutePath? = nil,
            name: String? = nil,
            icon: Icon? = nil,
            commands: Commands? = nil
        ) {
            self.projectID = projectID
            self.canonical = canonical
            self.name = name
            self.icon = icon
            self.commands = commands
        }
    }

    // parity: schema/src/project.ts#Event [status=implemented hash=e7550d251b3a]
    public enum Event {
        public static let updated = SchemaPrimitive.EventDescriptor.ephemeral(type: "project.updated")
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [updated]
    }
}

// MARK: - src/workspace.ts

public enum WorkspaceSchema {
    // parity: schema/src/workspace.ts#ID [status=implemented hash=1708c8458e95]
    public typealias ID = WorkspaceID

    // parity: schema/src/workspace.ts#DestroyResult [status=implemented hash=66a4321d9347]
    public struct DestroyResult: Equatable, Hashable, Sendable, Codable {
        public let destroyed: Bool

        public init(destroyed: Bool) {
            self.destroyed = destroyed
        }
    }

    // parity: schema/src/workspace.ts#Event [status=implemented hash=ac12f8899903]
    public enum Event {
        public static let ready = SchemaPrimitive.EventDescriptor.ephemeral(type: "workspace.ready")
        public static let failed = SchemaPrimitive.EventDescriptor.ephemeral(type: "workspace.failed")
        public static let status = SchemaPrimitive.EventDescriptor.ephemeral(type: "workspace.status")
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [ready, failed, status]
    }
}

// MARK: - src/worktree.ts

public enum WorktreeSchema {
    // parity: schema/src/worktree.ts#StrategyID [status=implemented hash=f3c97f13812f]
    public struct StrategyID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            let trimmed = SchemaPrimitive.trimWhitespace(rawValue)
            guard !trimmed.isEmpty else { return nil }
            self.rawValue = trimmed
        }

        public init(validating value: String) throws(SchemaPrimitive.ValidationError) {
            let trimmed = SchemaPrimitive.trimWhitespace(value)
            guard !trimmed.isEmpty else { throw .emptyString(field: "strategyID") }
            self.rawValue = trimmed
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let trimmed = SchemaPrimitive.trimWhitespace(raw)
            guard !trimmed.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Worktree.StrategyID must be non-empty"
                )
            }
            self.rawValue = trimmed
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/worktree.ts#CreateInput [status=implemented hash=5059b46bbfb7]
    public struct CreateInput: Equatable, Hashable, Sendable, Codable {
        public let projectID: ProjectID
        public let from: SchemaPrimitive.AbsolutePath?
        public let branch: String?
        public let directory: SchemaPrimitive.AbsolutePath?
        public let name: String?

        public init(
            projectID: ProjectID,
            from: SchemaPrimitive.AbsolutePath? = nil,
            branch: String? = nil,
            directory: SchemaPrimitive.AbsolutePath? = nil,
            name: String? = nil
        ) {
            self.projectID = projectID
            self.from = from
            self.branch = branch.map(SchemaPrimitive.trimWhitespace)
            self.directory = directory
            self.name = name
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.projectID = try container.decode(ProjectID.self, forKey: .projectID)
            self.from = try container.decodeIfPresent(SchemaPrimitive.AbsolutePath.self, forKey: .from)
            if let rawBranch = try container.decodeIfPresent(String.self, forKey: .branch) {
                let trimmed = SchemaPrimitive.trimWhitespace(rawBranch)
                guard !trimmed.isEmpty else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .branch,
                        in: container,
                        debugDescription: "Worktree.CreateInput.branch must be non-empty when present"
                    )
                }
                self.branch = trimmed
            } else {
                self.branch = nil
            }
            self.directory = try container.decodeIfPresent(SchemaPrimitive.AbsolutePath.self, forKey: .directory)
            self.name = try container.decodeIfPresent(String.self, forKey: .name)
        }

        enum CodingKeys: String, CodingKey {
            case projectID
            case from
            case branch
            case directory
            case name
        }
    }

    // parity: schema/src/worktree.ts#RemoveInput [status=implemented hash=52505ad35ebb]
    public struct RemoveInput: Equatable, Hashable, Sendable, Codable {
        public let projectID: ProjectID
        public let directory: SchemaPrimitive.AbsolutePath
        public let force: Bool

        public init(projectID: ProjectID, directory: SchemaPrimitive.AbsolutePath, force: Bool) {
            self.projectID = projectID
            self.directory = directory
            self.force = force
        }
    }

    // parity: schema/src/worktree.ts#Info [status=implemented hash=5d0f3bc6e4dc]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let directory: SchemaPrimitive.AbsolutePath

        public init(directory: SchemaPrimitive.AbsolutePath) {
            self.directory = directory
        }
    }

    // parity: schema/src/worktree.ts#Directory [status=implemented hash=9d68fe9aa4b2]
    public struct Directory: Equatable, Hashable, Sendable, Codable {
        public let directory: SchemaPrimitive.AbsolutePath
        public let strategy: String?

        public init(directory: SchemaPrimitive.AbsolutePath, strategy: String? = nil) {
            self.directory = directory
            self.strategy = strategy
        }
    }

    // parity: schema/src/worktree.ts#ListEntry [status=implemented hash=653e88bd2213]
    public struct ListEntry: Equatable, Hashable, Sendable, Codable {
        public enum EntryType: String, Equatable, Hashable, Sendable, Codable {
            case root
            case worktree
        }

        public let directory: SchemaPrimitive.AbsolutePath
        public let type: EntryType

        public init(directory: SchemaPrimitive.AbsolutePath, type: EntryType) {
            self.directory = directory
            self.type = type
        }
    }

    // parity: schema/src/worktree.ts#OperationError [status=implemented hash=8c0688dd5ea7]
    public struct OperationError: Swift.Error, Equatable, Hashable, Sendable, Codable {
        public static let tag = "Worktree.OperationError"
        public let message: String
        public let forceRequired: Bool?

        public init(message: String, forceRequired: Bool? = nil) {
            self.message = message
            self.forceRequired = forceRequired
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.tag) {
                try SchemaPrimitive.decodeRequiredLiteral(Self.tag, from: container, forKey: .tag)
            }
            self.message = try container.decode(String.self, forKey: .message)
            self.forceRequired = try container.decodeIfPresent(Bool.self, forKey: .forceRequired)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.tag, forKey: .tag)
            try container.encode(message, forKey: .message)
            try container.encodeIfPresent(forceRequired, forKey: .forceRequired)
        }

        enum CodingKeys: String, CodingKey {
            case tag = "_tag"
            case message
            case forceRequired
        }
    }

    // parity: schema/src/worktree.ts#List [status=implemented hash=3892002cae6e]
    public typealias List = [Directory]

    // parity: schema/src/worktree.ts#Event [status=implemented hash=35a10412729d]
    public enum Event {
        public struct UpdatedPayload: Equatable, Hashable, Sendable, Codable {
            public let projectID: ProjectID

            public init(projectID: ProjectID) {
                self.projectID = projectID
            }
        }

        public struct ResolvedPayload: Equatable, Hashable, Sendable, Codable {
            public let projectID: ProjectID
            public let directory: SchemaPrimitive.AbsolutePath
            public let previous: ProjectID
            public let adopted: [ProjectID]?

            public init(
                projectID: ProjectID,
                directory: SchemaPrimitive.AbsolutePath,
                previous: ProjectID,
                adopted: [ProjectID]? = nil
            ) {
                self.projectID = projectID
                self.directory = directory
                self.previous = previous
                self.adopted = adopted
            }
        }

        public static let updated = SchemaPrimitive.EventDescriptor.ephemeral(type: "worktree.updated")
        public static let resolved = SchemaPrimitive.EventDescriptor.durable(
            type: "worktree.resolved",
            aggregate: "projectID",
            version: 1
        )
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [updated, resolved]
    }

    public struct AdoptSession: Equatable, Hashable, Sendable {
        public let projectID: String
        public let directory: String
        public let workspaceID: String?

        public init(projectID: String, directory: String, workspaceID: String? = nil) {
            self.projectID = projectID
            self.directory = directory
            self.workspaceID = workspaceID
        }
    }

    public struct AdoptEvent: Equatable, Hashable, Sendable {
        public let projectID: String
        public let directory: String
        public let previous: String
        public let adopted: [String]?

        public init(projectID: String, directory: String, previous: String, adopted: [String]? = nil) {
            self.projectID = projectID
            self.directory = directory
            self.previous = previous
            self.adopted = adopted
        }
    }

    public struct AdoptionResult: Equatable, Hashable, Sendable {
        public let projectID: String
        public let subpath: String?

        public init(projectID: String, subpath: String? = nil) {
            self.projectID = projectID
            self.subpath = subpath
        }
    }

    /// Computes whether a session under a resolved worktree should be adopted into the resolved project.
    // parity: schema/src/worktree.ts#adopt [status=implemented hash=ba5db4a80658]
    public static func adopt(_ session: AdoptSession, _ event: AdoptEvent) -> AdoptionResult? {
        if let workspaceID = session.workspaceID, !workspaceID.isEmpty {
            return nil
        }
        let matchesAdopted = event.adopted?.contains(session.projectID) ?? false
        if session.projectID != event.previous &&
            session.projectID != ProjectID.global.rawValue &&
            !matchesAdopted
        {
            return nil
        }
        if session.projectID == event.projectID {
            return nil
        }

        func normalize(_ value: String) -> String {
            let replaced = String(value.map { $0 == "\\" ? "/" : $0 })
            var result = ""
            for segment in replaced.split(separator: "/", omittingEmptySubsequences: false) {
                if segment.isEmpty || segment == "." { continue }
                if segment == ".." {
                    if let idx = result.lastIndex(of: "/") {
                        result = String(result[..<idx])
                    } else {
                        result = ""
                    }
                    continue
                }
                result += "/\(segment)"
            }
            return result
        }

        let directory = normalize(session.directory)
        let root = normalize(event.directory)
        let rootBytes = Array(root.utf8)
        let isWindows = rootBytes.count >= 3 &&
            rootBytes[0] == 0x2F &&
            SchemaPrimitive.isAsciiLetter(rootBytes[1]) &&
            rootBytes[2] == 0x3A
        let key = isWindows ? directory.lowercased() : directory
        let parent = isWindows ? root.lowercased() : root
        if key != parent && !key.hasPrefix(parent + "/") {
            return nil
        }
        let subpath: String?
        if key == parent {
            subpath = nil
        } else {
            let cut = directory.utf16.index(directory.utf16.startIndex, offsetBy: root.utf16.count + 1)
            subpath = String(directory[cut...])
        }
        return AdoptionResult(projectID: event.projectID, subpath: subpath)
    }
}

// MARK: - src/location.ts

public enum LocationSchema {
    // parity: schema/src/location.ts#Ref [status=implemented hash=27e170edcfd4]
    public struct Ref: Equatable, Hashable, Sendable, Codable {
        public let directory: SchemaPrimitive.AbsolutePath
        public let workspaceID: WorkspaceID?

        public init(directory: SchemaPrimitive.AbsolutePath, workspaceID: WorkspaceID? = nil) {
            self.directory = directory
            self.workspaceID = workspaceID
        }
    }

    // parity: schema/src/location.ts#PublicRef [status=implemented hash=00f6ac414181]
    public struct PublicRef: Equatable, Hashable, Sendable, Codable {
        public let directory: SchemaPrimitive.AbsolutePath

        public init(directory: SchemaPrimitive.AbsolutePath) {
            self.directory = directory
        }
    }

    public struct ProjectRef: Equatable, Hashable, Sendable, Codable {
        public let id: ProjectID
        public let directory: SchemaPrimitive.AbsolutePath
        public let canonical: SchemaPrimitive.AbsolutePath

        public init(
            id: ProjectID,
            directory: SchemaPrimitive.AbsolutePath,
            canonical: SchemaPrimitive.AbsolutePath
        ) {
            self.id = id
            self.directory = directory
            self.canonical = canonical
        }
    }

    // parity: schema/src/location.ts#Info [status=implemented hash=eb1cd4f7156b]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let directory: SchemaPrimitive.AbsolutePath
        public let workspaceID: WorkspaceID?
        public let project: ProjectRef

        public init(
            directory: SchemaPrimitive.AbsolutePath,
            workspaceID: WorkspaceID? = nil,
            project: ProjectRef
        ) {
            self.directory = directory
            self.workspaceID = workspaceID
            self.project = project
        }
    }

    // parity: schema/src/location.ts#PublicInfo [status=implemented hash=6b31b6b90c2b]
    public struct PublicInfo: Equatable, Hashable, Sendable, Codable {
        public let directory: SchemaPrimitive.AbsolutePath
        public let project: ProjectRef

        public init(directory: SchemaPrimitive.AbsolutePath, project: ProjectRef) {
            self.directory = directory
            self.project = project
        }
    }

    public struct ResponseEnvelope<Data: Equatable & Hashable & Sendable & Codable>: Equatable, Hashable, Sendable, Codable {
        public let location: PublicRef
        public let data: Data

        public init(location: PublicRef, data: Data) {
            self.location = location
            self.data = data
        }
    }

    // parity: schema/src/location.ts#response [status=implemented hash=b4aa92c710af]
    public static func response<Data: Equatable & Hashable & Sendable & Codable>(
        location: PublicRef,
        data: Data
    ) -> ResponseEnvelope<Data> {
        ResponseEnvelope(location: location, data: data)
    }
}

// MARK: - src/vcs.ts

public enum VcsSchema {
    // parity: schema/src/vcs.ts#Branch [status=implemented hash=15cd963a0b40]
    public struct Branch: Equatable, Hashable, Sendable, Codable {
        public let current: String?
        public let defaultBranch: String?

        public init(current: String? = nil, defaultBranch: String? = nil) {
            self.current = current
            self.defaultBranch = defaultBranch
        }

        enum CodingKeys: String, CodingKey {
            case current
            case defaultBranch = "default"
        }
    }

    // parity: schema/src/vcs.ts#Info [status=implemented hash=062a1a8d096c]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let provider: String?
        public let branch: Branch

        public init(provider: String? = nil, branch: Branch) {
            self.provider = provider
            self.branch = branch
        }
    }

    // parity: schema/src/vcs.ts#BranchList [status=implemented hash=f17daaa07852]
    public typealias BranchList = [String]

    // parity: schema/src/vcs.ts#Base [status=implemented hash=300a321e1fc2]
    public struct Base: Equatable, Hashable, Sendable, Codable {
        public enum Source: String, Equatable, Hashable, Sendable, Codable {
            case reflog
            case `default`
        }

        public let name: String
        public let ref: String
        public let source: Source

        public init(name: String, ref: String, source: Source) {
            self.name = name
            self.ref = ref
            self.source = source
        }
    }

    // parity: schema/src/vcs.ts#Mode [status=implemented hash=2883bda55d21]
    public enum Mode: String, Equatable, Hashable, Sendable, Codable {
        case working
        case branch
        case committed
    }

    // parity: schema/src/vcs.ts#Untracked [status=implemented hash=c6174be233a6]
    public enum Untracked: String, Equatable, Hashable, Sendable, Codable {
        case files
        case folders
    }

    // parity: schema/src/vcs.ts#FileStatus [status=implemented hash=1846d3783585]
    public struct FileStatus: Equatable, Hashable, Sendable, Codable {
        public enum Status: String, Equatable, Hashable, Sendable, Codable {
            case added
            case deleted
            case modified
        }

        public let file: String
        public let additions: SchemaPrimitive.NonNegativeInt
        public let deletions: SchemaPrimitive.NonNegativeInt
        public let status: Status

        public init(
            file: String,
            additions: SchemaPrimitive.NonNegativeInt,
            deletions: SchemaPrimitive.NonNegativeInt,
            status: Status
        ) {
            self.file = file
            self.additions = additions
            self.deletions = deletions
            self.status = status
        }
    }
}

// MARK: - src/filesystem.ts

public enum FileSystemSchema {
    // parity: schema/src/filesystem.ts#Event [status=implemented hash=4e2a9d37bc0b]
    public enum Event {
        public enum ChangeKind: String, Equatable, Hashable, Sendable, Codable {
            case add
            case change
            case unlink
        }

        public struct ChangedPayload: Equatable, Hashable, Sendable, Codable {
            public let file: String
            public let event: ChangeKind

            public init(file: String, event: ChangeKind) {
                self.file = file
                self.event = event
            }
        }

        public static let changed = SchemaPrimitive.EventDescriptor.ephemeral(type: "filesystem.changed")
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [changed]
    }

    public enum EntryType: String, Equatable, Hashable, Sendable, Codable {
        case file
        case directory
    }

    // parity: schema/src/filesystem.ts#Entry [status=implemented hash=10006e92b25e]
    public struct Entry: Equatable, Hashable, Sendable, Codable {
        public let path: SchemaPrimitive.RelativePath
        public let type: EntryType

        public init(path: SchemaPrimitive.RelativePath, type: EntryType) {
            self.path = path
            self.type = type
        }
    }

    // parity: schema/src/filesystem.ts#Submatch [status=implemented hash=99d1a77356e7]
    public struct Submatch: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public let start: SchemaPrimitive.NonNegativeInt
        public let end: SchemaPrimitive.NonNegativeInt

        public init(
            text: String,
            start: SchemaPrimitive.NonNegativeInt,
            end: SchemaPrimitive.NonNegativeInt
        ) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    // parity: schema/src/filesystem.ts#Match [status=implemented hash=50c1bba0edd5]
    public struct Match: Equatable, Hashable, Sendable, Codable {
        public let entry: Entry
        public let line: SchemaPrimitive.PositiveInt
        public let offset: SchemaPrimitive.NonNegativeInt
        public let text: String
        public let submatches: [Submatch]

        public init(
            entry: Entry,
            line: SchemaPrimitive.PositiveInt,
            offset: SchemaPrimitive.NonNegativeInt,
            text: String,
            submatches: [Submatch]
        ) {
            self.entry = entry
            self.line = line
            self.offset = offset
            self.text = text
            self.submatches = submatches
        }
    }

    // parity: schema/src/filesystem.ts#FindInput [status=implemented hash=cdbc413e1795]
    public struct FindInput: Equatable, Hashable, Sendable, Codable {
        public let query: String
        public let type: EntryType?
        public let limit: SchemaPrimitive.PositiveInt?

        public init(query: String, type: EntryType? = nil, limit: SchemaPrimitive.PositiveInt? = nil) {
            self.query = query
            self.type = type
            self.limit = limit
        }
    }

    // parity: schema/src/filesystem.ts#Write [status=implemented hash=e9c75145d282]
    public struct Write: Equatable, Hashable, Sendable, Codable {
        public let path: SchemaPrimitive.AbsolutePath

        public init(path: SchemaPrimitive.AbsolutePath) {
            self.path = path
        }
    }
}

// MARK: - src/pty.ts

public enum PtySchema {
    // parity: schema/src/pty.ts#ID [status=implemented hash=211acc50d27d]
    public struct ID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            guard rawValue.hasPrefix("pty") else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: String) throws(IdentifierValidationError) {
            guard value.hasPrefix("pty") else {
                throw .invalidPrefix(expected: "pty", actual: value)
            }
            self.rawValue = value
        }

        private init(unchecked value: String) {
            self.rawValue = value
        }

        public static func create() -> ID {
            ID(unchecked: "pty_" + Identifier.ascending())
        }

        public static func ascending(_ id: String? = nil) throws(IdentifierValidationError) -> ID {
            guard let id else { return create() }
            return try ID(validating: id)
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            self = try ID(validating: value)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public enum Status: String, Equatable, Hashable, Sendable, Codable {
        case running
        case exited
    }

    // parity: schema/src/pty.ts#Info [status=implemented hash=63534a17c78f]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let id: ID
        public let title: String
        public let command: String
        public let args: [String]
        public let cwd: String
        public let status: Status
        public let pid: SchemaPrimitive.NonNegativeInt
        public let exitCode: SchemaPrimitive.NonNegativeInt?

        public init(
            id: ID,
            title: String,
            command: String,
            args: [String],
            cwd: String,
            status: Status,
            pid: SchemaPrimitive.NonNegativeInt,
            exitCode: SchemaPrimitive.NonNegativeInt? = nil
        ) {
            self.id = id
            self.title = title
            self.command = command
            self.args = args
            self.cwd = cwd
            self.status = status
            self.pid = pid
            self.exitCode = exitCode
        }
    }

    // parity: schema/src/pty.ts#Event [status=implemented hash=59ad455e011f]
    public enum Event {
        public struct InfoPayload: Equatable, Hashable, Sendable, Codable {
            public let info: Info

            public init(info: Info) {
                self.info = info
            }
        }

        public struct ExitedPayload: Equatable, Hashable, Sendable, Codable {
            public let id: ID
            public let exitCode: SchemaPrimitive.NonNegativeInt

            public init(id: ID, exitCode: SchemaPrimitive.NonNegativeInt) {
                self.id = id
                self.exitCode = exitCode
            }
        }

        public struct DeletedPayload: Equatable, Hashable, Sendable, Codable {
            public let id: ID

            public init(id: ID) {
                self.id = id
            }
        }

        public static let created = SchemaPrimitive.EventDescriptor.ephemeral(type: "pty.created")
        public static let updated = SchemaPrimitive.EventDescriptor.ephemeral(type: "pty.updated")
        public static let exited = SchemaPrimitive.EventDescriptor.ephemeral(type: "pty.exited")
        public static let deleted = SchemaPrimitive.EventDescriptor.ephemeral(type: "pty.deleted")
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [created, updated, exited, deleted]
    }

    // parity: schema/src/pty.ts#CreateInput [status=implemented hash=b1c13cca8799]
    public struct CreateInput: Equatable, Hashable, Sendable, Codable {
        public let command: String?
        public let args: [String]?
        public let cwd: String?
        public let title: String?
        public let env: [String: String]?

        public init(
            command: String? = nil,
            args: [String]? = nil,
            cwd: String? = nil,
            title: String? = nil,
            env: [String: String]? = nil
        ) {
            self.command = command
            self.args = args
            self.cwd = cwd
            self.title = title
            self.env = env
        }
    }

    public struct Size: Equatable, Hashable, Sendable, Codable {
        public let rows: SchemaPrimitive.PositiveInt
        public let cols: SchemaPrimitive.PositiveInt

        public init(rows: SchemaPrimitive.PositiveInt, cols: SchemaPrimitive.PositiveInt) {
            self.rows = rows
            self.cols = cols
        }
    }

    // parity: schema/src/pty.ts#UpdateInput [status=implemented hash=722d2f5422e4]
    public struct UpdateInput: Equatable, Hashable, Sendable, Codable {
        public let title: String?
        public let size: Size?

        public init(title: String? = nil, size: Size? = nil) {
            self.title = title
            self.size = size
        }
    }
}

// MARK: - src/pty-ticket.ts

public enum PtyTicketSchema {
    // parity: schema/src/pty-ticket.ts#ConnectToken [status=implemented hash=a4974124dc58]
    public struct ConnectToken: Equatable, Hashable, Sendable, Codable {
        public let ticket: String
        public let expiresIn: SchemaPrimitive.PositiveInt

        public init(ticket: String, expiresIn: SchemaPrimitive.PositiveInt) {
            self.ticket = ticket
            self.expiresIn = expiresIn
        }

        enum CodingKeys: String, CodingKey {
            case ticket
            case expiresIn = "expires_in"
        }
    }
}

// MARK: - src/persistent-pty.ts

public enum PersistentPtySchema {
    public struct Size: Equatable, Hashable, Sendable, Codable {
        public let cols: SchemaPrimitive.PositiveInt
        public let rows: SchemaPrimitive.PositiveInt

        public init(cols: SchemaPrimitive.PositiveInt, rows: SchemaPrimitive.PositiveInt) {
            self.cols = cols
            self.rows = rows
        }
    }

    public struct OutputRange: Equatable, Hashable, Sendable, Codable {
        public let head: SchemaPrimitive.NonNegativeInt
        public let tail: SchemaPrimitive.NonNegativeInt

        public init(head: SchemaPrimitive.NonNegativeInt, tail: SchemaPrimitive.NonNegativeInt) {
            self.head = head
            self.tail = tail
        }
    }

    public struct Cursor: Equatable, Hashable, Sendable, Codable {
        public let x: SchemaPrimitive.NonNegativeInt
        public let y: SchemaPrimitive.NonNegativeInt

        public init(x: SchemaPrimitive.NonNegativeInt, y: SchemaPrimitive.NonNegativeInt) {
            self.x = x
            self.y = y
        }
    }

    // parity: schema/src/persistent-pty.ts#Info [status=implemented hash=4b6258eb3237]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let id: PtySchema.ID
        public let title: String
        public let command: String
        public let args: [String]
        public let cwd: String
        public let status: PtySchema.Status
        public let pid: SchemaPrimitive.NonNegativeInt
        public let exitCode: SchemaPrimitive.NonNegativeInt?
        public let sessionID: SessionID
        public let userTitle: String?
        public let foregroundProcess: String?
        public let size: Size
        public let output: OutputRange

        public init(
            id: PtySchema.ID,
            title: String,
            command: String,
            args: [String],
            cwd: String,
            status: PtySchema.Status,
            pid: SchemaPrimitive.NonNegativeInt,
            exitCode: SchemaPrimitive.NonNegativeInt? = nil,
            sessionID: SessionID,
            userTitle: String?,
            foregroundProcess: String?,
            size: Size,
            output: OutputRange
        ) {
            self.id = id
            self.title = title
            self.command = command
            self.args = args
            self.cwd = cwd
            self.status = status
            self.pid = pid
            self.exitCode = exitCode
            self.sessionID = sessionID
            self.userTitle = userTitle
            self.foregroundProcess = foregroundProcess
            self.size = size
            self.output = output
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(PtySchema.ID.self, forKey: .id)
            self.title = try container.decode(String.self, forKey: .title)
            self.command = try container.decode(String.self, forKey: .command)
            self.args = try container.decode([String].self, forKey: .args)
            self.cwd = try container.decode(String.self, forKey: .cwd)
            self.status = try container.decode(PtySchema.Status.self, forKey: .status)
            self.pid = try container.decode(SchemaPrimitive.NonNegativeInt.self, forKey: .pid)
            self.exitCode = try container.decodeIfPresent(SchemaPrimitive.NonNegativeInt.self, forKey: .exitCode)
            self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
            self.userTitle = try container.decode(String?.self, forKey: .userTitle)
            self.foregroundProcess = try container.decode(String?.self, forKey: .foregroundProcess)
            self.size = try container.decode(Size.self, forKey: .size)
            self.output = try container.decode(OutputRange.self, forKey: .output)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encode(command, forKey: .command)
            try container.encode(args, forKey: .args)
            try container.encode(cwd, forKey: .cwd)
            try container.encode(status, forKey: .status)
            try container.encode(pid, forKey: .pid)
            try container.encodeIfPresent(exitCode, forKey: .exitCode)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(userTitle, forKey: .userTitle)
            try container.encode(foregroundProcess, forKey: .foregroundProcess)
            try container.encode(size, forKey: .size)
            try container.encode(output, forKey: .output)
        }

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case command
            case args
            case cwd
            case status
            case pid
            case exitCode
            case sessionID
            case userTitle
            case foregroundProcess
            case size
            case output
        }
    }

    // parity: schema/src/persistent-pty.ts#Handoff [status=implemented hash=1a3b238fe6c7]
    public struct Handoff: Equatable, Hashable, Sendable, Codable {
        public let directory: String
        public let instanceID: String
        public let ticket: String
        public let expiresAt: Double

        public init(directory: String, instanceID: String, ticket: String, expiresAt: Double) {
            self.directory = directory
            self.instanceID = instanceID
            self.ticket = ticket
            self.expiresAt = expiresAt
        }
    }

    // parity: schema/src/persistent-pty.ts#CreateInput [status=implemented hash=86d78f43ccee]
    public struct CreateInput: Equatable, Hashable, Sendable, Codable {
        public let command: String?
        public let args: [String]
        public let cwd: String?
        public let title: String
        public let env: [String: String]
        public let size: Size?

        public init(
            command: String? = nil,
            args: [String],
            cwd: String? = nil,
            title: String,
            env: [String: String],
            size: Size? = nil
        ) {
            self.command = command
            self.args = args
            self.cwd = cwd
            self.title = title
            self.env = env
            self.size = size
        }
    }

    // parity: schema/src/persistent-pty.ts#UpdateInput [status=implemented hash=174be94e313c]
    public struct UpdateInput: Equatable, Hashable, Sendable, Codable {
        public let attachmentID: String?
        public let size: Size?
        public let title: SchemaPrimitive.Nullable<String>?

        public init(
            attachmentID: String? = nil,
            size: Size? = nil,
            title: SchemaPrimitive.Nullable<String>? = nil
        ) {
            self.attachmentID = attachmentID
            self.size = size
            self.title = title
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.attachmentID = try container.decodeIfPresent(String.self, forKey: .attachmentID)
            self.size = try container.decodeIfPresent(Size.self, forKey: .size)
            if container.contains(.title) {
                if try container.decodeNil(forKey: .title) {
                    self.title = .null
                } else {
                    self.title = .value(try container.decode(String.self, forKey: .title))
                }
            } else {
                self.title = nil
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(attachmentID, forKey: .attachmentID)
            try container.encodeIfPresent(size, forKey: .size)
            if let title {
                switch title {
                case .null:
                    try container.encodeNil(forKey: .title)
                case .value(let s):
                    try container.encode(s, forKey: .title)
                }
            }
        }

        enum CodingKeys: String, CodingKey {
            case attachmentID
            case size
            case title
        }
    }

    // parity: schema/src/persistent-pty.ts#Snapshot [status=implemented hash=b8acc5ebb3f0]
    public struct Snapshot: Equatable, Hashable, Sendable, Codable {
        public let info: Info
        public let text: String
        public let checkpoint: [UInt8]
        public let cursor: Cursor

        public init(info: Info, text: String, checkpoint: [UInt8], cursor: Cursor) {
            self.info = info
            self.text = text
            self.checkpoint = checkpoint
            self.cursor = cursor
        }
    }

    /// Bounded read-lines count in `1...65535`.
    // parity: schema/src/persistent-pty.ts#ReadLines [status=implemented hash=1fee34a80a28]
    public struct ReadLines: RawRepresentable, Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: Int

        public init?(rawValue: Int) {
            guard rawValue >= 1 && rawValue <= 65_535 else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: Int) throws(SchemaPrimitive.ValidationError) {
            guard value >= 1 && value <= 65_535 else {
                throw .intOutOfRange(value, min: 1, max: 65_535)
            }
            self.rawValue = value
        }

        public var description: String { String(rawValue) }

        public static func < (lhs: ReadLines, rhs: ReadLines) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(Int.self)
            guard value >= 1 && value <= 65_535 else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected ReadLines in 1...65535, got \(value)"
                )
            }
            self.rawValue = value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/persistent-pty.ts#ReadResult [status=implemented hash=8e0a220cb37c]
    public struct ReadResult: Equatable, Hashable, Sendable, Codable {
        public struct Screen: Equatable, Hashable, Sendable, Codable {
            public let text: String
            public let cols: SchemaPrimitive.PositiveInt
            public let rows: SchemaPrimitive.PositiveInt
            public let cursor: Cursor

            public init(
                text: String,
                cols: SchemaPrimitive.PositiveInt,
                rows: SchemaPrimitive.PositiveInt,
                cursor: Cursor
            ) {
                self.text = text
                self.cols = cols
                self.rows = rows
                self.cursor = cursor
            }
        }

        public let ptyID: PtySchema.ID
        public let title: String
        public let cwd: String
        public let foregroundProcess: String?
        public let screen: Screen

        public init(
            ptyID: PtySchema.ID,
            title: String,
            cwd: String,
            foregroundProcess: String?,
            screen: Screen
        ) {
            self.ptyID = ptyID
            self.title = title
            self.cwd = cwd
            self.foregroundProcess = foregroundProcess
            self.screen = screen
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.ptyID = try container.decode(PtySchema.ID.self, forKey: .ptyID)
            self.title = try container.decode(String.self, forKey: .title)
            self.cwd = try container.decode(String.self, forKey: .cwd)
            self.foregroundProcess = try container.decode(String?.self, forKey: .foregroundProcess)
            self.screen = try container.decode(Screen.self, forKey: .screen)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(ptyID, forKey: .ptyID)
            try container.encode(title, forKey: .title)
            try container.encode(cwd, forKey: .cwd)
            try container.encode(foregroundProcess, forKey: .foregroundProcess)
            try container.encode(screen, forKey: .screen)
        }

        enum CodingKeys: String, CodingKey {
            case ptyID
            case title
            case cwd
            case foregroundProcess
            case screen
        }
    }

    public struct TerminalEventPayload: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let terminal: Info

        public init(sessionID: SessionID, terminal: Info) {
            self.sessionID = sessionID
            self.terminal = terminal
        }
    }

    public struct RemovedEventPayload: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let ptyID: PtySchema.ID

        public init(sessionID: SessionID, ptyID: PtySchema.ID) {
            self.sessionID = sessionID
            self.ptyID = ptyID
        }
    }

    // parity: schema/src/persistent-pty.ts#Added [status=implemented hash=a7312d030667]
    public static let added = SchemaPrimitive.EventDescriptor.ephemeral(type: "persistent-pty.added")

    // parity: schema/src/persistent-pty.ts#Removed [status=implemented hash=e6f9c6304449]
    public static let removed = SchemaPrimitive.EventDescriptor.ephemeral(type: "persistent-pty.removed")

    // parity: schema/src/persistent-pty.ts#Updated [status=implemented hash=d660ff41fc08]
    public static let updated = SchemaPrimitive.EventDescriptor.ephemeral(type: "persistent-pty.updated")

    // parity: schema/src/persistent-pty.ts#Event [status=implemented hash=ebc64d9ba020]
    public enum Event {
        public static let added = PersistentPtySchema.added
        public static let removed = PersistentPtySchema.removed
        public static let updated = PersistentPtySchema.updated
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [added, removed, updated]
    }
}

// MARK: - src/shell.ts

public enum ShellSchema {
    // parity: schema/src/shell.ts#ID [status=implemented hash=7d339c71b924]
    public struct ID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            guard rawValue.hasPrefix("sh_") else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: String) throws(IdentifierValidationError) {
            guard value.hasPrefix("sh_") else {
                throw .invalidPrefix(expected: "sh_", actual: value)
            }
            self.rawValue = value
        }

        private init(unchecked value: String) {
            self.rawValue = value
        }

        public static func create() -> ID {
            ID(unchecked: "sh_" + Identifier.ascending())
        }

        public static func ascending(_ id: String? = nil) throws(IdentifierValidationError) -> ID {
            guard let id else { return create() }
            return try ID(validating: id)
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            self = try ID(validating: value)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/shell.ts#Status [status=implemented hash=691c3e9db25b]
    public enum Status: String, Equatable, Hashable, Sendable, Codable {
        case running
        case exited
        case timeout
        case killed
    }

    // parity: schema/src/shell.ts#Time [status=implemented hash=d6ca9f1f864f]
    public struct Time: Equatable, Hashable, Sendable, Codable {
        public let started: Double
        public let completed: Double?

        public init(started: Double, completed: Double? = nil) {
            self.started = started
            self.completed = completed
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.started = try SchemaPrimitive.decodeFinite(from: container, forKey: .started)
            self.completed = try SchemaPrimitive.decodeFiniteIfPresent(from: container, forKey: .completed)
        }

        enum CodingKeys: String, CodingKey {
            case started
            case completed
        }
    }

    // parity: schema/src/shell.ts#Metadata [status=implemented hash=1a80e9f0220c]
    public typealias Metadata = [String: JSONValue]

    // parity: schema/src/shell.ts#Info [status=implemented hash=71c650215e61]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let id: ID
        public let status: Status
        public let command: String
        public let cwd: String
        public let shell: String
        public let file: String
        public let pid: SchemaPrimitive.NonNegativeInt?
        public let exit: Double?
        public let signal: String?
        public let metadata: Metadata
        public let time: Time

        public init(
            id: ID,
            status: Status,
            command: String,
            cwd: String,
            shell: String,
            file: String,
            pid: SchemaPrimitive.NonNegativeInt? = nil,
            exit: Double? = nil,
            signal: String? = nil,
            metadata: Metadata = [:],
            time: Time
        ) {
            self.id = id
            self.status = status
            self.command = command
            self.cwd = cwd
            self.shell = shell
            self.file = file
            self.pid = pid
            self.exit = exit
            self.signal = signal
            self.metadata = metadata
            self.time = time
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(ID.self, forKey: .id)
            self.status = try container.decode(Status.self, forKey: .status)
            self.command = try container.decode(String.self, forKey: .command)
            self.cwd = try container.decode(String.self, forKey: .cwd)
            self.shell = try container.decode(String.self, forKey: .shell)
            self.file = try container.decode(String.self, forKey: .file)
            self.pid = try container.decodeIfPresent(SchemaPrimitive.NonNegativeInt.self, forKey: .pid)
            self.exit = try SchemaPrimitive.decodeFiniteIfPresent(from: container, forKey: .exit)
            self.signal = try container.decodeIfPresent(String.self, forKey: .signal)
            self.metadata = try container.decode(Metadata.self, forKey: .metadata)
            self.time = try container.decode(Time.self, forKey: .time)
        }

        enum CodingKeys: String, CodingKey {
            case id
            case status
            case command
            case cwd
            case shell
            case file
            case pid
            case exit
            case signal
            case metadata
            case time
        }
    }

    // parity: schema/src/shell.ts#Event [status=implemented hash=c9ac61031e9e]
    public enum Event {
        public struct CreatedPayload: Equatable, Hashable, Sendable, Codable {
            public let info: Info

            public init(info: Info) {
                self.info = info
            }
        }

        public struct ExitedPayload: Equatable, Hashable, Sendable, Codable {
            public let id: ID
            public let exit: Double?
            public let status: Status

            public init(id: ID, exit: Double? = nil, status: Status) {
                self.id = id
                self.exit = exit
                self.status = status
            }
        }

        public struct DeletedPayload: Equatable, Hashable, Sendable, Codable {
            public let id: ID

            public init(id: ID) {
                self.id = id
            }
        }

        public static let created = SchemaPrimitive.EventDescriptor.ephemeral(type: "shell.created")
        public static let exited = SchemaPrimitive.EventDescriptor.ephemeral(type: "shell.exited")
        public static let deleted = SchemaPrimitive.EventDescriptor.ephemeral(type: "shell.deleted")
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [created, exited, deleted]
    }

    // parity: schema/src/shell.ts#CreateInput [status=implemented hash=d2ca5fd3f796]
    public struct CreateInput: Equatable, Hashable, Sendable, Codable {
        public let command: String
        public let cwd: String?
        public let timeout: SchemaPrimitive.NonNegativeInt?
        public let metadata: Metadata?

        public init(
            command: String,
            cwd: String? = nil,
            timeout: SchemaPrimitive.NonNegativeInt? = nil,
            metadata: Metadata? = nil
        ) {
            self.command = command
            self.cwd = cwd
            self.timeout = timeout
            self.metadata = metadata
        }
    }

    // parity: schema/src/shell.ts#OutputInput [status=implemented hash=384219111ffb]
    public struct OutputInput: Equatable, Hashable, Sendable, Codable {
        public let cursor: SchemaPrimitive.NonNegativeInt?
        public let limit: SchemaPrimitive.NonNegativeInt?

        public init(cursor: SchemaPrimitive.NonNegativeInt? = nil, limit: SchemaPrimitive.NonNegativeInt? = nil) {
            self.cursor = cursor
            self.limit = limit
        }
    }

    // parity: schema/src/shell.ts#Output [status=implemented hash=fc2684bcf6f9]
    public struct Output: Equatable, Hashable, Sendable, Codable {
        public let output: String
        public let cursor: SchemaPrimitive.NonNegativeInt
        public let size: SchemaPrimitive.NonNegativeInt
        public let truncated: Bool

        public init(
            output: String,
            cursor: SchemaPrimitive.NonNegativeInt,
            size: SchemaPrimitive.NonNegativeInt,
            truncated: Bool
        ) {
            self.output = output
            self.cursor = cursor
            self.size = size
            self.truncated = truncated
        }
    }
}

// MARK: - src/job.ts

public enum JobSchema {
    // parity: schema/src/job.ts#Kind [status=implemented hash=0688dca18680]
    public enum Kind: String, Equatable, Hashable, Sendable, Codable {
        case shell
        case subagent
        case image
        case video
        case codemode
    }

    // parity: schema/src/job.ts#Status [status=implemented hash=8837c635e520]
    public enum Status: String, Equatable, Hashable, Sendable, Codable {
        case running
        case completed
        case error
        case cancelled
    }

    // parity: schema/src/job.ts#Time [status=implemented hash=ba89737c1446]
    public struct Time: Equatable, Hashable, Sendable, Codable {
        public let started: Double
        public let completed: Double?

        public init(started: Double, completed: Double? = nil) {
            self.started = started
            self.completed = completed
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.started = try SchemaPrimitive.decodeFinite(from: container, forKey: .started)
            self.completed = try SchemaPrimitive.decodeFiniteIfPresent(from: container, forKey: .completed)
        }

        enum CodingKeys: String, CodingKey {
            case started
            case completed
        }
    }

    // parity: schema/src/job.ts#Shell [status=implemented hash=9b7d5f0065c4]
    public struct Shell: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let sessionID: SessionID
        public let status: Status
        public let title: String?
        public let time: Time
        public let shellID: String
        public let command: String

        public init(
            id: String,
            sessionID: SessionID,
            status: Status,
            title: String? = nil,
            time: Time,
            shellID: String,
            command: String
        ) {
            self.id = id
            self.sessionID = sessionID
            self.status = status
            self.title = title
            self.time = time
            self.shellID = shellID
            self.command = command
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("shell", from: container, forKey: .kind)
            self.id = try container.decode(String.self, forKey: .id)
            self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
            self.status = try container.decode(Status.self, forKey: .status)
            self.title = try container.decodeIfPresent(String.self, forKey: .title)
            self.time = try container.decode(Time.self, forKey: .time)
            self.shellID = try container.decode(String.self, forKey: .shellID)
            self.command = try container.decode(String.self, forKey: .command)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("shell", forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(time, forKey: .time)
            try container.encode(shellID, forKey: .shellID)
            try container.encode(command, forKey: .command)
        }

        enum CodingKeys: String, CodingKey {
            case kind
            case id
            case sessionID
            case status
            case title
            case time
            case shellID
            case command
        }
    }

    // parity: schema/src/job.ts#Subagent [status=implemented hash=27d6a54270dc]
    public struct Subagent: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let sessionID: SessionID
        public let status: Status
        public let title: String?
        public let time: Time
        public let childSessionID: SessionID
        public let agent: String
        public let description: String

        public init(
            id: String,
            sessionID: SessionID,
            status: Status,
            title: String? = nil,
            time: Time,
            childSessionID: SessionID,
            agent: String,
            description: String
        ) {
            self.id = id
            self.sessionID = sessionID
            self.status = status
            self.title = title
            self.time = time
            self.childSessionID = childSessionID
            self.agent = agent
            self.description = description
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("subagent", from: container, forKey: .kind)
            self.id = try container.decode(String.self, forKey: .id)
            self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
            self.status = try container.decode(Status.self, forKey: .status)
            self.title = try container.decodeIfPresent(String.self, forKey: .title)
            self.time = try container.decode(Time.self, forKey: .time)
            self.childSessionID = try container.decode(SessionID.self, forKey: .childSessionID)
            self.agent = try container.decode(String.self, forKey: .agent)
            self.description = try container.decode(String.self, forKey: .description)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("subagent", forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(time, forKey: .time)
            try container.encode(childSessionID, forKey: .childSessionID)
            try container.encode(agent, forKey: .agent)
            try container.encode(description, forKey: .description)
        }

        enum CodingKeys: String, CodingKey {
            case kind
            case id
            case sessionID
            case status
            case title
            case time
            case childSessionID
            case agent
            case description
        }
    }

    // parity: schema/src/job.ts#Image [status=implemented hash=d8878da24985]
    public struct Image: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let sessionID: SessionID
        public let status: Status
        public let title: String?
        public let time: Time
        public let path: String
        public let model: String

        public init(
            id: String,
            sessionID: SessionID,
            status: Status,
            title: String? = nil,
            time: Time,
            path: String,
            model: String
        ) {
            self.id = id
            self.sessionID = sessionID
            self.status = status
            self.title = title
            self.time = time
            self.path = path
            self.model = model
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("image", from: container, forKey: .kind)
            self.id = try container.decode(String.self, forKey: .id)
            self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
            self.status = try container.decode(Status.self, forKey: .status)
            self.title = try container.decodeIfPresent(String.self, forKey: .title)
            self.time = try container.decode(Time.self, forKey: .time)
            self.path = try container.decode(String.self, forKey: .path)
            self.model = try container.decode(String.self, forKey: .model)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("image", forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(time, forKey: .time)
            try container.encode(path, forKey: .path)
            try container.encode(model, forKey: .model)
        }

        enum CodingKeys: String, CodingKey {
            case kind
            case id
            case sessionID
            case status
            case title
            case time
            case path
            case model
        }
    }

    // parity: schema/src/job.ts#Video [status=implemented hash=97f135343e1c]
    public struct Video: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let sessionID: SessionID
        public let status: Status
        public let title: String?
        public let time: Time
        public let path: String

        public init(
            id: String,
            sessionID: SessionID,
            status: Status,
            title: String? = nil,
            time: Time,
            path: String
        ) {
            self.id = id
            self.sessionID = sessionID
            self.status = status
            self.title = title
            self.time = time
            self.path = path
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("video", from: container, forKey: .kind)
            self.id = try container.decode(String.self, forKey: .id)
            self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
            self.status = try container.decode(Status.self, forKey: .status)
            self.title = try container.decodeIfPresent(String.self, forKey: .title)
            self.time = try container.decode(Time.self, forKey: .time)
            self.path = try container.decode(String.self, forKey: .path)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("video", forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(time, forKey: .time)
            try container.encode(path, forKey: .path)
        }

        enum CodingKeys: String, CodingKey {
            case kind
            case id
            case sessionID
            case status
            case title
            case time
            case path
        }
    }

    // parity: schema/src/job.ts#CodeMode [status=implemented hash=29778a517ecd]
    public struct CodeMode: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let sessionID: SessionID
        public let status: Status
        public let title: String?
        public let time: Time

        public init(
            id: String,
            sessionID: SessionID,
            status: Status,
            title: String? = nil,
            time: Time
        ) {
            self.id = id
            self.sessionID = sessionID
            self.status = status
            self.title = title
            self.time = time
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("codemode", from: container, forKey: .kind)
            self.id = try container.decode(String.self, forKey: .id)
            self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
            self.status = try container.decode(Status.self, forKey: .status)
            self.title = try container.decodeIfPresent(String.self, forKey: .title)
            self.time = try container.decode(Time.self, forKey: .time)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("codemode", forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(time, forKey: .time)
        }

        enum CodingKeys: String, CodingKey {
            case kind
            case id
            case sessionID
            case status
            case title
            case time
        }
    }

    // parity: schema/src/job.ts#Info [status=implemented hash=ed48f803da56]
    public enum Info: Equatable, Hashable, Sendable, Codable {
        case shell(Shell)
        case subagent(Subagent)
        case image(Image)
        case video(Video)
        case codemode(CodeMode)

        enum TagKeys: String, CodingKey {
            case kind
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let kind = try container.decode(String.self, forKey: .kind)
            switch kind {
            case "shell":
                self = .shell(try Shell(from: decoder))
            case "subagent":
                self = .subagent(try Subagent(from: decoder))
            case "image":
                self = .image(try Image(from: decoder))
            case "video":
                self = .video(try Video(from: decoder))
            case "codemode":
                self = .codemode(try CodeMode(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "Unknown Job.Info kind '\(kind)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .shell(let v): try v.encode(to: encoder)
            case .subagent(let v): try v.encode(to: encoder)
            case .image(let v): try v.encode(to: encoder)
            case .video(let v): try v.encode(to: encoder)
            case .codemode(let v): try v.encode(to: encoder)
            }
        }
    }

    /// A background job started, moved to the background, or ended.
    /// Experimental: may change without compatibility guarantees.
    // parity: schema/src/job.ts#Event [status=implemented hash=e7550d251b3a]
    public enum Event {
        public static let updated = SchemaPrimitive.EventDescriptor.ephemeral(type: "experimental.job.updated")
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [updated]
    }
}

// MARK: - src/automation.ts

public enum AutomationSchema {
    // parity: schema/src/automation.ts#ID [status=implemented hash=922dd4e1c23c]
    public struct ID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            guard rawValue.hasPrefix("aut_") else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: String) throws(IdentifierValidationError) {
            guard value.hasPrefix("aut_") else {
                throw .invalidPrefix(expected: "aut_", actual: value)
            }
            self.rawValue = value
        }

        private init(unchecked value: String) {
            self.rawValue = value
        }

        public static func create() -> ID {
            ID(unchecked: "aut_" + Identifier.ascending())
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            self = try ID(validating: value)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Parses an Effect `DurationFromString` (`"<number> <unit>"`, e.g. `"90 seconds"`, `"5 minutes"`, `"2 hours"`)
    /// into milliseconds, returning `nil` when invalid.
    // parity: schema/src/automation.ts#durationMillis [status=implemented hash=8a57b51d5237]
    public static func durationMillis(_ value: String) -> Double? {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty else { return nil }
        // No leading/trailing whitespace
        if bytes.first == 0x20 || bytes.last == 0x20 || bytes.first == 0x09 || bytes.last == 0x09 {
            return nil
        }

        var idx = 0
        while idx < bytes.count && SchemaPrimitive.isAsciiDigit(bytes[idx]) {
            idx += 1
        }
        guard idx > 0 else { return nil }
        if idx < bytes.count && bytes[idx] == 0x2E {
            idx += 1
            let fracStart = idx
            while idx < bytes.count && SchemaPrimitive.isAsciiDigit(bytes[idx]) {
                idx += 1
            }
            guard idx > fracStart else { return nil }
        }
        let numberStr = String(decoding: bytes[0..<idx], as: UTF8.self)
        guard let amount = Double(numberStr), amount.isFinite else { return nil }

        let wsStart = idx
        while idx < bytes.count && (bytes[idx] == 0x20 || bytes[idx] == 0x09) {
            idx += 1
        }
        guard idx > wsStart, idx < bytes.count else { return nil }

        let unit = String(decoding: bytes[idx..<bytes.count], as: UTF8.self)
        let multiplier: Double
        switch unit {
        case "nano", "nanos":
            multiplier = 1e-6
        case "micro", "micros":
            multiplier = 1e-3
        case "milli", "millis":
            multiplier = 1.0
        case "second", "seconds":
            multiplier = 1_000.0
        case "minute", "minutes":
            multiplier = 60_000.0
        case "hour", "hours":
            multiplier = 3_600_000.0
        case "day", "days":
            multiplier = 86_400_000.0
        case "week", "weeks":
            multiplier = 604_800_000.0
        default:
            return nil
        }
        let result = amount * multiplier
        return result.isFinite ? result : nil
    }

    // parity: schema/src/automation.ts#DurationString [status=implemented hash=f1c85110ac39]
    public typealias DurationString = String

    // parity: schema/src/automation.ts#At [status=implemented hash=b4b6521eff6c]
    public struct At: Equatable, Hashable, Sendable, Codable {
        public let at: String
        public let tz: String?

        public init(at: String, tz: String? = nil) {
            self.at = at
            self.tz = tz
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("at", from: container, forKey: .type)
            self.at = try container.decode(String.self, forKey: .at)
            self.tz = try container.decodeIfPresent(String.self, forKey: .tz)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("at", forKey: .type)
            try container.encode(at, forKey: .at)
            try container.encodeIfPresent(tz, forKey: .tz)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case at
            case tz
        }
    }

    // parity: schema/src/automation.ts#Every [status=implemented hash=8a3d969cb71f]
    public struct Every: Equatable, Hashable, Sendable, Codable {
        public let every: DurationString
        public let tz: String?

        public init(every: DurationString, tz: String? = nil) {
            self.every = every
            self.tz = tz
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("every", from: container, forKey: .type)
            self.every = try container.decode(String.self, forKey: .every)
            self.tz = try container.decodeIfPresent(String.self, forKey: .tz)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("every", forKey: .type)
            try container.encode(every, forKey: .every)
            try container.encodeIfPresent(tz, forKey: .tz)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case every
            case tz
        }
    }

    // parity: schema/src/automation.ts#Cron [status=implemented hash=21b9a2c47285]
    public struct Cron: Equatable, Hashable, Sendable, Codable {
        public let cron: String
        public let tz: String?

        public init(cron: String, tz: String? = nil) {
            self.cron = cron
            self.tz = tz
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("cron", from: container, forKey: .type)
            self.cron = try container.decode(String.self, forKey: .cron)
            self.tz = try container.decodeIfPresent(String.self, forKey: .tz)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("cron", forKey: .type)
            try container.encode(cron, forKey: .cron)
            try container.encodeIfPresent(tz, forKey: .tz)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case cron
            case tz
        }
    }

    // parity: schema/src/automation.ts#Event [status=implemented hash=74ef9125cecd]
    public struct Event: Equatable, Hashable, Sendable, Codable {
        public let server: String
        public let event: String
        public let args: [String: JSONValue]?

        public init(server: String, event: String, args: [String: JSONValue]? = nil) {
            self.server = server
            self.event = event
            self.args = args
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("event", from: container, forKey: .type)
            let server = try container.decode(String.self, forKey: .server)
            guard !server.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .server, in: container, debugDescription: "server must be non-empty")
            }
            let event = try container.decode(String.self, forKey: .event)
            guard !event.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .event, in: container, debugDescription: "event must be non-empty")
            }
            self.server = server
            self.event = event
            self.args = try container.decodeIfPresent([String: JSONValue].self, forKey: .args)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("event", forKey: .type)
            try container.encode(server, forKey: .server)
            try container.encode(event, forKey: .event)
            try container.encodeIfPresent(args, forKey: .args)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case server
            case event
            case args
        }
    }

    // parity: schema/src/automation.ts#Trigger [status=implemented hash=8f4a7303a560]
    public enum Trigger: Equatable, Hashable, Sendable, Codable {
        case at(At)
        case every(Every)
        case cron(Cron)
        case event(Event)

        enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "at": self = .at(try At(from: decoder))
            case "every": self = .every(try Every(from: decoder))
            case "cron": self = .cron(try Cron(from: decoder))
            case "event": self = .event(try Event(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Automation.Trigger type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .at(let v): try v.encode(to: encoder)
            case .every(let v): try v.encode(to: encoder)
            case .cron(let v): try v.encode(to: encoder)
            case .event(let v): try v.encode(to: encoder)
            }
        }
    }

    /// Mutually exclusive target: either `{ session }` or `{ subagent }`; rejects objects containing both keys.
    // parity: schema/src/automation.ts#Target [status=implemented hash=c23476adf569]
    public enum Target: Equatable, Hashable, Sendable, Codable {
        case session(SessionID)
        case subagent(AgentSchema.ID)

        enum CodingKeys: String, CodingKey {
            case session
            case subagent
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let hasSession = container.contains(.session)
            let hasSubagent = container.contains(.subagent)
            if hasSession && hasSubagent {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Automation.Target cannot specify both 'session' and 'subagent'"
                    )
                )
            }
            if hasSession {
                self = .session(try container.decode(SessionID.self, forKey: .session))
            } else if hasSubagent {
                self = .subagent(try container.decode(AgentSchema.ID.self, forKey: .subagent))
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Automation.Target requires either 'session' or 'subagent'"
                    )
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .session(let sid):
                try container.encode(sid, forKey: .session)
            case .subagent(let agent):
                try container.encode(agent, forKey: .subagent)
            }
        }
    }

    /// Derives the deterministic child Session ID for a `{ subagent }` automation run.
    // parity: schema/src/automation.ts#runSessionID [status=implemented hash=eda140ae8649]
    public static func runSessionID(_ id: ID, run: Int) -> SessionID {
        SessionID(rawValue: "ses_\(id.rawValue)_\(run)")!
    }

    /// Returns whether a Session ID belongs to an automation `{ subagent }` run.
    // parity: schema/src/automation.ts#isRunSession [status=implemented hash=1b579b2ad800]
    public static func isRunSession(_ sessionID: SessionID) -> Bool {
        sessionID.rawValue.hasPrefix("ses_aut_")
    }

    // parity: schema/src/automation.ts#PromptAction [status=implemented hash=d740a6480faf]
    public struct PromptAction: Equatable, Hashable, Sendable, Codable {
        public let prompt: String
        public let to: Target

        public init(prompt: String, to: Target) {
            self.prompt = prompt
            self.to = to
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("prompt", from: container, forKey: .type)
            self.prompt = try container.decode(String.self, forKey: .prompt)
            self.to = try container.decode(Target.self, forKey: .to)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("prompt", forKey: .type)
            try container.encode(prompt, forKey: .prompt)
            try container.encode(to, forKey: .to)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case prompt
            case to
        }
    }

    // parity: schema/src/automation.ts#CodeResult [status=implemented hash=3d601ef6cd65]
    public struct CodeResult: Equatable, Hashable, Sendable, Codable {
        public struct SendTarget: Equatable, Hashable, Sendable, Codable {
            public let subagent: AgentSchema.ID

            public init(subagent: AgentSchema.ID) {
                self.subagent = subagent
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: SchemaPrimitive.AnyCodingKey.self)
                for key in container.allKeys where key.stringValue != "subagent" {
                    throw DecodingError.dataCorruptedError(
                        forKey: key,
                        in: container,
                        debugDescription: "Unexpected key '\(key.stringValue)' in Automation.CodeResult.send.to"
                    )
                }
                let subagent = try container.decode(AgentSchema.ID.self, forKey: .init("subagent"))
                guard SchemaPrimitive.containsNonWhitespace(subagent.rawValue) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: SchemaPrimitive.AnyCodingKey("subagent"),
                        in: container,
                        debugDescription: "subagent must contain non-whitespace"
                    )
                }
                self.subagent = subagent
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: SchemaPrimitive.AnyCodingKey.self)
                try container.encode(subagent, forKey: .init("subagent"))
            }
        }

        public struct Send: Equatable, Hashable, Sendable, Codable {
            public let prompt: String
            public let to: SendTarget?

            public init(prompt: String, to: SendTarget? = nil) {
                self.prompt = prompt
                self.to = to
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: SchemaPrimitive.AnyCodingKey.self)
                for key in container.allKeys where key.stringValue != "prompt" && key.stringValue != "to" {
                    throw DecodingError.dataCorruptedError(
                        forKey: key,
                        in: container,
                        debugDescription: "Unexpected key '\(key.stringValue)' in Automation.CodeResult.send"
                    )
                }
                let prompt = try container.decode(String.self, forKey: .init("prompt"))
                guard SchemaPrimitive.containsNonWhitespace(prompt) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: SchemaPrimitive.AnyCodingKey("prompt"),
                        in: container,
                        debugDescription: "prompt must contain non-whitespace"
                    )
                }
                self.prompt = prompt
                if container.contains(.init("to")) {
                    self.to = try container.decode(SendTarget.self, forKey: .init("to"))
                } else {
                    self.to = nil
                }
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: SchemaPrimitive.AnyCodingKey.self)
                try container.encode(prompt, forKey: .init("prompt"))
                try container.encodeIfPresent(to, forKey: .init("to"))
            }
        }

        /// `nil` means `"state"` was omitted; `.some(.null)` means `"state": null`.
        public let state: JSONValue?
        public let done: Bool?
        public let send: Send?

        public init(state: JSONValue? = nil, done: Bool? = nil, send: Send? = nil) {
            self.state = state
            self.done = done
            self.send = send
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: SchemaPrimitive.AnyCodingKey.self)
            for key in container.allKeys
                where key.stringValue != "state" && key.stringValue != "done" && key.stringValue != "send"
            {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "Unexpected key '\(key.stringValue)' in Automation.CodeResult"
                )
            }
            if container.contains(.init("state")) {
                if try container.decodeNil(forKey: .init("state")) {
                    self.state = .null
                } else {
                    self.state = try container.decode(JSONValue.self, forKey: .init("state"))
                }
            } else {
                self.state = nil
            }
            if container.contains(.init("done")) {
                self.done = try container.decode(Bool.self, forKey: .init("done"))
            } else {
                self.done = nil
            }
            if container.contains(.init("send")) {
                self.send = try container.decode(Send.self, forKey: .init("send"))
            } else {
                self.send = nil
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: SchemaPrimitive.AnyCodingKey.self)
            if let state {
                try container.encode(state, forKey: .init("state"))
            }
            try container.encodeIfPresent(done, forKey: .init("done"))
            try container.encodeIfPresent(send, forKey: .init("send"))
        }
    }

    public enum CodeResultDecodeError: Swift.Error, Equatable, Hashable, Sendable {
        case expectedNullOrObject
        case unexpectedKey(String)
        case invalidFieldType(field: String)
        case emptyField(field: String)
    }

    /// Decodes an untrusted Code Mode `JSONValue` into `CodeResult?` (`null` -> `nil`), rejecting unknown keys.
    // parity: schema/src/automation.ts#decodeCodeResult [status=implemented hash=2e43a6a2869b]
    public static func decodeCodeResult(_ value: JSONValue) -> Swift.Result<CodeResult?, CodeResultDecodeError> {
        switch value {
        case .null:
            return .success(nil)
        case .object(let dict):
            for key in dict.keys where key != "state" && key != "done" && key != "send" {
                return .failure(.unexpectedKey(key))
            }
            let state: JSONValue? = dict["state"]
            let done: Bool?
            if let rawDone = dict["done"] {
                guard case .bool(let b) = rawDone else {
                    return .failure(.invalidFieldType(field: "done"))
                }
                done = b
            } else {
                done = nil
            }
            let send: CodeResult.Send?
            if let rawSend = dict["send"] {
                guard case .object(let sendDict) = rawSend else {
                    return .failure(.invalidFieldType(field: "send"))
                }
                for key in sendDict.keys where key != "prompt" && key != "to" {
                    return .failure(.unexpectedKey(key))
                }
                guard case .string(let prompt) = sendDict["prompt"] else {
                    return .failure(.invalidFieldType(field: "send.prompt"))
                }
                guard SchemaPrimitive.containsNonWhitespace(prompt) else {
                    return .failure(.emptyField(field: "send.prompt"))
                }
                let to: CodeResult.SendTarget?
                if let rawTo = sendDict["to"] {
                    guard case .object(let toDict) = rawTo else {
                        return .failure(.invalidFieldType(field: "send.to"))
                    }
                    for key in toDict.keys where key != "subagent" {
                        return .failure(.unexpectedKey(key))
                    }
                    guard case .string(let subagent) = toDict["subagent"] else {
                        return .failure(.invalidFieldType(field: "send.to.subagent"))
                    }
                    guard SchemaPrimitive.containsNonWhitespace(subagent) else {
                        return .failure(.emptyField(field: "send.to.subagent"))
                    }
                    to = CodeResult.SendTarget(subagent: AgentSchema.ID(rawValue: subagent))
                } else {
                    to = nil
                }
                send = CodeResult.Send(prompt: prompt, to: to)
            } else {
                send = nil
            }
            return .success(CodeResult(state: state, done: done, send: send))
        default:
            return .failure(.expectedNullOrObject)
        }
    }

    // parity: schema/src/automation.ts#CodeAction [status=implemented hash=caa8523006dd]
    public struct CodeAction: Equatable, Hashable, Sendable, Codable {
        public let code: String
        public let args: JSONValue?

        public init(code: String, args: JSONValue? = nil) {
            self.code = code
            self.args = args
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("code", from: container, forKey: .type)
            self.code = try container.decode(String.self, forKey: .code)
            if container.contains(.args) {
                if try container.decodeNil(forKey: .args) {
                    self.args = .null
                } else {
                    self.args = try container.decode(JSONValue.self, forKey: .args)
                }
            } else {
                self.args = nil
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("code", forKey: .type)
            try container.encode(code, forKey: .code)
            if let args {
                try container.encode(args, forKey: .args)
            }
        }

        enum CodingKeys: String, CodingKey {
            case type
            case code
            case args
        }
    }

    // parity: schema/src/automation.ts#ShellAction [status=implemented hash=8157c5bb98e9]
    public struct ShellAction: Equatable, Hashable, Sendable, Codable {
        public let command: String

        public init(command: String) {
            self.command = command
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("shell", from: container, forKey: .type)
            let command = try container.decode(String.self, forKey: .command)
            guard !command.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .command, in: container, debugDescription: "command must be non-empty")
            }
            self.command = command
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("shell", forKey: .type)
            try container.encode(command, forKey: .command)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case command
        }
    }

    // parity: schema/src/automation.ts#Action [status=implemented hash=980f34069faf]
    public enum Action: Equatable, Hashable, Sendable, Codable {
        case prompt(PromptAction)
        case code(CodeAction)
        case shell(ShellAction)

        enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "prompt": self = .prompt(try PromptAction(from: decoder))
            case "code": self = .code(try CodeAction(from: decoder))
            case "shell": self = .shell(try ShellAction(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Automation.Action type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .prompt(let v): try v.encode(to: encoder)
            case .code(let v): try v.encode(to: encoder)
            case .shell(let v): try v.encode(to: encoder)
            }
        }
    }

    // parity: schema/src/automation.ts#Status [status=implemented hash=1de7550926b0]
    public enum Status: String, Equatable, Hashable, Sendable, Codable {
        case active
        case paused
        case done
    }

    // parity: schema/src/automation.ts#Outcome [status=implemented hash=b091d9db676d]
    public enum Outcome: String, Equatable, Hashable, Sendable, Codable {
        case fired
        case late
        case skipped
        case disabled
        case failed
        case expired
    }

    // parity: schema/src/automation.ts#Info [status=implemented hash=60145cb32b27]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public struct Time: Equatable, Hashable, Sendable, Codable {
            public let created: SchemaPrimitive.DateTimeUtcFromMillis
            public let updated: SchemaPrimitive.DateTimeUtcFromMillis

            public init(
                created: SchemaPrimitive.DateTimeUtcFromMillis,
                updated: SchemaPrimitive.DateTimeUtcFromMillis
            ) {
                self.created = created
                self.updated = updated
            }
        }

        public let id: ID
        public let name: String
        public let projectID: ProjectID
        public let sessionID: SessionID?
        public let directory: String
        public let trigger: Trigger
        public let tz: String
        public let action: Action
        public let expires: SchemaPrimitive.DateTimeUtcFromMillis?
        public let status: Status
        public let nextDueAt: SchemaPrimitive.DateTimeUtcFromMillis?
        public let runCount: SchemaPrimitive.NonNegativeInt
        public let lastRunAt: SchemaPrimitive.DateTimeUtcFromMillis?
        public let lastOutcome: Outcome?
        public let lastOutput: String?
        public let state: JSONValue?
        public let time: Time

        public init(
            id: ID,
            name: String,
            projectID: ProjectID,
            sessionID: SessionID? = nil,
            directory: String,
            trigger: Trigger,
            tz: String,
            action: Action,
            expires: SchemaPrimitive.DateTimeUtcFromMillis? = nil,
            status: Status,
            nextDueAt: SchemaPrimitive.DateTimeUtcFromMillis? = nil,
            runCount: SchemaPrimitive.NonNegativeInt,
            lastRunAt: SchemaPrimitive.DateTimeUtcFromMillis? = nil,
            lastOutcome: Outcome? = nil,
            lastOutput: String? = nil,
            state: JSONValue? = nil,
            time: Time
        ) {
            self.id = id
            self.name = name
            self.projectID = projectID
            self.sessionID = sessionID
            self.directory = directory
            self.trigger = trigger
            self.tz = tz
            self.action = action
            self.expires = expires
            self.status = status
            self.nextDueAt = nextDueAt
            self.runCount = runCount
            self.lastRunAt = lastRunAt
            self.lastOutcome = lastOutcome
            self.lastOutput = lastOutput
            self.state = state
            self.time = time
        }
    }

    // parity: schema/src/automation.ts#PromptActionInput [status=implemented hash=c56f27d1a236]
    public struct PromptActionInput: Equatable, Hashable, Sendable, Codable {
        public let prompt: String
        public let to: Target?

        public init(prompt: String, to: Target? = nil) {
            self.prompt = prompt
            self.to = to
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("prompt", from: container, forKey: .type)
            let prompt = try container.decode(String.self, forKey: .prompt)
            guard !prompt.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .prompt, in: container, debugDescription: "prompt must be non-empty")
            }
            self.prompt = prompt
            self.to = try container.decodeIfPresent(Target.self, forKey: .to)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("prompt", forKey: .type)
            try container.encode(prompt, forKey: .prompt)
            try container.encodeIfPresent(to, forKey: .to)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case prompt
            case to
        }
    }

    /// Code Mode JavaScript run on each trigger with no model (32 KB output cap).
    // parity: schema/src/automation.ts#CodeActionInput [status=implemented hash=1a3dcbb0068e]
    public struct CodeActionInput: Equatable, Hashable, Sendable, Codable {
        public let code: String
        public let args: JSONValue?

        public init(code: String, args: JSONValue? = nil) {
            self.code = code
            self.args = args
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("code", from: container, forKey: .type)
            let code = try container.decode(String.self, forKey: .code)
            guard !code.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .code, in: container, debugDescription: "code must be non-empty")
            }
            self.code = code
            if container.contains(.args) {
                if try container.decodeNil(forKey: .args) {
                    self.args = .null
                } else {
                    self.args = try container.decode(JSONValue.self, forKey: .args)
                }
            } else {
                self.args = nil
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("code", forKey: .type)
            try container.encode(code, forKey: .code)
            if let args {
                try container.encode(args, forKey: .args)
            }
        }

        enum CodingKeys: String, CodingKey {
            case type
            case code
            case args
        }
    }

    /// Fixed shell command run on each trigger without a model.
    // parity: schema/src/automation.ts#ShellActionInput [status=implemented hash=195fd4ec264e]
    public struct ShellActionInput: Equatable, Hashable, Sendable, Codable {
        public let command: String

        public init(command: String) {
            self.command = command
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("shell", from: container, forKey: .type)
            let command = try container.decode(String.self, forKey: .command)
            guard !command.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .command, in: container, debugDescription: "command must be non-empty")
            }
            self.command = command
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("shell", forKey: .type)
            try container.encode(command, forKey: .command)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case command
        }
    }

    // parity: schema/src/automation.ts#ActionInput [status=implemented hash=fb5016ba3d76]
    public enum ActionInput: Equatable, Hashable, Sendable, Codable {
        case prompt(PromptActionInput)
        case code(CodeActionInput)
        case shell(ShellActionInput)

        enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "prompt": self = .prompt(try PromptActionInput(from: decoder))
            case "code": self = .code(try CodeActionInput(from: decoder))
            case "shell": self = .shell(try ShellActionInput(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Automation.ActionInput type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .prompt(let v): try v.encode(to: encoder)
            case .code(let v): try v.encode(to: encoder)
            case .shell(let v): try v.encode(to: encoder)
            }
        }
    }

    /// Automation request payload: prompt, Code Mode, or shell command action with schedule or MCP push event trigger.
    // parity: schema/src/automation.ts#Request [status=implemented hash=4b57e59efaa8]
    public struct Request: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let trigger: Trigger
        public let action: ActionInput
        public let expires: String?

        public init(name: String, trigger: Trigger, action: ActionInput, expires: String? = nil) {
            self.name = name
            self.trigger = trigger
            self.action = action
            self.expires = expires
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let name = try container.decode(String.self, forKey: .name)
            guard !name.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .name, in: container, debugDescription: "name must be non-empty")
            }
            self.name = name
            self.trigger = try container.decode(Trigger.self, forKey: .trigger)
            self.action = try container.decode(ActionInput.self, forKey: .action)
            self.expires = try container.decodeIfPresent(String.self, forKey: .expires)
        }

        enum CodingKeys: String, CodingKey {
            case name
            case trigger
            case action
            case expires
        }
    }

    // parity: schema/src/automation.ts#CreateInput [status=implemented hash=26bbd713f6ab]
    public struct CreateInput: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID?
        public let directory: String?
        public let name: String
        public let trigger: Trigger
        public let action: ActionInput
        public let expires: String?

        public init(
            sessionID: SessionID? = nil,
            directory: String? = nil,
            name: String,
            trigger: Trigger,
            action: ActionInput,
            expires: String? = nil
        ) {
            self.sessionID = sessionID
            self.directory = directory
            self.name = name
            self.trigger = trigger
            self.action = action
            self.expires = expires
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.sessionID = try container.decodeIfPresent(SessionID.self, forKey: .sessionID)
            self.directory = try container.decodeIfPresent(String.self, forKey: .directory)
            let name = try container.decode(String.self, forKey: .name)
            guard !name.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .name, in: container, debugDescription: "name must be non-empty")
            }
            self.name = name
            self.trigger = try container.decode(Trigger.self, forKey: .trigger)
            self.action = try container.decode(ActionInput.self, forKey: .action)
            self.expires = try container.decodeIfPresent(String.self, forKey: .expires)
        }

        enum CodingKeys: String, CodingKey {
            case sessionID
            case directory
            case name
            case trigger
            case action
            case expires
        }
    }
}

// MARK: - src/integration.ts

public enum IntegrationSchema {
    // parity: schema/src/integration.ts#ID [status=implemented hash=142a7d6f0112]
    public typealias ID = IntegrationID

    // parity: schema/src/integration.ts#MethodID [status=implemented hash=9727e56eaac6]
    public typealias MethodID = IntegrationMethodID

    // parity: schema/src/integration.ts#OAuthMethod [status=implemented hash=0b87b04e6f34]
    public struct OAuthMethod: Equatable, Hashable, Sendable, Codable {
        public let id: MethodID
        public let label: String
        public let form: FormSchema.Fields?

        public init(id: MethodID, label: String, form: FormSchema.Fields? = nil) {
            self.id = id
            self.label = label
            self.form = form
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("oauth", from: container, forKey: .type)
            self.id = try container.decode(MethodID.self, forKey: .id)
            self.label = try container.decode(String.self, forKey: .label)
            self.form = try container.decodeIfPresent(FormSchema.Fields.self, forKey: .form)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("oauth", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(label, forKey: .label)
            try container.encodeIfPresent(form, forKey: .form)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case id
            case label
            case form
        }
    }

    // parity: schema/src/integration.ts#CommandMethod [status=implemented hash=f22b7b2dcff3]
    public struct CommandMethod: Equatable, Hashable, Sendable, Codable {
        public let id: MethodID
        public let label: String
        public let command: [String]

        public init(id: MethodID, label: String, command: [String]) {
            self.id = id
            self.label = label
            self.command = command
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("command", from: container, forKey: .type)
            self.id = try container.decode(MethodID.self, forKey: .id)
            self.label = try container.decode(String.self, forKey: .label)
            self.command = try container.decode([String].self, forKey: .command)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("command", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(label, forKey: .label)
            try container.encode(command, forKey: .command)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case id
            case label
            case command
        }
    }

    // parity: schema/src/integration.ts#KeyMethod [status=implemented hash=fb3b65a29999]
    public struct KeyMethod: Equatable, Hashable, Sendable, Codable {
        public let label: String?
        public let form: FormSchema.Fields?

        public init(label: String? = nil, form: FormSchema.Fields? = nil) {
            self.label = label
            self.form = form
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("key", from: container, forKey: .type)
            self.label = try container.decodeIfPresent(String.self, forKey: .label)
            self.form = try container.decodeIfPresent(FormSchema.Fields.self, forKey: .form)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("key", forKey: .type)
            try container.encodeIfPresent(label, forKey: .label)
            try container.encodeIfPresent(form, forKey: .form)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case label
            case form
        }
    }

    // parity: schema/src/integration.ts#ExternalMethod [status=implemented hash=3a6a44a9d62d]
    public struct ExternalMethod: Equatable, Hashable, Sendable, Codable {
        public let id: MethodID
        public let label: String
        public let form: FormSchema.Fields?

        public init(id: MethodID, label: String, form: FormSchema.Fields? = nil) {
            self.id = id
            self.label = label
            self.form = form
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("external", from: container, forKey: .type)
            self.id = try container.decode(MethodID.self, forKey: .id)
            self.label = try container.decode(String.self, forKey: .label)
            self.form = try container.decodeIfPresent(FormSchema.Fields.self, forKey: .form)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("external", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(label, forKey: .label)
            try container.encodeIfPresent(form, forKey: .form)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case id
            case label
            case form
        }
    }

    // parity: schema/src/integration.ts#EnvMethod [status=implemented hash=5423963a8900]
    public struct EnvMethod: Equatable, Hashable, Sendable, Codable {
        public let names: [String]

        public init(names: [String]) {
            self.names = names
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("env", from: container, forKey: .type)
            self.names = try container.decode([String].self, forKey: .names)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("env", forKey: .type)
            try container.encode(names, forKey: .names)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case names
        }
    }

    // parity: schema/src/integration.ts#Method [status=implemented hash=443d1f6690e3]
    public enum Method: Equatable, Hashable, Sendable, Codable {
        case oauth(OAuthMethod)
        case command(CommandMethod)
        case key(KeyMethod)
        case external(ExternalMethod)
        case env(EnvMethod)

        enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "oauth": self = .oauth(try OAuthMethod(from: decoder))
            case "command": self = .command(try CommandMethod(from: decoder))
            case "key": self = .key(try KeyMethod(from: decoder))
            case "external": self = .external(try ExternalMethod(from: decoder))
            case "env": self = .env(try EnvMethod(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Integration.Method type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .oauth(let v): try v.encode(to: encoder)
            case .command(let v): try v.encode(to: encoder)
            case .key(let v): try v.encode(to: encoder)
            case .external(let v): try v.encode(to: encoder)
            case .env(let v): try v.encode(to: encoder)
            }
        }
    }

    // parity: schema/src/integration.ts#Event [status=implemented hash=e7550d251b3a]
    public enum Event {
        public static let updated = SchemaPrimitive.EventDescriptor.ephemeral(type: "integration.updated")
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [updated]
    }

    // parity: schema/src/integration.ts#Ref [status=implemented hash=27e170edcfd4]
    public struct Ref: Equatable, Hashable, Sendable, Codable {
        public let id: ID
        public let name: String
        public let metadata: [String: JSONValue]?

        public init(id: ID, name: String, metadata: [String: JSONValue]? = nil) {
            self.id = id
            self.name = name
            self.metadata = metadata
        }
    }

    // parity: schema/src/integration.ts#Info [status=implemented hash=181894bdd3b8]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let id: ID
        public let name: String
        public let metadata: [String: JSONValue]?
        public let methods: [Method]
        public let connections: [ConnectionSchema.Info]

        public init(
            id: ID,
            name: String,
            metadata: [String: JSONValue]? = nil,
            methods: [Method],
            connections: [ConnectionSchema.Info]
        ) {
            self.id = id
            self.name = name
            self.metadata = metadata
            self.methods = methods
            self.connections = connections
        }
    }

    // parity: schema/src/integration.ts#AttemptID [status=implemented hash=86c369212414]
    public struct AttemptID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static func create() -> AttemptID {
            AttemptID(rawValue: "con_" + Identifier.ascending())
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public struct AttemptTime: Equatable, Hashable, Sendable, Codable {
        public let created: Double
        public let expires: Double

        public init(created: Double, expires: Double) {
            self.created = created
            self.expires = expires
        }
    }

    // parity: schema/src/integration.ts#Attempt [status=implemented hash=f59b149f035d]
    public struct Attempt: Equatable, Hashable, Sendable, Codable {
        public enum Mode: String, Equatable, Hashable, Sendable, Codable {
            case auto
            case code
        }

        public let attemptID: AttemptID
        public let url: String
        public let instructions: String
        public let mode: Mode
        public let paste: Bool?
        public let time: AttemptTime

        public init(
            attemptID: AttemptID,
            url: String,
            instructions: String,
            mode: Mode,
            paste: Bool? = nil,
            time: AttemptTime
        ) {
            self.attemptID = attemptID
            self.url = url
            self.instructions = instructions
            self.mode = mode
            self.paste = paste
            self.time = time
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.attemptID = try container.decode(AttemptID.self, forKey: .attemptID)
            self.url = try container.decode(String.self, forKey: .url)
            self.instructions = try container.decode(String.self, forKey: .instructions)
            self.mode = try container.decode(Mode.self, forKey: .mode)
            self.paste = try SchemaPrimitive.decodeOptionalLiteralTrue(from: container, forKey: .paste)
            self.time = try container.decode(AttemptTime.self, forKey: .time)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(attemptID, forKey: .attemptID)
            try container.encode(url, forKey: .url)
            try container.encode(instructions, forKey: .instructions)
            try container.encode(mode, forKey: .mode)
            if paste == true { try container.encode(true, forKey: .paste) }
            try container.encode(time, forKey: .time)
        }

        enum CodingKeys: String, CodingKey {
            case attemptID
            case url
            case instructions
            case mode
            case paste
            case time
        }
    }

    // parity: schema/src/integration.ts#AttemptStatus [status=implemented hash=734e648ed2cc]
    public enum AttemptStatus: Equatable, Hashable, Sendable, Codable {
        case pending(time: AttemptTime)
        case complete(time: AttemptTime)
        case failed(message: String, time: AttemptTime)
        case expired(time: AttemptTime)

        enum CodingKeys: String, CodingKey {
            case status
            case message
            case time
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let status = try container.decode(String.self, forKey: .status)
            let time = try container.decode(AttemptTime.self, forKey: .time)
            switch status {
            case "pending":
                self = .pending(time: time)
            case "complete":
                self = .complete(time: time)
            case "failed":
                self = .failed(message: try container.decode(String.self, forKey: .message), time: time)
            case "expired":
                self = .expired(time: time)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .status,
                    in: container,
                    debugDescription: "Unknown Integration.AttemptStatus '\(status)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .pending(let time):
                try container.encode("pending", forKey: .status)
                try container.encode(time, forKey: .time)
            case .complete(let time):
                try container.encode("complete", forKey: .status)
                try container.encode(time, forKey: .time)
            case .failed(let message, let time):
                try container.encode("failed", forKey: .status)
                try container.encode(message, forKey: .message)
                try container.encode(time, forKey: .time)
            case .expired(let time):
                try container.encode("expired", forKey: .status)
                try container.encode(time, forKey: .time)
            }
        }
    }

    // parity: schema/src/integration.ts#CommandAttempt [status=implemented hash=8491b6fae39e]
    public struct CommandAttempt: Equatable, Hashable, Sendable, Codable {
        public let attemptID: AttemptID
        public let time: AttemptTime

        public init(attemptID: AttemptID, time: AttemptTime) {
            self.attemptID = attemptID
            self.time = time
        }
    }

    // parity: schema/src/integration.ts#CommandAttemptStatus [status=implemented hash=9d9847dd75aa]
    public enum CommandAttemptStatus: Equatable, Hashable, Sendable, Codable {
        case pending(message: String? = nil, time: AttemptTime)
        case complete(time: AttemptTime)
        case failed(message: String, time: AttemptTime)
        case expired(time: AttemptTime)

        enum CodingKeys: String, CodingKey {
            case status
            case message
            case time
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let status = try container.decode(String.self, forKey: .status)
            let time = try container.decode(AttemptTime.self, forKey: .time)
            switch status {
            case "pending":
                self = .pending(message: try container.decodeIfPresent(String.self, forKey: .message), time: time)
            case "complete":
                self = .complete(time: time)
            case "failed":
                self = .failed(message: try container.decode(String.self, forKey: .message), time: time)
            case "expired":
                self = .expired(time: time)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .status,
                    in: container,
                    debugDescription: "Unknown Integration.CommandAttemptStatus '\(status)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .pending(let message, let time):
                try container.encode("pending", forKey: .status)
                try container.encodeIfPresent(message, forKey: .message)
                try container.encode(time, forKey: .time)
            case .complete(let time):
                try container.encode("complete", forKey: .status)
                try container.encode(time, forKey: .time)
            case .failed(let message, let time):
                try container.encode("failed", forKey: .status)
                try container.encode(message, forKey: .message)
                try container.encode(time, forKey: .time)
            case .expired(let time):
                try container.encode("expired", forKey: .status)
                try container.encode(time, forKey: .time)
            }
        }
    }
}

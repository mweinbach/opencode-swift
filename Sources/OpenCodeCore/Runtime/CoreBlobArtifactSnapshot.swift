#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - CoreBlobStore (`core/src/blob-store.ts`)

public enum CoreBlobStore {
    // parity: core/src/blob-store.ts#ID [status=implemented hash=92662842810b]
    public typealias ID = BlobStoreSchema.ID

    // parity: core/src/blob-store.ts#Info [status=implemented hash=7697ecac33cb]
    public typealias Info = BlobStoreSchema.Info

    // parity: core/src/blob-store.ts#NotFoundError [status=implemented hash=62227e30710d]
    public struct NotFoundError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "BlobStore.NotFoundError"
        public let id: String
        public let message: String

        public init(id: String, message: String? = nil) {
            self.id = id
            self.message = message ?? "Blob not found: \(id)"
        }

        public var description: String { message }
    }

    // parity: core/src/blob-store.ts#UnavailableError [status=implemented hash=80e00e2208d8]
    public struct UnavailableError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "BlobStore.UnavailableError"
        public let message: String

        public init(message: String) {
            self.message = message
        }

        public var description: String { message }
    }

    // parity: core/src/blob-store.ts#DIRECTORY [status=implemented hash=ce0798aa6dfc]
    public static let DIRECTORY: String = "blobs"

    // parity: core/src/blob-store.ts#Content [status=implemented hash=b8aeee8d3498]
    public struct Content: Equatable, Hashable, Sendable, Codable {
        public let id: ID
        public let mime: String
        public let bytes: Double
        public let path: String

        public init(id: ID, mime: String, bytes: Double, path: String) {
            self.id = id
            self.mime = mime
            self.bytes = bytes
            self.path = path
        }
    }

    // parity: core/src/blob-store.ts#Interface [status=adapted hash=b5e31de2ec7a]
    public protocol Interface: Sendable {
        func write(_ chunks: [[UInt8]]) async throws -> Info
        func read(_ id: ID) async throws -> Content
        func remove(_ id: ID) async
    }

    // parity: core/src/blob-store.ts#Service [status=adapted hash=f3db708547e5]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/BlobStore"

        private let directory: String
        private let fileSystem: any OpenCodeFileSystem

        public init(
            globalPaths: Global.Interface = Global.make(),
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
        ) {
            self.directory = CoreConfigDiscovery.joinPath(globalPaths.data, CoreBlobStore.DIRECTORY)
            self.fileSystem = fileSystem
        }

        private func blobPath(_ id: ID) -> String {
            CoreConfigDiscovery.joinPath(directory, id.rawValue)
        }

        public func write(_ bytes: [UInt8]) async throws -> Info {
            try await write([bytes])
        }

        public func write(_ chunks: [[UInt8]]) async throws -> Info {
            let id = ID.create()
            let target = blobPath(id)
            var combined: [UInt8] = []
            for chunk in chunks { combined.append(contentsOf: chunk) }
            do {
                try await fileSystem.makeDirectory(at: directory, recursive: true)
                try await fileSystem.writeFile(combined, to: target, createDirectories: true)
                try? await fileSystem.chmod(at: target, mode: 0o600)
            } catch {
                try? await fileSystem.remove(at: target)
                throw UnavailableError(message: "Could not store blob \(id.rawValue): \(error)")
            }
            let stored = try await read(id)
            return Info(id: stored.id, mime: stored.mime, bytes: stored.bytes)
        }

        public func read(_ id: ID) async throws -> Content {
            let target = blobPath(id)
            let bytes: [UInt8]
            do {
                bytes = try await fileSystem.readFile(at: target)
            } catch {
                throw NotFoundError(id: id.rawValue)
            }
            let head = Array(bytes.prefix(64))
            let mime = CoreFilesystem.Mime.detectMedia(head) ?? "application/octet-stream"
            return Content(id: id, mime: mime, bytes: Double(bytes.count), path: target)
        }

        public func remove(_ id: ID) async {
            try? await fileSystem.remove(at: blobPath(id))
        }
    }

    private final class UnsupportedService: Interface, Sendable {
        func write(_ chunks: [[UInt8]]) async throws -> Info {
            _ = chunks
            throw UnavailableError(message: "Blob storage is not supported in this runtime")
        }

        func read(_ id: ID) async throws -> Content {
            throw NotFoundError(id: id.rawValue)
        }

        func remove(_ id: ID) async {
            _ = id
        }
    }

    // parity: core/src/blob-store.ts#unsupportedLayer [status=adapted hash=adbd9bf952bc]
    public static let unsupportedLayer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer.succeed(
        key: Service.serviceKey,
        value: UnsupportedService() as any Interface
    )

    // parity: core/src/blob-store.ts#node [status=adapted hash=1ba2f21c2852]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            let global = deps.get(Global.Service.serviceKey, as: Global.Service.self)?.paths ?? Global.make()
            let fsUtil = deps.get(FSUtil.Service.serviceKey, as: FSUtil.Service.self)
            let svc = Service(globalPaths: global, fileSystem: fsUtil?.fileSystem ?? LocalFileSystem.shared)
            return LayerNode.Output([Service.serviceKey: svc as any Interface])
        },
        [FSUtil.node, Global.node]
    )
}

// MARK: - CoreArtifact (`core/src/artifact.ts`)

public enum CoreArtifact {
    // parity: core/src/artifact.ts#ID [status=implemented hash=6e85ce3fc596]
    public typealias ID = ArtifactSchema.ID
    // parity: core/src/artifact.ts#ProviderID [status=implemented hash=6e85ce3fc596]
    public typealias ProviderID = ArtifactSchema.ProviderID
    // parity: core/src/artifact.ts#Capability [status=implemented hash=6e85ce3fc596]
    public typealias Capability = ArtifactSchema.Capability
    // parity: core/src/artifact.ts#Provider [status=implemented hash=6e85ce3fc596]
    public typealias Provider = ArtifactSchema.Provider
    // parity: core/src/artifact.ts#Info [status=implemented hash=6e85ce3fc596]
    public typealias Info = ArtifactSchema.Info
    // parity: core/src/artifact.ts#Content [status=implemented hash=6e85ce3fc596]
    public typealias Content = ArtifactSchema.Content
    // parity: core/src/artifact.ts#CreateInput [status=implemented hash=6e85ce3fc596]
    public typealias CreateInput = ArtifactSchema.CreateInput
    // parity: core/src/artifact.ts#UpdateInput [status=implemented hash=6e85ce3fc596]
    public typealias UpdateInput = ArtifactSchema.UpdateInput
    // parity: core/src/artifact.ts#Event [status=implemented hash=6e85ce3fc596]
    public typealias Event = ArtifactSchema.Event

    // parity: core/src/artifact.ts#LocalProviderID [status=implemented hash=5cb10f76854f]
    public static let LocalProviderID = ProviderID(rawValue: "local")!
    private static let itemPrefix = "artifact:item:"

    // parity: core/src/artifact.ts#ProviderCreateInput [status=implemented hash=89efddd63924]
    public struct ProviderCreateInput: Equatable, Sendable {
        public let id: ID
        public let title: String
        public let entry: String
        public let files: [String: [UInt8]]
        public let sessionID: SessionID?

        public init(
            id: ID,
            title: String,
            entry: String,
            files: [String: [UInt8]],
            sessionID: SessionID? = nil
        ) {
            self.id = id
            self.title = title
            self.entry = entry
            self.files = files
            self.sessionID = sessionID
        }
    }

    // parity: core/src/artifact.ts#ProviderUpdateInput [status=implemented hash=7c65399f4183]
    public struct ProviderUpdateInput: Equatable, Sendable {
        public let title: String
        public let entry: String
        public let files: [String: [UInt8]]
        public let sessionID: SessionID?

        public init(
            title: String,
            entry: String,
            files: [String: [UInt8]],
            sessionID: SessionID? = nil
        ) {
            self.title = title
            self.entry = entry
            self.files = files
            self.sessionID = sessionID
        }
    }

    // parity: core/src/artifact.ts#ProviderResult [status=implemented hash=a96044542bdd]
    public struct ProviderResult: Equatable, Hashable, Sendable, Codable {
        public let url: String?

        public init(url: String? = nil) {
            self.url = url
        }
    }

    // parity: core/src/artifact.ts#ProviderImplementation [status=adapted hash=cfc308848870]
    public struct ProviderImplementation: Sendable {
        public let id: ProviderID
        public let name: String
        public let capabilities: [Capability]
        public let prompt: String
        public let create: @Sendable (ProviderCreateInput) async throws -> ProviderResult
        public let read: @Sendable (ID) async throws -> [String: [UInt8]]
        public let update: @Sendable (ID, ProviderUpdateInput) async throws -> ProviderResult
        public let delete: @Sendable (ID) async throws -> Void

        public init(
            id: ProviderID,
            name: String,
            capabilities: [Capability],
            prompt: String,
            create: @escaping @Sendable (ProviderCreateInput) async throws -> ProviderResult,
            read: @escaping @Sendable (ID) async throws -> [String: [UInt8]],
            update: @escaping @Sendable (ID, ProviderUpdateInput) async throws -> ProviderResult,
            delete: @escaping @Sendable (ID) async throws -> Void
        ) {
            self.id = id
            self.name = name
            self.capabilities = capabilities
            self.prompt = prompt
            self.create = create
            self.read = read
            self.update = update
            self.delete = delete
        }
    }

    // parity: core/src/artifact.ts#LocalFile [status=implemented hash=988ad4904cae]
    public struct LocalFile: Equatable, Sendable {
        public let bytes: [UInt8]
        public let mime: String

        public init(bytes: [UInt8], mime: String) {
            self.bytes = bytes
            self.mime = mime
        }
    }

    // parity: core/src/artifact.ts#ProviderPrompts [status=implemented hash=bbf731be1bf5]
    public struct ProviderPrompts: Equatable, Hashable, Sendable, Codable {
        public struct DefaultProvider: Equatable, Hashable, Sendable, Codable {
            public let id: ProviderID
            public let name: String
            public let capabilities: [Capability]
            public let prompt: String

            public init(id: ProviderID, name: String, capabilities: [Capability], prompt: String) {
                self.id = id
                self.name = name
                self.capabilities = capabilities
                self.prompt = prompt
            }
        }

        public struct OtherProvider: Equatable, Hashable, Sendable, Codable {
            public let id: ProviderID
            public let name: String
            public let capabilities: [Capability]

            public init(id: ProviderID, name: String, capabilities: [Capability]) {
                self.id = id
                self.name = name
                self.capabilities = capabilities
            }
        }

        public let defaultProvider: DefaultProvider
        public let others: [OtherProvider]

        public init(defaultProvider: DefaultProvider, others: [OtherProvider]) {
            self.defaultProvider = defaultProvider
            self.others = others
        }
    }

    // parity: core/src/artifact.ts#DisabledError [status=implemented hash=c14648b590fc]
    public struct DisabledError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "Artifact.DisabledError"
        public init() {}
        // parity: core/src/artifact.ts#DisabledError.message [status=implemented hash=c3bf102abe8f]
        public var message: String { "Artifacts are disabled; set experimental.artifacts in config" }
        public var description: String { message }
    }

    // parity: core/src/artifact.ts#NotFoundError [status=implemented hash=0c13ac8ccbf5]
    public struct NotFoundError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "Artifact.NotFoundError"
        public let artifactID: ID
        public init(artifactID: ID) { self.artifactID = artifactID }
        // parity: core/src/artifact.ts#NotFoundError.message [status=implemented hash=bf60bb4c1903]
        public var message: String { "Artifact not found: \(artifactID.rawValue)" }
        public var description: String { message }
    }

    // parity: core/src/artifact.ts#FileMissingError [status=implemented hash=8b0c6e4daa64]
    public struct FileMissingError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "Artifact.FileMissingError"
        public let artifactID: ID
        public let path: String
        public init(artifactID: ID, path: String) { self.artifactID = artifactID; self.path = path }
        // parity: core/src/artifact.ts#FileMissingError.message [status=implemented hash=788927af2063]
        public var message: String { "Artifact file not found: \(path)" }
        public var description: String { message }
    }

    // parity: core/src/artifact.ts#ProviderNotFoundError [status=implemented hash=659e3cf54dd0]
    public struct ProviderNotFoundError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "Artifact.ProviderNotFoundError"
        public let providerID: ProviderID
        public init(providerID: ProviderID) { self.providerID = providerID }
        // parity: core/src/artifact.ts#ProviderNotFoundError.message [status=implemented hash=5a728922330d]
        public var message: String { "Artifact provider not found: \(providerID.rawValue)" }
        public var description: String { message }
    }

    // parity: core/src/artifact.ts#InvalidError [status=implemented hash=d6575577332c]
    public struct InvalidError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "Artifact.InvalidError"
        public let reason: String
        public let field: String?
        public init(reason: String, field: String? = nil) { self.reason = reason; self.field = field }
        // parity: core/src/artifact.ts#InvalidError.message [status=implemented hash=8eadea097e1c]
        public var message: String { reason }
        public var description: String { reason }
    }

    // parity: core/src/artifact.ts#ProviderError [status=implemented hash=3092cb3dd1c5]
    public struct ProviderError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "Artifact.ProviderError"
        public let providerID: ProviderID
        public let detail: String?
        public init(providerID: ProviderID, detail: String? = nil) { self.providerID = providerID; self.detail = detail }
        // parity: core/src/artifact.ts#ProviderError.message [status=implemented hash=14eea9aa1692]
        public var message: String {
            if let detail, !detail.isEmpty { return "Artifact provider \(providerID.rawValue) failed: \(detail)" }
            return "Artifact provider \(providerID.rawValue) failed"
        }
        public var description: String { message }
    }

    // parity: core/src/artifact.ts#Error [status=implemented hash=a78162c83b06]
    public enum ArtifactError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        case disabled(DisabledError)
        case notFound(NotFoundError)
        case fileMissing(FileMissingError)
        case providerNotFound(ProviderNotFoundError)
        case invalid(InvalidError)
        case provider(ProviderError)

        public var description: String {
            switch self {
            case .disabled(let e): return e.description
            case .notFound(let e): return e.description
            case .fileMissing(let e): return e.description
            case .providerNotFound(let e): return e.description
            case .invalid(let e): return e.description
            case .provider(let e): return e.description
            }
        }
    }

    public struct StoredRecord: Equatable, Hashable, Sendable, Codable {
        public let info: Info
        public let directory: String
        public let projectID: String

        public init(info: Info, directory: String, projectID: String) {
            self.info = info
            self.directory = directory
            self.projectID = projectID
        }
    }

    public protocol KVStore: Sendable {
        func get(_ key: String) async -> JSONValue?
        func set(_ key: String, value: JSONValue) async
        func remove(_ key: String) async
        func scan(prefix: String) async -> [(key: String, value: JSONValue)]
    }

    public final class InMemoryKVStore: KVStore, Sendable {
        private let store = Mutex<[String: JSONValue]>([:])

        public init() {}

        public func get(_ key: String) async -> JSONValue? {
            store.withLock { $0[key] }
        }

        public func set(_ key: String, value: JSONValue) async {
            store.withLock { $0[key] = value }
        }

        public func remove(_ key: String) async {
            store.withLock { _ = $0.removeValue(forKey: key) }
        }

        public func scan(prefix: String) async -> [(key: String, value: JSONValue)] {
            store.withLock { map in
                map.filter { $0.key.hasPrefix(prefix) }
                    .sorted { $0.key < $1.key }
                    .map { (key: $0.key, value: $0.value) }
            }
        }
    }

    // parity: core/src/artifact.ts#Editor [status=adapted hash=618be97d3dba]
    public final class Editor: @unchecked Sendable {
        public private(set) var providers: [ProviderID: ProviderImplementation]
        public var defaultSelection: ProviderID?

        public init(
            providers: [ProviderID: ProviderImplementation],
            defaultSelection: ProviderID? = nil
        ) {
            self.providers = providers
            self.defaultSelection = defaultSelection
        }

        public func add(_ provider: ProviderImplementation) {
            providers[provider.id] = provider
        }

        public func remove(_ id: ProviderID) {
            if id == CoreArtifact.LocalProviderID { return }
            providers.removeValue(forKey: id)
            if defaultSelection == id { defaultSelection = nil }
        }
    }

    public struct ListFilter: Equatable, Hashable, Sendable {
        public let sessionID: SessionID?
        public let provider: ProviderID?

        public init(sessionID: SessionID? = nil, provider: ProviderID? = nil) {
            self.sessionID = sessionID
            self.provider = provider
        }
    }

    // parity: core/src/artifact.ts#Interface [status=adapted hash=014a93ae44ba]
    public protocol Interface: Sendable {
        func transform(_ fn: @escaping @Sendable (Editor) -> Void) async -> CoreFilesystem.LocationWatcherPolicy.Registration
        func reload() async
        func enabled() async -> Bool
        func providers() async throws -> [Provider]
        func prompts() async -> ProviderPrompts
        func list(_ filter: ListFilter?) async throws -> [Info]
        func create(_ input: CreateInput) async throws -> Info
        func get(_ id: ID) async throws -> Content
        func info(_ id: ID) async throws -> Info
        func update(_ id: ID, input: UpdateInput) async throws -> Info
        func remove(_ id: ID) async throws
        func readLocalFile(_ id: ID, subpath: String?) async throws -> LocalFile
    }

    /// Resolves the stored directory of an artifact from KV for HTTP routes without an explicit location query.
    // parity: core/src/artifact.ts#locate [status=implemented hash=76be013b2bf9]
    public static func locate(kv: any KVStore, id: ID) async -> String? {
        guard let raw = await kv.get(itemPrefix + id.rawValue),
              let data = try? JSONEncoder().encode(raw),
              let record = try? JSONDecoder().decode(StoredRecord.self, from: data)
        else {
            return nil
        }
        return record.directory
    }

    // parity: core/src/artifact.ts#Service [status=adapted hash=aeac65f56ab8]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/Artifact"

        private struct State: Sendable {
            var transforms: [UInt64: @Sendable (Editor) -> Void] = [:]
            var order: [UInt64] = []
            var providers: [ProviderID: ProviderImplementation]
            var selection: ProviderID? = nil
            var nextID: UInt64 = 1
        }

        private let directory: String
        private let projectID: ProjectID
        private let rootDir: String
        private let fileSystem: any OpenCodeFileSystem
        private let flags: any CoreFlag.Interface
        private let kv: any KVStore
        private let localProvider: ProviderImplementation
        private let nowMs: @Sendable () -> Int64
        private let state: Mutex<State>

        public init(
            directory: String = "/",
            projectID: ProjectID = .global,
            globalPaths: Global.Interface = Global.make(),
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            flags: any CoreFlag.Interface = CoreFlag.Service(config: CoreConfig.Test()),
            kv: any KVStore = InMemoryKVStore(),
            nowMs: @escaping @Sendable () -> Int64 = { Flock.currentEpochMs() }
        ) {
            self.directory = directory
            self.projectID = projectID
            let root = CoreConfigDiscovery.joinPath(globalPaths.data, "artifacts")
            self.rootDir = root
            self.fileSystem = fileSystem
            self.flags = flags
            self.kv = kv
            self.nowMs = nowMs

            let fs = fileSystem
            let local = ProviderImplementation(
                id: CoreArtifact.LocalProviderID,
                name: "Local",
                capabilities: [.static],
                prompt: "Artifacts are served as HTML by this OpenCode server. Only people who can reach this server can open them.",
                create: { input in
                    let dir = CoreConfigDiscovery.joinPath(root, input.id.rawValue)
                    try await Self.replaceDirectoryFiles(fs: fs, baseDir: dir, files: input.files)
                    return ProviderResult(url: Self.viewURL(input.id))
                },
                read: { id in
                    let dir = CoreConfigDiscovery.joinPath(root, id.rawValue)
                    return try await Self.readDirectoryFiles(fs: fs, baseDir: dir)
                },
                update: { id, input in
                    let dir = CoreConfigDiscovery.joinPath(root, id.rawValue)
                    try await Self.replaceDirectoryFiles(fs: fs, baseDir: dir, files: input.files)
                    return ProviderResult(url: Self.viewURL(id))
                },
                delete: { id in
                    let dir = CoreConfigDiscovery.joinPath(root, id.rawValue)
                    try? await fs.remove(at: dir)
                }
            )
            self.localProvider = local
            self.state = Mutex(State(providers: [CoreArtifact.LocalProviderID: local]))
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
            let local = self.localProvider
            state.withLock { s in
                let editor = Editor(providers: [CoreArtifact.LocalProviderID: local], defaultSelection: nil)
                for id in s.order { s.transforms[id]?(editor) }
                s.providers = editor.providers
                s.selection = editor.defaultSelection
            }
        }

        public func enabled() async -> Bool {
            await flags.enabled(.artifacts)
        }

        private func requireEnabled() async throws {
            guard await enabled() else { throw DisabledError() }
        }

        private func activeDefaultID() -> ProviderID {
            state.withLock { s in
                if let sel = s.selection, s.providers[sel] != nil { return sel }
                return CoreArtifact.LocalProviderID
            }
        }

        private func resolveProvider(_ requested: ProviderID?) throws -> ProviderImplementation {
            let target = requested ?? activeDefaultID()
            guard let found = state.withLock({ $0.providers[target] }) else {
                throw ProviderNotFoundError(providerID: target)
            }
            return found
        }

        public func providers() async throws -> [Provider] {
            try await requireEnabled()
            let defaultID = activeDefaultID()
            let list = state.withLock { Array($0.providers.values) }
            return list.map { p in
                Provider(id: p.id, name: p.name, capabilities: p.capabilities, isDefault: p.id == defaultID)
            }.sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.name < rhs.name
            }
        }

        public func prompts() async -> ProviderPrompts {
            let defaultID = activeDefaultID()
            let (def, others): (ProviderImplementation, [ProviderImplementation]) = state.withLock { s in
                let d = s.providers[defaultID] ?? localProvider
                let o = s.providers.values.filter { $0.id != d.id }.sorted { $0.name < $1.name }
                return (d, o)
            }
            return ProviderPrompts(
                defaultProvider: ProviderPrompts.DefaultProvider(
                    id: def.id,
                    name: def.name,
                    capabilities: def.capabilities,
                    prompt: def.prompt
                ),
                others: others.map {
                    ProviderPrompts.OtherProvider(id: $0.id, name: $0.name, capabilities: $0.capabilities)
                }
            )
        }

        public func list(_ filter: ListFilter? = nil) async throws -> [Info] {
            try await requireEnabled()
            let rows = await kv.scan(prefix: CoreArtifact.itemPrefix)
            var items: [Info] = []
            for (_, val) in rows {
                guard let record = Self.decodeRecord(val), record.projectID == projectID.rawValue else { continue }
                if let sid = filter?.sessionID, record.info.sessionID != sid { continue }
                if let pid = filter?.provider, record.info.provider != pid { continue }
                items.append(record.info)
            }
            return items.sorted { lhs, rhs in
                if lhs.time.updated != rhs.time.updated { return lhs.time.updated > rhs.time.updated }
                return lhs.id.rawValue > rhs.id.rawValue
            }
        }

        public func create(_ input: CreateInput) async throws -> Info {
            try await requireEnabled()
            let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw InvalidError(reason: "Artifact title must not be empty", field: "title")
            }
            let files = try Self.normalizeFiles(input.files.mapValues { Array($0.utf8) })
            let entry = try Self.resolveEntry(files: files, requested: input.entry)
            let provider = try resolveProvider(input.provider)
            let id = ID.create()
            let now = Double(nowMs())
            let created: ProviderResult
            do {
                created = try await provider.create(ProviderCreateInput(
                    id: id,
                    title: title,
                    entry: entry,
                    files: files,
                    sessionID: input.sessionID
                ))
            } catch {
                throw ProviderError(providerID: provider.id, detail: String(describing: error))
            }
            let info = Info(
                id: id,
                provider: provider.id,
                sessionID: input.sessionID,
                title: title,
                entry: entry,
                url: created.url ?? Self.viewURL(id),
                time: ArtifactSchema.Time(created: now, updated: now)
            )
            let record = StoredRecord(info: info, directory: directory, projectID: projectID.rawValue)
            if let encoded = Self.encodeRecord(record) {
                await kv.set(CoreArtifact.itemPrefix + id.rawValue, value: encoded)
            }
            return info
        }

        public func info(_ id: ID) async throws -> Info {
            try await requireEnabled()
            return try await requireRecord(id).info
        }

        public func get(_ id: ID) async throws -> Content {
            try await requireEnabled()
            let record = try await requireRecord(id)
            let provider = try resolveProvider(record.info.provider)
            let rawFiles: [String: [UInt8]]
            do {
                rawFiles = try await provider.read(id)
            } catch {
                throw ProviderError(providerID: provider.id, detail: String(describing: error))
            }
            let stringFiles = rawFiles.mapValues { String(decoding: $0, as: UTF8.self) }
            return Content(info: record.info, files: stringFiles)
        }

        public func update(_ id: ID, input: UpdateInput) async throws -> Info {
            try await requireEnabled()
            let record = try await requireRecord(id)
            let title = (input.title ?? record.info.title).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw InvalidError(reason: "Artifact title must not be empty", field: "title")
            }
            let files = try Self.normalizeFiles(input.files.mapValues { Array($0.utf8) })
            let defaultEntry = files[record.info.entry] != nil ? record.info.entry : nil
            let entry = try Self.resolveEntry(files: files, requested: input.entry ?? defaultEntry)
            let provider = try resolveProvider(record.info.provider)
            let now = Double(nowMs())
            let sessionID = input.sessionID ?? record.info.sessionID
            let updated: ProviderResult
            do {
                updated = try await provider.update(id, ProviderUpdateInput(
                    title: title,
                    entry: entry,
                    files: files,
                    sessionID: sessionID
                ))
            } catch {
                throw ProviderError(providerID: provider.id, detail: String(describing: error))
            }
            let info = Info(
                id: id,
                provider: record.info.provider,
                sessionID: sessionID,
                title: title,
                entry: entry,
                url: updated.url ?? record.info.url,
                time: ArtifactSchema.Time(created: record.info.time.created, updated: now)
            )
            let nextRecord = StoredRecord(info: info, directory: record.directory, projectID: record.projectID)
            if let encoded = Self.encodeRecord(nextRecord) {
                await kv.set(CoreArtifact.itemPrefix + id.rawValue, value: encoded)
            }
            return info
        }

        public func remove(_ id: ID) async throws {
            try await requireEnabled()
            let record = try await requireRecord(id)
            if let provider = state.withLock({ $0.providers[record.info.provider] }) {
                do {
                    try await provider.delete(id)
                } catch {
                    throw ProviderError(providerID: provider.id, detail: String(describing: error))
                }
            }
            await kv.remove(CoreArtifact.itemPrefix + id.rawValue)
        }

        public func readLocalFile(_ id: ID, subpath: String? = nil) async throws -> LocalFile {
            try await requireEnabled()
            let record = try await requireRecord(id)
            guard record.info.provider == CoreArtifact.LocalProviderID else {
                throw InvalidError(
                    reason: "Artifact \(id.rawValue) is hosted by provider \"\(record.info.provider.rawValue)\", not the local server",
                    field: "artifactID"
                )
            }
            let requested: String
            if let sub = subpath?.trimmingCharacters(in: .whitespacesAndNewlines), !sub.isEmpty {
                requested = try Self.normalizePath(sub)
            } else {
                requested = record.info.entry
            }
            let target = CoreConfigDiscovery.joinPath(
                CoreConfigDiscovery.joinPath(rootDir, id.rawValue),
                requested
            )
            guard let bytes = try? await fileSystem.readFile(at: target) else {
                throw FileMissingError(artifactID: id, path: requested)
            }
            let byName = FSPathUtil.mimeType(requested)
            let mime: String
            if byName != "application/octet-stream" {
                mime = (byName.hasPrefix("text/") || byName == "application/javascript" || byName == "application/json")
                    ? "\(byName); charset=utf-8"
                    : byName
            } else {
                mime = CoreFilesystem.Mime.detect(bytes)
            }
            return LocalFile(bytes: bytes, mime: mime)
        }

        private func requireRecord(_ id: ID) async throws -> StoredRecord {
            guard let raw = await kv.get(CoreArtifact.itemPrefix + id.rawValue),
                  let record = Self.decodeRecord(raw),
                  record.projectID == projectID.rawValue
            else {
                throw NotFoundError(artifactID: id)
            }
            return record
        }

        private static func viewURL(_ id: ID) -> String {
            "/api/experimental/artifacts/\(id.rawValue)/view/"
        }

        private static func encodeRecord(_ record: StoredRecord) -> JSONValue? {
            guard let data = try? JSONEncoder().encode(record),
                  let val = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { return nil }
            return val
        }

        private static func decodeRecord(_ val: JSONValue) -> StoredRecord? {
            guard let data = try? JSONEncoder().encode(val),
                  let record = try? JSONDecoder().decode(StoredRecord.self, from: data)
            else { return nil }
            return record
        }

        private static func normalizePath(_ raw: String) throws -> String {
            var trimmed = raw.replacing("\\", with: "/")
            while trimmed.hasPrefix("./") { trimmed.removeFirst(2) }
            while trimmed.hasPrefix("/") { trimmed.removeFirst() }
            if trimmed.isEmpty || trimmed.contains("\u{0}") {
                throw InvalidError(reason: "Invalid artifact file path: \(raw)", field: "files")
            }
            let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
                throw InvalidError(reason: "Artifact file path must stay relative: \(raw)", field: "files")
            }
            return segments.joined(separator: "/")
        }

        private static func normalizeFiles(_ files: [String: [UInt8]]) throws -> [String: [UInt8]] {
            if files.isEmpty {
                throw InvalidError(reason: "Artifact must include at least one file", field: "files")
            }
            var out: [String: [UInt8]] = [:]
            for (rawPath, content) in files {
                let clean = try normalizePath(rawPath)
                out[clean] = content
            }
            return out
        }

        private static func resolveEntry(files: [String: [UInt8]], requested: String?) throws -> String {
            if let requested {
                let clean = try normalizePath(requested)
                guard files[clean] != nil else {
                    throw InvalidError(reason: "Entry file not found in files: \(clean)", field: "entry")
                }
                return clean
            }
            if files["index.html"] != nil { return "index.html" }
            if files["index.md"] != nil { return "index.md" }
            if files.count == 1, let sole = files.keys.first { return sole }
            throw InvalidError(
                reason: "Include \"index.html\" or \"index.md\", or specify \"entry\" when publishing multiple files",
                field: "entry"
            )
        }

        private static func replaceDirectoryFiles(
            fs: any OpenCodeFileSystem,
            baseDir: String,
            files: [String: [UInt8]]
        ) async throws {
            try? await fs.remove(at: baseDir)
            try await fs.makeDirectory(at: baseDir, recursive: true)
            for (rel, bytes) in files {
                let dest = CoreConfigDiscovery.joinPath(baseDir, rel)
                try await fs.writeFile(bytes, to: dest, createDirectories: true)
            }
        }

        private static func readDirectoryFiles(
            fs: any OpenCodeFileSystem,
            baseDir: String
        ) async throws -> [String: [UInt8]] {
            var out: [String: [UInt8]] = [:]
            func walk(_ current: String, prefix: String) async {
                guard let names = try? await fs.readDirectory(at: current) else { return }
                for name in names {
                    let rel = prefix.isEmpty ? name : "\(prefix)/\(name)"
                    let full = CoreConfigDiscovery.joinPath(current, name)
                    guard let st = try? await fs.stat(at: full) else { continue }
                    if st.type == .directory {
                        await walk(full, prefix: rel)
                    } else if st.type == .file, let bytes = try? await fs.readFile(at: full) {
                        out[rel] = bytes
                    }
                }
            }
            await walk(baseDir, prefix: "")
            return out
        }
    }

    // parity: core/src/artifact.ts#node [status=adapted hash=4048d84296fe]
    public static let node: LayerNode.Provider = AppNode.makeLocationNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            let dir = deps.get("@opencode/Location.directory", as: String.self) ?? "/"
            let global = deps.get(Global.Service.serviceKey, as: Global.Service.self)?.paths ?? Global.make()
            let fsUtil = deps.get(FSUtil.Service.serviceKey, as: FSUtil.Service.self)
            let flags = deps.get(CoreFlag.Service.serviceKey, as: (any CoreFlag.Interface).self)
                ?? CoreFlag.Service(config: CoreConfig.Test())
            let svc = Service(
                directory: dir,
                globalPaths: global,
                fileSystem: fsUtil?.fileSystem ?? LocalFileSystem.shared,
                flags: flags
            )
            return LayerNode.Output([Service.serviceKey: svc as any Interface])
        },
        [CoreFlag.node, Global.node, FSUtil.node]
    )
}

// MARK: - CoreSnapshot (`core/src/snapshot.ts`)

public enum CoreSnapshot {
    // parity: core/src/snapshot.ts#ID [status=implemented hash=e49acddfac38]
    public typealias ID = SnapshotSchema.ID

    // parity: core/src/snapshot.ts#Error [status=implemented hash=c4ee1c7eb04d]
    public struct SnapshotError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public enum Operation: String, Equatable, Hashable, Sendable, Codable {
            case capture
            case files
            case diff
            case restore
        }

        public static let tag = "Snapshot.Error"
        public let operation: Operation
        public let message: String
        public let cause: String?

        public init(operation: Operation, message: String, cause: String? = nil) {
            self.operation = operation
            self.message = message
            self.cause = cause
        }

        public var description: String { "Snapshot.\(operation.rawValue): \(message)" }
    }

    // parity: core/src/snapshot.ts#CompareInput [status=implemented hash=9072bba0b4e0]
    public struct CompareInput: Equatable, Hashable, Sendable, Codable {
        public let from: ID
        public let to: ID

        public init(from: ID, to: ID) {
            self.from = from
            self.to = to
        }
    }

    // parity: core/src/snapshot.ts#DiffInput [status=implemented hash=a47b1ba99de3]
    public struct DiffInput: Equatable, Hashable, Sendable, Codable {
        public let from: ID
        public let to: ID
        public let context: Int?
        public let paths: [SchemaPrimitive.RelativePath]?

        public init(
            from: ID,
            to: ID,
            context: Int? = nil,
            paths: [SchemaPrimitive.RelativePath]? = nil
        ) {
            self.from = from
            self.to = to
            self.context = context
            self.paths = paths
        }
    }

    // parity: core/src/snapshot.ts#RestoreInput [status=implemented hash=e1adef799e58]
    public struct RestoreInput: Equatable, Hashable, Sendable {
        public let files: [SchemaPrimitive.RelativePath: ID]

        public init(files: [SchemaPrimitive.RelativePath: ID]) {
            self.files = files
        }
    }

    // parity: core/src/snapshot.ts#Editor [status=adapted hash=379e5361a8ef]
    public final class Editor: @unchecked Sendable {
        public private(set) var enabled: Bool

        public init(enabled: Bool = true) {
            self.enabled = enabled
        }

        public func configure(_ enabled: Bool) {
            self.enabled = enabled
        }
    }

    // parity: core/src/snapshot.ts#Interface [status=adapted hash=1ed67379da4e]
    public protocol Interface: Sendable {
        func transform(_ fn: @escaping @Sendable (Editor) -> Void) async -> CoreFilesystem.LocationWatcherPolicy.Registration
        func reload() async
        func capture() async -> ID?
        func files(_ input: CompareInput) async throws -> [SchemaPrimitive.RelativePath]
        func diff(_ input: DiffInput) async throws -> [FileDiffSchema.Info]
        func restore(_ input: RestoreInput) async throws
    }

    /// Content-addressed filesystem snapshot engine supporting `capture`, `files`, `diff`, and `restore`.
    // parity: core/src/snapshot.ts#Service [status=adapted hash=13c540357eaf]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/Snapshot"
        private static let maxUntrackedBytes = 2 * 1024 * 1024

        private struct State: Sendable {
            var enabled: Bool = true
            var transforms: [UInt64: @Sendable (Editor) -> Void] = [:]
            var order: [UInt64] = []
            var nextID: UInt64 = 1
            var trees: [ID: [String: [UInt8]]] = [:]
        }

        public let directory: String
        private let fileSystem: any OpenCodeFileSystem
        private let state = Mutex(State())

        public init(
            directory: String = "/",
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            enabled: Bool = true
        ) {
            self.directory = CoreConfigDiscovery.resolvePath(base: "/", relative: directory)
            self.fileSystem = fileSystem
            self.state.withLock { $0.enabled = enabled }
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
                let editor = Editor(enabled: true)
                for id in s.order { s.transforms[id]?(editor) }
                s.enabled = editor.enabled
            }
        }

        public func capture() async -> ID? {
            guard state.withLock({ $0.enabled }) else { return nil }
            var files: [String: [UInt8]] = [:]
            await walk(dir: directory, prefix: "", into: &files)

            var manifest = ""
            for key in files.keys.sorted() {
                let bytes = files[key] ?? []
                manifest += "\(key):\(Hash.sha256(bytes))\n"
            }
            let treeID = ID(rawValue: Hash.sha256(manifest))
            state.withLock { $0.trees[treeID] = files }
            return treeID
        }

        public func files(_ input: CompareInput) async throws -> [SchemaPrimitive.RelativePath] {
            let (fromTree, toTree) = try requireTrees(from: input.from, to: input.to, operation: .files)
            let allKeys = Set(fromTree.keys).union(toTree.keys).sorted()
            var changed: [SchemaPrimitive.RelativePath] = []
            for key in allKeys {
                if fromTree[key] != toTree[key] {
                    changed.append(SchemaPrimitive.RelativePath(rawValue: key))
                }
            }
            return changed
        }

        public func diff(_ input: DiffInput) async throws -> [FileDiffSchema.Info] {
            if let paths = input.paths, paths.isEmpty { return [] }
            let (fromTree, toTree) = try requireTrees(from: input.from, to: input.to, operation: .diff)
            let filterSet = input.paths.map { Set($0.map(\.rawValue)) }
            let allKeys = Set(fromTree.keys).union(toTree.keys).sorted()
            let ctx = input.context ?? 3
            var results: [FileDiffSchema.Info] = []
            for key in allKeys {
                if let filterSet, !filterSet.contains(key) { continue }
                let oldBytes = fromTree[key]
                let newBytes = toTree[key]
                if oldBytes == newBytes { continue }
                let status: FileDiffSchema.Status
                if oldBytes == nil { status = .added }
                else if newBytes == nil { status = .deleted }
                else { status = .modified }
                let before = oldBytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let after = newBytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
                results.append(CoreFilesystemDiff.compute(
                    file: key,
                    before: before,
                    after: after,
                    status: status,
                    contextLines: ctx
                ))
            }
            return results
        }

        public func restore(_ input: RestoreInput) async throws {
            guard state.withLock({ $0.enabled }) else {
                throw SnapshotError(operation: .restore, message: "Snapshots are disabled")
            }
            // Validate all paths first so escapes fail before any writes occur.
            var plan: [(path: String, abs: String, bytes: [UInt8]?)] = []
            for (relPath, snapID) in input.files {
                let abs = CoreConfigDiscovery.resolvePath(base: directory, relative: relPath.rawValue)
                guard FSPathUtil.contains(parent: directory, child: abs) else {
                    throw SnapshotError(operation: .restore, message: "Path escapes the project: \(relPath.rawValue)")
                }
                guard let tree = state.withLock({ $0.trees[snapID] }) else {
                    throw SnapshotError(operation: .restore, message: "Unknown snapshot ID: \(snapID.rawValue)")
                }
                plan.append((relPath.rawValue, abs, tree[relPath.rawValue]))
            }
            for item in plan {
                do {
                    if let bytes = item.bytes {
                        try await fileSystem.writeFile(bytes, to: item.abs, createDirectories: true)
                    } else {
                        try? await fileSystem.remove(at: item.abs)
                    }
                } catch {
                    throw SnapshotError(operation: .restore, message: "Failed to restore \(item.path)", cause: String(describing: error))
                }
            }
        }

        private func requireTrees(
            from: ID,
            to: ID,
            operation: SnapshotError.Operation
        ) throws -> ([String: [UInt8]], [String: [UInt8]]) {
            let pair: ([String: [UInt8]]?, [String: [UInt8]]?) = state.withLock { s in
                (s.trees[from], s.trees[to])
            }
            guard let f = pair.0 else {
                throw SnapshotError(operation: operation, message: "Unknown snapshot ID: \(from.rawValue)")
            }
            guard let t = pair.1 else {
                throw SnapshotError(operation: operation, message: "Unknown snapshot ID: \(to.rawValue)")
            }
            return (f, t)
        }

        private func walk(dir: String, prefix: String, into out: inout [String: [UInt8]]) async {
            guard let names = try? await fileSystem.readDirectory(at: dir) else { return }
            for name in names.sorted() {
                if name == ".git" { continue }
                let rel = prefix.isEmpty ? name : "\(prefix)/\(name)"
                let abs = CoreConfigDiscovery.joinPath(dir, name)
                guard let st = try? await fileSystem.stat(at: abs) else { continue }
                if st.type == .directory {
                    await walk(dir: abs, prefix: rel, into: &out)
                } else if st.type == .file && st.size <= Int64(Self.maxUntrackedBytes),
                          let bytes = try? await fileSystem.readFile(at: abs)
                {
                    out[rel] = bytes
                }
            }
        }
    }

    private final class NoopService: Interface, Sendable {
        func transform(_ fn: @escaping @Sendable (Editor) -> Void) async -> CoreFilesystem.LocationWatcherPolicy.Registration {
            _ = fn
            return CoreFilesystem.LocationWatcherPolicy.Registration(dispose: {})
        }
        func reload() async {}
        func capture() async -> ID? { nil }
        func files(_ input: CompareInput) async throws -> [SchemaPrimitive.RelativePath] { _ = input; return [] }
        func diff(_ input: DiffInput) async throws -> [FileDiffSchema.Info] { _ = input; return [] }
        func restore(_ input: RestoreInput) async throws { _ = input }
    }

    // parity: core/src/snapshot.ts#node [status=adapted hash=30ce7fecd74a]
    public static let node: LayerNode.Provider = AppNode.makeLocationNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            let dir = deps.get("@opencode/Location.directory", as: String.self) ?? "/"
            let fsUtil = deps.get(FSUtil.Service.serviceKey, as: FSUtil.Service.self)
            let svc = Service(directory: dir, fileSystem: fsUtil?.fileSystem ?? LocalFileSystem.shared)
            return LayerNode.Output([Service.serviceKey: svc as any Interface])
        },
        [FSUtil.node, Global.node]
    )

    // parity: core/src/snapshot.ts#noopLayer [status=adapted hash=923f80ee8a54]
    public static let noopLayer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer.succeed(
        key: Service.serviceKey,
        value: NoopService() as any Interface
    )
}

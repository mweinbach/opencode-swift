import Synchronization
import OpenCodePlatform
import OpenCodeUtil

/// Port of `core/src/machine/machines.ts`: the machines this home knows, their pairing keys, and their live workers.
public enum Machines {
    /// The server's own machine (`Environment.localID`).
    public static let localID = "local"

    /// A machine's name, as a path will use it: `gpu:/work`. Two characters or more, so a Windows drive such as `C:`
    /// is never a machine, and never `local`, which is the server's own machine. At most 63, like a DNS label, so the
    /// link's welcome, which carries the name, always fits in one Noise message.
    // parity: core/src/machine/machines.ts#Name [status=implemented hash=45d39d0a0a81]
    public enum Name {
        /// `^[a-z][a-z0-9-]{1,62}$`, and not `local`.
        public static func isValid(_ name: String) -> Bool {
            let bytes = Array(name.utf8)
            guard bytes.count >= 2, bytes.count <= 63, name != Machines.localID else { return false }
            guard (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(bytes[0]) else { return false }
            return bytes.dropFirst().allSatisfy { byte in
                (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                    || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || byte == UInt8(ascii: "-")
            }
        }
    }

    // parity: core/src/machine/machines.ts#Info [status=implemented hash=85a60593c15e]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let online: Bool
        /// Whether the machine has joined with its key. Until then it is known by name only.
        public let paired: Bool
        /// Last reported by the worker's hello, while it is online.
        public let os: String?
        public let arch: String?

        public init(id: String, online: Bool, paired: Bool, os: String? = nil, arch: String? = nil) {
            self.id = id
            self.online = online
            self.paired = paired
            self.os = os
            self.arch = arch
        }
    }

    // parity: core/src/machine/machines.ts#NotFound [status=implemented hash=43a579bfc1f7]
    public struct NotFound: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Machines.NotFound"
        public let machine: String
        public init(machine: String) { self.machine = machine }

        // parity: core/src/machine/machines.ts#NotFound.message [status=implemented hash=23a6d23ec613]
        public var message: String { "No machine named \(MachineJoin.jsonString(machine))." }
        public var description: String { message }
    }

    // parity: core/src/machine/machines.ts#InvalidName [status=implemented hash=a248f7c490ad]
    public struct InvalidName: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Machines.InvalidName"
        public let name: String
        public init(name: String) { self.name = name }

        // parity: core/src/machine/machines.ts#InvalidName.message [status=implemented hash=4c50f2c7a64f]
        public var message: String {
            "\(MachineJoin.jsonString(name)) is not a machine name. Use lowercase letters, digits and hyphens, starting with a letter, 2 to 63 characters, and not \"local\"."
        }

        public var description: String { message }
    }

    // parity: core/src/machine/machines.ts#AlreadyExists [status=implemented hash=d084aa60e078]
    public struct AlreadyExists: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Machines.AlreadyExists"
        public let machine: String
        public init(machine: String) { self.machine = machine }

        // parity: core/src/machine/machines.ts#AlreadyExists.message [status=implemented hash=1c154c7714cd]
        public var message: String { "\(MachineJoin.jsonString(machine)) is already a machine." }
        public var description: String { message }
    }

    // parity: core/src/machine/machines.ts#AlreadyPaired [status=implemented hash=2a4c9e4b61ae]
    public struct AlreadyPaired: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Machines.AlreadyPaired"
        public let machine: String
        public init(machine: String) { self.machine = machine }

        // parity: core/src/machine/machines.ts#AlreadyPaired.message [status=implemented hash=1c154c7714cd]
        public var message: String {
            "\(MachineJoin.jsonString(machine)) is already paired. Use replace to pair it again."
        }

        public var description: String { message }
    }

    /// One failure for every rejected join, saying nothing about which step rejected it.
    // parity: core/src/machine/machines.ts#InvalidJoin [status=implemented hash=399e4f76d143]
    public struct InvalidJoin: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Machines.InvalidJoin"
        public init() {}

        // parity: core/src/machine/machines.ts#InvalidJoin.message [status=implemented hash=51724ad3d104]
        public var message: String { "That join string is not valid." }
        public var description: String { message }
    }

    // parity: core/src/machine/machines.ts#UnknownKey [status=implemented hash=7297d1e58d19]
    public struct UnknownKey: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Machines.UnknownKey"
        public init() {}

        // parity: core/src/machine/machines.ts#UnknownKey.message [status=implemented hash=eca2f80b8951]
        public var message: String { "No machine has that key." }
        public var description: String { message }
    }

    // parity: core/src/machine/machines.ts#InviteOptions [status=implemented hash=392abad9211d]
    public struct InviteOptions: Equatable, Hashable, Sendable {
        public let reach: [MachineJoin.Reach]
        /// Pairs the machine again, replacing the key its current worker holds.
        public let replace: Bool

        public init(reach: [MachineJoin.Reach], replace: Bool = false) {
            self.reach = reach
            self.replace = replace
        }
    }

    // parity: core/src/machine/machines.ts#Interface [status=implemented hash=de60e37ad880]
    public protocol Interface: Sendable {
        /// Makes the machine known for good, returning its validated ID. Throws `InvalidName` or `AlreadyExists`.
        func add(_ name: String) async throws -> String
        /// Forgets the machine and ends it, failing what waits on it as `NotFound` and its processes at once.
        func remove(_ id: String) async throws
        func list() async -> [Info]
        /// The machine's environment, connected or not: calls on an offline machine fail with `NotSent`.
        func get(_ id: String) async throws -> any CoreLocation.Environment.Interface
        /// The home directory in the hello of the machine's connection, throwing `NotSent` while it is offline.
        func home(_ id: String) async throws -> String
        /// Serves one worker's connection, routed by the name in its hello, until it is lost or replaced.
        func connect(_ connection: MachineDriver.Connection) async throws
        /// Prints one join string for this machine, good once and for five minutes. A second invite replaces the first.
        func invite(_ id: String, options: InviteOptions) async throws -> String
        /// Pairs the machine holding the secret's join string with `key` and returns its id. The secret is spent either way.
        func join(secret: [UInt8], key: [UInt8]) async throws -> String
        /// The machine a paired worker's key belongs to, for its next connection. Throws `UnknownKey`.
        func identify(_ key: [UInt8]) async throws -> String
    }

    static let secretBytes = 32
    static let keyBytes = 32
    /// How long a printed join string stays good, in milliseconds.
    static let inviteTTL: Int64 = 5 * 60 * 1000

    static func digest(_ secret: [UInt8]) -> String {
        MachineCrypto.base64URLEncode(MachineCrypto.sha256(secret))
    }

    struct Invitation: Sendable {
        let hash: String
        let expires: Int64
        let replace: Bool
    }

    struct State {
        // One instance per known id for the life of the process: its running processes must survive reconnects.
        var instances: [String: any MachineDriver.Interface] = [:]
        // Keys are the one durable part of pairing, read at start and written by `join`, so `identify` answers from memory.
        var keys: [String: String] = [:]
        // Pending invitations are per process, like live connections: one per name, holding only the secret's hash.
        var invitations: [String: Invitation] = [:]
    }

    // parity: core/src/machine/machines.ts#Service [status=implemented hash=c75d3d7cc311]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/Machines"

        private let db: any SQLiteDatabase
        private let identity: any MachineIdentity.Interface
        private let now: @Sendable () -> Int64
        // The work under each name's lock runs to completion, so a dropped connection mid-join never leaves a row
        // written without memory updated to match.
        private let locks = CoreSubsystems.Effect.KeyedMutex<String>.makeUnsafe()
        private let state: Mutex<State>

        /// Known names are read once per process; a machine another process adds or removes in the shared database
        /// shows up here on restart. Live connections stay in the dialling process.
        public init(
            database: any SQLiteDatabase,
            identity: any MachineIdentity.Interface,
            now: @escaping @Sendable () -> Int64 = { Flock.currentEpochMs() }
        ) throws {
            self.db = database
            self.identity = identity
            self.now = now
            var initial = State()
            for row in try database.query("SELECT id, key FROM machine", parameters: []) {
                guard let id = row.string("id") else { continue }
                initial.instances[id] = MachineDriver.make(id)
                if let key = row.string("key") { initial.keys[id] = key }
            }
            state = Mutex(initial)
        }

        public func add(_ name: String) async throws -> String {
            guard Name.isValid(name) else { throw InvalidName(name: name) }
            let id = name
            try await locks.withLock(id) { () throws -> Void in
                if self.state.withLock({ $0.instances[id] != nil }) { throw AlreadyExists(machine: id) }
                let inserted = try self.db.execute(
                    "INSERT INTO machine (id, time_created) VALUES (?, ?) ON CONFLICT DO NOTHING",
                    parameters: [.text(id), .integer(self.now())]
                ).rowsAffected > 0
                // A row another process wrote is still a known machine, so it is taken into memory either way.
                self.state.withLock { $0.instances[id] = MachineDriver.make(id) }
                if !inserted { throw AlreadyExists(machine: id) }
            }
            return id
        }

        public func remove(_ id: String) async throws {
            try await locks.withLock(id) { () throws -> Void in
                guard self.state.withLock({ $0.instances[id] }) != nil else { return }
                _ = try self.db.execute("DELETE FROM machine WHERE id = ?", parameters: [.text(id)])
                let machine = self.state.withLock { s -> (any MachineDriver.Interface)? in
                    s.invitations.removeValue(forKey: id)
                    s.keys.removeValue(forKey: id)
                    return s.instances.removeValue(forKey: id)
                }
                machine?.close(NotFound(machine: id))
            }
        }

        public func list() async -> [Info] {
            state.withLock { s in
                s.instances.sorted { $0.key < $1.key }.map { id, machine in
                    let paired = s.keys[id] != nil
                    guard let hello = machine.hello() else { return Info(id: id, online: false, paired: paired) }
                    return Info(id: id, online: true, paired: paired, os: hello.os, arch: hello.arch)
                }
            }
        }

        public func get(_ id: String) async throws -> any CoreLocation.Environment.Interface {
            guard let machine = state.withLock({ $0.instances[id] }) else { throw NotFound(machine: id) }
            return machine.environment
        }

        public func home(_ id: String) async throws -> String {
            guard let machine = state.withLock({ $0.instances[id] }) else { throw NotFound(machine: id) }
            guard let hello = machine.hello() else { throw MachineDriver.NotSent(machine: id) }
            return hello.home
        }

        public func connect(_ connection: MachineDriver.Connection) async throws {
            let id = connection.hello.name
            guard let machine = state.withLock({ $0.instances[id] }) else { throw NotFound(machine: id) }
            await machine.connect(connection)
        }

        public func invite(_ id: String, options: InviteOptions) async throws -> String {
            let home = try await identity.publicKey()
            let now = self.now()
            let secret = MachineCrypto.randomBytes(Machines.secretBytes)
            let expires = now + Machines.inviteTTL
            // Every check and the write happen in one locked step.
            try state.withLock { s in
                if s.instances[id] == nil { throw NotFound(machine: id) }
                if s.keys[id] != nil && !options.replace { throw AlreadyPaired(machine: id) }
                s.invitations[id] = Invitation(hash: Machines.digest(secret), expires: expires, replace: options.replace)
            }
            return MachineJoin.encode(MachineJoin.Value(home: home, secret: secret, expires: expires, reach: options.reach))
        }

        public func join(secret: [UInt8], key: [UInt8]) async throws -> String {
            // Only an Ed25519 public key is ever stored as a machine's key. The secret is not spent on a malformed call.
            guard key.count == Machines.keyBytes else { throw InvalidJoin() }
            let hash = Machines.digest(secret)
            guard let id = state.withLock({ s in s.invitations.first(where: { $0.value.hash == hash })?.key }) else {
                throw InvalidJoin()
            }
            let encoded = MachineCrypto.base64URLEncode(key)
            try await locks.withLock(id) { () throws -> Void in
                // Read again under the name's lock: an invite or removal since the scan above invalidates this one.
                let invitation: Invitation = try self.state.withLock { s in
                    guard let invitation = s.invitations[id], invitation.hash == hash else { throw InvalidJoin() }
                    // Spent on the try, not on success: one join string pairs one worker, whatever happens next.
                    s.invitations.removeValue(forKey: id)
                    return invitation
                }
                if self.now() >= invitation.expires { throw InvalidJoin() }
                try self.state.withLock { s in
                    if s.keys[id] != nil && !invitation.replace { throw InvalidJoin() }
                    if s.keys.contains(where: { $0.value == encoded && $0.key != id }) { throw InvalidJoin() }
                }
                // The unique index turns two names writing one key at the same instant into an error here; the link
                // turns every failure into one refusal.
                let written = try self.db.execute(
                    "UPDATE machine SET key = ? WHERE id = ?",
                    parameters: [.text(encoded), .text(id)]
                ).rowsAffected > 0
                if !written { throw InvalidJoin() }
                self.state.withLock { $0.keys[id] = encoded }
            }
            return id
        }

        public func identify(_ key: [UInt8]) async throws -> String {
            let encoded = MachineCrypto.base64URLEncode(key)
            guard let id = state.withLock({ s in s.keys.first(where: { $0.value == encoded })?.key }) else {
                throw UnknownKey()
            }
            return id
        }
    }

    // parity: core/src/machine/machines.ts#node [status=implemented hash=80e9dc9472c8]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            guard let database = deps.get(CoreDatabaseStore.Service.serviceKey, as: CoreDatabaseStore.Service.self),
                  let identity = deps.get(MachineIdentity.Service.serviceKey, as: (any MachineIdentity.Interface).self)
            else {
                throw MachineDependencyMissing(service: Service.serviceKey)
            }
            let service = try Service(database: database.db, identity: identity)
            return LayerNode.Output([Service.serviceKey: service as any Interface])
        },
        [CoreDatabaseStore.node, MachineIdentity.node]
    )

    /// A dependency the layer graph did not provide.
    public struct MachineDependencyMissing: Error, Equatable, Sendable, CustomStringConvertible {
        public let service: String
        public var description: String { "\(service) is missing a dependency" }
    }
}

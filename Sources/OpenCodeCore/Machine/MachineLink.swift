// The handshake that opens a link between the home (the OpenCode server) and a machine that connects to it: a worker
// today, any client later (`core/src/machine/link.ts`). The side that opens the connection calls `dial`; the home
// calls `accept`. Both end holding the peer's proven identity and two ciphers for everything that follows, over a
// carrier that may pass through relays neither side trusts.
//
// It is Noise XX with the dialling side as initiator. Each side proves its long-term Ed25519 identity by signing a
// Noise static key made for this one connection together with the handshake hash so far. The home proves itself
// first, in message 2; the dialling side checks it against the home key it was given before it writes message 3, the
// one that carries its own identity and, on first contact, its join secret. Every field is fixed-size raw bytes:
//
//   1  worker -> home   e                                                                        32 bytes
//   2  home -> worker   e, s, { home key || sign(home key, HOME || home static || h1) }         192 bytes
//   3  worker -> home   s, { worker key || sign(worker key, MACHINE || worker static || h2)
//                              || has secret || secret }                                         193 bytes
//   then the home's first transport message, the machine's name in UTF-8
//
// h1 is the hash once message 1 is read and h2 once message 2 is read; both sides hold the same h at each step.

/// Port of `core/src/machine/link.ts`.
public enum MachineLink {
    static let prologue = Array("opencode-link-v1".utf8)
    static let homeLabel = Array("opencode-link-v1/home:".utf8)
    static let machineLabel = Array("opencode-link-v1/machine:".utf8)
    static let key = 32
    static let signature = 64
    static let tag = 16
    /// A reconnect sends zeros where an enrolment sends its secret, so a relay cannot tell the two apart by length.
    static let noSecret = [UInt8](repeating: 0, count: 32)
    static let first = key
    static let second = key + key + tag + (key + signature) + tag
    static let third = key + tag + (key + signature + 1 + key) + tag
    static let deadline: Duration = .seconds(10)

    /// The carrier ended: the connection under it closed.
    // parity: core/src/machine/link.ts#Closed [status=implemented hash=722fc801c3e6]
    public struct Closed: Error, Equatable, Hashable, Sendable {
        public static let tag = "Link.Closed"
        public init() {}
    }

    /// One failure for every refused handshake, on either side, saying nothing about which step refused it. The caller
    /// closes the carrier; nothing more is sent on it.
    // parity: core/src/machine/link.ts#Refused [status=implemented hash=311254a24398]
    public struct Refused: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Link.Refused"
        public init() {}

        // parity: core/src/machine/link.ts#Refused.message [status=implemented hash=68d5ef8a57c9]
        public var message: String { "The link was refused." }
        public var description: String { message }
    }

    /// Carries one binary message at a time, in order: a WebSocket, through whatever relays it. Both calls must honour
    /// task cancellation, or `accept`'s deadline cannot cut short a peer that stops reading or writing.
    // parity: core/src/machine/link.ts#Carrier [status=implemented hash=cc2606b548de]
    public protocol Carrier: Sendable {
        func send(_ message: [UInt8]) async
        /// The next message, throwing `Closed` once the carrier has ended.
        func receive() async throws -> [UInt8]
    }

    /// Only for reproducing the pinned transcript, which fixes them. Production callers never set these and get fresh
    /// key pairs for every connection.
    // parity: core/src/machine/link.ts#Fixed [status=implemented hash=c76fe2fae901]
    public struct Fixed: Sendable {
        public let `static`: MachineNoise.KeyPair?
        public let ephemeral: MachineNoise.KeyPair?

        public init(static: MachineNoise.KeyPair? = nil, ephemeral: MachineNoise.KeyPair? = nil) {
            self.static = `static`
            self.ephemeral = ephemeral
        }
    }

    // parity: core/src/machine/link.ts#DialOptions [status=implemented hash=092efc59aa08]
    public struct DialOptions: Sendable {
        /// The home's Ed25519 public key: the join string's on first contact, the caller's own record of it afterwards.
        public let home: [UInt8]
        /// The dialling side's long-term Ed25519 key, the one the home pairs with a machine.
        public let identity: MachineIdentity.Key
        /// The join secret, on first contact only. Forget it only once `dial` succeeds: until then the caller cannot
        /// know whether the home received it, and a home that already paired this key lets it in again whatever secret
        /// it brings.
        public let secret: [UInt8]?
        public let fixed: Fixed

        public init(home: [UInt8], identity: MachineIdentity.Key, secret: [UInt8]? = nil, fixed: Fixed = Fixed()) {
            self.home = home
            self.identity = identity
            self.secret = secret
            self.fixed = fixed
        }
    }

    /// A link both sides have proven: the peer's machine name and the ciphers for every later message, in order.
    public struct Established: Sendable {
        public let machine: String
        public let send: MachineNoise.Sender
        public let receive: MachineNoise.Receiver
    }

    /// The home's side, called with the carrier of a connection it received.
    ///
    /// Proves the home's key to the peer, then requires the peer's proof of its own key. A key the home has paired is
    /// a reconnect; a key it has not is paired only with a valid join secret for one of its machines. On success the
    /// home has already sent the welcome, the machine's name, and returns that machine's id with the ciphers.
    ///
    /// Anything else, including ten seconds passing, is `Refused`, and nothing that says why reaches the peer: the
    /// caller closes the carrier. Cancelling `accept` cancels it; that is never turned into `Refused`.
    // parity: core/src/machine/link.ts#accept [status=implemented hash=4e4f7b8c3b44]
    public static func accept(
        _ carrier: any Carrier,
        identity: any MachineIdentity.Interface,
        machines: any Machines.Interface,
        fixed: Fixed = Fixed()
    ) async throws -> Established {
        try await refusing(deadline: deadline) {
            let local = fixed.static ?? MachineNoise.generateKeyPair()
            let noise = try MachineNoise.handshake(
                MachineNoise.Options(initiator: false, prologue: prologue, static: local, ephemeral: fixed.ephemeral)
            )
            _ = try noise.read(try await receive(carrier, length: first))
            let homeSignature = try await identity.sign(homeLabel + local.publicKey + (try present(noise.hash)))
            await carrier.send(try noise.write(try await identity.publicKey() + homeSignature))
            let h2 = try present(noise.hash)
            let payload = try noise.read(try await receive(carrier, length: third))
            let workerKey = Array(payload[0..<key])
            let signed = machineLabel + (try present(noise.remoteStatic)) + h2
            guard MachineIdentity.verify(publicKey: workerKey, bytes: signed, signature: Array(payload[key..<(key + signature)])) else {
                throw Refused()
            }
            let flag = payload[key + signature]
            let secret = Array(payload[(key + signature + 1)...])
            if flag > 1 || (flag == 0 && secret != noSecret) { throw Refused() }
            // A key the home already knows is a reconnect whatever else the message carries; an unknown key needs a valid secret.
            let machine: String
            do {
                machine = try await machines.identify(workerKey)
            } catch {
                if flag == 0 { throw Refused() }
                machine = try await machines.join(secret: secret, key: workerKey)
            }
            let transport = try noise.split()
            await carrier.send(try transport.send.encrypt(Array(machine.utf8)))
            return Established(machine: machine, send: transport.send, receive: transport.receive)
        }
    }

    /// The side that opens the connection, called with the carrier it opened.
    ///
    /// Requires the home to prove the key in `options.home` first, and only then proves its own key and sends the join
    /// secret, so the secret never reaches any other home. On success returns the machine name the home welcomed it
    /// as, with the ciphers.
    ///
    /// Anything else is `Refused`, and the caller closes the carrier. `dial` has no deadline of its own: the caller
    /// bounds it. Cancelling it cancels it; that is never turned into `Refused`.
    // parity: core/src/machine/link.ts#dial [status=implemented hash=3affeca20df6]
    public static func dial(_ carrier: any Carrier, options: DialOptions) async throws -> Established {
        try await refusing(deadline: nil) {
            let home = options.home
            let secret = options.secret ?? noSecret
            guard secret.count == key else { throw Refused() }
            let local = options.fixed.static ?? MachineNoise.generateKeyPair()
            let noise = try MachineNoise.handshake(
                MachineNoise.Options(initiator: true, prologue: prologue, static: local, ephemeral: options.fixed.ephemeral)
            )
            await carrier.send(try noise.write([]))
            let h1 = try present(noise.hash)
            let payload = try noise.read(try await receive(carrier, length: second))
            let signed = homeLabel + (try present(noise.remoteStatic)) + h1
            guard Array(payload[0..<key]) == home,
                  MachineIdentity.verify(publicKey: home, bytes: signed, signature: Array(payload[key...]))
            else {
                throw Refused()
            }
            let workerSignature = options.identity.sign(machineLabel + local.publicKey + (try present(noise.hash)))
            let flag: [UInt8] = [options.secret == nil ? 0 : 1]
            await carrier.send(try noise.write(options.identity.publicKey + workerSignature + flag + secret))
            let transport = try noise.split()
            let welcome = try transport.receive.decrypt(try await carrier.receive())
            guard let machine = String(validating: welcome, as: UTF8.self) else { throw Refused() }
            return Established(machine: machine, send: transport.send, receive: transport.receive)
        }
    }

    /// The next message, refused unless it has exactly the length its step's layout gives it, before Noise reads it.
    static func receive(_ carrier: any Carrier, length: Int) async throws -> [UInt8] {
        let message = try await carrier.receive()
        guard message.count == length else { throw Refused() }
        return message
    }

    static func present<A>(_ value: A?) throws -> A {
        guard let value else { throw Refused() }
        return value
    }

    /// Runs `body`, turning every failure and a passed deadline into `Refused`, but never a cancellation of the caller.
    static func refusing<A: Sendable>(
        deadline: Duration?,
        _ body: @escaping @Sendable () async throws -> A
    ) async throws -> A {
        do {
            guard let deadline else { return try await body() }
            return try await withThrowingTaskGroup(of: A?.self) { group in
                group.addTask { try await body() }
                group.addTask {
                    try await Task.sleep(for: deadline)
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let value = first else { throw Refused() }
                return value
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw Refused()
        }
    }
}

import Synchronization

// Noise_XX_25519_AESGCM_SHA256 as the Noise Protocol Framework, revision 34, defines it:
// https://noiseprotocol.org/noise.html. Section numbers below refer to that text.
//
// Bytes are copied on the way in and on the way out (Swift arrays are values), so a caller reusing a buffer or
// filling a returned key cannot change a handshake.

/// Port of `core/src/machine/noise.ts`.
public enum MachineNoise {
    static let protocolName = "Noise_XX_25519_AESGCM_SHA256"
    static let dhLength = 32
    static let hashLength = 32
    static let tagLength = 16
    static let maxMessage = 65_535
    static let maxNonce = UInt64.max

    /// Section 7.5. XX has no pre-messages; the initiator writes messages 1 and 3, the responder message 2.
    enum Token: Sendable { case e, s, ee, es, se }
    static let pattern: [[Token]] = [[.e], [.e, .ee, .s, .es], [.s, .se]]

    /// Every failure ends the handshake or cipher it came from: later calls fail with `wrongStep`. `badKey` is a key
    /// that is not 32 bytes, refused before a key pair or handshake exists.
    // parity: core/src/machine/noise.ts#Failure [status=implemented hash=59a5fed63345]
    public enum Failure: String, Error, Equatable, Hashable, Sendable {
        case wrongStep = "WrongStep"
        case badMessage = "BadMessage"
        case tooLong = "TooLong"
        case badKey = "BadKey"
    }

    /// Raw 32-byte X25519 keys. Nothing here zeroes a private key after use; dropping the handshake when it is done is
    /// the real lifetime control.
    // parity: core/src/machine/noise.ts#KeyPair [status=implemented hash=6635ffc72126]
    public struct KeyPair: Equatable, Hashable, Sendable {
        public let publicKey: [UInt8]
        public let privateKey: [UInt8]

        public init(publicKey: [UInt8], privateKey: [UInt8]) {
            self.publicKey = publicKey
            self.privateKey = privateKey
        }
    }

    // parity: core/src/machine/noise.ts#Options [status=implemented hash=14044b69222a]
    public struct Options: Sendable {
        public let initiator: Bool
        public let prologue: [UInt8]
        public let `static`: KeyPair
        /// Only for reproducing published test vectors, which fix it. Production callers omit it and get a fresh key
        /// pair: an ephemeral used twice gives up forward secrecy.
        public let ephemeral: KeyPair?

        public init(initiator: Bool, prologue: [UInt8], static: KeyPair, ephemeral: KeyPair? = nil) {
            self.initiator = initiator
            self.prologue = prologue
            self.static = `static`
            self.ephemeral = ephemeral
        }
    }

    /// Section 12.1 GENERATE_KEYPAIR: any 32 random bytes are an X25519 private key.
    // parity: core/src/machine/noise.ts#generateKeyPair [status=implemented hash=e01079986c3b]
    public static func generateKeyPair() -> KeyPair {
        derive(MachineCrypto.randomBytes(dhLength))
    }

    /// The key pair of a raw 32-byte X25519 private key.
    // parity: core/src/machine/noise.ts#keyPair [status=implemented hash=4e7876dc8c62]
    public static func keyPair(_ privateKey: [UInt8]) throws(Failure) -> KeyPair {
        guard privateKey.count == dhLength else { throw .badKey }
        return derive(privateKey)
    }

    /// Section 5.3: an XX HandshakeState for one side, or `badKey` when a key in `options` is not 32 bytes.
    // parity: core/src/machine/noise.ts#handshake [status=implemented hash=e2587efca2b9]
    public static func handshake(_ options: Options) throws(Failure) -> Handshake {
        let keys = options.ephemeral.map { [options.static, $0] } ?? [options.static]
        guard keys.allSatisfy({ $0.publicKey.count == dhLength && $0.privateKey.count == dhLength }) else {
            throw .badKey
        }
        return Handshake(
            initiator: options.initiator,
            prologue: options.prologue,
            s: options.static,
            e: options.ephemeral ?? generateKeyPair()
        )
    }

    static func derive(_ privateKey: [UInt8]) -> KeyPair {
        KeyPair(publicKey: MachineCrypto.x25519PublicKey(privateKey: privateKey), privateKey: privateKey)
    }

    // MARK: - HandshakeState

    struct HandshakeState: Sendable {
        let initiator: Bool
        let s: KeyPair
        let e: KeyPair
        var h: [UInt8]
        var ck: [UInt8]
        var cipher = CipherState(key: nil)
        var re: [UInt8]?
        var rs: [UInt8]?
        var step = 0
        var taken = false
        var failed = false

        mutating func mixHash(_ data: [UInt8]) {
            h = MachineCrypto.sha256(h + data)
        }

        mutating func mixKey(_ inputKeyMaterial: [UInt8]) {
            let (chainingKey, tempK) = hkdf(ck, inputKeyMaterial)
            ck = chainingKey
            cipher = CipherState(key: tempK)
        }

        mutating func encryptAndHash(_ plaintext: [UInt8]) throws(Failure) -> [UInt8] {
            let ciphertext = try cipher.encrypt(ad: h, plaintext)
            mixHash(ciphertext)
            return ciphertext
        }

        mutating func decryptAndHash(_ ciphertext: [UInt8]) throws(Failure) -> [UInt8] {
            let plaintext = try cipher.decrypt(ad: h, ciphertext)
            mixHash(ciphertext)
            return plaintext
        }

        /// Section 7: in "es" the first letter is the initiator's key and the second the responder's; each side uses
        /// the private key it holds and the public key it received.
        mutating func mixDh(_ token: Token) throws(Failure) {
            let (first, second): (Bool, Bool) // true = ephemeral
            switch token {
            case .ee: (first, second) = (true, true)
            case .es: (first, second) = (true, false)
            case .se: (first, second) = (false, true)
            case .e, .s: return
            }
            let localIsEphemeral = initiator ? first : second
            let remoteIsEphemeral = initiator ? second : first
            guard let remoteKey = remoteIsEphemeral ? re : rs else { throw .badMessage }
            mixKey(try dh(localIsEphemeral ? e : s, remoteKey))
        }

        func turn(writing: Bool) -> Bool {
            !failed && step < MachineNoise.pattern.count && ((step % 2 == 0) == (initiator == writing))
        }

        mutating func write(_ payload: [UInt8]) throws(Failure) -> [UInt8] {
            guard turn(writing: true) else { throw .wrongStep }
            var message: [UInt8] = []
            for token in MachineNoise.pattern[step] {
                switch token {
                case .e:
                    message += e.publicKey
                    mixHash(e.publicKey)
                case .s:
                    message += try encryptAndHash(s.publicKey)
                default:
                    try mixDh(token)
                }
            }
            message += try encryptAndHash(payload)
            if message.count > MachineNoise.maxMessage { throw .tooLong }
            step += 1
            return message
        }

        mutating func read(_ message: [UInt8]) throws(Failure) -> [UInt8] {
            guard turn(writing: false) else { throw .wrongStep }
            if message.count > MachineNoise.maxMessage { throw .tooLong }
            var offset = 0
            for token in MachineNoise.pattern[step] {
                switch token {
                case .e:
                    if message.count - offset < MachineNoise.dhLength { throw .badMessage }
                    let key = Array(message[offset..<(offset + MachineNoise.dhLength)])
                    re = key
                    offset += MachineNoise.dhLength
                    mixHash(key)
                case .s:
                    let length = MachineNoise.dhLength + (cipher.hasKey ? MachineNoise.tagLength : 0)
                    if message.count - offset < length { throw .badMessage }
                    rs = try decryptAndHash(Array(message[offset..<(offset + length)]))
                    offset += length
                default:
                    try mixDh(token)
                }
            }
            let payload = try decryptAndHash(Array(message[offset...]))
            step += 1
            return payload
        }
    }

    /// One side of an XX handshake. Every failure ends it: later calls fail with `wrongStep`.
    public final class Handshake: Sendable {
        private let state: Mutex<HandshakeState>

        init(initiator: Bool, prologue: [UInt8], s: KeyPair, e: KeyPair) {
            // Section 5.2 InitializeSymmetric: the name fits in HASHLEN, so h is the name padded with zeros, not its hash.
            var h = Array(MachineNoise.protocolName.utf8)
            h += [UInt8](repeating: 0, count: MachineNoise.hashLength - h.count)
            var initial = HandshakeState(initiator: initiator, s: s, e: e, h: h, ck: h)
            initial.mixHash(prologue)
            state = Mutex(initial)
        }

        /// Runs `body` on the state; a failure ends the handshake.
        private func guarded<A: Sendable>(_ body: (inout HandshakeState) throws(Failure) -> A) throws(Failure) -> A {
            let result: Result<A, Failure> = state.withLock { s in
                do throws(Failure) {
                    return .success(try body(&s))
                } catch {
                    s.failed = true
                    return .failure(error)
                }
            }
            return try result.get()
        }

        /// Section 5.3 WriteMessage: the next handshake message, carrying `payload`.
        public func write(_ payload: [UInt8]) throws(Failure) -> [UInt8] {
            try guarded { (s: inout HandshakeState) throws(Failure) in try s.write(payload) }
        }

        /// Section 5.3 ReadMessage: the payload inside the peer's next handshake message.
        public func read(_ message: [UInt8]) throws(Failure) -> [UInt8] {
            try guarded { (s: inout HandshakeState) throws(Failure) in try s.read(message) }
        }

        /// The peer's static public key, once the message carrying it has been read and authenticated.
        public var remoteStatic: [UInt8]? {
            state.withLock { s in s.failed ? nil : s.rs }
        }

        /// The handshake hash h so far: before message 1 it covers the protocol name and prologue, after each message
        /// every message up to it. Once the handshake is complete it is the channel binding of section 11.2.
        public var hash: [UInt8]? {
            state.withLock { s in s.failed ? nil : s.h }
        }

        /// Section 5.2 Split, once: a second pair of CipherStates with the same keys would reuse nonces.
        public func split() throws(Failure) -> Transport {
            try guarded { (s: inout HandshakeState) throws(Failure) -> Transport in
                if s.failed || s.taken || s.step < MachineNoise.pattern.count { throw .wrongStep }
                s.taken = true
                let (initiatorToResponder, responderToInitiator) = hkdf(s.ck, [])
                return Transport(
                    send: Sender(key: s.initiator ? initiatorToResponder : responderToInitiator),
                    receive: Receiver(key: s.initiator ? responderToInitiator : initiatorToResponder)
                )
            }
        }
    }

    /// The two ciphers `split` returns, one per direction.
    public struct Transport: Sendable {
        public let send: Sender
        /// Any message but the next one fails: transport messages arrive in order or not at all.
        public let receive: Receiver
    }

    public final class Sender: Sendable {
        private let cipher: Mutex<CipherState>
        init(key: [UInt8]) { cipher = Mutex(CipherState(key: key)) }

        public func encrypt(_ plaintext: [UInt8]) throws(Failure) -> [UInt8] {
            try cipher.withLock { (c: inout CipherState) throws(Failure) -> [UInt8] in try c.encrypt(ad: [], plaintext) }
        }
    }

    public final class Receiver: Sendable {
        private let cipher: Mutex<CipherState>
        init(key: [UInt8]) { cipher = Mutex(CipherState(key: key)) }

        public func decrypt(_ ciphertext: [UInt8]) throws(Failure) -> [UInt8] {
            try cipher.withLock { (c: inout CipherState) throws(Failure) -> [UInt8] in try c.decrypt(ad: [], ciphertext) }
        }
    }

    // MARK: - CipherState

    /// Section 5.1. Unlike the spec, which keeps n after a failed DECRYPT so a caller may skip the message, any failure
    /// ends the CipherState: on an ordered link a forged or lost message ends the link.
    struct CipherState: Sendable {
        let key: [UInt8]?
        var n: UInt64 = 0
        var failed = false

        init(key: [UInt8]?) { self.key = key }

        var hasKey: Bool { key != nil }
        private var usable: Bool { !failed && n < MachineNoise.maxNonce }

        private mutating func advance(_ result: Result<[UInt8], Failure>) throws(Failure) -> [UInt8] {
            if case .failure = result { failed = true } else { failed = false }
            n += 1
            return try result.get()
        }

        mutating func encrypt(ad: [UInt8], _ plaintext: [UInt8]) throws(Failure) -> [UInt8] {
            guard let key else { return plaintext }
            guard usable else { throw .wrongStep }
            if plaintext.count + MachineNoise.tagLength > MachineNoise.maxMessage { return try advance(.failure(.tooLong)) }
            return try advance(.success(MachineCrypto.aes256GCMSeal(key: key, nonce: nonce(n), aad: ad, plaintext: plaintext)))
        }

        mutating func decrypt(ad: [UInt8], _ ciphertext: [UInt8]) throws(Failure) -> [UInt8] {
            guard let key else { return ciphertext }
            guard usable else { throw .wrongStep }
            if ciphertext.count > MachineNoise.maxMessage { return try advance(.failure(.tooLong)) }
            // Section 12.3 DECRYPT. The tag check is the only comparison of secrets this module makes.
            guard ciphertext.count >= MachineNoise.tagLength,
                  let plaintext = MachineCrypto.aes256GCMOpen(key: key, nonce: nonce(n), aad: ad, sealed: ciphertext)
            else {
                return try advance(.failure(.badMessage))
            }
            return try advance(.success(plaintext))
        }
    }

    /// Section 12.3 AESGCM: 32 zero bits, then the counter as a 64-bit big-endian integer.
    static func nonce(_ n: UInt64) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 12)
        for i in 0..<8 {
            bytes[4 + i] = UInt8(truncatingIfNeeded: n >> UInt64(56 - 8 * i))
        }
        return bytes
    }

    /// Section 12.1 DH. An all-zero output, from a low-order public key, is refused as the spec allows.
    static func dh(_ keyPair: KeyPair, _ publicKey: [UInt8]) throws(Failure) -> [UInt8] {
        guard publicKey.count == dhLength else { throw .badMessage }
        let shared = MachineCrypto.x25519(scalar: keyPair.privateKey, point: publicKey)
        // OR every byte rather than stop at the first non-zero one, so the time taken says nothing about the secret.
        if shared.reduce(0, |) == 0 { throw .badMessage }
        return shared
    }

    /// Section 4.3 HKDF with two outputs, the only count XX uses; three outputs are for PSK modes.
    static func hkdf(_ chainingKey: [UInt8], _ inputKeyMaterial: [UInt8]) -> ([UInt8], [UInt8]) {
        let tempKey = MachineCrypto.hmacSHA256(key: chainingKey, data: inputKeyMaterial)
        let output1 = MachineCrypto.hmacSHA256(key: tempKey, data: [0x01])
        return (output1, MachineCrypto.hmacSHA256(key: tempKey, data: output1 + [0x02]))
    }
}

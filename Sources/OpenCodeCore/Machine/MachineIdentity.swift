#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeUtil

/// Port of `core/src/machine/identity.ts`: the home's long-term Ed25519 key, kept as a raw 32-byte seed in
/// `<state>/machine/home-key`.
public enum MachineIdentity {
    static let file = "machine/home-key"
    static let seedBytes = 32
    static let keyBytes = 32
    static let signatureBytes = 64

    // parity: core/src/machine/identity.ts#InvalidKey [status=implemented hash=337eedc39ee9]
    public struct InvalidKey: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Identity.InvalidKey"
        public let file: String
        public let reason: String

        public init(file: String, reason: String) {
            self.file = file
            self.reason = reason
        }

        // parity: core/src/machine/identity.ts#InvalidKey.message [status=implemented hash=7b91c09de52d]
        public var message: String {
            "Cannot use the home key at \(file): \(reason). Every paired machine trusts this key, so it is never replaced."
        }

        public var description: String { message }
    }

    // parity: core/src/machine/identity.ts#Interface [status=implemented hash=9378ee785765]
    public protocol Interface: Sendable {
        func publicKey() async throws(InvalidKey) -> [UInt8]
        func sign(_ bytes: [UInt8]) async throws(InvalidKey) -> [UInt8]
    }

    /// An Ed25519 key that can sign: the home's, or a worker's on its side of the link.
    // parity: core/src/machine/identity.ts#Key [status=implemented hash=e4bab38c0529]
    public struct Key: Sendable {
        public let publicKey: [UInt8]
        public let sign: @Sendable ([UInt8]) -> [UInt8]

        public init(publicKey: [UInt8], sign: @escaping @Sendable ([UInt8]) -> [UInt8]) {
            self.publicKey = publicKey
            self.sign = sign
        }
    }

    /// The key of a raw 32-byte Ed25519 seed. Any other length is a programmer error and traps: callers check it
    /// first, as the home key's loader does with its own message.
    // parity: core/src/machine/identity.ts#fromSeed [status=implemented hash=07b68e4dd606]
    public static func fromSeed(_ seed: [UInt8]) -> Key {
        precondition(seed.count == seedBytes, "An Ed25519 seed is \(seedBytes) bytes, not \(seed.count)")
        let copy = seed
        return Key(publicKey: MachineCrypto.ed25519PublicKey(seed: copy)) { bytes in
            MachineCrypto.ed25519Sign(seed: copy, message: bytes)
        }
    }

    /// Whether `signature` is `publicKey`'s Ed25519 signature of `bytes`: false, never a throw, for a malformed key or
    /// signature. Like upstream's runtime it accepts small-order public keys, which a strict verifier refuses: a
    /// worker's key is chosen by whoever holds its invitation, and choosing a key anyone can sign for is no more than
    /// publishing its own private key.
    // parity: core/src/machine/identity.ts#verify [status=implemented hash=d90a2ee86d4f]
    public static func verify(publicKey: [UInt8], bytes: [UInt8], signature: [UInt8]) -> Bool {
        guard publicKey.count == keyBytes, signature.count == signatureBytes else { return false }
        return MachineCrypto.ed25519Verify(publicKey: publicKey, message: bytes, signature: signature)
    }

    /// Reads a file's permission bits, or `nil` where the platform has none.
    public typealias ModeReader = @Sendable (String) throws -> UInt16?

    /// POSIX permission bits through Foundation's file attributes.
    public static let defaultModeReader: ModeReader = { path in
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        switch attributes[.posixPermissions] {
        case let mode as Int: return UInt16(truncatingIfNeeded: mode)
        case let mode as UInt16: return mode
        case let mode as UInt32: return UInt16(truncatingIfNeeded: mode)
        case let mode as Int16: return UInt16(truncatingIfNeeded: mode)
        default: return nil
        }
    }

    // parity: core/src/machine/identity.ts#Service [status=implemented hash=3c35ccfa6a57]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/Identity"

        public let file: String
        private let fileSystem: any OpenCodeFileSystem
        private let modeReader: ModeReader
        private let platform: PlatformOS
        // Success only: a failed load is tried again next call, so a fixed file works without a restart.
        private let loaded = Mutex<Key?>(nil)

        public init(
            state: String,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            modeReader: @escaping ModeReader = MachineIdentity.defaultModeReader,
            platform: PlatformOS = Platform.current
        ) {
            self.file = state.hasSuffix("/") ? state + MachineIdentity.file : state + "/" + MachineIdentity.file
            self.fileSystem = fileSystem
            self.modeReader = modeReader
            self.platform = platform
        }

        public func publicKey() async throws(InvalidKey) -> [UInt8] {
            try await identity().publicKey
        }

        public func sign(_ bytes: [UInt8]) async throws(InvalidKey) -> [UInt8] {
            try await identity().sign(bytes)
        }

        private func identity() async throws(InvalidKey) -> Key {
            if let key = loaded.withLock({ $0 }) { return key }
            let key = try await load()
            return loaded.withLock { current in
                if let current { return current }
                current = key
                return key
            }
        }

        private func invalid(_ reason: String) -> InvalidKey {
            InvalidKey(file: file, reason: reason)
        }

        private func create() async throws(InvalidKey) -> [UInt8] {
            let seed = MachineCrypto.randomBytes(MachineIdentity.seedBytes)
            let directory = String(file[..<(file.lastIndex(of: "/") ?? file.endIndex)])
            do {
                try await fileSystem.makeDirectory(at: directory, recursive: true)
                if platform != .windows { try? await fileSystem.chmod(at: directory, mode: 0o700) }
                // Exclusive: never replaces a key another process wrote first; this call fails and the next one reads it.
                try await fileSystem.writeFileExclusive(seed, to: file)
                if platform != .windows { try await fileSystem.chmod(at: file, mode: 0o600) }
            } catch {
                throw invalid("could not be created: \(error)")
            }
            return seed
        }

        private func load() async throws(InvalidKey) -> Key {
            let seed: [UInt8]
            do {
                seed = try await fileSystem.readFile(at: file)
            } catch PlatformError.notFound {
                seed = try await create()
            } catch {
                throw invalid("could not be read: \(error)")
            }
            if seed.count != MachineIdentity.seedBytes {
                throw invalid("expected a \(MachineIdentity.seedBytes)-byte key, found \(seed.count) bytes")
            }
            if platform != .windows {
                let mode: UInt16?
                do {
                    mode = try modeReader(file)
                } catch {
                    throw invalid("could not be read: \(error)")
                }
                // Like ssh: a key another user can read is no key at all.
                if let mode, mode & 0o077 != 0 {
                    throw invalid(
                        "its mode \(String(mode & 0o777, radix: 8)) lets other users read it; run \"chmod 600 \(file)\""
                    )
                }
            }
            return MachineIdentity.fromSeed(seed)
        }
    }

    // parity: core/src/machine/identity.ts#node [status=implemented hash=37dc448ff436]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            let state = deps.get(Global.Service.serviceKey, as: Global.Service.self)?.paths.state
                ?? Global.Path.state
            let fileSystem = deps.get(LayerNodePlatform.fileSystemKey, as: (any OpenCodeFileSystem).self)
                ?? LocalFileSystem.shared
            let service = Service(state: state, fileSystem: fileSystem)
            return LayerNode.Output([Service.serviceKey: service as any Interface])
        },
        [Global.node]
    )
}

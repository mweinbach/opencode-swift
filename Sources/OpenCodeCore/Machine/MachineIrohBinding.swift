// The optional Iroh native binding (`core/src/machine/iroh-binding.ts`).
//
// Upstream treats `@number0/iroh` (n0's Rust QUIC peer-to-peer library) as an optional platform binding with no build
// on some targets (e.g., Intel Macs, workerd), returning `undefined` when absent so machines fall back cleanly to the
// WebSocket carrier. In Swift we mirror that contract with an injectable protocol hierarchy whose default loader
// returns `nil` (unavailable), avoiding any Rust/C dependency while allowing custom/test bindings to be injected.

/// Port of `core/src/machine/iroh-binding.ts`.
public enum MachineIrohBinding {
    /// Selected path metrics reported by an active Iroh QUIC connection (`connection.paths()`).
    public struct PathInfo: Equatable, Hashable, Sendable {
        public let isSelected: Bool
        public let isRelay: Bool
        public let rttMs: Double

        public init(isSelected: Bool, isRelay: Bool, rttMs: Double) {
            self.isSelected = isSelected
            self.isRelay = isRelay
            self.rttMs = rttMs
        }
    }

    /// Receive half of an Iroh bidirectional QUIC stream.
    public protocol RecvStream: Sendable {
        /// Reads up to `maxBytes` from the stream. Returns empty bytes on clean EOF.
        func read(_ maxBytes: Int) async throws -> [UInt8]
    }

    /// Send half of an Iroh bidirectional QUIC stream.
    public protocol SendStream: Sendable {
        /// Writes all bytes to the stream.
        func writeAll(_ bytes: [UInt8]) async throws
    }

    /// Bidirectional QUIC stream (`@number0/iroh` `BiStream`).
    public protocol BiStream: Sendable {
        var recv: any RecvStream { get }
        var send: any SendStream { get }
    }

    /// An established Iroh QUIC connection (`@number0/iroh` `Connection`).
    public protocol Connection: Sendable {
        func acceptBi() async throws -> any BiStream
        func paths() -> [PathInfo]
        func close(code: UInt64, reason: [UInt8])
    }

    /// An accepted incoming connection awaiting QUIC handshake completion (`incoming.accept()`).
    public protocol Accepting: Sendable {
        func connect() async throws -> any Connection
    }

    /// A pending incoming Iroh connection (`endpoint.acceptNext()`).
    public protocol Incoming: Sendable {
        func accept() async throws -> any Accepting
        func refuse() async
    }

    /// A bound Iroh QUIC endpoint (`@number0/iroh` `Endpoint`).
    public protocol Endpoint: Sendable {
        func acceptNext() async throws -> (any Incoming)?
        func boundSockets() -> [String]
        func close() async
    }

    /// Builder configuring and binding an Iroh endpoint (`Endpoint.builder()`).
    public protocol EndpointBuilder: Sendable {
        func applyMinimal()
        func applyN0()
        func bindAddr(_ address: String)
        func secretKey(_ key: [UInt8])
        func alpns(_ alpns: [[UInt8]])
        func bind() async throws -> any Endpoint
    }

    /// Injectable Swift protocol mirroring `@number0/iroh`'s native `Binding` surface.
    // parity: core/src/machine/iroh-binding.ts#Binding [status=adapted hash=af5c889e7423 reason=injectable-protocol-for-optional-native-iroh-binding]
    public protocol Binding: Sendable {
        func makeEndpointBuilder() -> any EndpointBuilder
    }

    /// Default lazy loader for the optional native Iroh binding.
    ///
    /// Returns `nil` because `swift-opencode` does not ship a Rust/C `@number0/iroh` native binding; callers fall back
    /// to WebSockets only, matching upstream's behavior on platforms with no native Iroh build.
    // parity: core/src/machine/iroh-binding.ts#default [status=adapted hash=eeb595a56e53 reason=optional-native-rust-iroh-binding-unavailable-by-default]
    public static func load() async throws -> (any Binding)? {
        nil
    }
}

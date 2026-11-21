import Synchronization

// What the link carries once its handshake is done (`core/src/machine/frames.ts`). Each carrier message is one Noise
// transport message, and its plaintext is one frame: a tag byte, then a piece of an application message, one wire.ts
// message as UTF-8 JSON.
//
//   0x00  final   the last or only piece of a message, of any length, empty included
//   0x01  more    a piece the next frame continues, always exactly PIECE (65,518) bytes
//
// A message too long for one frame is split across frames in order, and pieces of two messages never interleave in one
// direction. Every failure to decrypt, reassemble, decode or validate ends the link: nothing is skipped and nothing is
// answered.

/// Port of `core/src/machine/frames.ts`.
public enum MachineFrames {
    static let finalTag: UInt8 = 0
    static let moreTag: UInt8 = 1
    /// Noise's largest message, 65,535 bytes, less its 16-byte tag and the frame's tag byte.
    public static let piece = 65_535 - 16 - 1

    /// The largest message either side sends or accepts, in bytes of JSON. The largest file the home reads whole is
    /// video-generate's 100 MiB input (`MAX_INPUT_BYTES`), which base64 turns into about 133.4 MiB; the rest is headroom
    /// for the JSON around it. A worker refuses a larger read with an `fs` error instead of sending it.
    // parity: core/src/machine/frames.ts#MAX_MESSAGE [status=implemented hash=49b21632fd4b]
    public static let maxMessage = 160 * 1024 * 1024

    public enum Failure: String, Error, Equatable, Hashable, Sendable {
        case badFrame = "BadFrame"
        case tooLong = "TooLong"
        case ended = "Ended"
    }

    /// One cipher per direction, each rekeying itself: see `rekeying`.
    // parity: core/src/machine/frames.ts#Ciphers [status=implemented hash=d6d4a686e09d]
    public struct Ciphers: Sendable {
        public struct Sender: Sendable {
            private let body: @Sendable ([UInt8]) throws(MachineNoise.Failure) -> [UInt8]

            public init(encrypt: @escaping @Sendable ([UInt8]) throws(MachineNoise.Failure) -> [UInt8]) {
                self.body = encrypt
            }

            public func encrypt(_ plaintext: [UInt8]) throws(MachineNoise.Failure) -> [UInt8] {
                try body(plaintext)
            }
        }

        public struct Receiver: Sendable {
            private let body: @Sendable ([UInt8]) throws(MachineNoise.Failure) -> [UInt8]

            public init(decrypt: @escaping @Sendable ([UInt8]) throws(MachineNoise.Failure) -> [UInt8]) {
                self.body = decrypt
            }

            public func decrypt(_ ciphertext: [UInt8]) throws(MachineNoise.Failure) -> [UInt8] {
                try body(ciphertext)
            }
        }

        public let send: Sender
        public let receive: Receiver

        public init(send: Sender, receive: Receiver) {
            self.send = send
            self.receive = receive
        }
    }

    // parity: core/src/machine/frames.ts#Codec [status=implemented hash=e996c878ba84]
    public struct Codec<In: Sendable, Out: Sendable>: Sendable {
        public let decode: @Sendable ([UInt8]) throws -> In
        public let encode: @Sendable (Out) throws -> [UInt8]

        public init(
            decode: @escaping @Sendable ([UInt8]) throws -> In,
            encode: @escaping @Sendable (Out) throws -> [UInt8]
        ) {
            self.decode = decode
            self.encode = encode
        }
    }

    /// A framed channel returned by `open`: call `close()` when the enclosing scope ends.
    public struct Channel<In: Sendable, Out: Sendable>: Sendable {
        public let send: @Sendable (Out) -> Void
        public let messages: AsyncStream<In>
        public let close: @Sendable () -> Void

        public init(
            send: @escaping @Sendable (Out) -> Void,
            messages: AsyncStream<In>,
            close: @escaping @Sendable () -> Void
        ) {
            self.send = send
            self.messages = messages
            self.close = close
        }
    }

    /// The next message's bytes, reassembled from its frames, failing on a bad frame or a message over `maxMessage`.
    // parity: core/src/machine/frames.ts#read [status=implemented hash=71f077464449]
    public static func read(
        _ carrier: any MachineLink.Carrier,
        cipher: Ciphers.Receiver
    ) async throws -> [UInt8] {
        var pieces: [[UInt8]] = []
        var size = 0
        while true {
            let raw = try await carrier.receive()
            let frame = try cipher.decrypt(raw)
            guard let tag = frame.first else { throw Failure.badFrame }
            // A full `more` bounds the pieces held for one message by MAX_MESSAGE / PIECE, whatever the peer sends.
            if tag != finalTag && (tag != moreTag || frame.count != piece + 1) {
                throw Failure.badFrame
            }
            size += frame.count - 1
            if size > maxMessage { throw Failure.tooLong }
            pieces.append(Array(frame.dropFirst()))
            if tag == finalTag {
                if pieces.count == 1 { return pieces[0] }
                var result: [UInt8] = []
                result.reserveCapacity(size)
                for chunk in pieces {
                    result.append(contentsOf: chunk)
                }
                return result
            }
        }
    }

    /// Sends one message as frames, in order, refusing one over `maxMessage` before anything is sent.
    // parity: core/src/machine/frames.ts#write [status=implemented hash=e83f99b0f18a]
    public static func write(
        _ carrier: any MachineLink.Carrier,
        cipher: Ciphers.Sender,
        message: [UInt8]
    ) async throws {
        if message.count > maxMessage { throw Failure.tooLong }
        let frameCount = max(1, (message.count + piece - 1) / piece)
        for index in 0..<frameCount {
            let offset = index * piece
            let end = min(offset + piece, message.count)
            let isLast = offset + piece >= message.count
            var frame: [UInt8] = []
            frame.reserveCapacity(1 + (end - offset))
            frame.append(isLast ? finalTag : moreTag)
            frame.append(contentsOf: message[offset..<end])
            let encrypted = try cipher.encrypt(frame)
            await carrier.send(encrypted)
        }
    }

    private final class OpenState<Out: Sendable>: Sendable {
        private struct Inner {
            var ended = false
            var writer: Task<Void, Never>?
        }

        private let lock = Mutex(Inner())
        private let endedDeferred = MachineDeferred<Void>()
        private let outboxContinuation: AsyncStream<Out>.Continuation

        init(outboxContinuation: AsyncStream<Out>.Continuation) {
            self.outboxContinuation = outboxContinuation
        }

        var isEnded: Bool {
            lock.withLock { $0.ended }
        }

        func setWriter(_ task: Task<Void, Never>) {
            let alreadyEnded = lock.withLock { s -> Bool in
                if s.ended { return true }
                s.writer = task
                return false
            }
            if alreadyEnded {
                task.cancel()
            }
        }

        func offer(_ message: Out) {
            let active = lock.withLock { !$0.ended }
            guard active else { return }
            outboxContinuation.yield(message)
        }

        func end() {
            let writer = lock.withLock { s -> Task<Void, Never>? in
                if s.ended { return nil }
                s.ended = true
                let task = s.writer
                s.writer = nil
                return task
            }
            outboxContinuation.finish()
            endedDeferred.succeed(())
            writer?.cancel()
        }

        func waitForEnd() async {
            _ = try? await endedDeferred.wait()
        }
    }

    /// Carries messages over a link whose handshake is done, until it ends.
    ///
    /// `send` queues a message for one task that alone encrypts and writes; the queue holds messages until that task
    /// takes them, so a slow carrier holds back only what was already sent. `messages` reads as it is pulled, so a
    /// peer cannot get further ahead than the carrier buffers, and only pulling notices a carrier that ended or a bad
    /// frame. The link ends then, on a message to send over `maxMessage`, or when `close()` is called: `messages` ends
    /// and every later `send` is dropped. The caller then closes the carrier.
    ///
    /// `messages` has one reader: two would split a message's pieces between them.
    // parity: core/src/machine/frames.ts#open [status=implemented hash=d685cb57e385]
    public static func open<In: Sendable, Out: Sendable>(
        _ carrier: any MachineLink.Carrier,
        ciphers: Ciphers,
        codec: Codec<In, Out>
    ) -> Channel<In, Out> {
        let (outbox, outboxContinuation) = AsyncStream<Out>.makeStream()
        let state = OpenState<Out>(outboxContinuation: outboxContinuation)

        let writer = Task {
            defer { state.end() }
            for await message in outbox {
                if Task.isCancelled || state.isEnded { break }
                do {
                    let bytes = try codec.encode(message)
                    if Task.isCancelled || state.isEnded { break }
                    try await write(carrier, cipher: ciphers.send, message: bytes)
                } catch {
                    break
                }
            }
        }
        state.setWriter(writer)

        // Checked before each read, since racing alone could start the read first and deliver a frame already waiting.
        let messages = AsyncStream<In> {
            if state.isEnded { return nil }
            let outcome: Result<In, any Error>? = await withTaskGroup(of: Result<In, any Error>?.self) { group in
                group.addTask {
                    do {
                        let bytes = try await read(carrier, cipher: ciphers.receive)
                        return .success(try codec.decode(bytes))
                    } catch {
                        return .failure(error)
                    }
                }
                group.addTask {
                    await state.waitForEnd()
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let outcome else { return nil }
            switch outcome {
            case .success(let message):
                if state.isEnded { return nil }
                return message
            case .failure:
                state.end()
                return nil
            }
        }

        return Channel(
            send: { message in state.offer(message) },
            messages: messages,
            close: { state.end() }
        )
    }

    /// Each direction rekeys itself after every `interval`th transport message it carries, the welcome included: the
    /// sender once it has encrypted that message and the receiver once it has decrypted it. Both sides count the same
    /// messages, so nothing on the wire says when.
    // parity: core/src/machine/frames.ts#rekeying [status=implemented hash=1c528fcb4b2f]
    public static func rekeying(_ transport: MachineNoise.Transport, interval: Int) -> Ciphers {
        precondition(interval > 0, "Rekey interval must be positive")
        let sentCount = Mutex(0)
        let receivedCount = Mutex(0)
        return Ciphers(
            send: Ciphers.Sender { plaintext throws(MachineNoise.Failure) in
                try sentCount.withLock { (sent: inout Int) throws(MachineNoise.Failure) -> [UInt8] in
                    let ciphertext = try transport.send.encrypt(plaintext)
                    sent += 1
                    if sent % interval == 0 {
                        transport.send.rekey()
                    }
                    return ciphertext
                }
            },
            receive: Ciphers.Receiver { ciphertext throws(MachineNoise.Failure) in
                try receivedCount.withLock { (received: inout Int) throws(MachineNoise.Failure) -> [UInt8] in
                    let plaintext = try transport.receive.decrypt(ciphertext)
                    received += 1
                    if received % interval == 0 {
                        transport.receive.rekey()
                    }
                    return plaintext
                }
            }
        )
    }
}

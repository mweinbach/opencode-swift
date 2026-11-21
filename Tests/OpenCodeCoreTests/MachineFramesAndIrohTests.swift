import Testing
import OpenCodeCore
import OpenCodePlatform

private typealias Helper = MachineTestHelper

private let plainCiphers = MachineFrames.Ciphers(
    send: .init { $0 },
    receive: .init { $0 }
)

private let stringCodec = MachineFrames.Codec<String, String>(
    decode: { Helper.utf8($0) },
    encode: { Helper.bytes($0) }
)

private let sampleHello = MachineWire.Hello(
    os: "linux",
    arch: "x64",
    home: "/home/worker",
    instance: MachineWire.Instance("instance"),
    processes: []
)

private func startedMsg(_ id: String) -> MachineWire.FromWorker {
    .started(id: MachineWire.ProcessID(id), pid: 1)
}

private func releaseMsg(_ id: String) -> MachineWire.ToWorker {
    .release(id: MachineWire.ProcessID(id))
}

private func flipBit(_ bytes: [UInt8], bit: Int) -> [UInt8] {
    var copy = bytes
    copy[bit >> 3] ^= UInt8(1 << (bit & 7))
    return copy
}

private func enrol(
    _ name: String,
    machines: Machines.Service,
    identity: Helper.FixedIdentity
) async throws -> (id: String, home: [UInt8], worker: MachineIdentity.Key) {
    let id = try await machines.add(name)
    let join = try #require(MachineJoin.decode(try await machines.invite(id, options: .init(reach: []))))
    let worker = MachineIdentity.fromSeed(MachineCrypto.randomBytes(32))
    let (homePipe, workerPipe) = Helper.Pipe.pair()
    let serving = Task { try await MachineLink.serve(homePipe, identity: identity, machines: machines) }
    let dialed = try await MachineLink.connect(workerPipe, options: .init(home: join.home, identity: worker, secret: join.secret))
    dialed.send(.hello(sampleHello))
    let served = try await serving.value
    dialed.close()
    served.close()
    homePipe.close()
    return (id, join.home, worker)
}

private func takeCount<T: Sendable>(_ stream: AsyncStream<T>, count: Int) async -> [T] {
    var result: [T] = []
    var iterator = stream.makeAsyncIterator()
    while result.count < count, let item = await iterator.next() {
        result.append(item)
    }
    return result
}

private func collectAll<T: Sendable>(_ stream: AsyncStream<T>) async -> [T] {
    var result: [T] = []
    for await item in stream {
        result.append(item)
    }
    return result
}

@Suite("Machine frames, framed links and Iroh transport")
struct MachineFramesAndIrohTests {
    // MARK: - Frames encode/decode

    @Test("sends a message as full more pieces and one final piece of any length, and refuses a short more")
    func frameSplittingAndShortMore() async throws {
        let piece = MachineFrames.piece
        let cases: [(Int, [UInt8])] = [
            (0, [0]),
            (piece - 1, [0]),
            (piece, [0]),
            (piece + 1, [1, 0]),
            (2 * piece, [1, 0]),
        ]
        for (length, expectedTags) in cases {
            let (homePipe, workerPipe) = Helper.Pipe.pair()
            let message = MachineCrypto.randomBytes(length)
            try await MachineFrames.write(homePipe, cipher: plainCiphers.send, message: message)
            #expect(homePipe.sent.map { $0[0] } == expectedTags)
            #expect(try await MachineFrames.read(workerPipe, cipher: plainCiphers.receive) == message)
        }

        // Short `more` frame is refused with BadFrame.
        let (homePipe, workerPipe) = Helper.Pipe.pair()
        await homePipe.send([1] + [UInt8](repeating: 0, count: piece - 1))
        await homePipe.send([0] + Helper.bytes("rest"))
        await #expect(throws: MachineFrames.Failure.badFrame) {
            _ = try await MachineFrames.read(workerPipe, cipher: plainCiphers.receive)
        }

        // Empty frame and unknown tag byte are refused with BadFrame.
        let (h2, w2) = Helper.Pipe.pair()
        await h2.send([])
        await #expect(throws: MachineFrames.Failure.badFrame) {
            _ = try await MachineFrames.read(w2, cipher: plainCiphers.receive)
        }
        let (h3, w3) = Helper.Pipe.pair()
        await h3.send([2, 0x7b, 0x7d])
        await #expect(throws: MachineFrames.Failure.badFrame) {
            _ = try await MachineFrames.read(w3, cipher: plainCiphers.receive)
        }
    }

    @Test("write refuses a message over MAX_MESSAGE before sending any frame")
    func writeOverMaxMessage() async throws {
        let (homePipe, _) = Helper.Pipe.pair()
        // Use a single allocation of MAX_MESSAGE + 1 bytes to verify the exact boundary check.
        let oversized = [UInt8](repeating: 0x20, count: MachineFrames.maxMessage + 1)
        await #expect(throws: MachineFrames.Failure.tooLong) {
            try await MachineFrames.write(homePipe, cipher: plainCiphers.send, message: oversized)
        }
        #expect(homePipe.sent.isEmpty)
    }

    @Test("Frames.open closes cleanly before reads and delivers nothing after end even when a frame is waiting")
    func framesOpenLifecycle() async throws {
        // Close immediately before reading.
        let (h1, _) = Helper.Pipe.pair()
        let link1 = MachineFrames.open(h1, ciphers: plainCiphers, codec: stringCodec)
        link1.close()
        #expect(await collectAll(link1.messages).isEmpty)
        #expect(h1.readsWaiting == 0)

        // Writer fails to encode before anything is read -> ends link so a waiting frame is not delivered.
        struct EncodeError: Error {}
        let (h2, w2) = Helper.Pipe.pair()
        let failing = MachineFrames.open(
            h2,
            ciphers: plainCiphers,
            codec: MachineFrames.Codec<String, String>(
                decode: stringCodec.decode,
                encode: { _ in throw EncodeError() }
            )
        )
        failing.send("anything")
        #expect(await Helper.eventually { h2.readsWaiting == 0 })
        // Wait briefly for the writer task to fail and end the channel.
        try? await Task.sleep(for: .milliseconds(20))
        await w2.send([0] + Helper.bytes("waiting"))
        #expect(await collectAll(failing.messages).isEmpty)
    }

    // MARK: - Link.serve & Link.connect

    @Test("carries multi-frame messages intact both ways and rekeys across frame boundaries")
    func multiFrameAndRekeying() async throws {
        let (machines, identity, _) = try Helper.machines()
        let paired = try await enrol("gpu", machines: machines, identity: identity)
        let (homePipe, workerPipe) = Helper.Pipe.pair()

        // Short rekey interval of 3 so a 150 KB message (4 frames) crosses a rekey mid-message.
        let serving = Task {
            try await MachineLink.serve(homePipe, identity: identity, machines: machines, fixed: .init(rekeyInterval: 3))
        }
        let worker = try await MachineLink.connect(
            workerPipe,
            options: .init(home: paired.home, identity: paired.worker, fixed: .init(rekeyInterval: 3))
        )
        defer { worker.close() }
        worker.send(.hello(sampleHello))
        let served = try await serving.value
        defer { served.close() }

        let downBig = MachineWire.ToWorker.fs(.init(req: 1, call: .write(path: "/big", bytes: MachineCrypto.randomBytes(150_000))))
        let upBig = MachineWire.FromWorker.output(id: .init("p"), offset: 0, stream: .stdout, data: MachineCrypto.randomBytes(150_000))
        served.connection.send(downBig)
        served.connection.send(releaseMsg("next"))
        worker.send(upBig)
        worker.send(startedMsg("next"))

        #expect(await takeCount(worker.messages, count: 2) == [downBig, releaseMsg("next")])
        #expect(await takeCount(served.connection.messages, count: 2) == [upBig, startedMsg("next")])
        // Past handshake (msg2) and welcome: 4 frames for downBig (3 full 65535 + 1 final) then 1 for release.
        #expect(homePipe.sent.dropFirst(2).map { $0.count == 65_535 } == [true, true, true, false, false])
        // Past handshake (msg1, msg3) and hello: 4 frames for upBig + 1 for started.
        #expect(workerPipe.sent.dropFirst(3).map { $0.count == 65_535 } == [true, true, true, false, false])
    }

    @Test("skewed rekey intervals end the link at the first mismatched frame")
    func skewedRekeyFails() async throws {
        let (machines, identity, _) = try Helper.machines()
        let paired = try await enrol("gpu", machines: machines, identity: identity)
        let (homePipe, workerPipe) = Helper.Pipe.pair()
        let serving = Task {
            try await MachineLink.serve(homePipe, identity: identity, machines: machines, fixed: .init(rekeyInterval: 3))
        }
        let worker = try await MachineLink.connect(
            workerPipe,
            options: .init(home: paired.home, identity: paired.worker, fixed: .init(rekeyInterval: 4))
        )
        defer { worker.close() }
        worker.send(.hello(sampleHello))
        let served = try await serving.value
        defer { served.close() }

        let down = (0..<6).map { releaseMsg("\($0)") }
        for msg in down { served.connection.send(msg) }
        // Welcome is message #1; down[0] is #2, down[1] is #3 (home rekeys here, worker does not) -> down[2] fails.
        #expect(await collectAll(worker.messages) == Array(down.prefix(2)))
    }

    @Test("serves a worker as the paired machine regardless of extra name field in hello, and rejects bad hellos")
    func helloValidationAndProtocolMismatch() async throws {
        let (machines, identity, _) = try Helper.machines()
        let gpu = try await enrol("gpu", machines: machines, identity: identity)
        let box = try await enrol("box", machines: machines, identity: identity)

        // 1) Extra `name: "gpu"` in hello JSON is ignored; machine stays `box`.
        let (h1, w1) = Helper.Pipe.pair()
        let serving1 = Task { try await MachineLink.serve(h1, identity: identity, machines: machines) }
        let raw1 = try await MachineLink.dial(w1, options: .init(home: box.home, identity: box.worker))
        let claimedJSON = #"{"type":"hello","protocol":2,"name":"gpu","machine":"gpu","os":"linux","arch":"x64","home":"/home/worker","instance":"instance","processes":[]}"#
        await w1.send(try raw1.send.encrypt([0] + Helper.bytes(claimedJSON)))
        let served1 = try await serving1.value
        #expect(served1.machine == box.id)
        #expect(served1.connection.hello == sampleHello)
        #expect(gpu.id == "gpu")

        // A second hello on the established link ends it.
        await w1.send(try raw1.send.encrypt([0] + MachineWire.encodeJSON(.started(id: .init("a"), pid: 1))))
        await w1.send(try raw1.send.encrypt([0] + MachineWire.encodeJSON(.hello(sampleHello))))
        await w1.send(try raw1.send.encrypt([0] + MachineWire.encodeJSON(.started(id: .init("c"), pid: 2))))
        #expect(await collectAll(served1.connection.messages) == [startedMsg("a")])
        served1.close()

        // 2) First message not a hello -> Refused.
        let (h2, w2) = Helper.Pipe.pair()
        let serving2 = Task { try await MachineLink.serve(h2, identity: identity, machines: machines) }
        let raw2 = try await MachineLink.dial(w2, options: .init(home: box.home, identity: box.worker))
        await w2.send(try raw2.send.encrypt([0] + MachineWire.encodeJSON(startedMsg("a"))))
        await #expect(throws: MachineLink.Refused.self) { _ = try await serving2.value }

        // 3) Wrong protocol versions (1 and 3) -> Refused + exact update warning text.
        for badVersion in [1, 3] {
            let (h3, w3) = Helper.Pipe.pair()
            let warnings = MachineMutexBox<[String]>([])
            let serving3 = Task {
                try await MachineLink.serve(
                    h3,
                    identity: identity,
                    machines: machines,
                    onWarning: { msg in warnings.mutate { $0.append(msg) } }
                )
            }
            let raw3 = try await MachineLink.dial(w3, options: .init(home: box.home, identity: box.worker))
            let badHello = #"{"type":"hello","protocol":\#(badVersion),"os":"linux","arch":"x64","home":"/home/worker","instance":"i","processes":[]}"#
            await w3.send(try raw3.send.encrypt([0] + Helper.bytes(badHello)))
            await #expect(throws: MachineLink.Refused.self) { _ = try await serving3.value }
            #expect(warnings.get() == [
                "Machine box uses protocol \(badVersion); this home requires protocol 2. The worker and the home must be the same version.",
            ])
        }

        // 4) Flipped bit on a transport frame ends the link and delivers nothing after.
        let (h4, w4) = Helper.Pipe.pair(toHome: { msg, index in
            // 0=msg1, 1=msg3, 2=hello, 3=started("a"), 4=started("b")
            index == 4 ? flipBit(msg, bit: 160) : msg
        })
        let serving4 = Task { try await MachineLink.serve(h4, identity: identity, machines: machines) }
        let worker4 = try await MachineLink.connect(w4, options: .init(home: box.home, identity: box.worker))
        defer { worker4.close() }
        worker4.send(.hello(sampleHello))
        let served4 = try await serving4.value
        defer { served4.close() }
        worker4.send(startedMsg("a"))
        worker4.send(startedMsg("b"))
        worker4.send(startedMsg("c"))
        #expect(await collectAll(served4.connection.messages) == [startedMsg("a")])

        // 5) Missing hello past deadline -> Refused.
        let (h5, w5) = Helper.Pipe.pair()
        let serving5 = Task {
            defer { h5.close() }
            return try await MachineLink.serve(h5, identity: identity, machines: machines, deadline: .seconds(2))
        }
        _ = try? await MachineLink.dial(w5, options: .init(home: box.home, identity: box.worker))
        await #expect(throws: MachineLink.Refused.self) { _ = try await serving5.value }
    }

    // MARK: - Iroh carrier, unavailable fallback, and injectable binding

    @Test("default Iroh binding is unavailable and MachineIroh.listen fails with upstream's fallback message")
    func irohUnavailableFallback() async throws {
        let (machines, identity, _) = try Helper.machines()
        let loaded = try await MachineIrohBinding.load()
        #expect(loaded == nil)

        let err = await #expect(throws: MachineIroh.Unavailable.self) {
            _ = try await MachineIroh.listen(admit: { true }, identity: identity, machines: machines)
        }
        #expect(err?.message == "no Iroh build for this platform")

        // Fallback path: when Iroh is unavailable, a machine invite carries only WebSocket URL reach entries.
        let id = try await machines.add("gpu")
        let fallbackReach: [MachineJoin.Reach] = [.url("wss://home.example/api/machine/link")]
        let irohAvailable = (try? await MachineIroh.listen(admit: { true }, identity: identity, machines: machines)) != nil
        #expect(!irohAvailable)
        let effectiveReach = irohAvailable ? fallbackReach + [.iroh] : fallbackReach
        let joinString = try await machines.invite(id, options: .init(reach: effectiveReach))
        let decoded = try #require(MachineJoin.decode(joinString))
        #expect(decoded.reach == fallbackReach)
    }

    @Test("Iroh.carrier reads 900 messages intact from one chunk and reassembles split messages")
    func irohCarrierFraming() async throws {
        // 1) 900 messages of 70 bytes packed into one read chunk (mirrors upstream `machine-iroh.test.ts`).
        var messages: [[UInt8]] = []
        var packed: [UInt8] = []
        for index in 0..<900 {
            var msg = [UInt8](repeating: UInt8(index % 256), count: 70)
            msg[0] = UInt8((index >> 8) & 0xff)
            msg[1] = UInt8(index & 0xff)
            messages.append(msg)
            packed.append(0)
            packed.append(UInt8(msg.count))
            packed.append(contentsOf: msg)
        }
        let send1 = Helper.RecordingSendStream()
        let carrier1 = MachineIroh.carrier(
            Helper.StaticBiStream(recv: Helper.ChunkedRecvStream([packed]), send: send1),
            drop: {}
        )
        var received: [[UInt8]] = []
        for _ in 0..<messages.count {
            received.append(try await carrier1.receive())
        }
        #expect(received == messages)
        // Value isolation: mutating one received message does not affect another.
        received[0][0] ^= 1
        #expect(received[1] == messages[1])
        await #expect(throws: MachineLink.Closed.self) {
            _ = try await carrier1.receive()
        }

        // 2) Message split across two reads after an earlier message.
        let carrier2 = MachineIroh.carrier(
            Helper.StaticBiStream(
                recv: Helper.ChunkedRecvStream([
                    [0, 3, 1, 2, 3, 0, 4, 4],
                    [5, 6, 7],
                ]),
                send: Helper.RecordingSendStream()
            ),
            drop: {}
        )
        let first = try await carrier2.receive()
        let second = try await carrier2.receive()
        #expect(first == [1, 2, 3])
        #expect(second == [4, 5, 6, 7])
        await #expect(throws: MachineLink.Closed.self) {
            _ = try await carrier2.receive()
        }

        // 3) Outbound send frames with 2-byte big-endian length; write failure or stall triggers `drop`.
        let okSend = Helper.RecordingSendStream()
        let carrier3 = MachineIroh.carrier(
            Helper.StaticBiStream(recv: Helper.ChunkedRecvStream([]), send: okSend),
            drop: {}
        )
        await carrier3.send([0xaa, 0xbb, 0xcc])
        #expect(okSend.written == [[0x00, 0x03, 0xaa, 0xbb, 0xcc]])

        let droppedOnFail = MachineMutexBox(false)
        let carrierFail = MachineIroh.carrier(
            Helper.StaticBiStream(recv: Helper.ChunkedRecvStream([]), send: Helper.RecordingSendStream(fail: true)),
            drop: { droppedOnFail.set(true) }
        )
        await carrierFail.send([1, 2])
        #expect(droppedOnFail.get() == true)

        let droppedOnStall = MachineMutexBox(false)
        let carrierStall = MachineIroh.carrier(
            Helper.StaticBiStream(recv: Helper.ChunkedRecvStream([]), send: Helper.RecordingSendStream(delay: .seconds(5))),
            drop: { droppedOnStall.set(true) },
            stall: .milliseconds(30)
        )
        await carrierStall.send([1, 2])
        #expect(droppedOnStall.get() == true)
    }

    @Test("Iroh.listen pairs and serves a worker over an injected binding, reports path/rtt, refuses when disabled or bad secret")
    func irohListenWithInjectedBinding() async throws {
        let (machines, identity, _) = try Helper.machines()
        let id = try await machines.add("gpu")
        let joinString = try await machines.invite(id, options: .init(reach: [.iroh]))
        let join = try #require(MachineJoin.decode(joinString))
        #expect(join.reach == [.iroh])

        let mockBinding = Helper.MockIrohBinding()
        let watched = MachineMutexBox<Bool>(false)
        let admitFlag = MachineMutexBox(true)
        let listener = try await MachineIroh.listen(
            admit: { admitFlag.get() },
            identity: identity,
            machines: machines,
            testing: MachineIroh.Testing(
                offline: true,
                load: { mockBinding },
                watch: { _ in watched.set(true) }
            )
        )

        // Verify builder configuration for offline mode, secretKey == identity.seed(), and ALPN.
        let builder = try #require(mockBinding.latestBuilder)
        #expect(builder.recorded.usedMinimal == true)
        #expect(builder.recorded.usedN0 == false)
        #expect(builder.recorded.bindAddress == "127.0.0.1:0")
        #expect(builder.recorded.secretKey == (try await identity.seed()))
        #expect(builder.recorded.alpns == [MachineIroh.alpn])
        #expect(watched.get() == true)

        let endpoint = try #require(mockBinding.latestEndpoint)

        // 1) Refuses incoming connection when `admit` is false.
        admitFlag.set(false)
        let denied = Helper.MockIrohIncoming(paths: [])
        endpoint.enqueue(denied)
        #expect(await Helper.eventually { denied.refused })
        admitFlag.set(true)

        // 2) Stranger with wrong secret is refused and closed with code 1008.
        let strangerIncoming = Helper.MockIrohIncoming(paths: [
            .init(isSelected: true, isRelay: false, rttMs: 4.0),
        ])
        endpoint.enqueue(strangerIncoming)
        let strangerCarrier = MachineIroh.carrier(strangerIncoming.connection.clientStream, drop: {})
        await #expect(throws: MachineLink.Refused.self) {
            _ = try await MachineLink.connect(
                strangerCarrier,
                options: .init(
                    home: join.home,
                    identity: MachineIdentity.fromSeed(MachineCrypto.randomBytes(32)),
                    secret: MachineCrypto.randomBytes(32)
                )
            )
        }
        #expect(await Helper.eventually { strangerIncoming.connection.closedCode == MachineIroh.closeCode })

        // 3) Honest worker pairs over the injected Iroh stream and appears online with Iroh path & RTT.
        let honestIncoming = Helper.MockIrohIncoming(paths: [
            .init(isSelected: false, isRelay: true, rttMs: 80.0),
            .init(isSelected: true, isRelay: false, rttMs: 3.5),
        ])
        endpoint.enqueue(honestIncoming)
        let workerIdentity = MachineIdentity.fromSeed(MachineCrypto.randomBytes(32))
        let clientCarrier = MachineIroh.carrier(honestIncoming.connection.clientStream, drop: {})
        let connected = try await MachineLink.connect(
            clientCarrier,
            options: .init(home: join.home, identity: workerIdentity, secret: join.secret)
        )
        #expect(connected.machine == "gpu")
        connected.send(.hello(sampleHello))

        #expect(await Helper.eventuallyAsync { await machines.list().first?.online == true })
        let listedDirect = await machines.list()
        #expect(listedDirect == [
            Machines.Info(
                id: "gpu",
                online: true,
                paired: true,
                os: "linux",
                arch: "x64",
                connection: MachineDriver.ConnectionInfo(kind: .iroh, path: .direct, rtt: 3.5)
            ),
        ])

        // Dynamic path change is reflected on the next `machines.list()` call.
        honestIncoming.connection.setPaths([.init(isSelected: true, isRelay: true, rttMs: 42.0)])
        let listedRelayed = await machines.list()
        #expect(listedRelayed.first?.connection == MachineDriver.ConnectionInfo(kind: .iroh, path: .relayed, rtt: 42.0))

        connected.close()
        honestIncoming.connection.close(code: 0, reason: [])
        #expect(await Helper.eventuallyAsync { await machines.list().first?.online == false })

        await listener.close()
        #expect(endpoint.isClosed == true)
    }

    @Test("Iroh.listen uses applyN0 when testing.offline is false")
    func irohListenProductionDefaults() async throws {
        let (machines, identity, _) = try Helper.machines()
        let mockBinding = Helper.MockIrohBinding()
        let listener = try await MachineIroh.listen(
            admit: { true },
            identity: identity,
            machines: machines,
            testing: MachineIroh.Testing(offline: false, load: { mockBinding })
        )
        let builder = try #require(mockBinding.latestBuilder)
        #expect(builder.recorded.usedN0 == true)
        #expect(builder.recorded.usedMinimal == false)
        #expect(builder.recorded.bindAddress == nil)
        await listener.close()
    }
}

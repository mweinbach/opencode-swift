import Testing
import OpenCodeCore
import OpenCodePlatform

private let hex = MachineTestHelper.hex
private let toHex = MachineTestHelper.toHex

/// Runs `accept` and `dial` against each other over an in-memory carrier pair.
private func connect(
    machines: Machines.Service,
    identity: MachineTestHelper.FixedIdentity,
    dial options: MachineLink.DialOptions,
    fixed: MachineLink.Fixed = MachineLink.Fixed()
) async -> (home: Result<MachineLink.Established, any Error>, worker: Result<MachineLink.Established, any Error>, homePipe: MachineTestHelper.Pipe, workerPipe: MachineTestHelper.Pipe) {
    let (homePipe, workerPipe) = MachineTestHelper.Pipe.pair()
    async let home: Result<MachineLink.Established, any Error> = {
        do {
            return .success(try await MachineLink.accept(homePipe, identity: identity, machines: machines, fixed: fixed))
        } catch {
            homePipe.close()
            return .failure(error)
        }
    }()
    async let worker: Result<MachineLink.Established, any Error> = {
        do {
            return .success(try await MachineLink.dial(workerPipe, options: options))
        } catch {
            workerPipe.close()
            return .failure(error)
        }
    }()
    return (await home, await worker, homePipe, workerPipe)
}

private func secret(of join: String) -> (home: [UInt8], secret: [UInt8]) {
    let value = MachineJoin.decode(join)!
    return (value.home, value.secret)
}

@Suite("Machine link handshake")
struct MachineLinkTests {
    /// The transcript the Rust worker must reproduce byte for byte (upstream `test/fixture/link-v1-transcript.json`).
    @Test("reproduces the pinned v1 transcript")
    func pinnedTranscript() async throws {
        let (machines, identity, _) = try MachineTestHelper.machines(seed: hex("0101010101010101010101010101010101010101010101010101010101010101"))
        let id = try await machines.add("gpu")
        let worker = MachineIdentity.fromSeed(hex("0202020202020202020202020202020202020202020202020202020202020202"))
        let printed = secret(of: try await machines.invite(id, options: .init(reach: [])))
        // Real invitations are random, so the worker is paired first. The pinned secret is then unknown to the home,
        // which lets the paired key in, the same path a lost welcome takes: message 3 still carries the secret.
        let first = await connect(machines: machines, identity: identity, dial: .init(home: printed.home, identity: worker, secret: printed.secret))
        #expect((try? first.worker.get())?.machine == "gpu")
        let link = await connect(
            machines: machines,
            identity: identity,
            dial: .init(
                home: printed.home,
                identity: worker,
                secret: hex("0707070707070707070707070707070707070707070707070707070707070707"),
                fixed: .init(
                    static: try MachineNoise.keyPair(hex("0505050505050505050505050505050505050505050505050505050505050505")),
                    ephemeral: try MachineNoise.keyPair(hex("0606060606060606060606060606060606060606060606060606060606060606"))
                )
            ),
            fixed: .init(
                static: try MachineNoise.keyPair(hex("0303030303030303030303030303030303030303030303030303030303030303")),
                ephemeral: try MachineNoise.keyPair(hex("0404040404040404040404040404040404040404040404040404040404040404"))
            )
        )
        #expect((try? link.worker.get())?.machine == "gpu")
        #expect((try? link.home.get())?.machine == "gpu")
        #expect(toHex(try await identity.publicKey()) == "8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c")
        #expect(toHex(worker.publicKey) == "8139770ea87d175f56a35466c34c7ecccb8d8a91b4ee37a25df60f5b8fc9b394")
        let byWorker = link.workerPipe.sent
        let byHome = link.homePipe.sent
        #expect(byWorker.count == 2 && byHome.count == 2)
        #expect(toHex(byWorker[0]) == "f5b2d6e60f9477e310c2982daaa6c9136c108a1777c5947e448fa37d68174557")
        #expect(toHex(byHome[0]) == "ac01b2209e86354fb853237b5de0f4fab13c7fcbf433a61c019369617fecf10be70eb76cfd9879d19130c915124227827839e15f751a77083ebdbd809653c73f4682aa4bfb60a61a0a1b9cd8f978690799527bad0121199677bc5605fd1ae9b2b0f74fdd71a6c22a14a13010cc2c141a39f16a91e6c64e6caf541265ac450816c5e83f7f5623f786811b431a1c3abe4ec44dd5e625437aef884383d8c0693c6a8cb5462b5eb0be0d9d82d23bf11af8bc87aba22e7eeb96fda0348230b340662f")
        #expect(toHex(byWorker[1]) == "e30068bb3017141fc5433629ef2ca8f3d582a5d2814f134dfcb7d97afc19eb203ab96c6172a9c8008cd3156205860a72a3765bbe37068d3799bd6544c4db5198bcc7a0a68dad9ad06c2ce3795267b4bcefe7756b73acbd4d7bdceb453972942b477a555f7f26a204a8a137558e49f291b47c6e119ae5042f203826233f37f2a673fee0debe7112bae5dd51064f4df7168d0b8e17af9caf0265026752d6e7484f45d93b389310f5caa296f27926bbf95794fa3035d794a8b91e3d2799633053936e")
        #expect(toHex(byHome[1]) == "5c5416b97a5b04e8647ccb9652aa85d48f282d")
    }

    @Test("pairs with a join secret, reconnects without one, and both sides share working ciphers")
    func pairAndReconnect() async throws {
        let (machines, identity, _) = try MachineTestHelper.machines()
        let id = try await machines.add("gpu")
        let printed = secret(of: try await machines.invite(id, options: .init(reach: [.url("https://home.example")])))
        let worker = MachineIdentity.fromSeed([UInt8](repeating: 9, count: 32))
        let joined = await connect(machines: machines, identity: identity, dial: .init(home: printed.home, identity: worker, secret: printed.secret))
        let home = try joined.home.get()
        let dialled = try joined.worker.get()
        #expect(home.machine == "gpu" && dialled.machine == "gpu")
        #expect(try home.receive.decrypt(try dialled.send.encrypt([1, 2, 3])) == [1, 2, 3])
        #expect(await machines.list() == [Machines.Info(id: "gpu", online: false, paired: true)])
        // The secret is spent; a reconnect carries none and is let in by its key.
        let again = await connect(machines: machines, identity: identity, dial: .init(home: printed.home, identity: worker))
        #expect((try? again.home.get())?.machine == "gpu")
    }

    @Test("an unknown key without a valid secret is refused, as is a home that cannot prove the pinned key")
    func refusals() async throws {
        let (machines, identity, _) = try MachineTestHelper.machines()
        let id = try await machines.add("gpu")
        let printed = secret(of: try await machines.invite(id, options: .init(reach: [])))
        let stranger = MachineIdentity.fromSeed([UInt8](repeating: 4, count: 32))
        let noSecret = await connect(machines: machines, identity: identity, dial: .init(home: printed.home, identity: stranger))
        #expect(throws: MachineLink.Refused.self) { try noSecret.home.get() }
        let wrongSecret = await connect(
            machines: machines,
            identity: identity,
            dial: .init(home: printed.home, identity: stranger, secret: [UInt8](repeating: 8, count: 32))
        )
        #expect(throws: MachineLink.Refused.self) { try wrongSecret.home.get() }
        // A worker given another home's key never writes message 3, so the secret never reaches this home.
        let otherHome = MachineIdentity.fromSeed([UInt8](repeating: 5, count: 32)).publicKey
        let impostor = await connect(machines: machines, identity: identity, dial: .init(home: otherHome, identity: stranger, secret: printed.secret))
        #expect(throws: MachineLink.Refused.self) { try impostor.worker.get() }
        #expect(impostor.workerPipe.sent.count == 1)
        // The invitation survived: it is still good for the right worker.
        let honest = await connect(machines: machines, identity: identity, dial: .init(home: printed.home, identity: stranger, secret: printed.secret))
        #expect((try? honest.worker.get())?.machine == "gpu")
    }

    @Test("a message of the wrong length is refused before Noise reads it")
    func wrongLength() async throws {
        let (machines, identity, _) = try MachineTestHelper.machines()
        let (homePipe, workerPipe) = MachineTestHelper.Pipe.pair()
        await workerPipe.send([UInt8](repeating: 1, count: 31))
        await #expect(throws: MachineLink.Refused.self) {
            try await MachineLink.accept(homePipe, identity: identity, machines: machines)
        }
    }
}

@Suite("Machines list, invitations and pairing")
struct MachinesServiceTests {
    @Test("adds valid names once, lists them sorted, and removes them")
    func addListRemove() async throws {
        let (machines, _, db) = try MachineTestHelper.machines()
        #expect(try await machines.add("gpu") == "gpu")
        #expect(try await machines.add("a-box") == "a-box")
        await #expect(throws: Machines.AlreadyExists(machine: "gpu")) { try await machines.add("gpu") }
        for bad in ["local", "C", "Gpu", "9gpu", "gpu_1", String(repeating: "a", count: 64)] {
            await #expect(throws: Machines.InvalidName(name: bad)) { try await machines.add(bad) }
        }
        #expect(await machines.list().map(\.id) == ["a-box", "gpu"])
        #expect(try db.query("SELECT id FROM machine ORDER BY id", parameters: []).compactMap { $0.string("id") } == ["a-box", "gpu"])
        try await machines.remove("gpu")
        #expect(await machines.list().map(\.id) == ["a-box"])
        await #expect(throws: Machines.NotFound(machine: "gpu")) { try await machines.get("gpu") }
        #expect(Machines.InvalidName(name: "x").message.hasPrefix("\"x\" is not a machine name."))
        #expect(Machines.NotFound(machine: "gpu").message == "No machine named \"gpu\".")
    }

    @Test("a join string pairs once, before it expires, and a paired machine needs replace")
    func invitations() async throws {
        let clock = MachineClock()
        let (machines, identity, db) = try MachineTestHelper.machines(now: { clock.now })
        let id = try await machines.add("gpu")
        await #expect(throws: Machines.NotFound(machine: "cpu")) { try await machines.invite("cpu", options: .init(reach: [])) }
        let join = MachineJoin.decode(try await machines.invite(id, options: .init(reach: [.url("wss://home")])))!
        #expect(join.home == (try await identity.publicKey()))
        #expect(join.expires == clock.now + 300_000)
        #expect(join.reach == [.url("wss://home")])
        let key = [UInt8](repeating: 3, count: 32)
        await #expect(throws: Machines.InvalidJoin()) { try await machines.join(secret: join.secret, key: [1]) }
        #expect(try await machines.join(secret: join.secret, key: key) == "gpu")
        await #expect(throws: Machines.InvalidJoin()) { try await machines.join(secret: join.secret, key: key) }
        #expect(try await machines.identify(key) == "gpu")
        await #expect(throws: Machines.UnknownKey()) { try await machines.identify([UInt8](repeating: 4, count: 32)) }
        #expect(try db.queryOne("SELECT key FROM machine WHERE id = 'gpu'")?.string("key") == MachineCrypto.base64URLEncode(key))
        await #expect(throws: Machines.AlreadyPaired(machine: "gpu")) { try await machines.invite(id, options: .init(reach: [])) }

        let expiring = MachineJoin.decode(try await machines.invite(id, options: .init(reach: [], replace: true)))!
        clock.now += 300_000
        await #expect(throws: Machines.InvalidJoin()) { try await machines.join(secret: expiring.secret, key: [UInt8](repeating: 5, count: 32)) }

        let replaced = MachineJoin.decode(try await machines.invite(id, options: .init(reach: [], replace: true)))!
        let newKey = [UInt8](repeating: 6, count: 32)
        #expect(try await machines.join(secret: replaced.secret, key: newKey) == "gpu")
        #expect(try await machines.identify(newKey) == "gpu")

        // A key another machine holds is never paired twice.
        let other = try await machines.add("cpu")
        let stolen = MachineJoin.decode(try await machines.invite(other, options: .init(reach: [])))!
        await #expect(throws: Machines.InvalidJoin()) { try await machines.join(secret: stolen.secret, key: newKey) }
    }

    @Test("rows written earlier are known, with their keys, after a restart")
    func restart() async throws {
        let (machines, identity, db) = try MachineTestHelper.machines()
        let id = try await machines.add("gpu")
        let join = MachineJoin.decode(try await machines.invite(id, options: .init(reach: [])))!
        let key = [UInt8](repeating: 7, count: 32)
        _ = try await machines.join(secret: join.secret, key: key)
        let restarted = try Machines.Service(database: db, identity: identity)
        #expect(await restarted.list() == [Machines.Info(id: "gpu", online: false, paired: true)])
        #expect(try await restarted.identify(key) == "gpu")
    }
}

final class MachineClock: Sendable {
    private let value = MachineMutexBox<Int64>(1_000)
    var now: Int64 {
        get { value.get() }
        set { value.set(newValue) }
    }
}

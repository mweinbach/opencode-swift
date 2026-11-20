import Testing
import OpenCodeCore

private let hex = MachineTestHelper.hex
private let toHex = MachineTestHelper.toHex
private let text = MachineTestHelper.bytes

/// Every Noise_XX_25519_AESGCM_SHA256 vector in tests/vectors/cacophony.txt and tests/vectors/snow.txt of
/// https://github.com/mcginty/snow at commit 8ac60f51cfe3e010c84f0a454cc575ad9204fa12, as upstream's
/// `test/fixture/noise-xx-vectors.json` copies them.
private struct NoiseVector {
    let prologue: String
    let initStatic: String
    let initEphemeral: String
    let respStatic: String
    let respEphemeral: String
    let handshakeHash: String?
    let messages: [(payload: String, ciphertext: String)]
}

private let vectors: [NoiseVector] = [
    NoiseVector(
        prologue: "4a6f686e2047616c74",
        initStatic: "e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1",
        initEphemeral: "893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a",
        respStatic: "4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893",
        respEphemeral: "bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b",
        handshakeHash: "1b7aefb1125762aa21a252890d00af54519638b76437444538f9a52f21e2e0dc",
        messages: [
            ("4c756477696720766f6e204d69736573", "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c79444c756477696720766f6e204d69736573"),
            ("4d757272617920526f746862617264", "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f144808843757117acceb05bd7a45733bc22015c97a9d0cbaf41b80446d5988ff5127235d76b79eade70f473d6a4ef521fdcbeda5340d01e028ba793fc059f2724a83af05f12dda0448a7621a926b379a92477fd"),
            ("462e20412e20486179656b", "c90f1cf77eba4e50edb038991565e36c9758943a989229b6051244dc4fbecb6946744b401af2ee1a5881b65fbb87fd07cb6a328ececc9ce6ce84c399dc332d4fd521fa4bb7f467ce909395"),
            ("4361726c204d656e676572", "bc3fa77f6aca3e8466d7dc6bea10013e88a6a29add5132b461806c"),
            ("4a65616e2d426170746973746520536179", "250b01074cdfe0df2ecf8ccbf1737b15a2ddb5b52fd9a396604e9c793cee3b3bb9"),
            ("457567656e2042f6686d20766f6e2042617765726b", "449d4d433b3cdc3d02bf6fc881774b9df54366ebcffb9689bb13f14709822cd7ef42bcdb4d"),
        ]
    ),
    NoiseVector(
        prologue: "5468657265206973206e6f20726967687420616e642077726f6e672e2054686572652773206f6e6c792066756e20616e6420626f72696e672e",
        initStatic: "67a147237ca2e511a5328abf44fc049e725d23ac193f1d5e8da60d543670cd39",
        initEphemeral: "b4dbfea92d1afb2ce4a508bd5e014d21ee95ced8d12346d226985d40b2da95e7",
        respStatic: "0e64a9143ba4c2bb79a25cd1c12575a9da949b52338b32fe1208e4b598c9acc0",
        respEphemeral: "c3142e465cafd8356330d7f910146c5428a524e723df165d76a2d5a697aa7e6d",
        handshakeHash: nil,
        messages: [
            ("09f6721fa79e976f05d523c07e4818bfad6903108a05734e3163cec30442fcf5", "c8a324f41408be37f760130b5a8f2c4e9c92bab229e9b78007aa43b7c7656b3409f6721fa79e976f05d523c07e4818bfad6903108a05734e3163cec30442fcf5"),
            ("af62581a26fc31c4b722c1f04d73d845eb6daf35bcd64fc805a46a74bd747d90", "4e935a4c1dccaf91b78062590be1e790f984eeff2ab9a219e491387a99dbfe53b9ea4a0a1b78a30056a0615ef4cfcc5d5bcfa087abd07df701c08b2410ab385c490a43cd853a15a1d1e8162c25b78d362ff84afd1f02e0d0e8d25ada33fe5f8e8856cc49e9a896c1c10616508f52387ca29d35a037c7d1c968a45d07daf01667"),
            ("bae081c11b0a050d08a48d4a2dd387bd927e18d12c1f2758ae712ec4e3948dc8", "72eb5f83ef7773b38886a657b2216368f76f51e90855aaec0c9cd65c7750c531b3ef8a9261065b9b73009e698c3e0e1e7153c64e842d877db5f0953c2a43f12bdee99b360ebc11ee64a2989bf8f486a45267753caf35ad5900224e9b04c4b5b2"),
            ("062b027afab93baa74c7cdc1ac71b3486636bed142caec9f70f4dd672dbe120d", "9953df9aa4294b12364dd6896de6e705564a5583c67ed86f0b985054d63f4381bdb99faa8633893643d6ee3ba987344f"),
            ("3000ff396f68e4d00ac10c97a4c14e5901e3245dc29f9a801427babd59bfc2a3", "d9ea28203c96f5ac9024541d8f05e5e9bbfedccf701d2a2130ddeada49446a546d03c3ed440558782120b95e537a229e"),
        ]
    ),
]

private func pair(prologue: [UInt8] = MachineTestHelper.bytes("opencode")) throws -> (
    initiator: MachineNoise.Handshake, responder: MachineNoise.Handshake,
    initiatorStatic: MachineNoise.KeyPair, responderStatic: MachineNoise.KeyPair
) {
    let initiatorStatic = MachineNoise.generateKeyPair()
    let responderStatic = MachineNoise.generateKeyPair()
    return (
        try MachineNoise.handshake(.init(initiator: true, prologue: prologue, static: initiatorStatic)),
        try MachineNoise.handshake(.init(initiator: false, prologue: prologue, static: responderStatic)),
        initiatorStatic,
        responderStatic
    )
}

private func flip(_ message: [UInt8], bit: Int) -> [UInt8] {
    var copy = message
    copy[bit >> 3] ^= UInt8(1 << (bit & 7))
    return copy
}

private func failure(_ body: () throws(MachineNoise.Failure) -> [UInt8]) -> MachineNoise.Failure? {
    do {
        _ = try body()
        return nil
    } catch {
        return error
    }
}

@Suite("Machine Noise XX handshake")
struct MachineNoiseTests {
    @Test("reproduces every published Noise_XX_25519_AESGCM_SHA256 vector")
    func publishedVectors() throws {
        for vector in vectors {
            let initiator = try MachineNoise.handshake(.init(
                initiator: true,
                prologue: hex(vector.prologue),
                static: try MachineNoise.keyPair(hex(vector.initStatic)),
                ephemeral: try MachineNoise.keyPair(hex(vector.initEphemeral))
            ))
            let responder = try MachineNoise.handshake(.init(
                initiator: false,
                prologue: hex(vector.prologue),
                static: try MachineNoise.keyPair(hex(vector.respStatic)),
                ephemeral: try MachineNoise.keyPair(hex(vector.respEphemeral))
            ))
            var hashes: Set<String> = []
            for (index, message) in vector.messages.prefix(3).enumerated() {
                let sender = index % 2 == 0 ? initiator : responder
                let receiver = index % 2 == 0 ? responder : initiator
                #expect(toHex(try sender.write(hex(message.payload))) == message.ciphertext)
                #expect(try receiver.read(hex(message.ciphertext)) == hex(message.payload))
                // The link signs h after messages 1 and 2, so both sides must agree on it at every step.
                #expect(initiator.hash == responder.hash)
                hashes.insert(toHex(initiator.hash ?? []))
            }
            #expect(hashes.count == 3)
            if let handshakeHash = vector.handshakeHash {
                #expect(toHex(initiator.hash ?? []) == handshakeHash)
            }
            #expect(initiator.remoteStatic == (try MachineNoise.keyPair(hex(vector.respStatic))).publicKey)
            #expect(responder.remoteStatic == (try MachineNoise.keyPair(hex(vector.initStatic))).publicKey)
            let initiatorTransport = try initiator.split()
            let responderTransport = try responder.split()
            for (index, message) in vector.messages.dropFirst(3).enumerated() {
                // Transport message 0 is the fourth message overall, so the responder sends first.
                if index % 2 == 0 {
                    #expect(toHex(try responderTransport.send.encrypt(hex(message.payload))) == message.ciphertext)
                    #expect(try initiatorTransport.receive.decrypt(hex(message.ciphertext)) == hex(message.payload))
                } else {
                    #expect(toHex(try initiatorTransport.send.encrypt(hex(message.payload))) == message.ciphertext)
                    #expect(try responderTransport.receive.decrypt(hex(message.ciphertext)) == hex(message.payload))
                }
            }
        }
    }

    @Test("a handshake with fresh keys authenticates both sides and carries messages both ways")
    func freshHandshake() throws {
        let sides = try pair()
        #expect(sides.initiator.remoteStatic == nil)
        #expect(sides.initiator.hash == sides.responder.hash)
        #expect(try sides.responder.read(try sides.initiator.write(text("one"))) == text("one"))
        #expect(try sides.initiator.read(try sides.responder.write(text("two"))) == text("two"))
        #expect(try sides.responder.read(try sides.initiator.write(text("three"))) == text("three"))
        #expect(sides.initiator.remoteStatic == sides.responderStatic.publicKey)
        #expect(sides.responder.remoteStatic == sides.initiatorStatic.publicKey)
        #expect(sides.initiator.hash?.count == 32)
        let initiator = try sides.initiator.split()
        let responder = try sides.responder.split()
        for round in 0..<3 {
            #expect(try responder.receive.decrypt(try initiator.send.encrypt(text("up \(round)"))) == text("up \(round)"))
            #expect(try initiator.receive.decrypt(try responder.send.encrypt(text("down \(round)"))) == text("down \(round)"))
        }
        #expect(try responder.receive.decrypt(try initiator.send.encrypt([])) == [])
    }

    @Test("a flipped bit in message 2 or 3 fails the handshake and ends it")
    func flippedHandshakeBits() throws {
        for bit in stride(from: 0, to: 96 * 8, by: 37) {
            let sides = try pair()
            _ = try sides.responder.read(try sides.initiator.write(text("one")))
            let reply = try sides.responder.write(text("two"))
            #expect(failure { () throws(MachineNoise.Failure) in try sides.initiator.read(flip(reply, bit: bit)) } == .badMessage)
            #expect(sides.initiator.remoteStatic == nil)
            #expect(sides.initiator.hash == nil)
        }
        for bit in stride(from: 0, to: 64 * 8, by: 29) {
            let sides = try pair()
            _ = try sides.responder.read(try sides.initiator.write(text("one")))
            _ = try sides.initiator.read(try sides.responder.write(text("two")))
            let third = try sides.initiator.write(text("three"))
            #expect(failure { () throws(MachineNoise.Failure) in try sides.responder.read(flip(third, bit: bit)) } == .badMessage)
            #expect(sides.responder.remoteStatic == nil)
            #expect(sides.responder.hash == nil)
            #expect(throws: MachineNoise.Failure.wrongStep) { try sides.responder.split() }
        }
    }

    @Test("a flipped bit in a transport message fails and ends the receiver")
    func flippedTransportBits() throws {
        let sides = try pair()
        _ = try sides.responder.read(try sides.initiator.write([]))
        _ = try sides.initiator.read(try sides.responder.write([]))
        _ = try sides.responder.read(try sides.initiator.write([]))
        let initiator = try sides.initiator.split()
        let responder = try sides.responder.split()
        let sealed = try initiator.send.encrypt(text("hello"))
        #expect(failure { () throws(MachineNoise.Failure) in try responder.receive.decrypt(flip(sealed, bit: 3)) } == .badMessage)
        #expect(failure { () throws(MachineNoise.Failure) in try responder.receive.decrypt(sealed) } == .wrongStep)
    }

    @Test("messages out of turn, a second split and short keys are refused")
    func steps() throws {
        let sides = try pair()
        #expect(failure { () throws(MachineNoise.Failure) in try sides.responder.write([]) } == .wrongStep)
        // A call out of turn ends that side.
        #expect(sides.responder.hash == nil)
        let fresh = try pair()
        #expect(throws: MachineNoise.Failure.wrongStep) { try fresh.initiator.split() }
        #expect(throws: MachineNoise.Failure.badKey) { try MachineNoise.keyPair([1, 2, 3]) }
        #expect(throws: MachineNoise.Failure.badKey) {
            try MachineNoise.handshake(.init(
                initiator: true,
                prologue: [],
                static: MachineNoise.KeyPair(publicKey: [UInt8](repeating: 0, count: 31), privateKey: [UInt8](repeating: 0, count: 32))
            ))
        }
        let done = try pair()
        _ = try done.responder.read(try done.initiator.write([]))
        _ = try done.initiator.read(try done.responder.write([]))
        _ = try done.responder.read(try done.initiator.write([]))
        _ = try done.initiator.split()
        #expect(throws: MachineNoise.Failure.wrongStep) { try done.initiator.split() }
    }

    @Test("a message past 65535 bytes is too long")
    func tooLong() throws {
        let sides = try pair()
        #expect(failure { () throws(MachineNoise.Failure) in try sides.initiator.write([UInt8](repeating: 0, count: 65_535)) } == .tooLong)
        let reader = try pair()
        #expect(failure { () throws(MachineNoise.Failure) in try reader.responder.read([UInt8](repeating: 0, count: 65_536)) } == .tooLong)
    }
}

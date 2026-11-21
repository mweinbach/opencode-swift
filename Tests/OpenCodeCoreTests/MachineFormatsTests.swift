import Testing
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema

private typealias Helper = MachineTestHelper

@Suite("Machine paths, join strings, wire messages, identity and instructions")
struct MachineFormatsTests {
    // MARK: - Path

    @Test("parses a machine path and refuses drives, URLs, local and relative paths", arguments: [
        ("gpu:/work/a", MachinePath.Parsed(machine: "gpu", path: "/work/a")),
        ("gpu-2:/x", MachinePath.Parsed(machine: "gpu-2", path: "/x")),
        ("gpu:/a//b", MachinePath.Parsed(machine: "gpu", path: "/a//b")),
        ("gpu:/", MachinePath.Parsed(machine: "gpu", path: "/")),
        ("gpu:~/notes", MachinePath.Parsed(machine: "gpu", path: "~/notes")),
        ("gpu:~", MachinePath.Parsed(machine: "gpu", path: "~")),
    ] as [(String, MachinePath.Parsed)])
    func parsesMachinePaths(input: String, expected: MachinePath.Parsed) {
        #expect(MachinePath.parse(input) == expected)
    }

    @Test("refuses what is not a machine path", arguments: [
        "C:/Users/x", "C:\\x", "skill://thing", "file:///x", "https://host/x", "local:/x", "gpu:relative", "gpu:",
        "/plain/path", "relative/a:b/c", ":only", "A:/x", "todo:list.txt",
    ])
    func refusesOthers(input: String) {
        #expect(MachinePath.parse(input) == nil)
    }

    @Test("a NotAbsolute path explains the forms a machine path takes")
    func notAbsolute() {
        #expect(
            MachinePath.NotAbsolute(machine: "gpu").message
                == "Machine paths are absolute or start with ~/: write gpu:/… or gpu:~/… (for a local folder with that name, start with ./)"
        )
    }

    // MARK: - Join

    /// Also a test vector for the Rust worker: this exact string must keep decoding to the value.
    static let literal =
        "ocjoin_eyJ2IjoxLCJob21lIjoiQVFFQkFRRUJBUUVCQVFFQkFRRUJBUUVCQVFFQkFRRUJBUUVCQVFFQkFRRSIsInNlY3JldCI6IkFnSUNBZ0lDQWdJQ0FnSUNBZ0lDQWdJQ0FnSUNBZ0lDQWdJQ0FnSUNBZ0kiLCJleHBpcmVzIjoxNzY3MjI1NjAwMDAwLCJyZWFjaCI6W3sidHlwZSI6InVybCIsInVybCI6Imh0dHBzOi8vaG9tZS5leGFtcGxlIn1dfQ"
    static let value = MachineJoin.Value(
        home: [UInt8](repeating: 1, count: 32),
        secret: [UInt8](repeating: 2, count: 32),
        expires: 1_767_225_600_000,
        reach: [.url("https://home.example")]
    )

    @Test("a join string encodes and decodes upstream's pinned literal")
    func joinLiteral() {
        #expect(MachineJoin.encode(Self.value) == Self.literal)
        #expect(MachineJoin.decode(Self.literal) == Self.value)
        #expect(MachineJoin.decode("opencode_" + Self.literal.dropFirst("ocjoin_".count)) == nil)
    }

    @Test("a join string with a wrong field, too long, or not canonical is refused")
    func joinRefusals() {
        #expect(MachineJoin.decode(Helper.rawJoin([:])) == Self.value)
        for fields in [
            ["v": "2"],
            ["home": "\"\(MachineCrypto.base64URLEncode([UInt8](repeating: 1, count: 31)))\""],
            ["secret": "\"\(MachineCrypto.base64URLEncode([UInt8](repeating: 2, count: 33)))\""],
            ["expires": "\"soon\""], ["expires": "-1"], ["expires": "1.5"], ["expires": "9007199254740992"],
        ] {
            #expect(MachineJoin.decode(Helper.rawJoin(fields)) == nil)
        }
        let long = Helper.rawJoin(["reach": "[{\"type\":\"url\",\"url\":\"https://home.example/\(String(repeating: "a", count: 4_000))\"}]"])
        #expect(long.utf16.count > 4_096)
        #expect(MachineJoin.decode(long) == nil)
        #expect(MachineJoin.decode(Helper.rawJoin([:]) + "=") == nil)
        let reach = Helper.rawJoin(["reach": "[{\"type\":\"carrier\",\"band\":\"x\"},{\"type\":\"url\",\"url\":\"https://home.example\"}]"])
        #expect(MachineJoin.decode(reach)?.reach == [.url("https://home.example")])

        // Keeps an iroh entry after URLs and round-trips it cleanly.
        let withIroh = MachineJoin.Value(
            home: Self.value.home,
            secret: Self.value.secret,
            expires: Self.value.expires,
            reach: [.url("https://home.example"), .iroh]
        )
        let rawWithIroh = Helper.rawJoin(["reach": "[{\"type\":\"url\",\"url\":\"https://home.example\"},{\"type\":\"iroh\"}]"])
        #expect(MachineJoin.decode(rawWithIroh)?.reach == [.url("https://home.example"), .iroh])
        #expect(MachineJoin.decode(MachineJoin.encode(withIroh)) == withIroh)
    }

    // MARK: - Wire

    @Test("wire messages decode from and encode to upstream's v2 JSON")
    func wire() throws {
        let hello = try Helper.decode(
            MachineWire.FromWorker.self,
            #"{"type":"hello","protocol":2,"os":"linux","arch":"x64","home":"/home/me","instance":"i1","processes":[{"id":"p1","pid":4,"state":"exited","bytes":3,"code":null,"signal":"SIGTERM"},{"id":"p2","pid":5,"state":"running","bytes":0}]}"#
        )
        guard case .hello(let parsed) = hello else {
            Issue.record("expected a hello")
            return
        }
        #expect(parsed.`protocol` == 2)
        #expect(parsed.instance == MachineWire.Instance("i1"))
        #expect(parsed.processes[0].code == .some(nil) && parsed.processes[0].signal == "SIGTERM")
        #expect(parsed.processes[1].code == nil)
        #expect(throws: (any Error).self) {
            try Helper.decode(MachineWire.Hello.self, #"{"type":"hello","protocol":2,"os":"linux","arch":"x64","home":"relative","instance":"i","processes":[]}"#)
        }
        #expect(throws: (any Error).self) {
            try Helper.decode(MachineWire.Hello.self, #"{"type":"hello","protocol":1,"os":"linux","arch":"x64","home":"/home/me","instance":"i","processes":[]}"#)
        }
        #expect(throws: (any Error).self) {
            try Helper.decode(MachineWire.Hello.self, #"{"type":"hello","os":"linux","arch":"x64","home":"/home/me","instance":"i","processes":[]}"#)
        }
        #expect(try Helper.decode(MachineWire.FromWorker.self, #"{"type":"output","id":"p","offset":2,"stream":"stdout","data":"aGk="}"#)
            == .output(id: MachineWire.ProcessID("p"), offset: 2, stream: .stdout, data: Array("hi".utf8)))
        #expect(try Helper.decode(MachineWire.FromWorker.self, #"{"type":"output","id":"p","offset":2,"stream":"stderr","data":"ZXJy"}"#)
            == .output(id: MachineWire.ProcessID("p"), offset: 2, stream: .stderr, data: Array("err".utf8)))
        #expect(throws: (any Error).self) {
            try Helper.decode(MachineWire.FromWorker.self, #"{"type":"output","id":"p","offset":0,"data":""}"#)
        }
        #expect(try Helper.decode(MachineWire.FromWorker.self, #"{"type":"stdin","id":"p1","req":1,"ok":true}"#)
            == .stdin(id: MachineWire.ProcessID("p1"), req: 1, outcome: .ok))
        #expect(try Helper.decode(MachineWire.FromWorker.self, #"{"type":"stdin","id":"p1","req":2,"ok":false,"message":"Broken pipe"}"#)
            == .stdin(id: MachineWire.ProcessID("p1"), req: 2, outcome: .failed("Broken pipe")))
        #expect(try Helper.decode(MachineWire.FromWorker.self, #"{"type":"exit","id":"p","bytes":2,"code":null,"signal":"SIGKILL"}"#)
            == .exit(MachineWire.Exit(id: MachineWire.ProcessID("p"), bytes: 2, signal: "SIGKILL")))
        #expect(try Helper.decode(MachineWire.FromWorker.self, #"{"type":"exit","id":"p","bytes":2,"code":1}"#)
            == .exit(MachineWire.Exit(id: MachineWire.ProcessID("p"), bytes: 2, code: 1)))
        #expect(try Helper.decode(MachineWire.FromWorker.self, #"{"type":"fs","req":1,"ok":true,"result":null}"#)
            == .fs(MachineWire.FileReply(req: 1, outcome: .success(.none))))
        #expect(try Helper.decode(MachineWire.FromWorker.self, #"{"type":"fs","req":2,"ok":true,"result":{"type":"file","size":1,"mtimeMs":2.5}}"#)
            == .fs(MachineWire.FileReply(req: 2, outcome: .success(.info(MachineWire.FileInfo(type: .file, size: 1, mtimeMs: 2.5))))))
        #expect(try Helper.decode(MachineWire.FromWorker.self, #"{"type":"fs","req":3,"ok":true,"result":[{"name":"a","type":"directory"}]}"#)
            == .fs(MachineWire.FileReply(req: 3, outcome: .success(.list([MachineWire.DirEntry(name: "a", type: .directory)])))))
        #expect(try Helper.decode(MachineWire.FromWorker.self, #"{"type":"fs","req":4,"ok":true,"result":{"info":{"type":"file","size":2,"mtimeMs":0},"bytes":"aGk="}}"#)
            == .fs(MachineWire.FileReply(req: 4, outcome: .success(.read(MachineWire.ReadResult(info: MachineWire.FileInfo(type: .file, size: 2, mtimeMs: 0), bytes: Array("hi".utf8)))))))
        #expect(try Helper.decode(MachineWire.FromWorker.self, #"{"type":"fs","req":5,"ok":false,"error":{"kind":"wrong_kind","message":"m","actual":"directory"}}"#)
            == .fs(MachineWire.FileReply(req: 5, outcome: .failure(MachineWire.FileError(kind: .wrongKind, message: "m", actual: .directory)))))

        let id = MachineWire.ProcessID("p")
        #expect(try Helper.encode(MachineWire.ToWorker.start(id: id, argv: ["ls"], cwd: "/", env: ["A": "1"], stdin: false))
            == #"{"argv":["ls"],"cwd":"\/","env":{"A":"1"},"id":"p","stdin":false,"type":"start"}"#)
        #expect(throws: (any Error).self) {
            try Helper.decode(MachineWire.ToWorker.self, #"{"type":"start","id":"p","argv":["cat"],"cwd":"/","env":{}}"#)
        }
        #expect(throws: (any Error).self) {
            try Helper.decode(MachineWire.ToWorker.self, #"{"type":"stdin","id":"p","req":1}"#)
        }
        #expect(try Helper.encode(MachineWire.ToWorker.kill(id: id, signal: .SIGINT)) == #"{"id":"p","signal":"SIGINT","type":"kill"}"#)
        #expect(try Helper.encode(MachineWire.ToWorker.fs(MachineWire.FileCall(req: 1, call: .read(path: "/a", range: nil))))
            == #"{"call":"read","path":"\/a","req":1,"type":"fs"}"#)
        #expect(try Helper.encode(MachineWire.ToWorker.fs(MachineWire.FileCall(req: 2, call: .write(path: "/a", bytes: [0xff]))))
            == #"{"bytes":"\/w==","call":"write","path":"\/a","req":2,"type":"fs"}"#)

        // Shared upstream `machine-v2.json` messages round-trip byte-for-byte with canonical encoding.
        let v2ToWorker = [
            #"{"type":"start","id":"p1","argv":["cat"],"cwd":"/","env":{},"stdin":true}"#,
            #"{"type":"start","id":"p2","argv":["true"],"cwd":"/","env":{},"stdin":false}"#,
            #"{"type":"stdin","id":"p1","req":1,"data":"aGk="}"#,
            #"{"type":"stdin","id":"p1","req":2,"data":null}"#,
            #"{"type":"attach","id":"p1","from":1}"#,
        ]
        for json in v2ToWorker {
            let decoded = try Helper.decode(MachineWire.ToWorker.self, json)
            #expect(MachineWire.encodeJSONString(decoded) == json)
        }
        let v2FromWorker = [
            #"{"type":"output","id":"p1","offset":0,"stream":"stdout","data":"aGk="}"#,
            #"{"type":"output","id":"p1","offset":2,"stream":"stderr","data":"ZXJy"}"#,
            #"{"type":"stdin","id":"p1","req":1,"ok":true}"#,
            #"{"type":"stdin","id":"p1","req":2,"ok":false,"message":"Broken pipe"}"#,
        ]
        for json in v2FromWorker {
            let decoded = try Helper.decode(MachineWire.FromWorker.self, json)
            #expect(MachineWire.encodeJSONString(decoded) == json)
        }
        for message: MachineWire.ToWorker in [
            .attach(id: id, from: 3), .release(id: id),
            .stdin(id: id, req: 1, data: Array("hi".utf8)),
            .stdin(id: id, req: 2, data: nil),
            .fs(MachineWire.FileCall(req: 3, call: .move(from: "/a", to: "/b"))),
            .fs(MachineWire.FileCall(req: 4, call: .read(path: "/a", range: MachineWire.Range(offset: 1, length: 2)))),
        ] {
            #expect(try Helper.decode(MachineWire.ToWorker.self, try Helper.encode(message)) == message)
        }
    }

    // MARK: - Identity

    @Test("makes a key from a seed, signs deterministically, and verifies only well-formed keys and signatures")
    func identityKeys() {
        let key = MachineIdentity.fromSeed([UInt8](repeating: 1, count: 32))
        #expect(Helper.toHex(key.publicKey) == "8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c")
        let signature = key.sign(Array("hello".utf8))
        #expect(signature == key.sign(Array("hello".utf8)))
        #expect(MachineIdentity.verify(publicKey: key.publicKey, bytes: Array("hello".utf8), signature: signature))
        #expect(!MachineIdentity.verify(publicKey: key.publicKey + [0], bytes: Array("hello".utf8), signature: signature))
        #expect(!MachineIdentity.verify(publicKey: key.publicKey, bytes: Array("hello".utf8), signature: signature + [0]))
        #expect(!MachineIdentity.verify(publicKey: key.publicKey, bytes: Array("hellO".utf8), signature: signature))
    }

    @Test("creates the home key on first use with mode 600, keeps it, and refuses a key others can read")
    func identityService() async throws {
        let fs = InMemoryFileSystem()
        try await fs.makeDirectory(at: "/state", recursive: true)
        let modes = MachineMutexBox<UInt16>(0o600)
        let service = MachineIdentity.Service(state: "/state", fileSystem: fs, modeReader: { _ in modes.get() }, platform: .linux)
        let first = try await service.publicKey()
        let rawSeed = try await fs.readFile(at: "/state/machine/home-key")
        #expect(rawSeed.count == 32)
        #expect(try await service.seed() == rawSeed)
        #expect(MachineIdentity.fromSeed(try await service.seed()).publicKey == first)
        let again = MachineIdentity.Service(state: "/state", fileSystem: fs, modeReader: { _ in modes.get() }, platform: .linux)
        #expect(try await again.publicKey() == first)
        #expect(try await again.seed() == rawSeed)
        let signed = try await again.sign([1, 2, 3])
        #expect(MachineIdentity.verify(publicKey: first, bytes: [1, 2, 3], signature: signed))

        modes.set(0o644)
        let exposed = MachineIdentity.Service(state: "/state", fileSystem: fs, modeReader: { _ in modes.get() }, platform: .linux)
        await #expect(throws: MachineIdentity.InvalidKey(
            file: "/state/machine/home-key",
            reason: "its mode 644 lets other users read it; run \"chmod 600 /state/machine/home-key\""
        )) { try await exposed.publicKey() }
        // A failed load is tried again, so a fixed file works without a restart.
        modes.set(0o600)
        #expect(try await exposed.publicKey() == first)

        try await fs.writeFile([1, 2, 3], to: "/short/machine/home-key", createDirectories: true)
        let short = MachineIdentity.Service(state: "/short", fileSystem: fs, modeReader: { _ in 0o600 }, platform: .linux)
        await #expect(throws: MachineIdentity.InvalidKey(file: "/short/machine/home-key", reason: "expected a 32-byte key, found 3 bytes")) {
            try await short.publicKey()
        }
        #expect(MachineIdentity.InvalidKey(file: "f", reason: "r").message
            == "Cannot use the home key at f: r. Every paired machine trusts this key, so it is never replaced.")
    }

    // MARK: - Instructions

    @Test("lists the machines when the flag is on, and renders changes")
    func instructions() async throws {
        let (machines, _, _) = try Helper.machines()
        _ = try await machines.add("gpu")
        _ = try await machines.add("cpu")
        let flags = CoreFlag.Service(config: CoreConfig.Test(), channel: "local", overrides: "machines")
        let service = MachineInstructions.Service(flags: flags, machines: machines)
        let list = await service.load()
        #expect(list.map(\.key.rawValue) == ["core/machines"])
        let observed = await list[0].read()
        if CoreFlag.Key(rawValue: "machines") != nil {
            guard case .value(let json) = observed else {
                Issue.record("expected the machine names")
                return
            }
            #expect(json == .array([.string("cpu"), .string("gpu")]))
            let initial = list[0].initial(json)
            #expect(initial?.hasPrefix("Other machines are available: cpu, gpu.\nName one in a path, as in cpu:/work/file,") == true)
            let changed = list[0].changed(.array([.string("cpu")]), json)
            // Instructions.listUpdate diffs the machine names by key, so only the newly added name is listed.
            #expect(changed == "New machines are available in addition to those previously listed:\ngpu")
            #expect(list[0].removed(json) == "Other machines are no longer available. Do not use any previously listed machine.")
        } else {
            // A flag registry without `machines` reads as off.
            guard case .removed = observed else {
                Issue.record("expected the instruction to be removed")
                return
            }
        }
        let off = MachineInstructions.Service(flags: CoreFlag.Service(config: CoreConfig.Test(), channel: "local", overrides: "-machines"), machines: machines)
        guard case .removed = await (await off.load())[0].read() else {
            Issue.record("expected the instruction to be removed")
            return
        }
    }
}

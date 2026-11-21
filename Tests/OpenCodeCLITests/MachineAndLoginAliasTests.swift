import Testing
import OpenCodeCLIKit
import OpenCodeClient
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema

@Suite("CLI Machine Commands, Login Alias, Default Directory & ACP Execute Diff Tests")
struct MachineAndLoginAliasTests {
    @Test("CLIServiceURLs validates server URLs and detects loopback hosts")
    func serviceURLsValidationAndLoopback() throws {
        #expect(try CLIServiceURLs.parseServerURL("https://override.example.com:8443/") == "https://override.example.com:8443")
        #expect(try CLIServiceURLs.parseServerURL("HTTPS://EXAMPLE.COM:443/") == "https://example.com")
        #expect(try CLIServiceURLs.parseServerURL("http://127.0.0.1:4096") == "http://127.0.0.1:4096")
        #expect(throws: CLIError.self) { _ = try CLIServiceURLs.parseServerURL("ftp://example.com") }
        #expect(throws: CLIError.self) { _ = try CLIServiceURLs.parseServerURL("https://user:pass@example.com") }
        #expect(throws: CLIError.self) { _ = try CLIServiceURLs.parseServerURL("https://example.com?a=1") }
        #expect(throws: CLIError.self) { _ = try CLIServiceURLs.parseServerURL("https://example.com#frag") }

        #expect(CLIServiceURLs.isLoopback("localhost"))
        #expect(CLIServiceURLs.isLoopback("api.localhost"))
        #expect(CLIServiceURLs.isLoopback("127.0.0.1"))
        #expect(CLIServiceURLs.isLoopback("[::1]"))
        #expect(!CLIServiceURLs.isLoopback("::1"))
        #expect(!CLIServiceURLs.isLoopback("10.0.0.8"))
        #expect(!CLIServiceURLs.isLoopback("example.com"))
    }

    @Test("CLIMachine.machineReach orders reachable first and loopback last with ws(s) scheme")
    func machineReachOrdering() {
        let reach = CLIMachine.machineReach([
            "http://127.0.0.1:4096",
            "http://localhost:4096",
            "http://10.0.0.8:4096",
            "https://example.com",
            "http://[::1]:4096",
            "https://example.com/",
            "https://gpu.example.com:8443",
        ])
        #expect(reach == [
            MachineReach(url: "ws://10.0.0.8:4096/api/experimental/machine/link"),
            MachineReach(url: "wss://example.com/api/experimental/machine/link"),
            MachineReach(url: "wss://gpu.example.com:8443/api/experimental/machine/link"),
            MachineReach(url: "ws://127.0.0.1:4096/api/experimental/machine/link"),
            MachineReach(url: "ws://localhost:4096/api/experimental/machine/link"),
            MachineReach(url: "ws://[::1]:4096/api/experimental/machine/link"),
        ])
    }

    @Test("CLIMachine formatters match upstream add, list, and error text")
    func machineOutputFormatters() {
        let nonTTY = CLIMachine.formatMachineAdd(.init(
            name: "gpu",
            join: "ocjoin_example",
            expires: 300_000,
            reach: [.url("wss://example.com/api/experimental/machine/link")],
            tty: false,
            now: 0,
            eol: "\n"
        ))
        #expect(nonTTY == "ocjoin_example\n")

        let ttyIroh = CLIMachine.formatMachineAdd(.init(
            name: "gpu",
            join: "ocjoin_example",
            expires: 300_000,
            reach: [.url("ws://localhost:4096/api/experimental/machine/link"), .iroh],
            tty: true,
            now: 0,
            eol: "\n"
        ))
        #expect(ttyIroh.contains("Machine: gpu"))
        #expect(ttyIroh.contains("Expires in 5 minutes"))
        #expect(ttyIroh.contains("Works from any network.\nAddresses:\n"))
        #expect(ttyIroh.contains("  iroh\n"))

        let ttyLoopback = CLIMachine.formatMachineAdd(.init(
            name: "gpu",
            join: "ocjoin_example",
            expires: 300_000,
            reach: [.url("ws://127.0.0.1:4096/api/experimental/machine/link")],
            tty: true,
            now: 0,
            eol: "\n"
        ))
        #expect(ttyLoopback.contains("Only works on this computer. Pass --url with an address other computers can reach."))

        #expect(CLIMachine.formatMachineList([], eol: "\n") == "No machines added.")
        let formattedList = CLIMachine.formatMachineList([
            MachineInfo(id: "gpu", online: true, paired: true, os: "linux", arch: "x64", connection: .init(kind: .iroh, path: .direct, rtt: 81.6)),
            MachineInfo(id: "laptop", online: false, paired: true, connection: .init(kind: .iroh, path: .relayed, rtt: 123)),
            MachineInfo(id: "worker", online: false, paired: false),
        ], eol: "\n")
        #expect(formattedList == [
            "gpu     paired   connected  linux/x64  iroh direct 82ms",
            "laptop  paired   offline",
            "worker  waiting  offline",
        ].joined(separator: "\n"))

        #expect(CLIMachine.formatMachineError(ForbiddenError(message: "disabled")).contains("OPENCODE_FLAGS=machines"))
        #expect(CLIMachine.formatMachineError(InvalidRequestError(message: "bad", kind: "invalid_name"), name: "Bad").contains("2 to 63"))
        #expect(CLIMachine.formatMachineError(MachineNotFoundError(machine: "x", message: "missing"), name: "x") == "No machine named \"x\".")
        let conflict = CLIMachine.formatMachineError(ConflictError(message: "paired", resource: "gpu"), name: "gpu")
        #expect(conflict.contains("--replace"))
        #expect(conflict.contains("stops being able to connect"))
    }

    @Test("Hidden login alias is omitted from root help and matches auth login help")
    func hiddenLoginAlias() async {
        let (rootCtx, rootBuf, _) = CLITestFixtures.makeContext()
        let rootCode = await CLIEntrypoint.run(arguments: ["--help"], context: rootCtx)
        #expect(rootCode == 0)
        #expect(rootBuf.stdout.contains("  auth"))
        #expect(!rootBuf.stdout.contains("  login "))
        #expect(rootBuf.stdout.contains("  machine"))

        let (loginCtx, loginBuf, _) = CLITestFixtures.makeContext()
        let loginCode = await CLIEntrypoint.run(arguments: ["login", "--help"], context: loginCtx)
        #expect(loginCode == 0)
        #expect(loginBuf.stdout.contains("opencode login [options] [target]"))
    }

    @Test("Default command shows help and validation error for missing directory or file path")
    func defaultCommandInvalidDirectory() async {
        let (missingCtx, missingBuf, _) = CLITestFixtures.makeContext(files: ["/work/file.txt": "hi"], cwd: "/work")
        let missingCode = await CLIEntrypoint.run(arguments: ["missing-directory-not-a-command"], context: missingCtx)
        #expect(missingCode == 1)
        #expect(missingBuf.stdout.contains("USAGE"))
        #expect(missingBuf.stderr.contains("No directory or command named \"missing-directory-not-a-command\""))

        let (fileCtx, fileBuf, _) = CLITestFixtures.makeContext(files: ["/work/file.txt": "hi"], cwd: "/work")
        let fileCode = await CLIEntrypoint.run(arguments: ["file.txt"], context: fileCtx)
        #expect(fileCode == 1)
        #expect(fileBuf.stderr.contains("No directory or command named \"file.txt\""))
    }

    @Test("ACP PermissionBridge.withCompletedDiffs skips execute tool calls")
    func acpWithCompletedDiffsSkipsExecute() async {
        let fs = InMemoryFileSystem(initialFiles: ["/work/a.txt": Array("hello\n".utf8)])
        let initial = CLIACP.SessionUpdate.toolCallUpdate(
            CLIACP.ToolCallUpdate(toolCallId: "tc_1", status: .completed)
        )
        let source = CLIACP.ToolMapper.DiffSource(
            toolName: "execute",
            input: [:],
            metadata: [
                "files": .array([
                    .object(["file": .string("a.txt"), "status": .string("added"), "patch": .string("")]),
                ]),
            ]
        )
        let result = await CLIACP.PermissionBridge.withCompletedDiffs(initial, source: source, cwd: "/work", fileSystem: fs)
        #expect(result == initial)
    }
}

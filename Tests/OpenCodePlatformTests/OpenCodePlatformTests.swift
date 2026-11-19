import Testing
import OpenCodePlatform

@Suite("OpenCodePlatform Cross-Platform Tests")
struct OpenCodePlatformTests {
    @Test("Platform capabilities match OS families")
    func platformCapabilities() {
        #expect(PlatformCapabilities.forOS(.macOS).supportsPTY)
        #expect(PlatformCapabilities.forOS(.linux).supportsPTY)
        #expect(PlatformCapabilities.forOS(.windows).supportsNamedPipes)
        #expect(PlatformCapabilities.forOS(.windows).supportsPTY)
        #expect(!PlatformCapabilities.forOS(.iOS).supportsSubprocesses)
        #expect(!PlatformCapabilities.forOS(.wasi).supportsSubprocesses)
        #expect(!PlatformCapabilities.forOS(.wasi).supportsLocalHTTPServer)
    }

    @Test("GlobalPaths resolves XDG roots on POSIX and respects overrides")
    func globalPathsPOSIX() {
        let env = DictionaryEnvironment(
            variables: ["XDG_CONFIG_HOME": "/custom/config"],
            homeDirectory: "/Users/alice",
            temporaryDirectory: "/var/tmp"
        )
        let roots = GlobalPaths.roots(app: "opencode", environment: env, os: .macOS)
        #expect(roots.data == "/Users/alice/.local/share/opencode")
        #expect(roots.cache == "/Users/alice/.cache/opencode")
        #expect(roots.config == "/custom/config/opencode")
        #expect(roots.state == "/Users/alice/.local/state/opencode")
        #expect(roots.tmp == "/var/tmp/opencode")
    }

    @Test("GlobalPaths falls back cleanly on WASI with no home directory")
    func globalPathsWASI() {
        let env = DictionaryEnvironment(
            variables: [:],
            homeDirectory: nil,
            temporaryDirectory: "/tmp"
        )
        let roots = GlobalPaths.roots(app: "opencode", environment: env, os: .wasi)
        #expect(roots.tmp == "/tmp/opencode")
        #expect(roots.data == "/tmp/opencode/opencode")
    }
}

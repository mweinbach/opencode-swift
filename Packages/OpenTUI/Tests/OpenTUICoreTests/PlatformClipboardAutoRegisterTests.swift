import OpenTUICore
import OpenTUITerminal
import Testing

@Suite("PlatformHostClipboard Auto-Registration", .serialized)
struct PlatformClipboardAutoRegisterTests {
    @Test("ensurePlatformHostClipboardRegistered and PlatformTerminalBackend.init register native OS clipboard backend")
    func autoRegistrationRegistersNativeBackendAndPreservesCustomFactory() throws {
        let previous = NativeHostClipboardBackendRegistry.currentFactory()
        defer { NativeHostClipboardBackendRegistry.register(previous) }

        // 1. Direct call to ensurePlatformHostClipboardRegistered() registers platform backend
        uninstallPlatformHostClipboard()
        #expect(NativeHostClipboardBackendRegistry.currentFactory() == nil)

        ensurePlatformHostClipboardRegistered()
        #expect(NativeHostClipboardBackendRegistry.currentFactory() != nil)

        let backend = try createNativeHostClipboardBackend(NormalizedHostClipboardOptions())
        #if os(macOS)
        #expect(backend is MacOSHostClipboardBackend)
        #elseif os(Linux) || os(FreeBSD) || os(Android)
        #expect(backend is LinuxHostClipboardBackend)
        #elseif os(Windows)
        #expect(backend is WindowsHostClipboardBackend)
        #else
        #expect(backend is InMemoryHostClipboardBackend)
        #endif

        // 2. PlatformTerminalBackend.init also auto-registers when registry is empty
        uninstallPlatformHostClipboard()
        #expect(NativeHostClipboardBackendRegistry.currentFactory() == nil)
        #if os(macOS) || os(Linux) || os(FreeBSD) || os(Android)
        _ = PlatformTerminalBackend(inputFD: -1, outputFD: -1)
        #else
        _ = PlatformTerminalBackend()
        #endif
        #expect(NativeHostClipboardBackendRegistry.currentFactory() != nil)

        // 3. Preserves an already-registered custom factory without clobbering it
        let custom = InMemoryHostClipboardBackend()
        installPlatformHostClipboard { _ in custom }
        ensurePlatformHostClipboardRegistered()
        let resolved = try createNativeHostClipboardBackend(NormalizedHostClipboardOptions())
        #expect((resolved as? InMemoryHostClipboardBackend) === custom)
    }
}

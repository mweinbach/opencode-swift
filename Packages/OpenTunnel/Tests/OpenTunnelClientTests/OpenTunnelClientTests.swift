import Testing
import OpenTunnelClient

@Suite("OpenTunnelClient Module")
struct OpenTunnelClientModuleTests {
    @Test("module version is defined")
    func versionDefined() {
        #expect(!OpenTunnelClientModule.version.isEmpty)
    }
}

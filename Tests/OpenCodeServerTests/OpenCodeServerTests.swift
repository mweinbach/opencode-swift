import Testing
import OpenCodeServer

@Suite("OpenCodeServer Module Tests")
struct OpenCodeServerPlaceholderTests {
    @Test("OpenCodeServer module metadata")
    func moduleMetadata() {
        #expect(OpenCodeServerModule.upstreamPackage == "server")
    }
}

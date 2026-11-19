import Testing
import OpenCodeCore

@Suite("OpenCodeCore Module Tests")
struct OpenCodeCorePlaceholderTests {
    @Test("OpenCodeCore module metadata")
    func moduleMetadata() {
        #expect(OpenCodeCoreModule.upstreamPackage == "core")
    }
}

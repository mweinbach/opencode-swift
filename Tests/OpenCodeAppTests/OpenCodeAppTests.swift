import Testing
import OpenCodeApp

@Suite("OpenCodeApp Module")
struct OpenCodeAppModuleTests {
    @Test("module metadata")
    func metadata() {
        #expect(OpenCodeAppModule.name == "OpenCode")
    }
}

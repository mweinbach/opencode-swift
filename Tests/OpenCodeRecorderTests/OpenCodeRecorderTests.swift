import Testing
import OpenCodeRecorder

@Suite("OpenCodeRecorder Module")
struct OpenCodeRecorderModuleTests {
    @Test("module metadata")
    func metadata() {
        #expect(OpenCodeRecorderModule.upstreamPackage == "http-recorder")
    }
}

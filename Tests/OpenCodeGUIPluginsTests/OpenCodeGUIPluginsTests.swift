import Testing
import OpenCodeGUIPlugins

@Suite("OpenCodeGUIPlugins Module")
struct OpenCodeGUIPluginsModuleTests {
    @Test("module metadata")
    func metadata() {
        #expect(OpenCodeGUIPluginsModule.upstreamPackage == "gui-plugins")
    }
}

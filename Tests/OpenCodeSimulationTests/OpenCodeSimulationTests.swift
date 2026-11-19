import Testing
import OpenCodeSimulation

@Suite("OpenCodeSimulation Module")
struct OpenCodeSimulationModuleTests {
    @Test("module metadata")
    func metadata() {
        #expect(OpenCodeSimulationModule.upstreamPackage == "simulation")
    }
}

import Testing
import OpenCodeGUIPlugins

@Suite("OpenCodeGUIPlugins Module & Registry")
struct OpenCodeGUIPluginsModuleTests {
    @Test("module metadata matches upstream gui-plugins package")
    func metadata() {
        #expect(OpenCodeGUIPluginsModule.upstreamPackage == "gui-plugins")
    }

    @Test("default registry contains all 15 upstream built-in GUI plugins")
    func builtInRegistryInventory() {
        let registry = GUIPluginRegistry.default
        #expect(registry.plugins.count == 15)

        for id in GUIPluginID.allCases {
            let descriptor = registry.plugin(id)
            #expect(descriptor != nil)
            #expect(descriptor?.id == id.rawValue)
            #expect(registry.isBuiltIn(id.rawValue))
        }
    }

    @Test("OS eligibility filters Windows-only WSL plugin accurately")
    func osEligibilityFiltering() {
        let registry = GUIPluginRegistry.default
        let wsl = registry.plugin(.wsl)
        #expect(wsl?.runsOn(.windows) == true)
        #expect(wsl?.runsOn(.macos) == false)
        #expect(wsl?.runsOn(.linux) == false)

        let macPlugins = registry.available(on: .macos)
        let winPlugins = registry.available(on: .windows)
        #expect(macPlugins.count == 14)
        #expect(winPlugins.count == 15)
        #expect(!macPlugins.contains { $0.id == "wsl" })
        #expect(winPlugins.contains { $0.id == "wsl" })
    }

    @Test("IPC and contract reverse lookups locate owning plugins")
    func ipcAndContractLookups() {
        let registry = GUIPluginRegistry.default
        #expect(registry.plugin(forIPC: "ssh")?.id == "ssh")
        #expect(registry.plugin(forIPC: "wsl")?.id == "wsl")
        #expect(registry.plugin(forIPC: "pairing")?.id == "pairing")
        #expect(registry.plugin(forIPC: "updater")?.id == "updater")
        #expect(registry.plugin(forIPC: "debug.heap")?.id == "debug")
        #expect(registry.plugin(forIPC: "debug.memory")?.id == "debug")
        #expect(registry.plugin(forIPC: "unknown") == nil)

        #expect(registry.plugin(forContract: "review.details")?.id == "review")
        #expect(registry.plugin(forContract: "unknown") == nil)

        let macMainIDs = Set(registry.mainPlugins(on: .macos).map(\.id))
        #expect(macMainIDs == ["debug", "browser", "pairing", "updater", "ssh"])
        let winMainIDs = Set(registry.mainPlugins(on: .windows).map(\.id))
        #expect(winMainIDs == ["debug", "browser", "pairing", "updater", "ssh", "wsl"])
    }

    @Test("custom plugin registration appends and replaces by id")
    func customRegistration() {
        var registry = GUIPluginRegistry.default
        let custom = GUIPluginDescriptor(
            id: "acme.lint",
            displayName: "Acme Lint",
            summary: "Custom lint annotations",
            supportedOS: [.macos, .linux],
            hasMainEntry: false,
            hasWindowEntry: true,
            ipcIDs: ["acme.lint"]
        )
        registry.register(custom)
        #expect(registry.plugins.count == 16)
        #expect(!registry.isBuiltIn("acme.lint"))
        #expect(registry.plugin(id: "acme.lint") == custom)
        #expect(registry.plugin(forIPC: "acme.lint")?.id == "acme.lint")

        let updated = GUIPluginDescriptor(
            id: "acme.lint",
            displayName: "Acme Lint v2",
            summary: "Updated summary"
        )
        registry.register(updated)
        #expect(registry.plugins.count == 16)
        #expect(registry.plugin(id: "acme.lint")?.displayName == "Acme Lint v2")
    }

    @Test("FIFO dispatcher queues re-entrant events and translates throwing effects")
    func fifoDispatcherBehavior() {
        enum SampleEvent: Equatable, Sendable {
            case start
            case triggerFail
            case reentrant
            case recovered
        }
        enum SampleEffect: Equatable, Sendable {
            case emitReentrant
            case explode
        }
        struct SampleError: Error {}

        var statesSeen: [Int] = []
        var dispatcherRef: GUIStateMachineDispatcher<Int, SampleEvent, SampleEffect>?
        let dispatcher = GUIStateMachineDispatcher<Int, SampleEvent, SampleEffect>(
            initialState: 0,
            reduce: { state, event in
                switch event {
                case .start:
                    return GUIStateTransition(state: state + 1, effects: [.emitReentrant])
                case .triggerFail:
                    return GUIStateTransition(state: state + 10, effects: [.explode])
                case .reentrant:
                    return GUIStateTransition(state: state + 100)
                case .recovered:
                    return GUIStateTransition(state: state + 1000)
                }
            },
            onStateChange: { statesSeen.append($0) },
            runEffect: { effect in
                switch effect {
                case .emitReentrant:
                    dispatcherRef?.dispatch(.reentrant)
                case .explode:
                    throw SampleError()
                }
            },
            onEffectFailure: { effect in
                effect == .explode ? .recovered : nil
            }
        )
        dispatcherRef = dispatcher

        dispatcher.dispatch(.start)
        #expect(dispatcher.state == 101)
        #expect(statesSeen == [1, 101])

        dispatcher.dispatch(.triggerFail)
        #expect(dispatcher.state == 1111)
        #expect(statesSeen == [1, 101, 111, 1111])
    }
}

import Testing
import OpenTUIKeymap

// MARK: - Test Support Helpers (Pure Swift, Zero Foundation)

private final class ValueBox<T: Sendable>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private enum TestFailure: Error, Sendable, KeymapDescribedError {
    case boom(String)
    var errorMessage: String {
        switch self {
        case .boom(let msg): return msg
        }
    }
}

private final class MockRenderable: OpenTUIRenderableLike, @unchecked Sendable {
    let id: String
    weak var parentRenderable: MockRenderable?
    var isDestroyed: Bool = false
    var focused: Bool = false
    private var nextID: Int = 0
    private var destroyListeners: [(Int, @Sendable () -> Void)] = []

    init(id: String) {
        self.id = id
    }

    static func == (lhs: MockRenderable, rhs: MockRenderable) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    func onDestroyed(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let token = nextID
        nextID += 1
        destroyListeners.append((token, listener))
        return { [weak self] in self?.destroyListeners.removeAll { $0.0 == token } }
    }

    func destroy() {
        isDestroyed = true
        focused = false
        let current = destroyListeners
        destroyListeners.removeAll()
        for (_, fn) in current { fn() }
    }
}

private final class MockEditBuffer: EditBufferBindable, @unchecked Sendable {
    var isDestroyed: Bool = false
    var isManagedTextarea: Bool
    var isKeymapSuspended: Bool = false
    var actions: [String] = []

    init(isManagedTextarea: Bool = true) {
        self.isManagedTextarea = isManagedTextarea
    }

    private func record(_ name: String) -> Bool {
        actions.append(name)
        return true
    }

    func moveCursorLeft(select: Bool) -> Bool { record(select ? "select-left" : "move-left") }
    func moveCursorRight(select: Bool) -> Bool { record(select ? "select-right" : "move-right") }
    func moveCursorUp(select: Bool) -> Bool { record(select ? "select-up" : "move-up") }
    func moveCursorDown(select: Bool) -> Bool { record(select ? "select-down" : "move-down") }
    func gotoLineHome(select: Bool) -> Bool { record(select ? "select-line-home" : "line-home") }
    func gotoLineEnd(select: Bool) -> Bool { record(select ? "select-line-end" : "line-end") }
    func gotoVisualLineHome(select: Bool) -> Bool { record(select ? "select-visual-line-home" : "visual-line-home") }
    func gotoVisualLineEnd(select: Bool) -> Bool { record(select ? "select-visual-line-end" : "visual-line-end") }
    func gotoBufferHome(select: Bool) -> Bool { record(select ? "select-buffer-home" : "buffer-home") }
    func gotoBufferEnd(select: Bool) -> Bool { record(select ? "select-buffer-end" : "buffer-end") }
    func deleteLine() -> Bool { record("delete-line") }
    func deleteToLineEnd() -> Bool { record("delete-to-line-end") }
    func deleteToLineStart() -> Bool { record("delete-to-line-start") }
    func deleteCharBackward() -> Bool { record("backspace") }
    func deleteChar() -> Bool { record("delete") }
    func newLine() -> Bool { record("newline") }
    func undo() -> Bool { record("undo") }
    func redo() -> Bool { record("redo") }
    func moveWordForward(select: Bool) -> Bool { record(select ? "select-word-forward" : "word-forward") }
    func moveWordBackward(select: Bool) -> Bool { record(select ? "select-word-backward" : "word-backward") }
    func deleteWordForward() -> Bool { record("delete-word-forward") }
    func deleteWordBackward() -> Bool { record("delete-word-backward") }
    func selectAll() -> Bool { record("select-all") }
    func submit() -> Bool { record("submit") }
}

private final class MockOpenTUIRenderer: OpenTUIRendererLike, @unchecked Sendable {
    typealias Renderable = MockRenderable
    typealias Event = OpenTUIKeyEventAdapter

    let root = MockRenderable(id: "root")
    var isDestroyed: Bool = false
    var platform: HostPlatform
    var hasKittyKeyboard: Bool
    var currentFocusedRenderable: MockRenderable? = nil
    var currentFocusedEditor: (any EditBufferBindable)? = nil

    private var nextID: Int = 0
    private var keyPressListeners: [(Int, @Sendable (OpenTUIKeyEventAdapter) -> Void)] = []
    private var keyReleaseListeners: [(Int, @Sendable (OpenTUIKeyEventAdapter) -> Void)] = []
    private var focusListeners: [(Int, @Sendable (MockRenderable?) -> Void)] = []
    private var editorListeners: [(Int, @Sendable ((any EditBufferBindable)?, (any EditBufferBindable)?) -> Void)] = []
    private var destroyListeners: [(Int, @Sendable () -> Void)] = []
    private var rawListeners: [(Int, @Sendable (String) -> Bool)] = []

    init(platform: HostPlatform = .macos, hasKittyKeyboard: Bool = true) {
        self.platform = platform
        self.hasKittyKeyboard = hasKittyKeyboard
    }

    func focus(_ renderable: MockRenderable?) {
        currentFocusedRenderable?.focused = false
        currentFocusedRenderable = renderable
        renderable?.focused = true
        for (_, fn) in focusListeners { fn(renderable) }
    }

    func focusEditor(_ editor: (any EditBufferBindable)?) {
        let prev = currentFocusedEditor
        currentFocusedEditor = editor
        for (_, fn) in editorListeners { fn(editor, prev) }
    }

    func press(_ event: OpenTUIKeyEventAdapter) {
        for (_, fn) in keyPressListeners { fn(event) }
    }

    func release(_ event: OpenTUIKeyEventAdapter) {
        for (_, fn) in keyReleaseListeners { fn(event) }
    }

    func destroy() {
        isDestroyed = true
        let list = destroyListeners
        destroyListeners.removeAll()
        for (_, fn) in list { fn() }
    }

    func onKeyPress(_ listener: @escaping @Sendable (OpenTUIKeyEventAdapter) -> Void) -> @Sendable () -> Void {
        let id = nextID; nextID += 1
        keyPressListeners.append((id, listener))
        return { [weak self] in self?.keyPressListeners.removeAll { $0.0 == id } }
    }

    func onKeyRelease(_ listener: @escaping @Sendable (OpenTUIKeyEventAdapter) -> Void) -> @Sendable () -> Void {
        let id = nextID; nextID += 1
        keyReleaseListeners.append((id, listener))
        return { [weak self] in self?.keyReleaseListeners.removeAll { $0.0 == id } }
    }

    func onFocusChange(_ listener: @escaping @Sendable (MockRenderable?) -> Void) -> @Sendable () -> Void {
        let id = nextID; nextID += 1
        focusListeners.append((id, listener))
        return { [weak self] in self?.focusListeners.removeAll { $0.0 == id } }
    }

    func onFocusedEditorChange(
        _ listener: @escaping @Sendable ((any EditBufferBindable)?, (any EditBufferBindable)?) -> Void
    ) -> @Sendable () -> Void {
        let id = nextID; nextID += 1
        editorListeners.append((id, listener))
        return { [weak self] in self?.editorListeners.removeAll { $0.0 == id } }
    }

    func onDestroy(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = nextID; nextID += 1
        destroyListeners.append((id, listener))
        return { [weak self] in self?.destroyListeners.removeAll { $0.0 == id } }
    }

    func onRawInput(_ listener: @escaping @Sendable (String) -> Bool) -> @Sendable () -> Void {
        let id = nextID; nextID += 1
        rawListeners.append((id, listener))
        return { [weak self] in self?.rawListeners.removeAll { $0.0 == id } }
    }

    func createCommandEvent() -> OpenTUIKeyEventAdapter {
        OpenTUIKeyEventAdapter(name: "command")
    }
}

private func makeKeymap(
    platform: HostPlatform = .macos,
    primaryModifier: HostPrimaryModifier = .super,
    modifiers: [HostModifier: HostCapability] = [
        .ctrl: .supported,
        .shift: .supported,
        .meta: .supported,
        .super: .supported,
        .hyper: .supported,
    ]
) throws -> (InMemoryKeymapHost<String, BasicKeymapEvent>, Keymap<InMemoryKeymapHost<String, BasicKeymapEvent>>) {
    let host = InMemoryKeymapHost<String, BasicKeymapEvent>(rootTarget: "root", focusedTarget: "root")
    let meta = HostMetadata(platform: platform, primaryModifier: primaryModifier, modifiers: modifiers)
    let keymap = try Keymap(host: host, metadata: meta)
    return (host, keymap)
}

// MARK: - 1. KeymapLib Tests

@Suite("OpenTUIKeymap Lib & Services")
struct KeymapLibAndServicesTests {
    @Test("Emitter hook, on, once, off, clear, listenerCount, and error routing")
    func emitterLifecycle() {
        let errors = ValueBox<[String]>([])
        let received = ValueBox<[String]>([])
        let emitter = createRuntimeEmitter(
            onError: { (event: String, err: any Error) in
                errors.value.append("\(event):\(getErrorMessage(err, fallback: "unknown"))")
            }
        ) as Emitter<String, String>

        #expect(!emitter.has("ping"))
        #expect(emitter.listenerCount("ping") == 0)

        let offHook = emitter.hook("ping") { value in
            received.value.append("hook:\(value)")
        }
        let token = emitter.on("ping") { value in
            received.value.append("on:\(value)")
        }
        _ = emitter.once("ping") { value in
            received.value.append("once:\(value)")
        }
        _ = emitter.hook("ping") { _ in
            throw TestFailure.boom("listener-failed")
        }

        #expect(emitter.has("ping"))
        #expect(emitter.listenerCount("ping") == 4)

        emitter.emit("ping", "one")
        #expect(received.value == ["hook:one", "on:one", "once:one"])
        #expect(errors.value == ["ping:listener-failed"])
        #expect(emitter.listenerCount("ping") == 3)

        emitter.off("ping", token: token)
        offHook()
        emitter.emit("ping", "two")
        #expect(received.value == ["hook:one", "on:one", "once:one"])
        #expect(errors.value.count == 2)

        emitter.clear()
        #expect(!emitter.has("ping"))
        #expect(emitter.listenerCount("ping") == 0)
    }

    @Test("OrderedRegistry and PriorityRegistry runtime helpers")
    func registries() {
        let ordered = createRuntimeOrderedRegistry(["b"])
        let offPrepend = ordered.prepend("a")
        _ = ordered.append(contentsOf: ["c", "d"])
        #expect(ordered.values() == ["a", "b", "c", "d"])
        #expect(ordered.values(where: { $0 >= "b" }) == ["b", "c", "d"])

        offPrepend()
        #expect(ordered.values() == ["b", "c", "d"])

        #expect(ordered.remove("c"))
        #expect(!ordered.remove("z"))
        #expect(ordered.values() == ["b", "d"])
        ordered.clear()
        #expect(!ordered.has())

        let prio: PriorityRegistry<String, Void> = createRuntimePriorityRegistry()
        _ = prio.register("low", priority: 1)
        _ = prio.register("high1", priority: 10)
        _ = prio.register("high2", priority: 10)
        _ = prio.register("mid", priority: 5)
        #expect(prio.has())
        #expect(prio.registrations().map(\.listener) == ["high1", "high2", "mid", "low"])
    }

    @Test("createKeymapState and createNotificationService batching, warnOnce, and loop guard")
    func stateAndNotificationService() {
        let state: State<String, BasicKeymapEvent> = createKeymapState()
        let diagEmitter = Emitter<DiagnosticChannel, DiagnosticPayload>()
        let hookEmitter = Emitter<HookName, Hooks<String, BasicKeymapEvent>>()
        let notify = createNotificationService(state: state, events: diagEmitter, hooks: hookEmitter)

        let stateTicks = ValueBox(0)
        let beforeTicks = ValueBox(0)
        let warnings = ValueBox<[WarningEvent]>([])
        let errors = ValueBox<[ErrorEvent]>([])

        notify.onStateEvent { beforeTicks.value += 1 }
        _ = hookEmitter.hook(.state) { _ in stateTicks.value += 1 }
        _ = diagEmitter.hook(.warning) { payload in
            if case .warning(let w) = payload { warnings.value.append(w) }
        }
        _ = diagEmitter.hook(.error) { payload in
            if case .error(let e) = payload { errors.value.append(e) }
        }

        notify.runWithStateChangeBatch {
            notify.queueStateChange()
            notify.queueStateChange()
            #expect(stateTicks.value == 0)
        }
        #expect(beforeTicks.value == 1)
        #expect(stateTicks.value == 1)
        #expect(state.derivedVersion == 2)
        #expect(state.cacheVersion == 2)

        notify.warnOnce(key: "k1", code: "dup", message: "first")
        notify.warnOnce(key: "k1", code: "dup", message: "second")
        #expect(warnings.value.count == 1)

        notify.reportListenerError(.dispatch, error: TestFailure.boom("oops"))
        #expect(errors.value.last?.code == "dispatch-listener-error")
        #expect(MAX_STATE_CHANGE_FLUSH_ITERATIONS == 1000)

        // Feedback loop guard
        let loopHook = hookEmitter.hook(.state) { _ in
            notify.queueStateChange()
        }
        notify.queueStateChange()
        loopHook()
        #expect(errors.value.contains { $0.code == "state-change-feedback-loop" })
    }

    @Test("createLayerSlot preserves mount order and replaces layers cleanly")
    func layerSlotOrdering() throws {
        let (_, keymap) = try makeKeymap()
        let hits = ValueBox<[String]>([])

        let slotA = createLayerSlot(keymap)
        let slotB = createLayerSlot(keymap)

        _ = slotA(Layer(bindings: [Binding(key: "a", cmd: .handler { _ in hits.value.append("A1"); return true })]))
        _ = slotB(Layer(bindings: [Binding(key: "a", cmd: .handler { _ in hits.value.append("B1"); return true })]))

        // slotB was created after slotA so it wins by order
        keymap.handleKeyPress(BasicKeymapEvent(name: "a"))
        #expect(hits.value == ["B1"])

        // Replacing slotA keeps its original lower order so slotB still wins
        _ = slotA(Layer(bindings: [Binding(key: "a", cmd: .handler { _ in hits.value.append("A2"); return true })]))
        keymap.handleKeyPress(BasicKeymapEvent(name: "a"))
        #expect(hits.value == ["B1", "B1"])

        // Clearing slotB reveals slotA's updated binding
        _ = slotB(nil)
        keymap.handleKeyPress(BasicKeymapEvent(name: "a"))
        #expect(hits.value == ["B1", "B1", "A2"])

        #expect(runtimeModules.count == 9)
        #expect(runtimeModules["@opentui/keymap/extras/graph"]?.lazy == false)
        #expect(runtimeModules["@opentui/keymap/react"]?.lazy == true)
    }
}

// MARK: - 2. Universal Addons Tests

@Suite("OpenTUIKeymap Universal Addons")
struct KeymapUniversalAddonsTests {
    @Test("registerDefaultKeys, registerLeader, escapeClears, and backspacePops")
    func leaderEscapeAndBackspace() throws {
        let (_, keymap) = try makeKeymap()
        keymap.clearBindingParsers()
        keymap.clearEventMatchResolvers()
        let offDefault = registerDefaultKeys(keymap)
        let offLeader = try registerLeader(keymap, options: LeaderOptions(trigger: "space"))
        let offEsc = registerEscapeClearsPendingSequence(keymap)
        let offBs = registerBackspacePopsPendingSequence(keymap)

        let ran = ValueBox(0)
        _ = keymap.registerLayer(
            Layer(bindings: [
                Binding(key: "<leader>fg", cmd: .handler { _ in ran.value += 1; return true })
            ])
        )

        // Start <leader> f, then backspace back to <leader>, then press f g
        keymap.handleKeyPress(BasicKeymapEvent(name: "space"))
        keymap.handleKeyPress(BasicKeymapEvent(name: "f"))
        #expect(keymap.getPendingSequence().count == 2)

        let bsEvent = BasicKeymapEvent(name: "backspace")
        keymap.handleKeyPress(bsEvent)
        #expect(bsEvent.defaultPrevented)
        #expect(keymap.getPendingSequence().count == 1)

        // Escape clears pending sequence
        let escEvent = BasicKeymapEvent(name: "escape")
        keymap.handleKeyPress(escEvent)
        #expect(escEvent.defaultPrevented)
        #expect(!keymap.hasPendingSequence())

        // Escape when idle does NOT consume
        let idleEsc = BasicKeymapEvent(name: "escape")
        keymap.handleKeyPress(idleEsc)
        #expect(!idleEsc.defaultPrevented)

        // Full leader sequence executes
        keymap.handleKeyPress(BasicKeymapEvent(name: "space"))
        keymap.handleKeyPress(BasicKeymapEvent(name: "f"))
        keymap.handleKeyPress(BasicKeymapEvent(name: "g"))
        #expect(ran.value == 1)

        // Leader trigger validation
        #expect(try resolveLeaderTrigger(.bindings([])) == nil)
        #expect(throws: KeymapAddonError.self) {
            _ = try resolveLeaderTrigger(.bindings([LeaderBindingTrigger(key: "a"), LeaderBindingTrigger(key: "b")]))
        }

        offBs()
        offEsc()
        offLeader()
        offDefault()
    }

    @Test("registerTimedLeader arms, disarms, and times out pending leader sequence")
    func timedLeaderTimeout() async throws {
        let (_, keymap) = try makeKeymap()
        let arms = ValueBox(0)
        let disarms = ValueBox(0)

        let off = try registerTimedLeader(
            keymap,
            options: TimedLeaderOptions(
                trigger: .stroke(KeyStrokeInput(name: "x", ctrl: true)),
                timeoutMs: 30,
                onArm: { arms.value += 1 },
                onDisarm: { disarms.value += 1 }
            )
        )

        _ = keymap.registerLayer(
            Layer(bindings: [Binding(key: "<leader>s", cmd: .handler { _ in true })])
        )

        keymap.handleKeyPress(BasicKeymapEvent(name: "x", ctrl: true))
        #expect(arms.value == 1)
        #expect(keymap.hasPendingSequence())

        for _ in 0..<200 where keymap.hasPendingSequence() || disarms.value < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!keymap.hasPendingSequence())
        #expect(disarms.value == 1)

        off()
    }

    @Test("registerNeovimDisambiguation defers exact-vs-prefix and resolves on timeout or continuation")
    func neovimDisambiguation() async throws {
        let (_, keymap) = try makeKeymap()
        let off = registerNeovimDisambiguation(keymap, options: NeovimDisambiguationOptions(timeoutMs: 35))
        let calls = ValueBox<[String]>([])

        _ = keymap.registerLayer(
            Layer(bindings: [
                Binding(key: "g", cmd: .handler { _ in calls.value.append("exact-g"); return true }),
                Binding(key: "gg", cmd: .handler { _ in calls.value.append("prefix-gg"); return true }),
            ])
        )

        // Fast continuation picks "gg"
        keymap.handleKeyPress(BasicKeymapEvent(name: "g"))
        keymap.handleKeyPress(BasicKeymapEvent(name: "g"))
        #expect(calls.value == ["prefix-gg"])

        // Single press times out and runs exact "g"
        keymap.handleKeyPress(BasicKeymapEvent(name: "g"))
        #expect(calls.value == ["prefix-gg"])
        for _ in 0..<200 where calls.value.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(calls.value == ["prefix-gg", "exact-g"])

        off()
    }

    @Test("registerAliasesField remaps single-key bindings within layer")
    func aliasesAddon() throws {
        let (_, keymap) = try makeKeymap()
        let off = try registerAliasesField(keymap)
        let hits = ValueBox(0)

        _ = keymap.registerLayer(
            Layer(
                bindings: [Binding(key: "ctrl+enter", cmd: .handler { _ in hits.value += 1; return true })],
                fields: ["aliases": .object(["enter": .string("return")])]
            )
        )

        keymap.handleKeyPress(BasicKeymapEvent(name: "enter", ctrl: true))
        keymap.handleKeyPress(BasicKeymapEvent(name: "return", ctrl: true))
        #expect(hits.value == 2)
        off()
    }

    @Test("registerExCommands parses arguments, aliases, and nargs validation")
    func exCommandsAddon() throws {
        let (_, keymap) = try makeKeymap()
        let off = try registerExCommands(keymap)
        let captured = ValueBox<[ExCommandPayload]>([])

        let editCmd = ExCommand<String, BasicKeymapEvent>(
            name: "edit",
            aliases: ["e"],
            nargs: .one
        ) { _, payload in
            captured.value.append(payload)
            return true
        }

        _ = keymap.registerLayer(Layer(commands: [editCmd.toCommand()]))

        let okResult = keymap.runCommand(":e main.swift")
        #expect(okResult.ok)
        #expect(captured.value.count == 1)
        #expect(captured.value[0].raw == ":e main.swift")
        #expect(captured.value[0].args == ["main.swift"])

        let badArgs = keymap.runCommand(":edit")
        #expect(!badArgs.ok)
        #expect(captured.value.count == 1)

        let okFull = keymap.runCommand(":edit foo.swift")
        #expect(okFull.ok)
        #expect(captured.value.count == 2)
        off()
    }

    @Test("registerBindingOverrides replaces command bindings in a layer")
    func bindingOverridesAddon() throws {
        let (_, keymap) = try makeKeymap()
        let off = try registerBindingOverrides(keymap)
        let log = ValueBox<[String]>([])

        let overrideBinding = Binding<String, BasicKeymapEvent>(key: "ctrl+w", commandName: "save")
        _ = keymap.registerLayer(
            Layer(
                bindings: [
                    Binding(key: "ctrl+s", commandName: "save"),
                    Binding(key: "ctrl+q", commandName: "quit"),
                ],
                commands: [
                    Command(name: "save") { _ in log.value.append("save"); return true },
                    Command(name: "quit") { _ in log.value.append("quit"); return true },
                ],
                fields: ["bindingOverrides": .array([overrideBinding.toOverrideValue()])]
            )
        )

        // Old ctrl+s was replaced by ctrl+w
        keymap.handleKeyPress(BasicKeymapEvent(name: "s", ctrl: true))
        #expect(log.value.isEmpty)

        keymap.handleKeyPress(BasicKeymapEvent(name: "w", ctrl: true))
        keymap.handleKeyPress(BasicKeymapEvent(name: "q", ctrl: true))
        #expect(log.value == ["save", "quit"])
        off()
    }

    @Test("registerCommaBindings, registerEmacsBindings, and registerModBindings")
    func commaEmacsAndModAddons() throws {
        // macOS host: mod -> super
        let (_, macKeymap) = try makeKeymap(platform: .macos, primaryModifier: .super)
        let offComma = try registerCommaBindings(macKeymap)
        let offMod = try registerModBindings(macKeymap)
        let offEmacs = try registerEmacsBindings(macKeymap)

        let events = ValueBox<[String]>([])
        _ = macKeymap.registerLayer(
            Layer(bindings: [
                Binding(key: "mod+s, ctrl+w", cmd: .handler { _ in events.value.append("save"); return true }),
                Binding(key: "C-x C-f", cmd: .handler { _ in events.value.append("find-file"); return true }),
                Binding(key: "M-x", cmd: .handler { _ in events.value.append("execute"); return true }),
                Binding(key: "ctrl+c ctrl+k", cmd: .handler { _ in events.value.append("kill"); return true }),
            ])
        )

        macKeymap.handleKeyPress(BasicKeymapEvent(name: "s", super: true))
        macKeymap.handleKeyPress(BasicKeymapEvent(name: "w", ctrl: true))
        macKeymap.handleKeyPress(BasicKeymapEvent(name: "x", ctrl: true))
        macKeymap.handleKeyPress(BasicKeymapEvent(name: "f", ctrl: true))
        macKeymap.handleKeyPress(BasicKeymapEvent(name: "x", meta: true))
        macKeymap.handleKeyPress(BasicKeymapEvent(name: "c", ctrl: true))
        macKeymap.handleKeyPress(BasicKeymapEvent(name: "k", ctrl: true))
        #expect(events.value == ["save", "save", "find-file", "execute", "kill"])

        offEmacs()
        offMod()
        offComma()

        // Linux host: mod -> ctrl
        let (_, linuxKeymap) = try makeKeymap(platform: .linux, primaryModifier: .ctrl)
        _ = try registerModBindings(linuxKeymap)
        let saved = ValueBox(0)
        _ = linuxKeymap.registerLayer(
            Layer(bindings: [Binding(key: "mod+s", cmd: .handler { _ in saved.value += 1; return true })])
        )
        linuxKeymap.handleKeyPress(BasicKeymapEvent(name: "s", ctrl: true))
        #expect(saved.value == 1)
    }

    @Test("registerEnabledFields, registerMetadataFields, deadBindings, and unresolvedCommands")
    func enabledMetadataAndDiagnosticsAddons() throws {
        let (_, keymap) = try makeKeymap()
        let registry = EnabledConditionRegistry()
        let offEnabled = try registerEnabledFields(keymap, registry: registry)
        let offMeta = try registerMetadataFields(keymap)
        let offDead = try registerDeadBindingWarnings(keymap)
        let offUnresolved = try registerUnresolvedCommandWarnings(keymap)

        let warnings = ValueBox<[KeymapDiagnosticEvent]>([])
        _ = keymap.on(.warning { warnings.value.append($0) })

        let dynamicFlag = ValueBox(false)
        let dynHandle = registry.register(.predicate { dynamicFlag.value })
        let hits = ValueBox<[String]>([])

        _ = keymap.registerLayer(
            Layer(
                bindings: [
                    Binding(
                        key: "a",
                        commandName: "cmd.live",
                        fields: ["desc": .string("Run live"), "group": .string("General")]
                    ),
                    Binding(key: "b", commandName: "cmd.missing"),
                    Binding(key: "z", cmd: nil, fields: ["desc": .string("Dead metadata binding")]),
                    Binding(key: "d", cmd: .handler { _ in hits.value.append("dyn"); return true }, fields: ["enabled": dynHandle]),
                ],
                commands: [
                    Command(
                        name: "cmd.live",
                        fields: ["desc": .string("Live command"), "title": .string("Live"), "category": .string("App")]
                    ) { _ in
                        hits.value.append("live")
                        return true
                    }
                ]
            )
        )

        // Disabled layer should not trigger
        _ = keymap.registerLayer(
            Layer(
                bindings: [Binding(key: "x", cmd: .handler { _ in hits.value.append("disabled"); return true })],
                fields: ["enabled": .bool(false)]
            )
        )

        keymap.handleKeyPress(BasicKeymapEvent(name: "a"))
        keymap.handleKeyPress(BasicKeymapEvent(name: "x"))
        keymap.handleKeyPress(BasicKeymapEvent(name: "d"))
        #expect(hits.value == ["live"])

        // Toggle dynamic enabled predicate
        dynamicFlag.value = true
        keymap.handleKeyPress(BasicKeymapEvent(name: "d"))
        #expect(hits.value == ["live", "dyn"])

        // Metadata attrs materialized in active keys
        let activeKeys = keymap.getActiveKeys(ActiveKeyOptions(includeBindings: true, includeMetadata: true))
        let aKey = activeKeys.first { $0.stroke.name == "a" }
        #expect(aKey?.bindingAttrs?["desc"] == .string("Run live"))
        #expect(aKey?.bindingAttrs?["group"] == .string("General"))
        #expect(aKey?.commandAttrs?["title"] == .string("Live"))
        #expect(aKey?.commandAttrs?["category"] == .string("App"))

        // Diagnostics warnings emitted
        #expect(warnings.value.contains { $0.code == "dead-binding" })
        #expect(warnings.value.contains { $0.code == "unresolved-command" && $0.detail == "cmd.missing" })

        registry.unregister(dynHandle)
        offUnresolved()
        offDead()
        offMeta()
        offEnabled()
    }
}

// MARK: - 3. KeymapExtras Tests

@Suite("OpenTUIKeymap Extras")
struct KeymapExtrasTests {
    @Test("createBindingLookup supports commandMap, bindingDefaults, gather, pick, omit, and update")
    func bindingLookupOperations() throws {
        let lookup: DefaultBindingLookup<String, BasicKeymapEvent> = try createBindingLookup(
            [
                "save": "ctrl+s",
                "quit": ["ctrl+q", "ctrl+c"],
                "disabled": .none,
                "legacy": "ctrl+l",
            ],
            options: CreateBindingLookupOptions(
                commandMap: ["legacy": "modern"],
                bindingDefaults: { ctx in
                    ["source": .string("defaults:\(ctx.command)")]
                }
            )
        )

        #expect(lookup.has("save"))
        #expect(lookup.has("modern"))
        #expect(!lookup.has("legacy"))
        #expect(!lookup.has("disabled"))
        #expect(lookup.get("quit").count == 2)
        #expect(lookup.get("save").first?.fields["source"] == .string("defaults:save"))

        let group = lookup.gather("file", commands: ["save", "quit", "modern"])
        #expect(group.count == 4)
        #expect(lookup.pick("file", commands: ["save"]).count == 1)
        #expect(lookup.omit("file", commands: ["quit"]).count == 2)

        try lookup.update(["save": "super+s"])
        #expect(lookup.get("save").first?.key == .string("super+s"))
        #expect(!lookup.has("quit"))
    }

    @Test("commandBindings normalizes entries and emits override warnings and invalid stroke errors")
    func commandBindingsHelper() {
        let warnings = ValueBox<[CommandBindingsOverrideWarning]>([])
        let errors = ValueBox<[CommandBindingsError]>([])

        let bindings: [Binding<String, BasicKeymapEvent>] = commandBindings(
            [
                (" save ", .string("ctrl+s")),
                ("save", .string("super+s")),
                ("bad", .stroke(KeyStrokeInput(name: "   "))),
            ],
            options: CommandBindingsOptions(
                onWarning: { warnings.value.append($0) },
                onError: { errors.value.append($0) }
            )
        )

        #expect(bindings.count == 1)
        #expect(bindings[0].cmd?.commandName == "save")
        #expect(bindings[0].key == .string("super+s"))
        #expect(warnings.value.count == 1)
        #expect(warnings.value[0].previousKey == .string("ctrl+s"))
        #expect(warnings.value[0].nextKey == .string("super+s"))
        #expect(errors.value.count == 1)
    }

    @Test("formatKeySequence and formatCommandBindings render macOS symbols, POSIX labels, tokens, and dedupe")
    func formattingExtras() throws {
        let (_, keymap) = try makeKeymap()
        _ = try registerLeader(keymap, options: LeaderOptions(trigger: "space"))

        let parts = try keymap.parseKeySequence("<leader>super+shift+p")
        let defaultText = formatKeySequence(parts)
        #expect(defaultText == "<leader> shift+super+p")

        let macText = formatKeySequence(
            parts,
            options: FormatKeySequenceOptions(
                tokenDisplay: .map(["leader": "SPC"]),
                keyNameAliases: FormatKeySequenceOptions.macOSSymbols.keyNameAliases,
                modifierAliases: FormatKeySequenceOptions.macOSSymbols.modifierAliases,
                separator: " ",
                modifierJoiner: ""
            )
        )
        #expect(macText == "SPC ⇧⌘p")

        let posixText = formatKeySequence(
            try keymap.parseKeySequence("ctrl+meta+return"),
            options: .posixLabels
        )
        #expect(posixText == "Ctrl+Alt+Enter")

        let b1 = ActiveBinding<String, BasicKeymapEvent>(sequence: try keymap.parseKeySequence("ctrl+s"))
        let b2 = ActiveBinding<String, BasicKeymapEvent>(sequence: try keymap.parseKeySequence("ctrl+s"))
        let b3 = ActiveBinding<String, BasicKeymapEvent>(sequence: try keymap.parseKeySequence("super+s"))

        let formatted = formatCommandBindings(
            [b1, b2, b3],
            options: FormatCommandBindingsOptions(keySequenceOptions: .macOSSymbols, bindingSeparator: " / ", dedupe: true)
        )
        #expect(formatted == "⌃s / ⌘s")
    }

    @Test("getGraphSnapshot and createGraphExtra inspect live layers, pending paths, shadowing, and inactive reasons")
    func graphSnapshotInspection() throws {
        let (host, keymap) = try makeKeymap()
        _ = try registerEnabledFields(keymap)

        host.setParent("root", for: "panel")
        host.setFocusedTarget("root")

        // Global layer with multi-stroke sequence + shadowed binding + unresolved binding
        _ = keymap.registerLayer(
            Layer(
                priority: 1,
                bindings: [
                    Binding(key: "gg", commandName: "top"),
                    Binding(key: "x", commandName: "missing.cmd"),
                ],
                commands: [Command(name: "top") { _ in true }]
            )
        )

        // Higher-priority layer shadowing "gg"
        _ = keymap.registerLayer(
            Layer(
                priority: 10,
                bindings: [Binding(key: "gg", commandName: "top")],
                commands: [Command(name: "top") { _ in true }]
            )
        )

        // Unfocused panel layer
        _ = keymap.registerLayer(
            Layer(
                target: "panel",
                bindings: [Binding(key: "p", commandName: "top")]
            )
        )

        // Trigger first stroke of "gg" so pending & pendingPath are populated
        keymap.handleKeyPress(BasicKeymapEvent(name: "g"))

        let graphExtra = createGraphExtra(keymap)
        let snapshot = graphExtra.getGraphSnapshot()

        #expect(snapshot.focused == "root")
        #expect(snapshot.pendingSequence.count == 1)
        #expect(snapshot.layers.count == 3)

        let panelLayer = snapshot.layers.first { $0.target == "panel" }
        #expect(panelLayer?.active == false)
        #expect(panelLayer?.inactiveReasons.contains(.focus) == true)

        let unresolvedBinding = snapshot.bindings.first { $0.command?.commandName == "missing.cmd" }
        #expect(unresolvedBinding?.commandResolved == false)
        #expect(unresolvedBinding?.inactiveReasons.contains(.commandUnresolved) == true)

        let shadowedBinding = snapshot.bindings.first { $0.shadowed }
        #expect(shadowedBinding != nil)
        #expect(shadowedBinding?.inactiveReasons.contains(.shadowed) == true)

        let pendingNodes = snapshot.sequenceNodes.filter(\.pending)
        #expect(!pendingNodes.isEmpty)
        #expect(snapshot.sequenceNodes.contains { $0.pendingPath && $0.depth == 0 })

        // includeTargets: false omits targets
        let redacted = getGraphSnapshot(keymap, options: GraphSnapshotOptions(includeTargets: false))
        #expect(redacted.focused == nil)
        #expect(redacted.layers.allSatisfy { $0.target == nil })
    }
}

// MARK: - 4. Host Adapters & Reactive Scope Hooks Tests

@Suite("OpenTUIKeymap Host Adapters & Hooks")
struct KeymapHostAdaptersTests {
    @Test("createDefaultOpenTuiKeymap, registerBaseLayoutFallback, and EditBuffer/Textarea bindings")
    func openTuiHostAndEditBufferBindings() throws {
        let renderer = MockOpenTUIRenderer(platform: .macos, hasKittyKeyboard: true)
        let keymap = try createDefaultOpenTuiKeymap(renderer)
        let offBaseLayout = try registerBaseLayoutFallback(keymap)

        #expect(keymap.getHostMetadata().platform == .macos)
        #expect(keymap.getHostMetadata().primaryModifier == .super)
        #expect(keymap.getHostMetadata().modifiers[.super] == .supported)

        let copied = ValueBox(0)
        let tabOne = ValueBox(0)
        let dvorakJ = ValueBox(0)
        _ = keymap.registerLayer(
            Layer(bindings: [
                Binding(key: "ctrl+c", cmd: .handler { _ in copied.value += 1; return true }),
                Binding(key: "ctrl+1", cmd: .handler { _ in tabOne.value += 1; return true }),
                Binding(key: "ctrl+j", cmd: .handler { _ in dvorakJ.value += 1; return true }),
            ])
        )

        // Korean Ctrl+ㅊ (baseCode = 'c' = 99) falls back to ctrl+c
        renderer.press(OpenTUIKeyEventAdapter(name: "ㅊ", ctrl: true, baseCode: 99))
        #expect(copied.value == 1)

        // AZERTY Ctrl+& (baseCode = '1' = 49) falls back to ctrl+1
        renderer.press(OpenTUIKeyEventAdapter(name: "&", ctrl: true, baseCode: 49))
        #expect(tabOne.value == 1)

        // Dvorak ASCII Ctrl+j with baseCode 'c' stays ctrl+j (does not fall back)
        renderer.press(OpenTUIKeyEventAdapter(name: "j", ctrl: true, baseCode: 99))
        #expect(dvorakJ.value == 1)
        #expect(copied.value == 1)

        // Managed textarea layer + suspension + edit buffer commands
        let editor = MockEditBuffer(isManagedTextarea: true)
        renderer.focusEditor(editor)
        #expect(!editor.isKeymapSuspended)

        let offTextarea = try registerManagedTextareaLayer(
            keymap,
            renderer: renderer,
            layer: ManagedTextareaLayer(bindings: [Binding(key: "dd", commandName: "input.delete.line")]),
            options: EditBufferCommandOptions(includeFineGroup: true)
        )

        #expect(editor.isKeymapSuspended)
        #expect(keyBindingToString(KeyStrokeInput(name: "z", shift: true, super: true)) == "shift+super+z")
        #expect(editBufferCommandNames.count == 36)
        #expect(editBufferCommandDescriptions.count == 36)

        renderer.press(OpenTUIKeyEventAdapter(name: "d"))
        renderer.press(OpenTUIKeyEventAdapter(name: "d"))
        renderer.press(OpenTUIKeyEventAdapter(name: "left"))
        renderer.press(OpenTUIKeyEventAdapter(name: "z", super: true))
        #expect(editor.actions == ["delete-line", "move-left", "undo"])

        offTextarea()
        #expect(!editor.isKeymapSuspended)
        offBaseLayout()

        renderer.destroy()
        #expect(throws: KeymapHostError.self) {
            _ = try createOpenTuiKeymap(renderer)
        }
    }

    @Test("DOMKeyboardEventLike, normalizeHtmlKeyName, createHtmlKeymapEvent, and createDefaultHtmlKeymap")
    func htmlDomAdapter() throws {
        #expect(normalizeHtmlKeyName(" ") == "space")
        #expect(normalizeHtmlKeyName("ArrowUp") == "up")
        #expect(normalizeHtmlKeyName("Enter") == "return")
        #expect(normalizeHtmlKeyName("Meta") == "super")
        #expect(normalizeHtmlKeyName("F12") == "f12")
        #expect(normalizeHtmlKeyName("A") == "a")

        let converted = createHtmlKeymapEvent(
            DOMKeyboardEventLike(key: "k", ctrlKey: false, shiftKey: true, altKey: true, metaKey: true)
        )
        #expect(converted.name == "k")
        #expect(converted.meta == true)
        #expect(converted.`super` == true)
        #expect(converted.shift == true)

        let root = InMemoryDOMElement(id: "root")
        let child = InMemoryDOMElement(id: "child")
        root.appendChild(child)
        root.setActiveElement(child)

        let keymap = try createDefaultHtmlKeymap(root, platform: .macos)
        let helpOpened = ValueBox(0)
        let paletteOpened = ValueBox(0)

        _ = keymap.registerLayer(
            Layer(
                target: child,
                bindings: [
                    Binding(key: "?", cmd: .handler { _ in helpOpened.value += 1; return true }),
                    Binding(key: "super+k", cmd: .handler { _ in paletteOpened.value += 1; return true }),
                ]
            )
        )

        // Browser Shift+? matches unshifted "?" binding via htmlEventMatchResolver
        root.dispatchKeyDown(DOMKeyboardEventLike(key: "?", shiftKey: true))
        root.dispatchKeyDown(DOMKeyboardEventLike(key: "k", metaKey: true))
        #expect(helpOpened.value == 1)
        #expect(paletteOpened.value == 1)
    }

    @Test("Adapted React and Solid declarative reactive scope hooks")
    func declarativeScopeHooks() throws {
        let (host, keymap) = try makeKeymap()
        let hits = ValueBox(0)
        let targetRef = UseBindingsTargetRef("root")

        // Missing provider throws
        #expect(throws: KeymapScopeError.missingProvider) {
            _ = try useKeymap(InMemoryKeymapHost<String, BasicKeymapEvent>.self)
        }

        try KeymapProvider(KeymapProviderProps(keymap: keymap)) {
            let scoped = try useKeymap(InMemoryKeymapHost<String, BasicKeymapEvent>.self)
            #expect(scoped === keymap)

            let hook = try useBindings(InMemoryKeymapHost<String, BasicKeymapEvent>.self) {
                UseBindingsLayer(
                    targetRef: targetRef,
                    bindings: [Binding(key: "gh", cmd: .handler { _ in hits.value += 1; return true })]
                )
            }

            let active = try useActiveKeys(InMemoryKeymapHost<String, BasicKeymapEvent>.self)
            #expect(active.contains { $0.stroke.name == "g" && $0.continues })

            keymap.handleKeyPress(BasicKeymapEvent(name: "g"))
            let pending = try usePendingSequence(InMemoryKeymapHost<String, BasicKeymapEvent>.self)
            #expect(pending.count == 1)

            keymap.handleKeyPress(BasicKeymapEvent(name: "h"))
            #expect(hits.value == 1)
            hook.dispose()
        }

        // Solid-style provider, selector, and signal matcher
        let signal = KeymapSignal(false)
        let signalMatcher = reactiveMatcherFromSignal(signal)
        #expect(try !signalMatcher.get())
        let storeNotified = ValueBox(0)
        let offSignal = try signalMatcher.subscribe { storeNotified.value += 1 }
        signal.set(true)
        #expect(try signalMatcher.get())
        #expect(storeNotified.value == 1)
        offSignal()

        let storeMatcher = reactiveMatcherFromStore(
            subscribe: { cb in signal.subscribe(cb) },
            getSnapshot: { signal.get() ? 42 : 0 },
            predicate: { $0 == 42 }
        )
        #expect(try storeMatcher.get())

        try SolidKeymapProvider(SolidKeymapProviderProps(keymap: keymap)) {
            let scoped = try useSolidKeymap(InMemoryKeymapHost<String, BasicKeymapEvent>.self)
            #expect(scoped === keymap)

            let countSelector = try useKeymapSelector(InMemoryKeymapHost<String, BasicKeymapEvent>.self) { km in
                km.getActiveKeys().count
            }
            #expect(countSelector.get() == 0)

            let solidHook = try useSolidBindings(InMemoryKeymapHost<String, BasicKeymapEvent>.self) {
                SolidUseBindingsLayer(
                    target: { host.rootTarget },
                    bindings: [Binding(key: "k", cmd: .handler { _ in true })]
                )
            }
            #expect(countSelector.get() == 1)

            solidHook.dispose()
            #expect(countSelector.get() == 0)
            countSelector.dispose()
        }
    }
}

import Testing
import OpenTUIKeymap

private final class Box<T: Sendable>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private enum RuntimeTestError: Error, Sendable, KeymapDescribedError {
    case boom(String)

    var errorMessage: String {
        switch self {
        case .boom(let msg): return msg
        }
    }
}

private struct FakePromise: PromiseLike {}

private final class ExternalMarkerObject: @unchecked Sendable {
    let tag: String
    init(_ tag: String) { self.tag = tag }
}

private final class TestInteractiveHost: InteractiveKeymapHost, @unchecked Sendable {
    typealias Target = String
    typealias Event = BasicKeymapEvent

    let rootTarget: String = "root"
    let metadata: HostMetadata = HostMetadata(
        platform: .macos,
        primaryModifier: .super,
        modifiers: [.ctrl: .supported, .shift: .supported, .meta: .supported, .super: .supported, .hyper: .unsupported]
    )
    var isDestroyed: Bool = false

    private var focused: String? = nil
    private var parents: [String: String] = [:]
    private var destroyedTargets: Set<String> = []
    private var keyPressListeners: [(Int, @Sendable (BasicKeymapEvent) -> Void)] = []
    private var keyReleaseListeners: [(Int, @Sendable (BasicKeymapEvent) -> Void)] = []
    private var focusListeners: [(Int, @Sendable (String?) -> Void)] = []
    private var rawListeners: [(Int, @Sendable (String) -> Bool)] = []
    private var destroyListeners: [(Int, @Sendable () -> Void)] = []
    private var targetDestroyListeners: [String: [(Int, @Sendable () -> Void)]] = [:]
    private var nextID: Int = 0

    func setParent(_ parent: String, for target: String) {
        parents[target] = parent
    }

    func focus(_ target: String?) {
        focused = target
        for (_, fn) in focusListeners {
            fn(target)
        }
    }

    func emitPress(_ event: BasicKeymapEvent) {
        for (_, fn) in keyPressListeners {
            fn(event)
        }
    }

    func emitRelease(_ event: BasicKeymapEvent) {
        for (_, fn) in keyReleaseListeners {
            fn(event)
        }
    }

    func emitRaw(_ seq: String) -> Bool {
        for (_, fn) in rawListeners {
            if fn(seq) { return true }
        }
        return false
    }

    func destroyHost() {
        isDestroyed = true
        for (_, fn) in destroyListeners {
            fn()
        }
    }

    func destroyTarget(_ target: String) {
        destroyedTargets.insert(target)
        let listeners = targetDestroyListeners.removeValue(forKey: target) ?? []
        for (_, fn) in listeners { fn() }
    }

    func getFocusedTarget() -> String? { focused }
    func getParentTarget(_ target: String) -> String? { parents[target] }
    func isTargetDestroyed(_ target: String) -> Bool { destroyedTargets.contains(target) }
    func createCommandEvent() -> BasicKeymapEvent { BasicKeymapEvent(name: "") }

    func onKeyPress(_ listener: @escaping @Sendable (BasicKeymapEvent) -> Void) -> @Sendable () -> Void {
        let id = nextID; nextID += 1
        keyPressListeners.append((id, listener))
        return { [weak self] in self?.keyPressListeners.removeAll { $0.0 == id } }
    }

    func onKeyRelease(_ listener: @escaping @Sendable (BasicKeymapEvent) -> Void) -> @Sendable () -> Void {
        let id = nextID; nextID += 1
        keyReleaseListeners.append((id, listener))
        return { [weak self] in self?.keyReleaseListeners.removeAll { $0.0 == id } }
    }

    func onFocusChange(_ listener: @escaping @Sendable (String?) -> Void) -> @Sendable () -> Void {
        let id = nextID; nextID += 1
        focusListeners.append((id, listener))
        return { [weak self] in self?.focusListeners.removeAll { $0.0 == id } }
    }

    func onRawInput(_ listener: @escaping @Sendable (String) -> Bool) -> @Sendable () -> Void {
        let id = nextID; nextID += 1
        rawListeners.append((id, listener))
        return { [weak self] in self?.rawListeners.removeAll { $0.0 == id } }
    }

    func onDestroy(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = nextID; nextID += 1
        destroyListeners.append((id, listener))
        return { [weak self] in self?.destroyListeners.removeAll { $0.0 == id } }
    }

    func onTargetDestroy(_ target: String, _ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = nextID; nextID += 1
        targetDestroyListeners[target, default: []].append((id, listener))
        return { [weak self] in self?.targetDestroyListeners[target]?.removeAll { $0.0 == id } }
    }
}

private func digitCountPattern() -> SequencePattern<BasicKeymapEvent> {
    SequencePattern<BasicKeymapEvent>(
        name: "count",
        payloadKey: "count",
        min: 1,
        max: 4,
        match: { event in
            guard event.name.count == 1,
                let scalar = event.name.unicodeScalars.first,
                scalar.value >= 48 && scalar.value <= 57
            else {
                return nil
            }
            return SequencePatternMatch(value: .string(event.name), display: event.name)
        },
        finalize: { values in
            let digits = values.map(\.stringDescription).joined()
            return .int(Int(digits) ?? 0)
        }
    )
}

// MARK: - 1. Values Tests

@Suite("OpenTUIKeymap Values")
struct KeymapValuesTests {
    @Test("isPlainData validates depth limits, __proto__ keys, and identityKey exemptions")
    func plainDataChecks() {
        #expect(isPlainData(.string("ok")))
        #expect(isPlainData(.object(["a": .int(1), "b": .array([.bool(true), .null])])))
        #expect(!isPlainData(.object(["__proto__": .object([:])])))

        // Deep nesting beyond depth 16 is rejected.
        var nested: KeymapValue = .int(1)
        for _ in 0..<17 {
            nested = .array([nested])
        }
        #expect(!isPlainData(nested))

        // identityKey skips validating that top-level key's value.
        let withTarget: KeymapValue = .object(["target": nested, "priority": .int(1)])
        #expect(!isPlainData(withTarget))
        #expect(isPlainData(withTarget, identityKey: "target"))
    }

    @Test("createForwarder, collectExternal, markSupplied, markExternal, and sameCompiledData")
    func forwardersAndExternalTracking() {
        let objA = ExternalMarkerObject("a")
        let objB = ExternalMarkerObject("b")
        let registry = ExternalObjectRegistry()

        collectExternal(registry) {
            markSupplied(objA)
            markExternal(["nested": [objB]])
        }
        #expect(registry.contains(objA))
        #expect(registry.contains(objB))
        #expect(registry.count == 2)

        // Forwarders record retarget moves when compared via sameCompiledData.
        let f1 = createForwarder({ @Sendable (x: Int) in x + 1 })
        let f2 = createForwarder({ @Sendable (x: Int) in x * 10 })
        var moves: [CompiledDataMove] = []
        #expect(sameCompiledData(f1, f2, key: "run", external: registry, moves: &moves))
        #expect(moves.count == 1)
        #expect(f1.target(3) == 4)
        moves[0].apply()
        #expect(f1.target(3) == 30)

        // External forwarder compares strictly by identity.
        registry.add(f1)
        var blockedMoves: [CompiledDataMove] = []
        #expect(!sameCompiledData(f1, f2, external: registry, moves: &blockedMoves))
        #expect(blockedMoves.isEmpty)

        // Value comparison honors Object.is (+0.0 != -0.0, NaN == NaN).
        #expect(sameCompiledData(.double(.nan), .double(.nan), moves: &moves))
        #expect(!sameCompiledData(.double(0.0), .double(-0.0), moves: &moves))
        #expect(objectIs(Double.nan, Double.nan))
        #expect(!objectIs(0.0, -0.0))
    }

    @Test("getErrorMessage, isPromiseLike, and snapshotDataValue")
    func errorMessagePromiseAndSnapshot() {
        #expect(getErrorMessage(RuntimeTestError.boom("custom failure"), fallback: "fallback") == "custom failure")
        #expect(getErrorMessage(nil, fallback: "fallback") == "fallback")
        #expect(isPromiseLike(FakePromise()))
        #expect(!isPromiseLike("not a promise"))

        let source: KeymapValue = .object(["list": .array([.int(1), .string("two")])])
        let shallow = snapshotDataValue(source)
        let deep = snapshotDataValue(source, options: SnapshotDataOptions(deep: true, freeze: true))
        #expect(shallow == source)
        #expect(deep == source)
    }
}

// MARK: - 2. ActiveKeyCache Tests

@Suite("OpenTUIKeymap ActiveKeyCache")
struct KeymapActiveKeyCacheTests {
    @Test("ActiveKeysCaches routes all four option combinations and invalidates by cacheVersion")
    func cacheRoutingAndVersionInvalidation() {
        let caches = createActiveKeysCaches() as ActiveKeysCaches<String, BasicKeymapEvent>

        let plain = getActiveKeysCache(caches, options: nil)
        let bindings = getActiveKeysCache(caches, options: ActiveKeyOptions(includeBindings: true))
        let metadata = getActiveKeysCache(caches, options: ActiveKeyOptions(includeMetadata: true))
        let both = getActiveKeysCache(caches, options: ActiveKeyOptions(includeBindings: true, includeMetadata: true))

        #expect(plain === caches.plain)
        #expect(bindings === caches.bindings)
        #expect(metadata === caches.metadata)
        #expect(both === caches.bindingsAndMetadata)

        let key = ActiveKey<String, BasicKeymapEvent>(
            stroke: NormalizedKeyStroke(name: "k", ctrl: true),
            display: "ctrl+k",
            command: .named("editor.kill"),
            continues: false
        )

        setFocusedActiveKeysCache(plain, cacheVersion: 1, focused: "editor", value: [key])
        setFocusedActiveKeysCache(plain, cacheVersion: 1, focused: nil, value: [])

        #expect(getFocusedActiveKeysCache(plain, cacheVersion: 1, focused: "editor")?.value.count == 1)
        #expect(getFocusedActiveKeysCache(plain, cacheVersion: 1, focused: nil)?.value.isEmpty == true)
        #expect(getFocusedActiveKeysCache(plain, cacheVersion: 2, focused: "editor") == nil)
        #expect(getFocusedActiveKeysCache(plain, cacheVersion: 1, focused: "sidebar") == nil)

        caches.invalidateAll()
        #expect(getFocusedActiveKeysCache(plain, cacheVersion: 1, focused: "editor") == nil)
    }
}

// MARK: - 3. CommandCatalog & CommandExecutor Tests

@Suite("OpenTUIKeymap CommandCatalog")
struct KeymapCommandCatalogTests {
    @Test("Command catalog queries, filtering, search, namespace, bindings, and resolvers")
    func catalogQueriesAndResolvers() throws {
        let host = InMemoryKeymapHost<String, BasicKeymapEvent>(rootTarget: "root", focusedTarget: "editor")
        host.setParent("root", for: "editor")
        host.setParent("root", for: "sidebar")

        let keymap = try createKeymap(host: host)

        keymap.registerCommandFields([
            "when": { value, ctx in
                if case .string(let mode) = value {
                    try ctx.require("mode", .string(mode))
                }
            },
            "desc": { value, ctx in
                try ctx.attr("desc", value)
            },
        ])

        let log = Box<[String]>([])

        keymap.registerLayer(
            Layer(
                target: "root",
                bindings: [
                    Binding(key: "ctrl+s", commandName: "file.save"),
                    Binding(key: "ctrl+p", commandName: "palette.open"),
                ],
                commands: [
                    Command(
                        name: "file.save",
                        fields: ["namespace": "file", "desc": "Save current file"],
                        run: { _ in log.value.append("root:save"); return true }
                    ),
                    Command(
                        name: "palette.open",
                        fields: ["namespace": "ui", "desc": "Open command palette", "when": "normal"],
                        run: { _ in log.value.append("root:palette"); return true }
                    ),
                ]
            )
        )

        keymap.registerLayer(
            Layer(
                target: "sidebar",
                commands: [
                    Command(
                        name: "sidebar.toggle",
                        fields: ["namespace": "ui", "desc": "Toggle sidebar"],
                        run: { _ in log.value.append("sidebar:toggle"); return true }
                    )
                ]
            )
        )

        // Initially mode is unset, so palette.open is disabled and sidebar.toggle is inactive.
        let reachable = keymap.getCommands()
        #expect(reachable.map(\.name) == ["file.save"])

        let allRegistered = keymap.getCommands(CommandQuery(visibility: .registered))
        #expect(allRegistered.map(\.name) == ["file.save", "palette.open", "sidebar.toggle"])

        // Enable mode = "normal" so palette.open becomes reachable.
        keymap.setData("mode", "normal")
        #expect(keymap.getCommands().map(\.name) == ["file.save", "palette.open"])

        // Search across custom searchIn fields (desc).
        let searchResults = keymap.getCommands(
            CommandQuery(visibility: .registered, search: "sidebar", searchIn: ["name", "desc"])
        )
        #expect(searchResults.map(\.name) == ["sidebar.toggle"])

        // Namespace filter & limit.
        let uiCommands = keymap.getCommands(CommandQuery(visibility: .registered, namespace: "ui", limit: 1))
        #expect(uiCommands.map(\.name) == ["palette.open"])

        // Command entries include bound sequences.
        let entries = keymap.getCommandEntries(CommandQuery(filter: .fields(["name": .exact("file.save")])))
        #expect(entries.count == 1)
        #expect(entries[0].bindings.count == 1)
        #expect(entries[0].bindings[0].sequence[0].display == "ctrl+s")

        // getCommandBindings returns map keyed by requested commands.
        let bindingMap = keymap.getCommandBindings(
            CommandBindingsQuery(visibility: .registered, commands: ["file.save", "sidebar.toggle"])
        )
        #expect(bindingMap["file.save"]?.count == 1)
        #expect(bindingMap["sidebar.toggle"]?.isEmpty == true)

        // Resolver alias redirecting "save" -> "file.save" with custom payload.
        let offResolver = keymap.appendCommandResolver { name, ctx in
            guard name == "save" else { return nil }
            ctx.setPayload(.string("aliased"))
            return ctx.getCommand("file.save")
        }
        let aliasResult = keymap.dispatchCommand("save", options: RunCommandOptions(includeCommand: true))
        #expect(aliasResult.ok)
        #expect(aliasResult.command?.name == "file.save")
        #expect(log.value == ["root:save"])
        offResolver()

        // dispatchCommand distinguishes inactive vs disabled vs not-found vs invalid-args.
        keymap.setData("mode", "insert")
        #expect(keymap.dispatchCommand("palette.open").reason == .disabled)
        #expect(keymap.dispatchCommand("sidebar.toggle").reason == .inactive)
        #expect(keymap.dispatchCommand("missing.cmd").reason == .notFound)
        #expect(keymap.dispatchCommand("   ").reason == .invalidArgs)

        // runCommand runs registered commands regardless of focus/conditions.
        let runSidebar = keymap.runCommand("sidebar.toggle")
        #expect(runSidebar.ok)
        #expect(log.value == ["root:save", "sidebar:toggle"])
    }

    @Test("CommandExecutor falls through rejected commands and emits error on throw")
    func executorFallbackAndErrors() throws {
        let host = InMemoryKeymapHost<String, BasicKeymapEvent>(rootTarget: "root", focusedTarget: "editor")
        host.setParent("root", for: "editor")
        let keymap = try createKeymap(host: host)

        let calls = Box<[String]>([])
        let errors = Box<[KeymapDiagnosticEvent]>([])
        keymap.on(.error { errors.value.append($0) })

        keymap.registerLayer(
            Layer(
                target: "root",
                priority: 0,
                commands: [
                    Command(name: "act") { _ in
                        calls.value.append("root")
                        return true
                    },
                    Command(name: "explode") { _ in
                        throw RuntimeTestError.boom("kaboom")
                    },
                ]
            )
        )
        keymap.registerLayer(
            Layer(
                target: "editor",
                priority: 10,
                commands: [
                    Command(name: "act") { _ in
                        calls.value.append("editor-reject")
                        return false
                    }
                ]
            )
        )

        let res = keymap.dispatchCommand("act")
        #expect(res.ok)
        #expect(calls.value == ["editor-reject", "root"])

        let errRes = keymap.dispatchCommand("explode")
        #expect(!errRes.ok)
        #expect(errRes.reason == .error)
        #expect(errors.value.count == 1)
        #expect(errors.value[0].code == "command-execution-error")
    }
}

// MARK: - 4. Dispatch & KeymapRuntime Tests

@Suite("OpenTUIKeymap Dispatch & KeymapRuntime")
struct KeymapRuntimeDispatchTests {
    @Test("Single-stroke, multi-stroke chords, pending sequence pop/clear, and release bindings")
    func chordsPendingAndReleaseDispatch() throws {
        let host = InMemoryKeymapHost<String, BasicKeymapEvent>(rootTarget: "root", focusedTarget: "editor")
        host.setParent("root", for: "editor")
        let keymap = try createKeymap(host: host)

        let executed = Box<[String]>([])
        let afterReasons = Box<[KeyAfterReason]>([])
        let pendingHistory = Box<[[String]]>([])
        let dispatchPhases = Box<[DispatchPhase]>([])

        keymap.on(.pendingSequence { parts in
            pendingHistory.value.append(parts.map(\.display))
        })
        keymap.on(.dispatch { ev in
            dispatchPhases.value.append(ev.phase)
        })
        keymap.intercept(.keyAfter({ ctx in
            afterReasons.value.append(ctx.reason)
        }))

        keymap.registerLayer(
            Layer(
                target: "editor",
                bindings: [
                    Binding(key: "gg", commandName: "doc.top"),
                    Binding(key: "gd", commandName: "goto.def"),
                    Binding(key: "gxy", commandName: "deep.chord"),
                    Binding(key: "space", commandName: "space.up", event: .release),
                ],
                commands: [
                    Command(name: "doc.top") { _ in executed.value.append("doc.top"); return true },
                    Command(name: "goto.def") { _ in executed.value.append("goto.def"); return true },
                    Command(name: "deep.chord") { _ in executed.value.append("deep.chord"); return true },
                    Command(name: "space.up") { _ in executed.value.append("space.up"); return true },
                ]
            )
        )

        // Start chord "g"
        let gEvent = BasicKeymapEvent(name: "g")
        keymap.handleKeyPress(gEvent)
        #expect(gEvent.defaultPrevented)
        #expect(gEvent.propagationStopped)
        #expect(keymap.hasPendingSequence())
        #expect(keymap.getPendingSequence().map(\.display) == ["g"])

        // Active keys inside pending sequence show continuations ("g", "d", "x")
        let nextKeys = keymap.getActiveKeys(ActiveKeyOptions(includeBindings: true))
        let displays = Set(nextKeys.map(\.display))
        #expect(displays == Set(["g", "d", "x"]))

        // Advance to "g x", pop back to "g", then complete "g x y"
        keymap.handleKeyPress(BasicKeymapEvent(name: "x"))
        #expect(keymap.getPendingSequence().map(\.display) == ["g", "x"])
        #expect(keymap.popPendingSequence() == true)
        #expect(keymap.getPendingSequence().map(\.display) == ["g"])

        keymap.handleKeyPress(BasicKeymapEvent(name: "x"))
        keymap.handleKeyPress(BasicKeymapEvent(name: "y"))
        #expect(!keymap.hasPendingSequence())
        #expect(executed.value == ["deep.chord"])
        #expect(afterReasons.value.last == .bindingHandled)

        // Fresh chord "g d" executes goto.def
        keymap.handleKeyPress(BasicKeymapEvent(name: "g"))
        keymap.handleKeyPress(BasicKeymapEvent(name: "d"))
        #expect(!keymap.hasPendingSequence())
        #expect(executed.value == ["deep.chord", "goto.def"])
        #expect(afterReasons.value.last == .bindingHandled)

        // Sequence miss clears pending sequence without preventing default
        keymap.handleKeyPress(BasicKeymapEvent(name: "g"))
        #expect(keymap.hasPendingSequence())
        let missEvent = BasicKeymapEvent(name: "z")
        keymap.handleKeyPress(missEvent)
        #expect(!keymap.hasPendingSequence())
        #expect(!missEvent.defaultPrevented)
        #expect(afterReasons.value.last == .sequenceMiss)

        // Release binding fires only on release
        keymap.handleKeyPress(BasicKeymapEvent(name: "space"))
        #expect(executed.value == ["deep.chord", "goto.def"])
        let relEvent = BasicKeymapEvent(name: "space")
        keymap.handleKeyRelease(relEvent)
        #expect(executed.value == ["deep.chord", "goto.def", "space.up"])
        #expect(relEvent.defaultPrevented)

        #expect(dispatchPhases.value.contains(.sequenceStart))
        #expect(dispatchPhases.value.contains(.sequenceAdvance))
        #expect(dispatchPhases.value.contains(.bindingExecute))
        #expect(dispatchPhases.value.contains(.sequenceClear))
        #expect(!pendingHistory.value.isEmpty)
    }

    @Test("Pattern capture payloads, tokens, interceptors, and fallthrough across layers")
    func patternsTokensInterceptorsAndFallthrough() throws {
        let host = InMemoryKeymapHost<String, BasicKeymapEvent>(rootTarget: "root", focusedTarget: "editor")
        host.setParent("root", for: "editor")
        let keymap = try createKeymap(host: host)

        let capturedPayload = Box<KeymapValue?>(nil)
        let log = Box<[String]>([])

        keymap.registerSequencePattern(digitCountPattern())
        let offLeader = keymap.registerToken(KeyToken(name: "leader", key: "space"))

        keymap.registerLayer(
            Layer(
                target: "root",
                priority: 0,
                bindings: [
                    Binding(key: "j", commandName: "root.j"),
                    Binding(key: "{count}d", commandName: "delete.lines"),
                    Binding(key: "<leader>f", commandName: "find.files"),
                ],
                commands: [
                    Command(name: "root.j") { _ in log.value.append("root.j"); return true },
                    Command(name: "delete.lines") { ctx in
                        capturedPayload.value = ctx.payload
                        log.value.append("delete.lines")
                        return true
                    },
                    Command(name: "find.files") { _ in log.value.append("find.files"); return true },
                ]
            )
        )

        keymap.registerLayer(
            Layer(
                target: "editor",
                priority: 10,
                bindings: [
                    Binding(key: "j", commandName: "editor.j", preventDefault: false, fallthrough: true)
                ],
                commands: [
                    Command(name: "editor.j") { _ in log.value.append("editor.j"); return true }
                ]
            )
        )

        // Fallthrough runs both editor.j and root.j!
        keymap.handleKeyPress(BasicKeymapEvent(name: "j"))
        #expect(log.value == ["editor.j", "root.j"])

        // Pattern capture "{count} d" with "1", "2", "d" -> payload {"count": 12}
        keymap.handleKeyPress(BasicKeymapEvent(name: "1"))
        keymap.handleKeyPress(BasicKeymapEvent(name: "2"))
        #expect(keymap.hasPendingSequence())
        keymap.handleKeyPress(BasicKeymapEvent(name: "d"))
        #expect(!keymap.hasPendingSequence())
        #expect(capturedPayload.value == .object(["count": .int(12)]))

        // Token "<leader> f" matches space then f
        keymap.handleKeyPress(BasicKeymapEvent(name: "space"))
        keymap.handleKeyPress(BasicKeymapEvent(name: "f"))
        #expect(log.value.last == "find.files")

        // Unregistering leader token recompiles layer so space f no longer triggers find.files
        offLeader()
        let beforeCount = log.value.count
        keymap.handleKeyPress(BasicKeymapEvent(name: "space"))
        keymap.handleKeyPress(BasicKeymapEvent(name: "f"))
        #expect(log.value.count == beforeCount)

        // Raw & key interceptors respect priority and consumption.
        let rawCalls = Box<[String]>([])
        keymap.intercept(.raw({ ctx in
            rawCalls.value.append("low:\(ctx.sequence)")
        }, RawInterceptOptions(priority: 0)))
        keymap.intercept(.raw({ ctx in
            rawCalls.value.append("high:\(ctx.sequence)")
            ctx.stop()
        }, RawInterceptOptions(priority: 10)))
        #expect(keymap.handleRawSequence("\u{1B}[A") == true)
        #expect(rawCalls.value == ["high:\u{1B}[A"])

        let offKeyIntercept = keymap.intercept(.key({ ctx in
            if ctx.event.name == "j" {
                ctx.consume()
            }
        }))
        let blockedCount = log.value.count
        keymap.handleKeyPress(BasicKeymapEvent(name: "j"))
        #expect(log.value.count == blockedCount)
        offKeyIntercept()
    }

    @Test("Prefix/exact ambiguity disambiguation supports sync decisions and deferred timeout flushing")
    func prefixDisambiguationSyncAndDeferred() async throws {
        let host = InMemoryKeymapHost<String, BasicKeymapEvent>(rootTarget: "root", focusedTarget: "editor")
        host.setParent("root", for: "editor")
        let keymap = try createKeymap(host: host)

        let ran = Box<[String]>([])

        // Register a deferred disambiguation resolver that waits 25ms then runs exact if not aborted.
        let offResolver = keymap.appendDisambiguationResolver { ctx in
            ctx.defer { deferredCtx in
                let completed = await deferredCtx.sleep(25)
                if completed {
                    return deferredCtx.runExact()
                }
                return nil
            }
        }

        keymap.registerLayer(
            Layer(
                target: "editor",
                bindings: [
                    Binding(key: "j", commandName: "move.down"),
                    Binding(key: "jk", commandName: "exit.insert"),
                ],
                commands: [
                    Command(name: "move.down") { _ in ran.value.append("move.down"); return true },
                    Command(name: "exit.insert") { _ in ran.value.append("exit.insert"); return true },
                ]
            )
        )

        // Case 1: Press "j" then quickly "k" before timeout -> aborts deferred and runs "exit.insert"
        keymap.handleKeyPress(BasicKeymapEvent(name: "j"))
        #expect(keymap.hasPendingSequence())
        #expect(ran.value.isEmpty)
        keymap.handleKeyPress(BasicKeymapEvent(name: "k"))
        #expect(!keymap.hasPendingSequence())
        #expect(ran.value == ["exit.insert"])

        // Wait past 40ms to verify aborted deferred did NOT fire move.down.
        try await Task.sleep(for: .milliseconds(45))
        #expect(ran.value == ["exit.insert"])

        // Case 2: Press "j" and wait past timeout -> deferred flushes and runs "move.down"
        keymap.handleKeyPress(BasicKeymapEvent(name: "j"))
        #expect(keymap.hasPendingSequence())
        try await Task.sleep(for: .milliseconds(60))
        #expect(!keymap.hasPendingSequence())
        #expect(ran.value == ["exit.insert", "move.down"])

        offResolver()
    }

    @Test("InteractiveKeymapHost wiring, key matcher, formatKey, and acquireResource lifecycle")
    func interactiveHostAndLifecycle() throws {
        let host = TestInteractiveHost()
        host.setParent("root", for: "input")
        host.focus("input")

        let keymap = try Keymap(host: host)
        #expect(keymap.getHostMetadata().platform == .macos)
        #expect(keymap.getHostMetadata().primaryModifier == .super)

        let matcher = try keymap.createKeyMatcher("ctrl+k")
        #expect(matcher(.stroke(KeyStrokeInput(name: "k", ctrl: true))) == true)
        #expect(matcher(.stroke(KeyStrokeInput(name: "k", ctrl: false))) == false)
        #expect(matcher(nil) == false)

        #expect(try keymap.formatKey("ctrl+enter", options: StringifyOptions(preferDisplay: true)) == "ctrl+enter")
        #expect(try keymap.parseKeySequence("gg").count == 2)

        let hits = Box<[String]>([])
        keymap.registerLayer(
            Layer(
                target: "input",
                bindings: [Binding(key: "gg", commandName: "top")],
                commands: [Command(name: "top") { _ in hits.value.append("top"); return true }]
            )
        )

        // Focus change cancels pending sequence automatically.
        host.emitPress(BasicKeymapEvent(name: "g"))
        #expect(keymap.hasPendingSequence())
        host.focus("root")
        #expect(!keymap.hasPendingSequence())

        // Resource refcounting & host destroy cleanup.
        let disposedCount = Box(0)
        let r1 = try keymap.acquireResource(key: "shared") {
            return { disposedCount.value += 1 }
        }
        let r2 = try keymap.acquireResource(key: "shared") {
            return { disposedCount.value += 100 }
        }
        r1()
        #expect(disposedCount.value == 0)
        r2()
        #expect(disposedCount.value == 1)

        // Host destroy cleans up remaining acquired resources and prevents further acquisition.
        _ = try keymap.acquireResource(key: "auto") {
            return { disposedCount.value += 10 }
        }
        host.destroyHost()
        #expect(disposedCount.value == 11)

        var threwOnDestroyed = false
        do {
            _ = try keymap.acquireResource(key: "after") { {} }
        } catch {
            threwOnDestroyed = true
        }
        #expect(threwOnDestroyed)
    }
}

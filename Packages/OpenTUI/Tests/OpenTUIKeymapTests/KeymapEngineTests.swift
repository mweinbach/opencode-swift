import Testing
import OpenTUIKeymap

private enum SampleTestError: Error, Sendable {
    case boom
}

private final class AtomicBox<T: Sendable>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private final class TestMatchable: RuntimeMatchable, @unchecked Sendable {
    let requires: [KeymapRequirement]
    let matchers: [RuntimeMatcher]

    init(requires: [KeymapRequirement] = [], matchers: [RuntimeMatcher] = []) {
        self.requires = requires
        self.matchers = matchers
    }
}

private func makeCountPattern(
    name: String = "count",
    payloadKey: String? = nil,
    min: Int = 1,
    max: Int = Int.max
) -> ResolvedSequencePattern<BasicKeymapEvent> {
    ResolvedSequencePattern<BasicKeymapEvent>(
        name: name,
        payloadKey: payloadKey ?? name,
        min: min,
        max: max,
        matcher: { event in
            guard event.name.count == 1, let scalar = event.name.unicodeScalars.first,
                scalar.value >= 48 && scalar.value <= 57
            else {
                return nil
            }
            return SequencePatternMatch(value: .string(event.name), display: event.name)
        },
        finalize: { values in
            let joined = values.map(\.stringDescription).joined()
            return .int(Int(joined) ?? 0)
        }
    )
}

// MARK: - 1. Conditions & Field Invariants

@Suite("OpenTUIKeymap Conditions")
struct KeymapConditionsTests {
    @Test("KeymapValue matches JavaScript Object.is semantics")
    func keymapValueObjectIsSemantics() {
        #expect(KeymapValue.double(.nan) == KeymapValue.double(.nan))
        #expect(KeymapValue.double(0.0) != KeymapValue.double(-0.0))
        #expect(KeymapValue.undefined != KeymapValue.null)
        #expect(KeymapValue.string("normal") == "normal")
        #expect(KeymapValue.int(42) == 42)
        #expect(KeymapValue.bool(true) == true)
    }

    @Test("ConditionService evaluates requirements, matchers, error handling, and epoch seenResults")
    func conditionServiceEvaluationAndEpochs() {
        let dataBox = AtomicBox<EventData>(["vim.mode": "normal"])
        let notify = KeymapNotifier()
        let conditions = createConditionService(readData: { dataBox.value }, notify: notify)

        let toggle = AtomicBox(true)
        let matcher = conditions.buildRuntimeMatcher(.predicate { toggle.value }, source: "test.when")
        let target = TestMatchable(
            requires: [KeymapRequirement(name: "vim.mode", value: "normal")],
            matchers: [matcher]
        )

        #expect(conditions.matchesConditions(target) == true)
        #expect(conditions.seenResults(target) == 2) // bit 2 = true

        toggle.value = false
        #expect(conditions.matchesConditions(target) == false)
        #expect(conditions.seenResults(target) == 3) // bit 1 | bit 2

        // State event advances epoch and resets seenResults.
        notify.queueStateChange()
        #expect(conditions.seenResults(target) == 0)

        // Missing key compares as .undefined (not .null).
        dataBox.value = [:]
        #expect(conditions.matchesConditions(target) == false)
        #expect(conditions.seenResults(target) == 1) // bit 1 = false

        // Throwing matcher emits runtime-matcher-error and evaluates to false.
        let throwingMatcher = conditions.buildRuntimeMatcher(
            .predicate { throw SampleTestError.boom },
            source: "broken.field"
        )
        let brokenTarget = TestMatchable(matchers: [throwingMatcher])
        #expect(conditions.matchesConditions(brokenTarget) == false)
        #expect(notify.errors.count == 1)
        #expect(notify.errors[0].code == "runtime-matcher-error")
        #expect(notify.errors[0].message.contains("broken.field"))
    }

    @Test("ConditionService supports reactive matchers and logical combinators")
    func reactiveMatchersAndCombinators() throws {
        let notify = KeymapNotifier()
        let conditions = createConditionService(readData: { [:] }, notify: notify)
        let flagA = AtomicBox(true)
        let flagB = AtomicBox(false)
        let disposed = AtomicBox(false)

        let reactive = ReactiveMatcher(
            get: { flagA.value },
            subscribe: { _ in { disposed.value = true } }
        )
        let mA = conditions.buildRuntimeMatcher(.reactive(reactive), source: "flagA")
        let mB = conditions.buildRuntimeMatcher(.predicate { flagB.value }, source: "flagB")

        let all = ConditionCombinators.allOf([mA, mB])
        let any = ConditionCombinators.anyOf([mA, mB])
        let negated = ConditionCombinators.not(mB)

        #expect(try all.match() == false)
        #expect(try any.match() == true)
        #expect(try negated.match() == true)

        flagB.value = true
        #expect(try all.match() == true)
        #expect(try negated.match() == false)

        let subscribe = try #require(mA.subscribe)
        let unsub = try subscribe({})
        unsub()
        #expect(disposed.value == true)
    }

    @Test("Field invariant helpers detect conflicting requirements and attributes")
    func fieldInvariantsConflicts() throws {
        let notify = KeymapNotifier()
        let conditions = createConditionService(readData: { [:] }, notify: notify)
        let acc = FieldAccumulator(allowsAttributes: true)
        let ctx = createFieldCompilerContext(fieldName: "mode", conditions: conditions, accumulator: acc)

        try ctx.require("mode", "normal")
        try ctx.require("mode", "normal") // identical value is allowed
        try ctx.attr("label", "Normal")
        try ctx.attr("label", "Normal")

        #expect(throws: KeymapConditionError.conflictingRequirement(name: "mode", source: "field mode")) {
            try ctx.require("mode", "insert")
        }
        #expect(throws: KeymapConditionError.conflictingAttribute(name: "label", source: "field mode")) {
            try ctx.attr("label", "Insert")
        }

        let noAttrAcc = FieldAccumulator(allowsAttributes: false)
        let noAttrCtx = createFieldCompilerContext(fieldName: "x", conditions: conditions, accumulator: noAttrAcc)
        #expect(throws: KeymapConditionError.cannotPublishAttributes(source: "field x")) {
            try noAttrCtx.attr("foo", "bar")
        }
    }
}

// MARK: - 2. Compiler & Default Parser

@Suite("OpenTUIKeymap Compiler")
struct KeymapCompilerTests {
    @Test("Default binding parser handles modifiers, aliases, named keys, F-keys, tokens, and patterns")
    func defaultParserAndFormatKey() throws {
        let notify = KeymapNotifier()
        let conditions = createConditionService(readData: { [:] }, notify: notify)
        let env = CompilerEnvironment<String, BasicKeymapEvent>()
        let leaderStroke = try normalizeKeyStroke(KeyStrokeInput(name: "x", ctrl: true))
        env.tokens["leader"] = ResolvedKeyToken(
            stroke: leaderStroke,
            match: try createKeyMatch(leaderStroke.asStrokeInput)
        )
        env.patterns["count"] = makeCountPattern()

        let compiler = createCompilerService(environment: env, notify: notify, conditions: conditions)

        // Modified key with modifier aliases (control -> ctrl, option/alt -> meta)
        let chord = try compiler.parseKeySequence(.string("control+option+shift+enter"))
        #expect(chord.count == 1)
        #expect(chord[0].stroke == NormalizedKeyStroke(name: "enter", ctrl: true, shift: true, meta: true))
        #expect(chord[0].display == "ctrl+shift+meta+enter")

        // Spaced modifier chord
        let spaced = try compiler.parseKeySequence(.string("ctrl + shift + a"))
        #expect(spaced.count == 1)
        #expect(spaced[0].stroke == NormalizedKeyStroke(name: "a", ctrl: true, shift: true))

        // Multi-key sequence combining token, pattern, and named key
        let complex = try compiler.parseKeySequence(.string("<leader>{count}pageup"))
        #expect(complex.count == 3)
        #expect(complex[0].display == "<leader>")
        #expect(complex[0].tokenName == "leader")
        #expect(complex[1].patternName == "count")
        #expect(complex[1].payloadKey == "count")
        #expect(complex[2].stroke.name == "pageup")

        // Function keys and multi-char sequence
        let fkey = try compiler.parseKeySequence(.string("ctrl+f12"))
        #expect(fkey.count == 1)
        #expect(fkey[0].stroke == NormalizedKeyStroke(name: "f12", ctrl: true))

        // formatKey
        #expect(try compiler.formatKey(.string("gg"), options: StringifyOptions(separator: " ")) == "g g")
        #expect(
            try compiler.formatKey(.string("<leader>w"), options: StringifyOptions(preferDisplay: true)) == "<leader>w"
        )
    }

    @Test("CompilerService validates release bindings, unbounded patterns, and exact-prefix ambiguity")
    func compilerValidationInvariants() {
        let notify = KeymapNotifier()
        let conditions = createConditionService(readData: { [:] }, notify: notify)
        let unknownTokens = AtomicBox<[String]>([])
        let unknownFields = AtomicBox<[String]>([])
        let env = CompilerEnvironment<String, BasicKeymapEvent>()
        env.patterns["count"] = makeCountPattern()

        let compiler = createCompilerService(
            environment: env,
            notify: notify,
            conditions: conditions,
            options: CompilerOptions(
                warnUnknownField: { _, field in unknownFields.value.append(field) },
                warnUnknownToken: { token, _ in unknownTokens.value.append(token) }
            )
        )

        let result = compiler.compileBindings(
            [
                // Valid single-stroke press
                Binding(key: "g", commandName: "go"),
                // Conflicts with exact prefix "g" above
                Binding(key: "gg", commandName: "top"),
                // Release binding with > 1 stroke is rejected
                Binding(key: "ab", commandName: "bad-release", event: .release),
                // Unbounded terminal pattern is rejected
                Binding(key: "d{count}", commandName: "bad-terminal-pattern"),
                // Unknown token is warned & skipped, sets hasTokenBindings = true
                Binding(key: "<missing>x", commandName: "tok"),
                // Unknown field triggers warning but still compiles
                Binding(key: "z", commandName: "ok", fields: ["mystery": "yes"]),
            ],
            tokens: env.tokens,
            sourceTarget: nil,
            sourceLayerOrder: 0
        )

        #expect(result.hasTokenBindings == true)
        #expect(unknownTokens.value == ["missing"])
        #expect(unknownFields.value == ["mystery"])
        #expect(result.bindings.count == 2) // "g" and "z"
        #expect(result.bindings[0].command?.commandName == "go")
        #expect(result.bindings[1].command?.commandName == "ok")
        #expect(notify.errors.filter { $0.code == "binding-compile-error" }.count == 3)
    }

    @Test("CompilerService runs expanders, transformers, and custom binding field compilers")
    func expandersTransformersAndFields() {
        let notify = KeymapNotifier()
        let conditions = createConditionService(readData: { [:] }, notify: notify)
        let env = CompilerEnvironment<String, BasicKeymapEvent>()

        env.bindingExpanders.append { ctx in
            if ctx.input == "NAV" {
                return [
                    BindingExpansion(key: "j", displays: ["↓"]),
                    BindingExpansion(key: "k", displays: ["↑"]),
                ]
            }
            return nil
        }

        env.bindingFields["mode"] = { value, ctx in
            try ctx.require("vim.mode", value)
            try ctx.attr("mode", value)
        }

        env.bindingTransformers.append { parsed, ctx in
            if parsed.sequence.first?.stroke.name == "k" {
                var extra = parsed
                extra.sequence = [try ctx.parseKey(.string("up"))]
                ctx.add(extra)
            }
        }

        let compiler = createCompilerService(environment: env, notify: notify, conditions: conditions)
        let result = compiler.compileBindings(
            [Binding(key: "NAV", commandName: "move", fields: ["mode": "normal"])],
            tokens: [:],
            sourceTarget: nil,
            sourceLayerOrder: 1
        )

        #expect(notify.errors.isEmpty)
        #expect(result.bindings.count == 3) // j, k, and transformed up
        #expect(result.bindings[0].sequence[0].display == "↓")
        #expect(result.bindings[1].sequence[0].display == "↑")
        #expect(result.bindings[2].sequence[0].stroke.name == "up")
        #expect(result.bindings[0].requires == [KeymapRequirement(name: "vim.mode", value: "normal")])
        #expect(result.bindings[0].attrs?["mode"] == "normal")
    }

    @Test("Command normalization trims names and rejects invalid whitespace")
    func commandNormalizationPrimitives() throws {
        #expect(try normalizeCommandName("  editor.save  ") == "editor.save")
        #expect(throws: KeymapCompileError.emptyCommandName) {
            _ = try normalizeCommandName("   ")
        }
        #expect(throws: KeymapCompileError.commandNameContainsWhitespace(name: "bad name")) {
            _ = try normalizeCommandName("bad name")
        }

        let cmd: BindingCommand<String, BasicKeymapEvent>? = try normalizeBindingCommand(.named("  quit  "))
        #expect(cmd?.commandName == "quit")
        #expect(throws: KeymapCompileError.emptyCommand) {
            let _: BindingCommand<String, BasicKeymapEvent>? = try normalizeBindingCommand(.named("   "))
        }
    }
}

// MARK: - 3. Sequence Index & Pending Sequence

@Suite("OpenTUIKeymap SequenceIndex & PendingSequence")
struct KeymapSequenceTests {
    @Test("buildSequenceTree, traversal, presentation, and active options")
    func sequenceTreeAndTraversal() throws {
        let notify = KeymapNotifier()
        let conditions = createConditionService(readData: { [:] }, notify: notify)
        let env = CompilerEnvironment<String, BasicKeymapEvent>()
        let leaderStroke = try normalizeKeyStroke(KeyStrokeInput(name: "x", ctrl: true))
        env.tokens["leader"] = ResolvedKeyToken(
            stroke: leaderStroke,
            match: try createKeyMatch(leaderStroke.asStrokeInput)
        )
        env.patterns["count"] = makeCountPattern()

        let compiler = createCompilerService(environment: env, notify: notify, conditions: conditions)
        let compiled = compiler.compileBindings(
            [
                Binding(key: "<leader>f", commandName: "find"),
                Binding(key: "<leader>s", commandName: "save"),
                Binding(key: "{count}w", commandName: "word"),
                Binding(key: "r", commandName: "release-only", event: .release),
            ],
            tokens: env.tokens,
            sourceTarget: nil,
            sourceLayerOrder: 0
        )

        let root = buildSequenceTree(compiled.bindings, patterns: env.patterns)
        let rootChildren = childNodes(root)
        #expect(rootChildren.count == 2) // <leader> direct child + {count} pattern child
        #expect(rootChildren[0].depth == 1)
        #expect(rootChildren[1].pattern?.name == "count")

        let leaderMatch = env.tokens["leader"]!.match
        let leaderNode = try #require(firstNodeForMatch(root: root, match: leaderMatch))
        #expect(getNodePresentation(leaderNode) == SequenceNodePresentation(display: "<leader>", tokenName: "leader"))

        let fMatch = try createKeyMatch(KeyStrokeInput(name: "f"))
        let fNode = try #require(firstNodeForMatch(root: leaderNode, match: fMatch))
        let nodeSeq = getNodeSequence(fNode)
        #expect(nodeSeq.map(\.match) == [leaderMatch, fMatch])
        #expect(fNode.bindings.count == 1)
        #expect(fNode.bindings[0].command?.commandName == "find")

        let activeOpts = activeOptionsForBindings(compiled.bindings)
        #expect(activeOpts.count == 4)
        #expect(activeOpts[0].exact == false && activeOpts[0].continues == true)
        #expect(activeOpts[3].exact == true && activeOpts[3].continues == false)
    }

    @Test("advanceSequenceBinding, advanceSequenceCapture, collectRootSequenceCaptures, popCapture, and collectSequencePartsFromPending")
    func sequenceAdvancementAndPendingHelpers() throws {
        let notify = KeymapNotifier()
        let conditions = createConditionService(readData: { [:] }, notify: notify)
        let env = CompilerEnvironment<String, BasicKeymapEvent>()
        let countPattern = makeCountPattern(min: 1, max: 3)
        env.patterns["count"] = countPattern

        let compiler = createCompilerService(environment: env, notify: notify, conditions: conditions)
        let compiled = compiler.compileBindings(
            [
                Binding(key: "{count}w", commandName: "word"),
                Binding(key: "x", commandName: "direct-x"),
                Binding(key: "y", commandName: "fallback-y"),
            ],
            tokens: [:],
            sourceTarget: nil,
            sourceLayerOrder: 0
        )

        let root = buildSequenceTree(compiled.bindings, patterns: env.patterns)
        let layer = RegisteredLayer<String, BasicKeymapEvent>(
            order: 0,
            bindings: compiled.bindings,
            root: root
        )

        let matchPattern: (String, BasicKeymapEvent) -> SequencePatternMatch? = { name, event in
            matchSequencePattern(patterns: env.patterns, notify: notify, patternName: name, event: event)
        }
        let createPart: (BasicKeymapEvent, String, SequencePatternMatch) -> KeySequencePart = { event, name, match in
            try! createPatternEventPart(patterns: env.patterns, event: event, patternName: name, match: match)
        }

        // Priority test: direct match "x" beats fallback match "y"
        let xMatch = try createKeyMatch(KeyStrokeInput(name: "x"))
        let yMatch = try createKeyMatch(KeyStrokeInput(name: "y"))
        let prioritized = collectRootSequenceCaptures(
            layer: layer,
            matchKeys: [xMatch, yMatch],
            event: BasicKeymapEvent(name: "x"),
            matchPattern: matchPattern,
            createPatternPart: createPart
        )
        #expect(prioritized.count == 1)
        #expect(prioritized[0].binding.command?.commandName == "direct-x")
        #expect(capturePriority(prioritized[0], matchKeys: [xMatch, yMatch]) == 0)

        // Pattern repetition test: "1" -> "2" -> "w"
        let ev1 = BasicKeymapEvent(name: "1")
        let caps1 = collectRootSequenceCaptures(
            layer: layer,
            matchKeys: [try createKeyMatch(KeyStrokeInput(name: "1"))],
            event: ev1,
            matchPattern: matchPattern,
            createPatternPart: createPart
        )
        #expect(caps1.count == 1)
        let cap1 = caps1[0]
        #expect(patternCaptureCount(cap1) == 1)
        #expect(captureHasMinimum(cap1, patterns: env.patterns) == true)
        #expect(captureHasContinuations(cap1, patterns: env.patterns) == true)
        #expect(captureIsExact(cap1, patterns: env.patterns) == false)
        #expect(getCaptureNode(root: root, capture: cap1)?.pattern?.name == "count")

        // Active continuation options after "1" should expose "w"
        let nextOpts = activeOptionsForCaptures(caps1, patterns: env.patterns)
        #expect(nextOpts.count == 1)
        #expect(nextOpts[0].part.stroke.name == "w")
        #expect(nextOpts[0].exact == true)

        // Advance with "2" (stays on index 0 of pattern)
        let cap2 = try #require(
            advanceSequenceCapture(
                cap1,
                matchKeys: [try createKeyMatch(KeyStrokeInput(name: "2"))],
                event: BasicKeymapEvent(name: "2"),
                patterns: env.patterns,
                matchPattern: matchPattern,
                createPatternPart: createPart
            )
        )
        #expect(cap2.index == 0)
        #expect(patternCaptureCount(cap2) == 2)

        // Pending sequence equality & popping repeated pattern stroke
        let pending2 = PendingSequenceState(captures: [cap2])
        #expect(isSamePendingSequence(pending2, PendingSequenceState(captures: [cap2])) == true)
        #expect(isSamePendingSequence(pending2, PendingSequenceState(captures: [cap1])) == false)
        #expect(isSamePendingSequence(nil as PendingSequenceState<String, BasicKeymapEvent>?, nil) == true)

        let popped = try #require(popCapture(cap2))
        #expect(popped.index == 0)
        #expect(patternCaptureCount(popped) == 1)
        #expect(popCapture(popped) == nil)

        // Collect sequence parts from pending
        let collectedParts = collectSequencePartsFromPending(pending2)
        #expect(collectedParts.map(\.display) == ["1", "2"])

        // Advance with "w" completes the binding and creates payload { count: 12 }
        let capDone = try #require(
            advanceSequenceCapture(
                cap2,
                matchKeys: [try createKeyMatch(KeyStrokeInput(name: "w"))],
                event: BasicKeymapEvent(name: "w"),
                patterns: env.patterns,
                matchPattern: matchPattern,
                createPatternPart: createPart
            )
        )
        #expect(captureIsExact(capDone, patterns: env.patterns) == true)
        let payload = createSequencePayload(patterns: env.patterns, notify: notify, capture: capDone)
        #expect(payload == .object(["count": .int(12)]))
    }

    @Test("collectSequencePartsFromPending resolves display and token conflicts")
    func pendingPartsConflictResolution() throws {
        let stroke = try normalizeKeyStroke(KeyStrokeInput(name: "x", ctrl: true))
        let match = try createKeyMatch(stroke.asStrokeInput)
        let partA = try createKeySequencePart(stroke.asStrokeInput, display: "<leader>", match: match, tokenName: "leader")
        let partB = try createKeySequencePart(stroke.asStrokeInput, display: "ctrl+x", match: match, tokenName: nil)
        let dummyBindingA = BindingState<String, BasicKeymapEvent>(
            binding: Binding(key: "<leader>a"),
            sequence: [partA],
            command: nil,
            parsedBinding: ParsedBinding(key: "<leader>a", sequence: [partA])
        )
        let dummyBindingB = BindingState<String, BasicKeymapEvent>(
            binding: Binding(key: "ctrl+xb"),
            sequence: [partB],
            command: nil,
            parsedBinding: ParsedBinding(key: "ctrl+xb", sequence: [partB])
        )
        let layer = RegisteredLayer<String, BasicKeymapEvent>(
            order: 0,
            bindings: [dummyBindingA, dummyBindingB],
            root: createSequenceNode(parent: nil, stroke: nil, match: nil)
        )

        let pending = PendingSequenceState<String, BasicKeymapEvent>(captures: [
            PendingSequenceCapture(layer: layer, binding: dummyBindingA, index: 0, parts: [partA]),
            PendingSequenceCapture(layer: layer, binding: dummyBindingB, index: 0, parts: [partB]),
        ])
        let parts = collectSequencePartsFromPending(pending)
        #expect(parts.count == 1)
        #expect(parts[0].display == "ctrl+x")
        #expect(parts[0].tokenName == nil)
    }
}

// MARK: - 4. Dispatch Decisions & Patterns

@Suite("OpenTUIKeymap DispatchDecisions & Patterns")
struct KeymapDispatchDecisionTests {
    @Test("Sync and deferred decisions brand identification")
    func decisionBranding() {
        let sync = createSyncDecision(.runExact)
        let deferred = createDeferredDecision(.continueSequence)

        #expect(isSyncDecision(sync) == true)
        #expect(isDeferredDecision(sync) == false)
        #expect(isDeferredDecision(deferred) == true)
        #expect(isSyncDecision(deferred) == false)
        #expect(isSyncDecision("not a decision") == false)
        #expect(isDeferredDecision(nil) == false)
    }

    @Test("sleepWithSignal respects immediate abort, mid-flight abort, and normal completion")
    func sleepWithSignalBehavior() async {
        // Already aborted -> immediate false
        let preAborted = KeymapAbortController()
        preAborted.abort()
        let immediateResult = await sleepWithSignal(50, signal: preAborted.signal)
        #expect(immediateResult == false)

        // Normal short completion -> true
        let normal = KeymapAbortController()
        let normalResult = await sleepWithSignal(5, signal: normal.signal)
        #expect(normalResult == true)

        // Aborted mid-flight -> false
        let midFlight = KeymapAbortController()
        let task = Task {
            await sleepWithSignal(5_000, signal: midFlight.signal)
        }
        try? await Task.sleep(for: .milliseconds(10))
        midFlight.abort()
        let abortedResult = await task.value
        #expect(abortedResult == false)
    }

    @Test("matchSequencePattern and createSequencePayload handle errors and duplicate payload keys")
    func dispatchPatternsErrorsAndAggregation() throws {
        let notify = KeymapNotifier()
        let failingMatcher = ResolvedSequencePattern<BasicKeymapEvent>(
            name: "bad",
            matcher: { _ in throw SampleTestError.boom }
        )
        let numPattern = ResolvedSequencePattern<BasicKeymapEvent>(
            name: "num",
            payloadKey: "nums",
            matcher: { event in SequencePatternMatch(value: .string(event.name)) },
            finalize: { values in .string(values.map(\.stringDescription).joined()) }
        )
        let badFinalizer = ResolvedSequencePattern<BasicKeymapEvent>(
            name: "badFin",
            matcher: { event in SequencePatternMatch(value: .string(event.name)) },
            finalize: { _ in throw SampleTestError.boom }
        )
        let patterns = ["bad": failingMatcher, "num": numPattern, "badFin": badFinalizer]

        // Error in matcher emits diagnostic and returns nil
        let matched = matchSequencePattern(
            patterns: patterns,
            notify: notify,
            patternName: "bad",
            event: BasicKeymapEvent(name: "a")
        )
        #expect(matched == nil)
        #expect(notify.errors.last?.code == "sequence-pattern-match-error")

        // Duplicate payloadKey aggregates into array; failing finalizer emits diagnostic and skips
        let part = try createPatternEventPart(
            patterns: patterns,
            event: BasicKeymapEvent(name: "5"),
            patternName: "num",
            match: SequencePatternMatch(value: .string("5"))
        )
        #expect(part.patternName == "num")
        #expect(part.payloadKey == "nums")

        let binding = BindingState<String, BasicKeymapEvent>(
            binding: Binding(key: "{num}{num}"),
            sequence: [part],
            command: nil,
            parsedBinding: ParsedBinding(key: "{num}{num}", sequence: [part])
        )
        let layer = RegisteredLayer<String, BasicKeymapEvent>(
            order: 0,
            bindings: [binding],
            root: createSequenceNode(parent: nil, stroke: nil, match: nil)
        )
        let capture = PendingSequenceCapture(
            layer: layer,
            binding: binding,
            index: 0,
            parts: [part],
            patterns: [
                PendingSequencePatternCapture(name: "num", payloadKey: "nums", values: ["1", "2"], parts: [part]),
                PendingSequencePatternCapture(name: "num", payloadKey: "nums", values: ["3"], parts: [part]),
                PendingSequencePatternCapture(name: "badFin", payloadKey: "oops", values: ["x"], parts: [part]),
            ]
        )

        let payload = createSequencePayload(patterns: patterns, notify: notify, capture: capture)
        #expect(payload == .object(["nums": .array(["12", "3"])]))
        #expect(notify.errors.contains { $0.code == "sequence-pattern-finalize-error" })
    }
}

// MARK: - 5. Layers, Focus Semantics, Slots, Tokens & Diagnostics

@Suite("OpenTUIKeymap Layers")
struct KeymapLayersTests {
    @Test("Layer stack priority, focus vs focus-within, target destruction, and conflict diagnostics")
    func layersFocusPriorityAndDiagnostics() throws {
        let host = InMemoryKeymapHost<String, BasicKeymapEvent>(rootTarget: "root")
        host.setParent("root", for: "parent")
        host.setParent("parent", for: "child")
        host.setFocusedTarget("child")

        let state = LayerStackState<String, BasicKeymapEvent>()
        let notify = KeymapNotifier()
        let conditions = createConditionService(readData: { state.data }, notify: notify)
        let compilerEnv = CompilerEnvironment<String, BasicKeymapEvent>()
        let compiler = createCompilerService(environment: compilerEnv, notify: notify, conditions: conditions)
        let diagnostics: DefaultLayerDiagnostics<String, BasicKeymapEvent> = createLayerDiagnostics(notify: notify)

        let analyzedOrders = AtomicBox<[Int]>([])
        diagnostics.appendLayerAnalyzer { ctx in
            analyzedOrders.value.append(ctx.order)
            for b in ctx.bindings {
                if let name = b.command?.commandName, ctx.checkCommandResolution(name) == .unresolved {
                    ctx.warn("unresolved-command", detail: name, message: "Unresolved command \(name)")
                }
            }
        }

        let layers = createLayerService(
            state: state,
            notify: notify,
            conditions: conditions,
            compiler: compiler,
            host: host,
            diagnostics: diagnostics
        )

        // Global layer (priority 0, order 0)
        let offGlobal = layers.registerLayer(
            Layer(
                bindings: [Binding(key: "x", commandName: "global-x")],
                commands: [Command(name: "global-x") { _ in true }]
            )
        )

        // Parent layer with default focus-within (priority 0, order 1) -> active when child is focused
        _ = layers.registerLayer(
            Layer(
                target: "parent",
                bindings: [Binding(key: "x", commandName: "parent-x")],
                commands: [Command(name: "parent-x") { _ in true }]
            )
        )

        // Parent layer with strict focus mode (priority 10, order 2) -> NOT active when child is focused
        _ = layers.registerLayer(
            Layer(
                target: "parent",
                priority: 10,
                bindings: [Binding(key: "x", commandName: "parent-focus-only")],
                commands: [Command(name: "parent-focus-only") { _ in true }],
                targetMode: .focus
            )
        )

        #expect(getActivationPath(host: host, focused: "child") == Set(["child", "parent", "root"]))
        let activeForChild = layers.resolveActiveBindings()
        #expect(activeForChild.map { $0.binding.command?.commandName } == ["parent-x", "global-x"])

        // Conflict detection identifies parent-x shadowing global-x
        let conflicts = layers.detectActiveConflicts()
        #expect(conflicts.count == 1)
        #expect(conflicts[0].winningBinding.command?.commandName == "parent-x")
        #expect(conflicts[0].shadowedBinding.command?.commandName == "global-x")

        // Focus parent directly -> focus-only layer (priority 10) now wins!
        host.setFocusedTarget("parent")
        let activeForParent = layers.resolveActiveBindings()
        #expect(activeForParent.first?.binding.command?.commandName == "parent-focus-only")

        // Destroying "parent" automatically unregisters its layers
        host.destroyTarget("parent")
        #expect(state.layers.count == 1)
        #expect(layers.resolveActiveBindings(focused: "root").map { $0.binding.command?.commandName } == ["global-x"])

        // Registering on destroyed target emits destroyed-layer-target error
        _ = layers.registerLayer(Layer(target: "parent", bindings: [Binding(key: "a", commandName: "nope")]))
        #expect(notify.errors.contains { $0.code == "destroyed-layer-target" })

        // targetMode without target emits register-layer-failed
        _ = layers.registerLayer(Layer(bindings: [Binding(key: "a", commandName: "nope")], targetMode: .focus))
        #expect(notify.errors.contains { $0.code == "register-layer-failed" })

        offGlobal()
        #expect(state.layers.isEmpty)
        #expect(analyzedOrders.value == [0, 1, 2])
    }

    @Test("LayerSlot preserves mount order across replaceLayer and applyTokenState recompiles token bindings")
    func slotsAndTokenRecompilation() throws {
        let host = InMemoryKeymapHost<String, BasicKeymapEvent>(rootTarget: "root")
        let state = LayerStackState<String, BasicKeymapEvent>()
        let notify = KeymapNotifier()
        let conditions = createConditionService(readData: { state.data }, notify: notify)
        let compilerEnv = CompilerEnvironment<String, BasicKeymapEvent>()
        let compiler = createCompilerService(environment: compilerEnv, notify: notify, conditions: conditions)
        let pendingCleared = AtomicBox(false)

        let layers = createLayerService(
            state: state,
            notify: notify,
            conditions: conditions,
            activation: LayerActivationHooks(
                setPendingSequence: { next in
                    state.pending = next
                    if next == nil { pendingCleared.value = true }
                }
            ),
            compiler: compiler,
            host: host
        )

        // Reserve slot at order 0, then register another layer at order 1
        let slot = layers.createSlot()
        #expect(slot.order == 0)

        _ = layers.registerLayer(Layer(bindings: [Binding(key: "a", commandName: "later-layer")]))

        // Mount into slot 0 -> keeps order 0 (below order 1)
        let mounted = try #require(
            layers.replaceLayer(
                slot: slot,
                layer: Layer(bindings: [Binding(key: "<leader>q", commandName: "quit")])
            )
        )
        #expect(mounted.order == 0)
        #expect(mounted.hasTokenBindings == true)
        #expect(mounted.bindings.isEmpty) // <leader> not registered yet
        #expect(state.layers.map(\.order) == [0, 1])

        // Applying token state compiles <leader>q and updates the sequence tree
        let leaderStroke = try normalizeKeyStroke(KeyStrokeInput(name: "space"))
        let token = ResolvedKeyToken(stroke: leaderStroke, match: try createKeyMatch(leaderStroke.asStrokeInput))
        layers.applyTokenState(["leader": token])

        #expect(mounted.bindings.count == 1)
        #expect(mounted.bindings[0].sequence.count == 2)
        #expect(firstNodeForMatch(root: mounted.root, match: token.match) != nil)

        // Clearing slot removes its layer
        let cleared = layers.replaceLayer(slot: slot, layer: nil)
        #expect(cleared == nil)
        #expect(state.layers.count == 1)
        layers.cleanup()
    }

    @Test("Reactive matchers subscribe on layer registration, fire state change, and dispose on cleanup")
    func reactiveMatcherLifecycle() {
        let host = InMemoryKeymapHost<String, BasicKeymapEvent>(rootTarget: "root")
        let state = LayerStackState<String, BasicKeymapEvent>()
        let notify = KeymapNotifier()
        let conditions = createConditionService(readData: { state.data }, notify: notify)
        let compilerEnv = CompilerEnvironment<String, BasicKeymapEvent>()

        let enabled = AtomicBox(true)
        let listenerBox = AtomicBox<(@Sendable () -> Void)?>(nil)
        let disposedCount = AtomicBox(0)

        state.layerFields["enabled"] = { _, ctx in
            ctx.activeWhen(
                ReactiveMatcher(
                    get: { enabled.value },
                    subscribe: { onChange in
                        listenerBox.value = onChange
                        return { disposedCount.value += 1 }
                    }
                )
            )
        }

        let compiler = createCompilerService(environment: compilerEnv, notify: notify, conditions: conditions)
        let layers = createLayerService(
            state: state,
            notify: notify,
            conditions: conditions,
            compiler: compiler,
            host: host
        )

        let stateChanges = AtomicBox(0)
        notify.onStateChange { stateChanges.value += 1 }

        _ = layers.registerLayer(
            Layer(
                bindings: [Binding(key: "x", commandName: "act")],
                fields: ["enabled": true]
            )
        )

        #expect(state.activeKeyCacheBlockers == 1)
        #expect(layers.resolveActiveBindings().count == 1)

        // Flip reactive signal -> fires state change and disables bindings
        let changesBefore = stateChanges.value
        enabled.value = false
        listenerBox.value?()
        #expect(stateChanges.value == changesBefore + 1)
        #expect(layers.resolveActiveBindings().isEmpty)

        layers.cleanup()
        #expect(disposedCount.value == 1)
    }
}

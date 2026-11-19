// Pure Swift 6 port of keymap/src/services/notify.ts, keymap/src/services/state.ts,
// keymap/src/services/extension-context.ts, keymap/src/runtime-modules.ts, and keymap/src/types.ts.

// MARK: - Core Types & Contracts (src/types.ts)

// parity: keymap/src/types.ts#KeymapEvent [status=implemented hash=69e7fe21f748]
public extension KeymapEvent {
    /// Returns a `KeyStrokeInput` representation of this event.
    var asKeyStrokeInput: KeyStrokeInput {
        KeyStrokeInput(
            name: name,
            ctrl: ctrl,
            shift: shift,
            meta: meta,
            super: `super` ?? false,
            hyper: hyper == true ? true : nil
        )
    }
}

// parity: keymap/src/types.ts#HostPlatform [status=implemented hash=60b6ecd0e59a]
public extension HostPlatform {
    var defaultPrimaryModifier: HostPrimaryModifier {
        switch self {
        case .macos: return .super
        case .windows, .linux: return .ctrl
        case .unknown: return .unknown
        }
    }
}

// parity: keymap/src/types.ts#HostModifier [status=implemented hash=a8dbb5ce4fef]
public extension HostModifier {
    static let allModifiers: [HostModifier] = [.ctrl, .shift, .meta, .super, .hyper]
}

// parity: keymap/src/types.ts#HostCapability [status=implemented hash=a5e1fa37dd5f]
public extension HostCapability {
    var isSupported: Bool { self == .supported }
}

// parity: keymap/src/types.ts#HostMetadata [status=implemented hash=5d06fd98baaf]
public extension HostMetadata {
    func capability(for modifier: HostModifier) -> HostCapability {
        modifiers[modifier] ?? .unknown
    }
}

// parity: keymap/src/types.ts#KeymapHost [status=implemented hash=14cb2c5979f2]
public extension KeymapHost {
    var isLive: Bool { !isDestroyed }
}

// parity: keymap/src/types.ts#EventData [status=implemented hash=089f06ed866c]
public typealias KeymapEventData = EventData

// parity: keymap/src/types.ts#Attributes [status=implemented hash=cf6d8d6effbb]
public typealias KeymapAttributes = Attributes

// parity: keymap/src/types.ts#KeyStrokeInput [status=implemented hash=eb0a80518521]
public extension KeyStrokeInput {
    func normalized() throws(KeymapError) -> NormalizedKeyStroke {
        try normalizeKeyStroke(self)
    }
}

// parity: keymap/src/types.ts#NormalizedKeyStroke [status=implemented hash=4796383567a2]
public extension NormalizedKeyStroke {
    func canonicalString() throws(KeymapError) -> String {
        try stringifyKeyStroke(.stroke(asStrokeInput))
    }
}

// parity: keymap/src/types.ts#KeyMatch [status=implemented hash=8ed82bd81647]
public typealias KeymapKeyMatch = KeyMatch

// parity: keymap/src/types.ts#EventMatchResolverContext [status=implemented hash=d453e637906a]
public extension EventMatchResolverContext {
    func resolveStroke(_ stroke: KeyStrokeInput) throws -> KeyMatch {
        try resolveKey(.stroke(stroke))
    }
}

// parity: keymap/src/types.ts#EventMatchResolver [status=implemented hash=db2c1e0b2ce1]
public typealias KeymapEventMatchResolver<Event: KeymapEvent> = EventMatchResolver<Event>

// parity: keymap/src/types.ts#KEY_DISAMBIGUATION_DECISION [status=implemented hash=bde3e78d5a7b]
public let KEY_DISAMBIGUATION_DECISION = "keymap-disambiguation-decision"

// parity: keymap/src/types.ts#KEY_DEFERRED_DISAMBIGUATION_DECISION [status=implemented hash=2d531e7977de]
public let KEY_DEFERRED_DISAMBIGUATION_DECISION = "keymap-deferred-disambiguation-decision"

// parity: keymap/src/types.ts#KeyDisambiguationDecision [status=implemented hash=0a431cc98253]
public extension KeyDisambiguationDecision {
    var decisionBrand: String { KEY_DISAMBIGUATION_DECISION }
}

// parity: keymap/src/types.ts#KeyDeferredDisambiguationDecision [status=implemented hash=b862df3eab58]
public extension KeyDeferredDisambiguationDecision {
    var deferredDecisionBrand: String { KEY_DEFERRED_DISAMBIGUATION_DECISION }
}

// parity: keymap/src/types.ts#KeyDisambiguationContext [status=implemented hash=bddd30819cce]
public extension KeyDisambiguationContext {
    var hasExactMatch: Bool { !exact.isEmpty }
    var hasContinuations: Bool { !continuations.isEmpty }
}

// parity: keymap/src/types.ts#KeyDeferredDisambiguationContext [status=implemented hash=45c628bf6c0e]
public extension KeyDeferredDisambiguationContext {
    var isAborted: Bool { signal.isAborted }
}

// parity: keymap/src/types.ts#KeyDeferredDisambiguationHandler [status=implemented hash=e0645aae6921]
public typealias KeymapDeferredDisambiguationHandler = KeyDeferredDisambiguationHandler

// parity: keymap/src/types.ts#KeyDisambiguationResolver [status=implemented hash=0fe77f2eb4a8]
public typealias KeymapDisambiguationResolver<Target: Hashable & Sendable, Event: KeymapEvent> =
    KeyDisambiguationResolver<Target, Event>

// parity: keymap/src/types.ts#ResolvedKeyToken [status=implemented hash=96ca04ee7f6c]
public extension ResolvedKeyToken {
    var strokeInput: KeyStrokeInput { stroke.asStrokeInput }
}

// parity: keymap/src/types.ts#KeySequencePart [status=implemented hash=f89a4db9268f]
public extension KeySequencePart {
    var isPattern: Bool { patternName != nil }
    var isToken: Bool { tokenName != nil }
}

// parity: keymap/src/types.ts#StringifyOptions [status=implemented hash=a67436428c9c]
public extension StringifyOptions {
    static let displayPreferred = StringifyOptions(preferDisplay: true)
}

// parity: keymap/src/types.ts#KeyStringifyInput [status=implemented hash=aee7fc979db3]
public extension KeyStringifyInput {
    func stringified(options: StringifyOptions? = nil) throws(KeymapError) -> String {
        try stringifyKeyStroke(self, options: options)
    }
}

// parity: keymap/src/types.ts#KeyLike [status=implemented hash=ac525f43ca6d]
public extension KeyLike {
    var rawString: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var rawStroke: KeyStrokeInput? {
        if case .stroke(let s) = self { return s }
        return nil
    }
}

// parity: keymap/src/types.ts#Command [status=implemented hash=a0aee7e3c866]
public extension Command {
    var descriptionField: String? {
        if case .string(let s) = fields["desc"] { return s }
        return nil
    }
}

// parity: keymap/src/types.ts#CommandQueryValue [status=implemented hash=200d3e607637]
public extension CommandQueryValue {
    static func string(_ value: String) -> Self { .exact(.string(value)) }
}

// parity: keymap/src/types.ts#CommandFilter [status=implemented hash=16765b1bb3ff]
public extension CommandFilter {
    static func field(_ key: String, equals value: KeymapValue) -> Self {
        .fields([key: .exact(value)])
    }
}

// parity: keymap/src/types.ts#CommandQuery [status=implemented hash=b65ae9c7476a]
public extension CommandQuery {
    static var allRegistered: Self { CommandQuery(visibility: .registered) }
}

// parity: keymap/src/types.ts#CommandBindingsQuery [status=implemented hash=29b683ba14c8]
public extension CommandBindingsQuery {
    static func reachable(_ commands: [String]) -> Self {
        CommandBindingsQuery(visibility: .reachable, commands: commands)
    }
}

// parity: keymap/src/types.ts#RunCommandOptions [status=implemented hash=f553f95c3312]
public extension RunCommandOptions {
    static var withCommand: Self { RunCommandOptions(includeCommand: true) }
}

// parity: keymap/src/types.ts#RunCommandResult [status=implemented hash=1d9e8b3b8d48]
public extension RunCommandResult {
    var isFailure: Bool { !ok }
}

// parity: keymap/src/types.ts#CommandContext [status=implemented hash=27e9553968cb]
public extension CommandContext {
    var hasPayload: Bool { payload != nil && payload != .undefined }
}

/// Result returned by a command handler: handled boolean, void, or structured `RunCommandResult`.
// parity: keymap/src/types.ts#CommandResult [status=implemented hash=0700175419c2]
public enum CommandResult<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    case handled(Bool)
    case void
    case runResult(RunCommandResult<Target, Event>)

    public var isRejected: Bool {
        switch self {
        case .handled(false):
            return true
        case .runResult(let result):
            return !result.ok && result.reason == .rejected
        default:
            return false
        }
    }

    public var asBoolResult: Bool? {
        switch self {
        case .handled(let value):
            return value
        case .void:
            return nil
        case .runResult(let result):
            return result.ok
        }
    }
}

// parity: keymap/src/types.ts#CommandResolutionStatus [status=implemented hash=a8b1f980a40b]
public extension CommandResolutionStatus {
    var isResolved: Bool { self == .resolved }
}

// parity: keymap/src/types.ts#CommandHandler [status=implemented hash=86ef77b401aa]
public typealias KeymapCommandHandler<Target: Hashable & Sendable, Event: KeymapEvent> = CommandHandler<Target, Event>

// parity: keymap/src/types.ts#BindingCommand [status=implemented hash=d37479279c24]
public extension BindingCommand {
    var isNamed: Bool { commandName != nil }
}

// parity: keymap/src/types.ts#BindingEvent [status=implemented hash=a20720b115e1]
public extension BindingEvent {
    var isRelease: Bool { self == .release }
}

// parity: keymap/src/types.ts#Binding [status=implemented hash=d462cf3ec3e5]
public extension Binding {
    var resolvedEvent: BindingEvent { event ?? .press }
}

// parity: keymap/src/types.ts#Bindings [status=implemented hash=9a1787f00f3b]
public typealias Bindings<Target: Hashable & Sendable, Event: KeymapEvent> = [Binding<Target, Event>]

// parity: keymap/src/types.ts#TargetMode [status=implemented hash=a80b14178eb1]
public extension TargetMode {
    var includesDescendants: Bool { self == .focusWithin }
}

// parity: keymap/src/types.ts#Layer [status=implemented hash=ada02bc3a6b4]
public extension Layer {
    var isGlobal: Bool { target == nil }
}

/// Structured result of parsing a whitespace-delimited command string (e.g. Ex command input).
// parity: keymap/src/types.ts#ParsedCommand [status=implemented hash=bcde54019280]
public struct ParsedCommand: Equatable, Hashable, Sendable {
    public let input: String
    public let name: String
    public let args: [String]

    public init(input: String, name: String, args: [String] = []) {
        self.input = input
        self.name = name
        self.args = args
    }
}

// parity: keymap/src/types.ts#CommandResolverContext [status=implemented hash=49306fda45c4]
public extension CommandResolverContext {
    var hasPayload: Bool { payload != nil && payload != .undefined }
}

// parity: keymap/src/types.ts#CommandResolver [status=implemented hash=6a8fb39e2e6d]
public typealias KeymapCommandResolver<Target: Hashable & Sendable, Event: KeymapEvent> =
    CommandResolver<Target, Event>

// parity: keymap/src/types.ts#KeyToken [status=implemented hash=0d35654f534b]
public extension KeyToken {
    func normalizedName() throws(KeymapError) -> String {
        try normalizeBindingTokenName(name)
    }
}

// parity: keymap/src/types.ts#SequencePatternMatch [status=implemented hash=77834a94123a]
public extension SequencePatternMatch {
    var hasValue: Bool { value != nil }
}

// parity: keymap/src/types.ts#SequencePattern [status=implemented hash=50d49b08a349]
public extension SequencePattern {
    var effectivePayloadKey: String { payloadKey ?? name }
}

// parity: keymap/src/types.ts#ResolvedSequencePattern [status=implemented hash=89abf3a922ea]
public extension ResolvedSequencePattern {
    var isFixedLength: Bool { min == max }
}

// parity: keymap/src/types.ts#ActiveBinding [status=implemented hash=4107d91695d6]
public extension ActiveBinding {
    var isMultiStroke: Bool { sequence.count > 1 }
}

// parity: keymap/src/types.ts#DispatchLayer [status=implemented hash=a76c880a7342]
public extension DispatchLayer {
    var isGlobal: Bool { target == nil }
}

// parity: keymap/src/types.ts#DispatchBinding [status=implemented hash=970518cb3bf8]
public extension DispatchBinding {
    var asActiveBinding: ActiveBinding<Target, Event> {
        ActiveBinding(
            sequence: sequence,
            command: command,
            commandAttrs: commandAttrs,
            attrs: attrs,
            event: event,
            preventDefault: preventDefault,
            fallthrough: `fallthrough`
        )
    }
}

// parity: keymap/src/types.ts#DispatchPhase [status=implemented hash=b8cccfe13da3]
public extension DispatchPhase {
    var isSequencePhase: Bool {
        switch self {
        case .sequenceStart, .sequenceAdvance, .sequenceClear: return true
        case .bindingExecute, .bindingReject: return false
        }
    }
}

// parity: keymap/src/types.ts#DispatchEvent [status=implemented hash=bf284e0c497e]
public extension DispatchEvent {
    var isBindingExecution: Bool { phase == .bindingExecute }
}

// parity: keymap/src/types.ts#KeyAfterReason [status=implemented hash=d573d83c96bf]
public extension KeyAfterReason {
    var wasHandled: Bool {
        self != .noMatch && self != .sequenceMiss && self != .bindingRejected
    }
}

// parity: keymap/src/types.ts#KeyAfterInputContext [status=implemented hash=298c17fb3ccb]
public extension KeyAfterInputContext {
    var hasPendingSequence: Bool { !pendingSequence.isEmpty }
}

// parity: keymap/src/types.ts#CommandEntry [status=implemented hash=707f1d9a55da]
public extension CommandEntry {
    var primaryBinding: ActiveBinding<Target, Event>? { bindings.first }
}

// parity: keymap/src/types.ts#ActiveKeyOptions [status=implemented hash=1c47307cde8f]
public extension ActiveKeyOptions {
    static let full = ActiveKeyOptions(includeBindings: true, includeMetadata: true)
}

// parity: keymap/src/types.ts#ActiveKey [status=implemented hash=170cc95a41c0]
public extension ActiveKey {
    var isTerminal: Bool { !continues }
}

// parity: keymap/src/types.ts#ReactiveMatcher [status=implemented hash=d5ef05a09ccc]
public extension ReactiveMatcher {
    var asMatcherInput: MatcherInput { .reactive(self) }
}

// parity: keymap/src/types.ts#BindingFieldContext [status=implemented hash=4622c3c1e4b5]
public typealias BindingFieldContext = FieldCompilerContext

// parity: keymap/src/types.ts#BindingFieldCompiler [status=implemented hash=b9a551978aa7]
public typealias BindingFieldCompiler = FieldCompiler

// parity: keymap/src/types.ts#LayerFieldContext [status=implemented hash=19f26d8ec7ee]
public typealias LayerFieldContext = FieldCompilerContext

// parity: keymap/src/types.ts#LayerFieldCompiler [status=implemented hash=3e4775976984]
public typealias LayerFieldCompiler = FieldCompiler

// parity: keymap/src/types.ts#LayerAnalysisContext [status=implemented hash=56f6a4e5c3bd]
public extension LayerAnalysisContext {
    var isGlobalLayer: Bool { target == nil }
}

// parity: keymap/src/types.ts#LayerBindingAnalysis [status=implemented hash=7441e8a210d6]
public extension LayerBindingAnalysis {
    var hasCommand: Bool { command != nil }
}

// parity: keymap/src/types.ts#LayerAnalyzer [status=implemented hash=24abf3129db1]
public typealias KeymapLayerAnalyzer<Target: Hashable & Sendable, Event: KeymapEvent> = LayerAnalyzer<Target, Event>

// parity: keymap/src/types.ts#BindingParserContext [status=implemented hash=48f9bb952f0f]
public extension BindingParserContext {
    var isAtStart: Bool { index == 0 }
}

// parity: keymap/src/types.ts#BindingExpanderContext [status=implemented hash=36aab82ba3ef]
public extension BindingExpanderContext {
    var hasDisplays: Bool { displays != nil }
}

// parity: keymap/src/types.ts#BindingExpansion [status=implemented hash=57463a5c6b8b]
public extension BindingExpansion {
    var hasCustomDisplays: Bool { displays != nil }
}

// parity: keymap/src/types.ts#BindingParserResult [status=implemented hash=e175b509b5fe]
public extension BindingParserResult {
    var hasUnknownTokens: Bool { !unknownTokens.isEmpty }
}

// parity: keymap/src/types.ts#BindingParser [status=implemented hash=4bed6245cbf3]
public typealias KeymapBindingParser = BindingParser

// parity: keymap/src/types.ts#BindingExpander [status=implemented hash=bea845b5b26f]
public typealias KeymapBindingExpander = BindingExpander

// parity: keymap/src/types.ts#ParsedBinding [status=implemented hash=e6e70ea7a750]
public extension ParsedBinding {
    var isSingleStroke: Bool { sequence.count == 1 }
}

// parity: keymap/src/types.ts#BindingTransformerContext [status=implemented hash=c0174ea63a37]
public extension BindingTransformerContext {
    func parseStroke(_ stroke: KeyStrokeInput) throws -> KeySequencePart {
        try parseKey(.stroke(stroke))
    }
}

// parity: keymap/src/types.ts#BindingTransformer [status=implemented hash=1d009c65e50d]
public typealias KeymapBindingTransformer<Target: Hashable & Sendable, Event: KeymapEvent> =
    BindingTransformer<Target, Event>

// parity: keymap/src/types.ts#BindingsValidationResult [status=implemented hash=c83683c38a30]
public extension BindingsValidationResult {
    var failureReason: String? {
        if case .invalid(let reason) = self { return reason }
        return nil
    }
}

// parity: keymap/src/types.ts#LayerBindingsTransformerContext [status=implemented hash=ea7a45776dd2]
public extension LayerBindingsTransformerContext {
    var isGlobalLayer: Bool { layer.target == nil }
}

// parity: keymap/src/types.ts#LayerBindingsTransformer [status=implemented hash=ed8bb7456ab9]
public typealias KeymapLayerBindingsTransformer<Target: Hashable & Sendable, Event: KeymapEvent> =
    LayerBindingsTransformer<Target, Event>

// parity: keymap/src/types.ts#CommandTransformerContext [status=implemented hash=1f274de5d731]
public extension CommandTransformerContext {
    var isGlobalLayer: Bool { layer.target == nil }
}

// parity: keymap/src/types.ts#CommandTransformer [status=implemented hash=c94f74c1306f]
public typealias KeymapCommandTransformer<Target: Hashable & Sendable, Event: KeymapEvent> =
    CommandTransformer<Target, Event>

// parity: keymap/src/types.ts#CommandFieldContext [status=implemented hash=64a0980047d1]
public typealias CommandFieldContext = FieldCompilerContext

// parity: keymap/src/types.ts#CommandFieldCompiler [status=implemented hash=9a8d3b6b9e06]
public typealias CommandFieldCompiler = FieldCompiler

// parity: keymap/src/types.ts#KeyInputContext [status=implemented hash=f5da147f7ceb]
public extension KeyInputContext {
    var keyName: String { event.name }
}

// parity: keymap/src/types.ts#RawInputContext [status=implemented hash=915effe7b4cb]
public extension RawInputContext {
    var isEmpty: Bool { sequence.isEmpty }
}

/// Discriminated union of keymap lifecycle/dispatch hook payloads.
// parity: keymap/src/types.ts#Hooks [status=implemented hash=845e2888bc4d]
public enum Hooks<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    case state
    case pendingSequence([KeySequencePart])
    case dispatch(DispatchEvent<Target, Event>)
}

/// Hook event names exposed on a keymap's hook emitter.
// parity: keymap/src/types.ts#HookName [status=implemented hash=f0f3d9cc80bd]
public enum HookName: String, Equatable, Hashable, Sendable, CaseIterable {
    case state
    case pendingSequence
    case dispatch
}

// parity: keymap/src/types.ts#Listener [status=implemented hash=a8af4f16c120]
public typealias Listener<Value: Sendable> = @Sendable (Value) -> Void

/// Diagnostic warning payload emitted via `keymap.on(.warning(...))` or `NotificationService`.
// parity: keymap/src/types.ts#WarningEvent [status=implemented hash=6a7cf1a6d2e5]
public struct WarningEvent: Equatable, Sendable {
    public let code: String
    public let message: String
    public let warning: KeymapValue?

    public init(code: String, message: String, warning: KeymapValue? = nil) {
        self.code = code
        self.message = message
        self.warning = warning
    }
}

/// Diagnostic error payload emitted via `keymap.on(.error(...))` or `NotificationService`.
// parity: keymap/src/types.ts#ErrorEvent [status=implemented hash=fb9e2be241f9]
public struct ErrorEvent: Equatable, Sendable {
    public let code: String
    public let message: String
    public let error: KeymapValue?

    public init(code: String, message: String, error: KeymapValue? = nil) {
        self.code = code
        self.message = message
        self.error = error
    }
}

/// Complete union of events exposed by `Keymap.on(...)`.
// parity: keymap/src/types.ts#Events [status=implemented hash=b30fee9693a8]
public enum Events<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    case state
    case pendingSequence([KeySequencePart])
    case dispatch(DispatchEvent<Target, Event>)
    case warning(WarningEvent)
    case error(ErrorEvent)
}

/// Event names exposed by `Keymap.on(...)`.
// parity: keymap/src/types.ts#EventName [status=implemented hash=05ca28f8a50e]
public enum EventName: String, Equatable, Hashable, Sendable, CaseIterable {
    case state
    case pendingSequence
    case dispatch
    case warning
    case error
}

/// Discriminated union of intercept context payloads exposed by `Keymap.intercept(...)`.
// parity: keymap/src/types.ts#Intercepts [status=implemented hash=5a44c62ea5a6]
public enum Intercepts<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    case key(KeyInputContext<Event>)
    case keyAfter(KeyAfterInputContext<Target, Event>)
    case raw(RawInputContext)
}

/// Intercept channel names exposed by `Keymap.intercept(...)`.
// parity: keymap/src/types.ts#InterceptName [status=implemented hash=f138306ac915]
public enum InterceptName: String, Equatable, Hashable, Sendable, CaseIterable {
    case key = "key"
    case keyAfter = "key:after"
    case raw = "raw"
}

// parity: keymap/src/types.ts#KeyInterceptOptions [status=implemented hash=4f849fb984b5]
public extension KeyInterceptOptions {
    static let defaultPress = KeyInterceptOptions(priority: 0, release: false)
    static let defaultRelease = KeyInterceptOptions(priority: 0, release: true)
}

// parity: keymap/src/types.ts#RawInterceptOptions [status=implemented hash=cfe87a9ecee8]
public extension RawInterceptOptions {
    static let `default` = RawInterceptOptions(priority: 0)
}

// parity: keymap/src/types.ts#RuntimeMatcher [status=implemented hash=9a2beba8fb36]
public extension RuntimeMatcher {
    var isReactive: Bool { subscribe != nil }
}

// parity: keymap/src/types.ts#RuntimeMatchable [status=implemented hash=7e76ce990f81]
public extension RuntimeMatchable {
    var hasConditions: Bool { !requires.isEmpty || !matchers.isEmpty }
}

// parity: keymap/src/types.ts#BindingState [status=implemented hash=4cdcde504473]
public extension BindingState {
    var hasCommand: Bool { command != nil }
}

/// Public snapshot describing an active key selection candidate during active-key computation.
// parity: keymap/src/types.ts#ActiveKeySelection [status=implemented hash=c031d248b85b]
public struct KeymapActiveKeySelection<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let display: String
    public let tokenName: String?
    public let continues: Bool
    public let firstBinding: BindingState<Target, Event>?
    public let commandBinding: BindingState<Target, Event>?
    public let bindings: [BindingState<Target, Event>]?
    public let stop: Bool

    public init(
        display: String,
        tokenName: String? = nil,
        continues: Bool,
        firstBinding: BindingState<Target, Event>? = nil,
        commandBinding: BindingState<Target, Event>? = nil,
        bindings: [BindingState<Target, Event>]? = nil,
        stop: Bool
    ) {
        self.display = display
        self.tokenName = tokenName
        self.continues = continues
        self.firstBinding = firstBinding
        self.commandBinding = commandBinding
        self.bindings = bindings
        self.stop = stop
    }
}

/// Public mutable accumulator state for an active key prior to materialization.
// parity: keymap/src/types.ts#ActiveKeyState [status=implemented hash=e7801d488ca0]
public final class KeymapActiveKeyState<Target: Hashable & Sendable, Event: KeymapEvent>: @unchecked Sendable {
    public let stroke: NormalizedKeyStroke
    public let display: String
    public let tokenName: String?
    public var continues: Bool
    public var firstBinding: BindingState<Target, Event>?
    public var commandBinding: BindingState<Target, Event>?
    public var bindings: [BindingState<Target, Event>]?

    public init(
        stroke: NormalizedKeyStroke,
        display: String,
        tokenName: String? = nil,
        continues: Bool,
        firstBinding: BindingState<Target, Event>? = nil,
        commandBinding: BindingState<Target, Event>? = nil,
        bindings: [BindingState<Target, Event>]? = nil
    ) {
        self.stroke = stroke
        self.display = display
        self.tokenName = tokenName
        self.continues = continues
        self.firstBinding = firstBinding
        self.commandBinding = commandBinding
        self.bindings = bindings
    }
}

// parity: keymap/src/types.ts#CommandState [status=implemented hash=11d09ddc81f5]
public extension CommandState {
    var name: String { command.name }
}

// parity: keymap/src/types.ts#BindingCompilationResult [status=implemented hash=f622e3cf3932]
public extension BindingCompilationResult {
    var isEmpty: Bool { bindings.isEmpty }
}

// parity: keymap/src/types.ts#SequenceNode [status=implemented hash=cc64c514ae4c]
public extension SequenceNode {
    var isRoot: Bool { parent == nil }
}

// parity: keymap/src/types.ts#RegisteredLayer [status=implemented hash=da86c2c6568d]
public extension RegisteredLayer {
    var isGlobal: Bool { target == nil }
}

// parity: keymap/src/types.ts#PendingSequenceCapture [status=implemented hash=97d6104ec3ff]
public extension PendingSequenceCapture {
    var matchedLength: Int { parts.count }
}

// parity: keymap/src/types.ts#PendingSequencePatternCapture [status=implemented hash=2dcfc8c88afd]
public extension PendingSequencePatternCapture {
    var count: Int { values.count }
}

// parity: keymap/src/types.ts#PendingSequenceState [status=implemented hash=16590a776d80]
public extension PendingSequenceState {
    var isEmpty: Bool { captures.isEmpty }
}

// MARK: - Keymap State Service (services/state.ts)

// parity: keymap/src/services/state.ts#LayerCommandEntry [status=implemented hash=9b0358521c50]
public extension LayerCommandEntry {
    var commandName: String { commandState.command.name }
}

// parity: keymap/src/services/state.ts#ResolvedCommandEntry [status=implemented hash=17860283690c]
public extension ResolvedCommandEntry {
    var commandName: String { command.name }
}

// parity: keymap/src/services/state.ts#ActiveCommandView [status=implemented hash=f83edcb619cd]
public extension ActiveCommandView {
    var isEmpty: Bool { entries.isEmpty }
}

// parity: keymap/src/services/state.ts#CommandView [status=implemented hash=ff96ffe5eb29]
public extension CommandView {
    var isEmpty: Bool { entries.isEmpty }
}

/// Complete mutable runtime state container mirroring upstream `services/state.ts#State`.
// parity: keymap/src/services/state.ts#State [status=implemented hash=fc6d9426fd46]
public final class State<Target: Hashable & Sendable, Event: KeymapEvent>: @unchecked Sendable {
    public var order: Int = 0
    public var tokens: [String: ResolvedKeyToken] = [:]
    public var patterns: [String: ResolvedSequencePattern<Event>] = [:]
    public var layerFields: [String: LayerFieldCompiler] = [:]
    public let layerBindingsTransformers: OrderedRegistry<LayerBindingsTransformer<Target, Event>>
    public let bindingExpanders: OrderedRegistry<BindingExpander>
    public let bindingParsers: OrderedRegistry<BindingParser>
    public let bindingTransformers: OrderedRegistry<BindingTransformer<Target, Event>>
    public var bindingFields: [String: BindingFieldCompiler] = [:]
    public let commandTransformers: OrderedRegistry<CommandTransformer<Target, Event>>
    public var commandFields: [String: CommandFieldCompiler] = [:]
    public let eventMatchResolvers: OrderedRegistry<EventMatchResolver<Event>>
    public let disambiguationResolvers: OrderedRegistry<KeyDisambiguationResolver<Target, Event>>
    public let keyHooks: PriorityRegistry<@Sendable (KeyInputContext<Event>) throws -> Void, Bool>
    public let keyAfterHooks: PriorityRegistry<@Sendable (KeyAfterInputContext<Target, Event>) throws -> Void, Bool>
    public let rawHooks: PriorityRegistry<@Sendable (RawInputContext) throws -> Void, Void>
    public var layers: [RegisteredLayer<Target, Event>] = []
    public var sortedLayers: [RegisteredLayer<Target, Event>] = []
    public var activeLayersCacheVersion: Int = -1
    public var activeLayersCacheFocused: Target? = nil
    public var activeLayersCache: [RegisteredLayer<Target, Event>] = []
    public var activeKeyCacheBlockers: Int = 0
    public var activeCommandViewCacheBlockers: Int = 0
    public let commandResolvers: OrderedRegistry<CommandResolver<Target, Event>>
    public var pending: PendingSequenceState<Target, Event>? = nil
    public var data: EventData = [:]
    public var dataVersion: Int = 0
    public var readonlyDataVersion: Int = -1
    public var readonlyData: EventData = [:]
    public var cacheVersion: Int = 0
    public var derivedVersion: Int = 0
    public var stateChangeDepth: Int = 0
    public var stateChangePending: Bool = false
    public var flushingStateChange: Bool = false
    public var usedWarningKeys: Set<String> = []

    public init() {
        self.layerBindingsTransformers = createRuntimeOrderedRegistry()
        self.bindingExpanders = createRuntimeOrderedRegistry()
        self.bindingParsers = createRuntimeOrderedRegistry()
        self.bindingTransformers = createRuntimeOrderedRegistry()
        self.commandTransformers = createRuntimeOrderedRegistry()
        self.eventMatchResolvers = createRuntimeOrderedRegistry()
        self.disambiguationResolvers = createRuntimeOrderedRegistry()
        self.keyHooks = createRuntimePriorityRegistry()
        self.keyAfterHooks = createRuntimePriorityRegistry()
        self.rawHooks = createRuntimePriorityRegistry()
        self.commandResolvers = createRuntimeOrderedRegistry()
    }
}

// parity: keymap/src/services/state.ts#createKeymapState [status=implemented hash=0f03c4d0ad22]
public func createKeymapState<Target: Hashable & Sendable, Event: KeymapEvent>() -> State<Target, Event> {
    State()
}

// MARK: - Notification Service (services/notify.ts)

// parity: keymap/src/services/notify.ts#MAX_STATE_CHANGE_FLUSH_ITERATIONS [status=implemented hash=252a3ad49083]
public let MAX_STATE_CHANGE_FLUSH_ITERATIONS: Int = 1000

public enum DiagnosticChannel: String, Equatable, Hashable, Sendable {
    case warning
    case error
}

public enum DiagnosticPayload: Equatable, Sendable {
    case warning(WarningEvent)
    case error(ErrorEvent)
}

public struct QueueStateChangeOptions: Equatable, Hashable, Sendable {
    public let invalidateCaches: Bool

    public init(invalidateCaches: Bool = true) {
        self.invalidateCaches = invalidateCaches
    }
}

// parity: keymap/src/services/notify.ts#NotificationService [status=implemented hash=3cc3fbf2fa7c]
public protocol NotificationService<Target, Event>: AnyObject, Sendable {
    associatedtype Target: Hashable & Sendable
    associatedtype Event: KeymapEvent

    func runWithStateChangeBatch<T>(_ fn: () throws -> T) rethrows -> T
    func queueStateChange(_ options: QueueStateChangeOptions?)
    func onStateEvent(_ listener: @escaping @Sendable () -> Void)
    func emitWarning(_ code: String, warning: KeymapValue?, message: String)
    func emitError(_ code: String, error: KeymapValue?, message: String)
    func reportListenerError(_ name: HookName, error: any Error)
    func warnOnce(key: String, code: String, warning: KeymapValue?, message: String)
}

public final class DefaultNotificationService<Target: Hashable & Sendable, Event: KeymapEvent>: NotificationService,
    @unchecked Sendable
{
    private let state: State<Target, Event>
    private let events: Emitter<DiagnosticChannel, DiagnosticPayload>
    private let hooks: Emitter<HookName, Hooks<Target, Event>>
    private var beforeStateEvent: (@Sendable () -> Void)?

    public private(set) var fallbackWarnings: [WarningEvent] = []
    public private(set) var fallbackErrors: [ErrorEvent] = []

    public init(
        state: State<Target, Event>,
        events: Emitter<DiagnosticChannel, DiagnosticPayload>,
        hooks: Emitter<HookName, Hooks<Target, Event>>
    ) {
        self.state = state
        self.events = events
        self.hooks = hooks
    }

    public func runWithStateChangeBatch<T>(_ fn: () throws -> T) rethrows -> T {
        state.stateChangeDepth += 1
        defer {
            state.stateChangeDepth -= 1
            if state.stateChangeDepth == 0 {
                flushStateChange()
            }
        }
        return try fn()
    }

    public func queueStateChange(_ options: QueueStateChangeOptions? = nil) {
        state.derivedVersion += 1
        if options?.invalidateCaches != false {
            state.cacheVersion += 1
        }
        guard hooks.has(.state) else {
            return
        }
        state.stateChangePending = true
        if state.stateChangeDepth == 0 && !state.flushingStateChange {
            flushStateChange()
        }
    }

    public func onStateEvent(_ listener: @escaping @Sendable () -> Void) {
        beforeStateEvent = listener
    }

    public func emitWarning(_ code: String, warning: KeymapValue? = nil, message: String) {
        let payload = WarningEvent(code: code, message: message, warning: warning)
        if !events.has(.warning) {
            fallbackWarnings.append(payload)
            return
        }
        events.emit(.warning, .warning(payload))
    }

    public func emitError(_ code: String, error: KeymapValue? = nil, message: String) {
        let payload = ErrorEvent(code: code, message: message, error: error)
        if !events.has(.error) {
            fallbackErrors.append(payload)
            return
        }
        events.emit(.error, .error(payload))
    }

    public func reportListenerError(_ name: HookName, error: any Error) {
        let detail = KeymapValue.string(getErrorMessage(error, fallback: String(describing: error)))
        switch name {
        case .state:
            emitError("state-listener-error", error: detail, message: "[Keymap] Error in state listener:")
        case .pendingSequence:
            emitError(
                "pending-sequence-listener-error",
                error: detail,
                message: "[Keymap] Error in pending sequence listener:"
            )
        case .dispatch:
            emitError("dispatch-listener-error", error: detail, message: "[Keymap] Error in dispatch listener:")
        }
    }

    public func warnOnce(key: String, code: String, warning: KeymapValue? = nil, message: String) {
        if state.usedWarningKeys.contains(key) {
            return
        }
        state.usedWarningKeys.insert(key)
        emitWarning(code, warning: warning, message: message)
    }

    private func flushStateChange() {
        if !state.stateChangePending || state.stateChangeDepth > 0 || state.flushingStateChange {
            return
        }
        state.flushingStateChange = true
        defer { state.flushingStateChange = false }

        var iterations = 0
        while state.stateChangePending && state.stateChangeDepth == 0 {
            if iterations >= MAX_STATE_CHANGE_FLUSH_ITERATIONS {
                state.stateChangePending = false
                emitError(
                    "state-change-feedback-loop",
                    error: .object(["iterations": .int(MAX_STATE_CHANGE_FLUSH_ITERATIONS)]),
                    message:
                        "[Keymap] Possible infinite state listener feedback loop detected after \(MAX_STATE_CHANGE_FLUSH_ITERATIONS) iterations; pending state notifications were dropped"
                )
                break
            }
            iterations += 1
            state.stateChangePending = false
            beforeStateEvent?()
            hooks.emit(.state, .state)
        }
    }
}

// parity: keymap/src/services/notify.ts#createNotificationService [status=implemented hash=8d741a6ac908]
public func createNotificationService<Target: Hashable & Sendable, Event: KeymapEvent>(
    state: State<Target, Event>,
    events: Emitter<DiagnosticChannel, DiagnosticPayload>,
    hooks: Emitter<HookName, Hooks<Target, Event>>
) -> DefaultNotificationService<Target, Event> {
    DefaultNotificationService(state: state, events: events, hooks: hooks)
}

// MARK: - Extension Context & Layer Slots (services/extension-context.ts)

// parity: keymap/src/services/extension-context.ts#KEYMAP_EXTENSION_CONTEXT [status=implemented hash=ab6a8855c68b]
public let KEYMAP_EXTENSION_CONTEXT = "keymap-extension-context"

/// Internal service bundle exposed to extras and framework adapters via `KeymapExtensionProvider`.
// parity: keymap/src/services/extension-context.ts#KeymapExtensionContext [status=implemented hash=cd282020ef98]
public struct KeymapExtensionContext<Host: KeymapHost>: Sendable {
    public typealias Target = Host.Target
    public typealias Event = Host.Event

    public let state: LayerStackState<Target, Event>
    public let host: Host
    public let conditions: any ConditionService
    public let catalog: any CommandCatalogService<Target, Event>
    public let activation: any ActivationService<Target, Event>
    public let layers: any LayerService<Target, Event>

    public init(
        state: LayerStackState<Target, Event>,
        host: Host,
        conditions: any ConditionService,
        catalog: any CommandCatalogService<Target, Event>,
        activation: any ActivationService<Target, Event>,
        layers: any LayerService<Target, Event>
    ) {
        self.state = state
        self.host = host
        self.conditions = conditions
        self.catalog = catalog
        self.activation = activation
        self.layers = layers
    }
}

// parity: keymap/src/services/extension-context.ts#KeymapExtensionProvider [status=implemented hash=9ce071b58f62]
public protocol KeymapExtensionProvider<Host>: AnyObject, Sendable {
    associatedtype Host: KeymapHost
    func keymapExtensionContext() -> KeymapExtensionContext<Host>
}

extension Keymap: KeymapExtensionProvider {
    public func keymapExtensionContext() -> KeymapExtensionContext<Host> {
        let mirror = Mirror(reflecting: self)
        var resolvedState: LayerStackState<Target, Event>?
        var resolvedConditions: DefaultConditionService?
        var resolvedCatalog: DefaultCommandCatalogService<Host>?
        var resolvedActivation: DefaultActivationService<Host>?
        var resolvedLayers: DefaultLayerService<Host, DefaultCompilerService<Target, Event>>?

        for child in mirror.children {
            switch child.label {
            case "state":
                resolvedState = child.value as? LayerStackState<Target, Event>
            case "conditions":
                resolvedConditions = child.value as? DefaultConditionService
            case "catalog":
                resolvedCatalog = child.value as? DefaultCommandCatalogService<Host>
            case "activation":
                resolvedActivation = child.value as? DefaultActivationService<Host>
            case "layers":
                resolvedLayers = child.value as? DefaultLayerService<Host, DefaultCompilerService<Target, Event>>
            default:
                break
            }
        }

        guard let state = resolvedState,
            let conditions = resolvedConditions,
            let catalog = resolvedCatalog,
            let activation = resolvedActivation,
            let layers = resolvedLayers
        else {
            preconditionFailure("Keymap internal service layout changed")
        }

        return KeymapExtensionContext(
            state: state,
            host: host,
            conditions: conditions,
            catalog: catalog,
            activation: activation,
            layers: layers
        )
    }
}

/// Creates a mount-order-preserving replaceable layer slot for framework adapters (`useBindings`).
// parity: keymap/src/services/extension-context.ts#createLayerSlot [status=implemented hash=7426211b1996]
public func createLayerSlot<Provider: KeymapExtensionProvider>(
    _ keymap: Provider
) -> @Sendable (Layer<Provider.Host.Target, Provider.Host.Event>?) -> RegisteredLayer<
    Provider.Host.Target, Provider.Host.Event
>? {
    let layers = keymap.keymapExtensionContext().layers
    let slot = layers.createSlot()
    return { layer in
        layers.replaceLayer(slot: slot, layer: layer)
    }
}

// MARK: - Runtime Module Registry (src/runtime-modules.ts)

/// Descriptor for a registered `@opentui/keymap` runtime module entrypoint.
public struct KeymapRuntimeModuleDescriptor: Equatable, Hashable, Sendable {
    public let specifier: String
    public let lazy: Bool
    public let exports: [String]

    public init(specifier: String, lazy: Bool = false, exports: [String] = []) {
        self.specifier = specifier
        self.lazy = lazy
        self.exports = exports
    }
}

/// Static catalog of runtime module entrypoints exported by `@opentui/keymap`.
// parity: keymap/src/runtime-modules.ts#runtimeModules [status=implemented hash=0a1d6a93ff71]
public let runtimeModules: [String: KeymapRuntimeModuleDescriptor] = [
    "@opentui/keymap": KeymapRuntimeModuleDescriptor(
        specifier: "@opentui/keymap",
        lazy: false,
        exports: ["Keymap", "createKeymap", "stringifyKeyStroke", "stringifyKeySequence"]
    ),
    "@opentui/keymap/extras": KeymapRuntimeModuleDescriptor(
        specifier: "@opentui/keymap/extras",
        lazy: false,
        exports: ["createBindingLookup", "commandBindings", "formatKeySequence", "formatCommandBindings"]
    ),
    "@opentui/keymap/extras/graph": KeymapRuntimeModuleDescriptor(
        specifier: "@opentui/keymap/extras/graph",
        lazy: false,
        exports: ["getGraphSnapshot", "createGraphExtra"]
    ),
    "@opentui/keymap/addons": KeymapRuntimeModuleDescriptor(
        specifier: "@opentui/keymap/addons",
        lazy: false,
        exports: [
            "registerDefaultKeys",
            "registerLeader",
            "registerTimedLeader",
            "registerAliasesField",
            "registerBackspacePopsPendingSequence",
            "registerEscapeClearsPendingSequence",
            "registerNeovimDisambiguation",
            "registerExCommands",
            "registerBindingOverrides",
            "registerCommaBindings",
            "registerDeadBindingWarnings",
            "registerEmacsBindings",
            "registerEnabledFields",
            "registerMetadataFields",
            "registerModBindings",
            "registerUnresolvedCommandWarnings",
        ]
    ),
    "@opentui/keymap/addons/opentui": KeymapRuntimeModuleDescriptor(
        specifier: "@opentui/keymap/addons/opentui",
        lazy: false,
        exports: [
            "registerBaseLayoutFallback",
            "createTextareaBindings",
            "registerTextareaMappingSuspension",
            "registerEditBufferCommands",
            "registerManagedTextareaLayer",
        ]
    ),
    "@opentui/keymap/html": KeymapRuntimeModuleDescriptor(
        specifier: "@opentui/keymap/html",
        lazy: false,
        exports: [
            "normalizeHtmlKeyName",
            "createHtmlKeymapEvent",
            "createHtmlKeymapHost",
            "htmlEventMatchResolver",
            "createHtmlKeymap",
            "createDefaultHtmlKeymap",
        ]
    ),
    "@opentui/keymap/opentui": KeymapRuntimeModuleDescriptor(
        specifier: "@opentui/keymap/opentui",
        lazy: false,
        exports: ["createOpenTuiKeymapHost", "createOpenTuiKeymap", "createDefaultOpenTuiKeymap"]
    ),
    "@opentui/keymap/react": KeymapRuntimeModuleDescriptor(
        specifier: "@opentui/keymap/react",
        lazy: true,
        exports: [
            "KeymapProvider",
            "useKeymap",
            "useActiveKeys",
            "usePendingSequence",
            "useBindings",
            "reactiveMatcherFromStore",
        ]
    ),
    "@opentui/keymap/solid": KeymapRuntimeModuleDescriptor(
        specifier: "@opentui/keymap/solid",
        lazy: true,
        exports: [
            "KeymapProvider",
            "useKeymap",
            "useKeymapSelector",
            "useBindings",
            "reactiveMatcherFromSignal",
        ]
    ),
]

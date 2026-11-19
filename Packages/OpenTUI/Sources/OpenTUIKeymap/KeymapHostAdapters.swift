// Pure Swift 6 port of keymap/src/opentui.ts, addons/opentui/base-layout.ts,
// addons/opentui/edit-buffer-bindings.ts, src/html.ts, src/react/index.ts, and src/solid/index.ts.

// MARK: - OpenTUI Host Adapter Protocols (Zero External Dependencies)

/// Minimal key event protocol consumed by OpenTUI keymap hosts and Kitty base-layout fallback.
public protocol OpenTUIKeyEventLike: KeymapEvent {
    var baseCode: UInt32? { get }
}

/// Concrete pure-Swift `OpenTUIKeyEventLike` event usable headless or bridged from `OpenTUICore.KeyEvent`.
public final class OpenTUIKeyEventAdapter: OpenTUIKeyEventLike, @unchecked Sendable {
    public let name: String
    public let ctrl: Bool
    public let shift: Bool
    public let meta: Bool
    public let `super`: Bool?
    public let hyper: Bool?
    public let baseCode: UInt32?
    public private(set) var defaultPrevented: Bool = false
    public private(set) var propagationStopped: Bool = false

    public init(
        name: String,
        ctrl: Bool = false,
        shift: Bool = false,
        meta: Bool = false,
        super isSuper: Bool? = nil,
        hyper: Bool? = nil,
        baseCode: UInt32? = nil
    ) {
        self.name = name
        self.ctrl = ctrl
        self.shift = shift
        self.meta = meta
        self.`super` = isSuper
        self.hyper = hyper
        self.baseCode = baseCode
    }

    public func preventDefault() {
        defaultPrevented = true
    }

    public func stopPropagation() {
        propagationStopped = true
    }
}

/// Minimal renderable node protocol for focus/parent/destruction traversal in `OpenTUIKeymapHost`.
public protocol OpenTUIRenderableLike: AnyObject, Hashable, Sendable {
    var parentRenderable: Self? { get }
    var isDestroyed: Bool { get }
    var focused: Bool { get }
    func onDestroyed(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void
}

/// Minimal edit-buffer/textarea protocol for `registerEditBufferCommands` and `registerManagedTextareaLayer`.
public protocol EditBufferBindable: AnyObject, Sendable {
    var isDestroyed: Bool { get }
    var isManagedTextarea: Bool { get }
    var isKeymapSuspended: Bool { get set }

    func moveCursorLeft(select: Bool) -> Bool
    func moveCursorRight(select: Bool) -> Bool
    func moveCursorUp(select: Bool) -> Bool
    func moveCursorDown(select: Bool) -> Bool
    func gotoLineHome(select: Bool) -> Bool
    func gotoLineEnd(select: Bool) -> Bool
    func gotoVisualLineHome(select: Bool) -> Bool
    func gotoVisualLineEnd(select: Bool) -> Bool
    func gotoBufferHome(select: Bool) -> Bool
    func gotoBufferEnd(select: Bool) -> Bool
    func deleteLine() -> Bool
    func deleteToLineEnd() -> Bool
    func deleteToLineStart() -> Bool
    func deleteCharBackward() -> Bool
    func deleteChar() -> Bool
    func newLine() -> Bool
    func undo() -> Bool
    func redo() -> Bool
    func moveWordForward(select: Bool) -> Bool
    func moveWordBackward(select: Bool) -> Bool
    func deleteWordForward() -> Bool
    func deleteWordBackward() -> Bool
    func selectAll() -> Bool
    func submit() -> Bool
}

public extension EditBufferBindable {
    func submit() -> Bool { false }
}

/// Minimal renderer protocol bridged by `createOpenTuiKeymapHost`.
public protocol OpenTUIRendererLike<Renderable, Event>: AnyObject, Sendable {
    associatedtype Renderable: OpenTUIRenderableLike
    associatedtype Event: OpenTUIKeyEventLike

    var root: Renderable { get }
    var isDestroyed: Bool { get }
    var platform: HostPlatform { get }
    var hasKittyKeyboard: Bool { get }
    var currentFocusedRenderable: Renderable? { get }
    var currentFocusedEditor: (any EditBufferBindable)? { get }

    func onKeyPress(_ listener: @escaping @Sendable (Event) -> Void) -> @Sendable () -> Void
    func onKeyRelease(_ listener: @escaping @Sendable (Event) -> Void) -> @Sendable () -> Void
    func onFocusChange(_ listener: @escaping @Sendable (Renderable?) -> Void) -> @Sendable () -> Void
    func onFocusedEditorChange(
        _ listener: @escaping @Sendable ((any EditBufferBindable)?, (any EditBufferBindable)?) -> Void
    ) -> @Sendable () -> Void
    func onDestroy(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void
    func onRawInput(_ listener: @escaping @Sendable (String) -> Bool) -> @Sendable () -> Void
    func createCommandEvent() -> Event
}

public extension OpenTUIRendererLike {
    var platform: HostPlatform { .unknown }
    var hasKittyKeyboard: Bool { false }
    var currentFocusedEditor: (any EditBufferBindable)? { nil }

    func onFocusedEditorChange(
        _ listener: @escaping @Sendable ((any EditBufferBindable)?, (any EditBufferBindable)?) -> Void
    ) -> @Sendable () -> Void {
        {}
    }
}

// MARK: - OpenTUI Keymap Host & Factories (src/opentui.ts)

public final class OpenTUIKeymapHost<Renderer: OpenTUIRendererLike>: InteractiveKeymapHost, @unchecked Sendable {
    public typealias Target = Renderer.Renderable
    public typealias Event = Renderer.Event

    public let renderer: Renderer

    public init(renderer: Renderer) {
        self.renderer = renderer
    }

    public var metadata: HostMetadata {
        let platform = renderer.platform
        let primary: HostPrimaryModifier =
            switch platform {
            case .macos: .super
            case .windows, .linux: .ctrl
            case .unknown: .unknown
            }
        let kittyCap: HostCapability = renderer.hasKittyKeyboard ? .supported : .unknown
        return HostMetadata(
            platform: platform,
            primaryModifier: primary,
            modifiers: [
                .ctrl: .supported,
                .shift: .supported,
                .meta: .supported,
                .super: kittyCap,
                .hyper: kittyCap,
            ]
        )
    }

    public var rootTarget: Target {
        renderer.root
    }

    public var isDestroyed: Bool {
        renderer.isDestroyed
    }

    public func getFocusedTarget() -> Target? {
        guard let focused = renderer.currentFocusedRenderable, !focused.isDestroyed, focused.focused else {
            return nil
        }
        return focused
    }

    public func getParentTarget(_ target: Target) -> Target? {
        target.parentRenderable
    }

    public func isTargetDestroyed(_ target: Target) -> Bool {
        target.isDestroyed
    }

    public func onKeyPress(_ listener: @escaping @Sendable (Event) -> Void) -> @Sendable () -> Void {
        renderer.onKeyPress(listener)
    }

    public func onKeyRelease(_ listener: @escaping @Sendable (Event) -> Void) -> @Sendable () -> Void {
        renderer.onKeyRelease(listener)
    }

    public func onFocusChange(_ listener: @escaping @Sendable (Target?) -> Void) -> @Sendable () -> Void {
        renderer.onFocusChange(listener)
    }

    public func onDestroy(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        renderer.onDestroy(listener)
    }

    public func onTargetDestroy(_ target: Target, _ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        target.onDestroyed(listener)
    }

    public func onRawInput(_ listener: @escaping @Sendable (String) -> Bool) -> @Sendable () -> Void {
        renderer.onRawInput(listener)
    }

    public func createCommandEvent() -> Event {
        renderer.createCommandEvent()
    }
}

// parity: keymap/src/opentui.ts#createOpenTuiKeymapHost [status=implemented hash=8e3a5fb4c829]
public func createOpenTuiKeymapHost<Renderer: OpenTUIRendererLike>(
    _ renderer: Renderer
) -> OpenTUIKeymapHost<Renderer> {
    OpenTUIKeymapHost(renderer: renderer)
}

// parity: keymap/src/opentui.ts#createOpenTuiKeymap [status=implemented hash=94a4dd51d1e3]
public func createOpenTuiKeymap<Renderer: OpenTUIRendererLike>(
    _ renderer: Renderer
) throws -> Keymap<OpenTUIKeymapHost<Renderer>> {
    if renderer.isDestroyed {
        throw KeymapHostError.hostDestroyed
    }
    return try Keymap(host: createOpenTuiKeymapHost(renderer))
}

// parity: keymap/src/opentui.ts#createDefaultOpenTuiKeymap [status=implemented hash=dbaf44b631c9]
public func createDefaultOpenTuiKeymap<Renderer: OpenTUIRendererLike>(
    _ renderer: Renderer
) throws -> Keymap<OpenTUIKeymapHost<Renderer>> {
    if renderer.isDestroyed {
        throw KeymapHostError.hostDestroyed
    }
    let keymap = try Keymap(host: createOpenTuiKeymapHost(renderer))
    keymap.clearBindingParsers()
    keymap.clearEventMatchResolvers()
    _ = registerDefaultKeys(keymap)
    _ = try registerEnabledFields(keymap)
    _ = try registerMetadataFields(keymap)
    return keymap
}

// MARK: - Kitty Base Layout Fallback (addons/opentui/base-layout.ts)

private let BASE_LAYOUT_FALLBACK_RESOURCE = "keymap:base-layout-fallback"

private func getBaseLayoutKeyName(typedName: String, baseCode: UInt32?) -> String? {
    guard let baseCode, baseCode > 32, baseCode != 127 else {
        return nil
    }
    let scalars = Array(typedName.unicodeScalars)
    let isSingleNonAscii = scalars.count == 1 && scalars[0].value > 0x7F
    let isBaseDigit = baseCode >= 48 && baseCode <= 57
    if !isSingleNonAscii && !isBaseDigit {
        return nil
    }
    guard let scalar = Unicode.Scalar(baseCode) else {
        return nil
    }
    if scalar.value >= 65 && scalar.value <= 90, let lower = Unicode.Scalar(scalar.value + 32) {
        return String(lower)
    }
    return String(scalar)
}

/// Falls back to the event's Kitty base-layout key when the typed key is a single non-ASCII
/// character (e.g. Korean `Ctrl+ㅊ` -> `ctrl+c`) or the base key is a digit (e.g. AZERTY `Ctrl+&` -> `ctrl+1`),
/// while leaving ASCII remappings such as Dvorak untouched.
// parity: keymap/src/addons/opentui/base-layout.ts#registerBaseLayoutFallback [status=implemented hash=9c01518fa22a]
@discardableResult
public func registerBaseLayoutFallback<Host: KeymapHost>(
    _ keymap: Keymap<Host>
) throws -> @Sendable () -> Void where Host.Event: OpenTUIKeyEventLike {
    try keymap.acquireResource(key: BASE_LAYOUT_FALLBACK_RESOURCE) {
        keymap.appendEventMatchResolver { event, ctx in
            guard let name = getBaseLayoutKeyName(typedName: event.name, baseCode: event.baseCode) else {
                return nil
            }
            return [
                try ctx.resolveKey(
                    .stroke(
                        KeyStrokeInput(
                            name: name,
                            ctrl: event.ctrl,
                            shift: event.shift,
                            meta: event.meta,
                            super: event.`super` ?? false,
                            hyper: event.hyper == true ? true : nil
                        )
                    )
                )
            ]
        }
    }
}

// MARK: - EditBuffer & Textarea Bindings (addons/opentui/edit-buffer-bindings.ts)

public struct EditBufferKeyBindingSpec: Equatable, Hashable, Sendable {
    public let name: String
    public let ctrl: Bool
    public let shift: Bool
    public let meta: Bool
    public let `super`: Bool
    public let action: EditBufferCommandName

    public init(
        name: String,
        ctrl: Bool = false,
        shift: Bool = false,
        meta: Bool = false,
        super isSuper: Bool = false,
        action: EditBufferCommandName
    ) {
        self.name = name
        self.ctrl = ctrl
        self.shift = shift
        self.meta = meta
        self.`super` = isSuper
        self.action = action
    }
}

// parity: keymap/src/addons/opentui/edit-buffer-bindings.ts#keyBindingToString [status=implemented hash=7ae1d8754459]
public func keyBindingToString(_ binding: KeyStrokeInput) -> String {
    var parts: [String] = []
    if binding.ctrl == true { parts.append("ctrl") }
    if binding.shift == true { parts.append("shift") }
    if binding.meta == true { parts.append("meta") }
    if binding.`super` == true { parts.append("super") }
    parts.append(binding.name)
    return parts.joined(separator: "+")
}

// parity: keymap/src/addons/opentui/edit-buffer-bindings.ts#EditBufferCommandName [status=implemented hash=fb5d61e229ec]
public enum EditBufferCommandName: String, Equatable, Hashable, Sendable, CaseIterable {
    case moveLeft = "move-left"
    case moveRight = "move-right"
    case moveUp = "move-up"
    case moveDown = "move-down"
    case selectLeft = "select-left"
    case selectRight = "select-right"
    case selectUp = "select-up"
    case selectDown = "select-down"
    case lineHome = "line-home"
    case lineEnd = "line-end"
    case selectLineHome = "select-line-home"
    case selectLineEnd = "select-line-end"
    case visualLineHome = "visual-line-home"
    case visualLineEnd = "visual-line-end"
    case selectVisualLineHome = "select-visual-line-home"
    case selectVisualLineEnd = "select-visual-line-end"
    case bufferHome = "buffer-home"
    case bufferEnd = "buffer-end"
    case selectBufferHome = "select-buffer-home"
    case selectBufferEnd = "select-buffer-end"
    case deleteLine = "delete-line"
    case deleteToLineEnd = "delete-to-line-end"
    case deleteToLineStart = "delete-to-line-start"
    case backspace = "backspace"
    case delete = "delete"
    case newline = "newline"
    case undo = "undo"
    case redo = "redo"
    case wordForward = "word-forward"
    case wordBackward = "word-backward"
    case selectWordForward = "select-word-forward"
    case selectWordBackward = "select-word-backward"
    case deleteWordForward = "delete-word-forward"
    case deleteWordBackward = "delete-word-backward"
    case selectAll = "select-all"
    case submit = "submit"
}

// parity: keymap/src/addons/opentui/edit-buffer-bindings.ts#EditBufferFineGroup [status=implemented hash=9fa510fd4ade]
public enum EditBufferFineGroup: String, Equatable, Hashable, Sendable, CaseIterable {
    case cursor = "Cursor"
    case selection = "Selection"
    case delete = "Delete"
    case history = "History"
    case insert = "Insert"
    case submit = "Submit"
}

private let DEFAULT_EDIT_BUFFER_METADATA_GROUP = "Text Editing"
private let EDIT_BUFFER_COMMANDS_RESOURCE = "keymap:edit-buffer-commands"
private let TEXTAREA_MAPPING_SUSPENSION_RESOURCE = "keymap:textarea-mapping-suspension"

// parity: keymap/src/addons/opentui/edit-buffer-bindings.ts#editBufferCommandNames [status=implemented hash=d0b36d274ce7]
public let editBufferCommandNames: [EditBufferCommandName: String] = [
    .moveLeft: "input.move.left",
    .moveRight: "input.move.right",
    .moveUp: "input.move.up",
    .moveDown: "input.move.down",
    .selectLeft: "input.select.left",
    .selectRight: "input.select.right",
    .selectUp: "input.select.up",
    .selectDown: "input.select.down",
    .lineHome: "input.line.home",
    .lineEnd: "input.line.end",
    .selectLineHome: "input.select.line.home",
    .selectLineEnd: "input.select.line.end",
    .visualLineHome: "input.visual.line.home",
    .visualLineEnd: "input.visual.line.end",
    .selectVisualLineHome: "input.select.visual.line.home",
    .selectVisualLineEnd: "input.select.visual.line.end",
    .bufferHome: "input.buffer.home",
    .bufferEnd: "input.buffer.end",
    .selectBufferHome: "input.select.buffer.home",
    .selectBufferEnd: "input.select.buffer.end",
    .deleteLine: "input.delete.line",
    .deleteToLineEnd: "input.delete.to.line.end",
    .deleteToLineStart: "input.delete.to.line.start",
    .backspace: "input.backspace",
    .delete: "input.delete",
    .newline: "input.newline",
    .undo: "input.undo",
    .redo: "input.redo",
    .wordForward: "input.word.forward",
    .wordBackward: "input.word.backward",
    .selectWordForward: "input.select.word.forward",
    .selectWordBackward: "input.select.word.backward",
    .deleteWordForward: "input.delete.word.forward",
    .deleteWordBackward: "input.delete.word.backward",
    .selectAll: "input.select.all",
    .submit: "input.submit",
]

// parity: keymap/src/addons/opentui/edit-buffer-bindings.ts#editBufferCommandDescriptions [status=implemented hash=58b21b64f3f1]
public let editBufferCommandDescriptions: [EditBufferCommandName: String] = [
    .moveLeft: "Cursor left",
    .moveRight: "Cursor right",
    .moveUp: "Cursor up",
    .moveDown: "Cursor down",
    .selectLeft: "Select left",
    .selectRight: "Select right",
    .selectUp: "Select up",
    .selectDown: "Select down",
    .lineHome: "Line start",
    .lineEnd: "Line end",
    .selectLineHome: "Select to line start",
    .selectLineEnd: "Select to line end",
    .visualLineHome: "Visual line start",
    .visualLineEnd: "Visual line end",
    .selectVisualLineHome: "Select to visual line start",
    .selectVisualLineEnd: "Select to visual line end",
    .bufferHome: "Buffer start",
    .bufferEnd: "Buffer end",
    .selectBufferHome: "Select to buffer start",
    .selectBufferEnd: "Select to buffer end",
    .deleteLine: "Delete line",
    .deleteToLineEnd: "Delete to line end",
    .deleteToLineStart: "Delete to line start",
    .backspace: "Delete backward",
    .delete: "Delete forward",
    .newline: "New line",
    .undo: "Undo",
    .redo: "Redo",
    .wordForward: "Next word",
    .wordBackward: "Previous word",
    .selectWordForward: "Select next word",
    .selectWordBackward: "Select previous word",
    .deleteWordForward: "Delete next word",
    .deleteWordBackward: "Delete previous word",
    .selectAll: "Select all",
    .submit: "Submit",
]

private let editBufferFineGroups: [EditBufferCommandName: EditBufferFineGroup] = [
    .moveLeft: .cursor,
    .moveRight: .cursor,
    .moveUp: .cursor,
    .moveDown: .cursor,
    .selectLeft: .selection,
    .selectRight: .selection,
    .selectUp: .selection,
    .selectDown: .selection,
    .lineHome: .cursor,
    .lineEnd: .cursor,
    .selectLineHome: .selection,
    .selectLineEnd: .selection,
    .visualLineHome: .cursor,
    .visualLineEnd: .cursor,
    .selectVisualLineHome: .selection,
    .selectVisualLineEnd: .selection,
    .bufferHome: .cursor,
    .bufferEnd: .cursor,
    .selectBufferHome: .selection,
    .selectBufferEnd: .selection,
    .deleteLine: .delete,
    .deleteToLineEnd: .delete,
    .deleteToLineStart: .delete,
    .backspace: .delete,
    .delete: .delete,
    .newline: .insert,
    .undo: .history,
    .redo: .history,
    .wordForward: .cursor,
    .wordBackward: .cursor,
    .selectWordForward: .selection,
    .selectWordBackward: .selection,
    .deleteWordForward: .delete,
    .deleteWordBackward: .delete,
    .selectAll: .selection,
    .submit: .submit,
]

public let defaultTextareaKeyBindingSpecs: [EditBufferKeyBindingSpec] = [
    EditBufferKeyBindingSpec(name: "left", action: .moveLeft),
    EditBufferKeyBindingSpec(name: "right", action: .moveRight),
    EditBufferKeyBindingSpec(name: "up", action: .moveUp),
    EditBufferKeyBindingSpec(name: "down", action: .moveDown),
    EditBufferKeyBindingSpec(name: "left", shift: true, action: .selectLeft),
    EditBufferKeyBindingSpec(name: "right", shift: true, action: .selectRight),
    EditBufferKeyBindingSpec(name: "up", shift: true, action: .selectUp),
    EditBufferKeyBindingSpec(name: "down", shift: true, action: .selectDown),
    EditBufferKeyBindingSpec(name: "home", action: .bufferHome),
    EditBufferKeyBindingSpec(name: "end", action: .bufferEnd),
    EditBufferKeyBindingSpec(name: "home", shift: true, action: .selectBufferHome),
    EditBufferKeyBindingSpec(name: "end", shift: true, action: .selectBufferEnd),
    EditBufferKeyBindingSpec(name: "a", ctrl: true, action: .lineHome),
    EditBufferKeyBindingSpec(name: "e", ctrl: true, action: .lineEnd),
    EditBufferKeyBindingSpec(name: "a", ctrl: true, shift: true, action: .selectLineHome),
    EditBufferKeyBindingSpec(name: "e", ctrl: true, shift: true, action: .selectLineEnd),
    EditBufferKeyBindingSpec(name: "a", meta: true, action: .visualLineHome),
    EditBufferKeyBindingSpec(name: "e", meta: true, action: .visualLineEnd),
    EditBufferKeyBindingSpec(name: "a", shift: true, meta: true, action: .selectVisualLineHome),
    EditBufferKeyBindingSpec(name: "e", shift: true, meta: true, action: .selectVisualLineEnd),
    EditBufferKeyBindingSpec(name: "f", ctrl: true, action: .moveRight),
    EditBufferKeyBindingSpec(name: "b", ctrl: true, action: .moveLeft),
    EditBufferKeyBindingSpec(name: "w", ctrl: true, action: .deleteWordBackward),
    EditBufferKeyBindingSpec(name: "backspace", ctrl: true, action: .deleteWordBackward),
    EditBufferKeyBindingSpec(name: "d", meta: true, action: .deleteWordForward),
    EditBufferKeyBindingSpec(name: "delete", meta: true, action: .deleteWordForward),
    EditBufferKeyBindingSpec(name: "delete", ctrl: true, action: .deleteWordForward),
    EditBufferKeyBindingSpec(name: "d", ctrl: true, shift: true, action: .deleteLine),
    EditBufferKeyBindingSpec(name: "k", ctrl: true, action: .deleteToLineEnd),
    EditBufferKeyBindingSpec(name: "u", ctrl: true, action: .deleteToLineStart),
    EditBufferKeyBindingSpec(name: "backspace", action: .backspace),
    EditBufferKeyBindingSpec(name: "backspace", shift: true, action: .backspace),
    EditBufferKeyBindingSpec(name: "d", ctrl: true, action: .delete),
    EditBufferKeyBindingSpec(name: "delete", action: .delete),
    EditBufferKeyBindingSpec(name: "delete", shift: true, action: .delete),
    EditBufferKeyBindingSpec(name: "return", action: .newline),
    EditBufferKeyBindingSpec(name: "kpenter", action: .newline),
    EditBufferKeyBindingSpec(name: "linefeed", action: .newline),
    EditBufferKeyBindingSpec(name: "return", meta: true, action: .submit),
    EditBufferKeyBindingSpec(name: "kpenter", meta: true, action: .submit),
    EditBufferKeyBindingSpec(name: "-", ctrl: true, action: .undo),
    EditBufferKeyBindingSpec(name: ".", ctrl: true, action: .redo),
    EditBufferKeyBindingSpec(name: "z", super: true, action: .undo),
    EditBufferKeyBindingSpec(name: "z", shift: true, super: true, action: .redo),
    EditBufferKeyBindingSpec(name: "f", meta: true, action: .wordForward),
    EditBufferKeyBindingSpec(name: "b", meta: true, action: .wordBackward),
    EditBufferKeyBindingSpec(name: "right", meta: true, action: .wordForward),
    EditBufferKeyBindingSpec(name: "left", meta: true, action: .wordBackward),
    EditBufferKeyBindingSpec(name: "right", ctrl: true, action: .wordForward),
    EditBufferKeyBindingSpec(name: "left", ctrl: true, action: .wordBackward),
    EditBufferKeyBindingSpec(name: "f", shift: true, meta: true, action: .selectWordForward),
    EditBufferKeyBindingSpec(name: "b", shift: true, meta: true, action: .selectWordBackward),
    EditBufferKeyBindingSpec(name: "right", shift: true, meta: true, action: .selectWordForward),
    EditBufferKeyBindingSpec(name: "left", shift: true, meta: true, action: .selectWordBackward),
    EditBufferKeyBindingSpec(name: "backspace", meta: true, action: .deleteWordBackward),
    EditBufferKeyBindingSpec(name: "left", super: true, action: .visualLineHome),
    EditBufferKeyBindingSpec(name: "right", super: true, action: .visualLineEnd),
    EditBufferKeyBindingSpec(name: "up", super: true, action: .bufferHome),
    EditBufferKeyBindingSpec(name: "down", super: true, action: .bufferEnd),
    EditBufferKeyBindingSpec(name: "backspace", super: true, action: .deleteToLineStart),
    EditBufferKeyBindingSpec(name: "left", shift: true, super: true, action: .selectVisualLineHome),
    EditBufferKeyBindingSpec(name: "right", shift: true, super: true, action: .selectVisualLineEnd),
    EditBufferKeyBindingSpec(name: "up", shift: true, super: true, action: .selectBufferHome),
    EditBufferKeyBindingSpec(name: "down", shift: true, super: true, action: .selectBufferEnd),
    EditBufferKeyBindingSpec(name: "a", super: true, action: .selectAll),
]

public enum EditBufferBindingsError: Error, Equatable, Sendable, KeymapDescribedError {
    case emptyField(String)
    case duplicateCommandName(String, EditBufferCommandName, EditBufferCommandName)

    public var errorMessage: String {
        switch self {
        case .emptyField(let msg): return msg
        case .duplicateCommandName(let name, let a, let b):
            return "Edit buffer command name \"\(name)\" is assigned to both \"\(a.rawValue)\" and \"\(b.rawValue)\""
        }
    }
}

// parity: keymap/src/addons/opentui/edit-buffer-bindings.ts#EditBufferCommandOptions [status=implemented hash=67fe2ecc712e]
public struct EditBufferCommandOptions: Equatable, Sendable {
    public let category: String?
    public let group: String?
    public let includeFineGroup: Bool
    public let commandNames: [EditBufferCommandName: String]?
    public let descriptions: [EditBufferCommandName: String]?

    public init(
        category: String? = nil,
        group: String? = nil,
        includeFineGroup: Bool = false,
        commandNames: [EditBufferCommandName: String]? = nil,
        descriptions: [EditBufferCommandName: String]? = nil
    ) {
        self.category = category
        self.group = group
        self.includeFineGroup = includeFineGroup
        self.commandNames = commandNames
        self.descriptions = descriptions
    }
}

// parity: keymap/src/addons/opentui/edit-buffer-bindings.ts#ManagedTextareaLayer [status=implemented hash=950cf92496e7]
public struct ManagedTextareaLayer<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public var priority: Int?
    public var bindings: [Binding<Target, Event>]?
    public var commands: [Command<Target, Event>]?
    public var fields: [String: KeymapValue]

    public init(
        priority: Int? = nil,
        bindings: [Binding<Target, Event>]? = nil,
        commands: [Command<Target, Event>]? = nil,
        fields: [String: KeymapValue] = [:]
    ) {
        self.priority = priority
        self.bindings = bindings
        self.commands = commands
        self.fields = fields
    }
}

private func resolveEditBufferCommandNames(
    _ options: EditBufferCommandOptions?
) throws(EditBufferBindingsError) -> [EditBufferCommandName: String] {
    var names = editBufferCommandNames
    if let overrides = options?.commandNames {
        for action in EditBufferCommandName.allCases {
            guard let override = overrides[action] else { continue }
            let trimmed = keymapTrimWhitespace(override)
            if trimmed.isEmpty {
                throw .emptyField("Edit buffer command name for \"\(action.rawValue)\" cannot be empty")
            }
            names[action] = trimmed
        }
    }
    var seen: [String: EditBufferCommandName] = [:]
    for action in EditBufferCommandName.allCases {
        let cmdName = names[action]!
        if let existing = seen[cmdName] {
            throw .duplicateCommandName(cmdName, existing, action)
        }
        seen[cmdName] = action
    }
    return names
}

private func resolveEditBufferDescriptions(
    _ options: EditBufferCommandOptions?
) throws(EditBufferBindingsError) -> [EditBufferCommandName: String] {
    var descriptions = editBufferCommandDescriptions
    if let overrides = options?.descriptions {
        for action in EditBufferCommandName.allCases {
            guard let override = overrides[action] else { continue }
            let trimmed = keymapTrimWhitespace(override)
            if trimmed.isEmpty {
                throw .emptyField("Edit buffer command description for \"\(action.rawValue)\" cannot be empty")
            }
            descriptions[action] = trimmed
        }
    }
    return descriptions
}

private func normalizeEditBufferMeta(
    field: String,
    value: String?
) throws(EditBufferBindingsError) -> String {
    let normalized = keymapTrimWhitespace(value ?? DEFAULT_EDIT_BUFFER_METADATA_GROUP)
    if normalized.isEmpty {
        throw .emptyField("Edit buffer metadata field \"\(field)\" cannot be empty")
    }
    return normalized
}

private func runEditBufferAction(_ action: EditBufferCommandName, on editor: any EditBufferBindable) -> Bool {
    switch action {
    case .moveLeft: return editor.moveCursorLeft(select: false)
    case .moveRight: return editor.moveCursorRight(select: false)
    case .moveUp: return editor.moveCursorUp(select: false)
    case .moveDown: return editor.moveCursorDown(select: false)
    case .selectLeft: return editor.moveCursorLeft(select: true)
    case .selectRight: return editor.moveCursorRight(select: true)
    case .selectUp: return editor.moveCursorUp(select: true)
    case .selectDown: return editor.moveCursorDown(select: true)
    case .lineHome: return editor.gotoLineHome(select: false)
    case .lineEnd: return editor.gotoLineEnd(select: false)
    case .selectLineHome: return editor.gotoLineHome(select: true)
    case .selectLineEnd: return editor.gotoLineEnd(select: true)
    case .visualLineHome: return editor.gotoVisualLineHome(select: false)
    case .visualLineEnd: return editor.gotoVisualLineEnd(select: false)
    case .selectVisualLineHome: return editor.gotoVisualLineHome(select: true)
    case .selectVisualLineEnd: return editor.gotoVisualLineEnd(select: true)
    case .bufferHome: return editor.gotoBufferHome(select: false)
    case .bufferEnd: return editor.gotoBufferEnd(select: false)
    case .selectBufferHome: return editor.gotoBufferHome(select: true)
    case .selectBufferEnd: return editor.gotoBufferEnd(select: true)
    case .deleteLine: return editor.deleteLine()
    case .deleteToLineEnd: return editor.deleteToLineEnd()
    case .deleteToLineStart: return editor.deleteToLineStart()
    case .backspace: return editor.deleteCharBackward()
    case .delete: return editor.deleteChar()
    case .newline: return editor.newLine()
    case .undo: return editor.undo()
    case .redo: return editor.redo()
    case .wordForward: return editor.moveWordForward(select: false)
    case .wordBackward: return editor.moveWordBackward(select: false)
    case .selectWordForward: return editor.moveWordForward(select: true)
    case .selectWordBackward: return editor.moveWordBackward(select: true)
    case .deleteWordForward: return editor.deleteWordForward()
    case .deleteWordBackward: return editor.deleteWordBackward()
    case .selectAll: return editor.selectAll()
    case .submit: return editor.submit()
    }
}

/// Returns the default textarea bindings with any overrides prepended so they take precedence.
// parity: keymap/src/addons/opentui/edit-buffer-bindings.ts#createTextareaBindings [status=implemented hash=e28c3bc1efca]
public func createTextareaBindings<Target: Hashable & Sendable, Event: KeymapEvent>(
    overrides: [Binding<Target, Event>]? = nil,
    options: EditBufferCommandOptions? = nil
) throws(EditBufferBindingsError) -> [Binding<Target, Event>] {
    let names = try resolveEditBufferCommandNames(options)
    let descriptions = try resolveEditBufferDescriptions(options)
    let group = try normalizeEditBufferMeta(field: "group", value: options?.group)
    let includeFineGroup = options?.includeFineGroup ?? false

    let defaults: [Binding<Target, Event>] = defaultTextareaKeyBindingSpecs.map { spec in
        let stroke = KeyStrokeInput(
            name: spec.name,
            ctrl: spec.ctrl,
            shift: spec.shift,
            meta: spec.meta,
            super: spec.`super`
        )
        var fields: [String: KeymapValue] = [
            "desc": .string(descriptions[spec.action]!),
            "group": .string(group),
        ]
        if includeFineGroup, let fineGroup = editBufferFineGroups[spec.action] {
            fields["fineGroup"] = .string(fineGroup.rawValue)
        }
        return Binding(
            key: .string(keyBindingToString(stroke)),
            commandName: names[spec.action]!,
            fields: fields
        )
    }

    return (overrides ?? []) + defaults
}

private final class SuspensionTracker: @unchecked Sendable {
    var previousStates: [ObjectIdentifier: Bool] = [:]
    weak var suspendedEditor: (any EditBufferBindable)?

    func suspend(_ editor: (any EditBufferBindable)?) {
        guard let editor, editor.isManagedTextarea, !editor.isDestroyed else {
            suspendedEditor = nil
            return
        }
        let id = ObjectIdentifier(editor)
        if previousStates[id] == nil {
            previousStates[id] = editor.isKeymapSuspended
        }
        editor.isKeymapSuspended = true
        suspendedEditor = editor
    }

    func restore(_ editor: (any EditBufferBindable)?) {
        guard let editor, editor.isManagedTextarea else { return }
        let id = ObjectIdentifier(editor)
        guard let previous = previousStates.removeValue(forKey: id) else { return }
        if !editor.isDestroyed {
            editor.isKeymapSuspended = previous
        }
        if let current = suspendedEditor, ObjectIdentifier(current) == id {
            suspendedEditor = nil
        }
    }
}

/// Suspends a focused managed textarea's own key handling so keymap bindings take over,
/// restoring previous suspend state on focus change or disposal.
// parity: keymap/src/addons/opentui/edit-buffer-bindings.ts#registerTextareaMappingSuspension [status=implemented hash=8f3d1e1e0670]
@discardableResult
public func registerTextareaMappingSuspension<Renderer: OpenTUIRendererLike>(
    _ keymap: Keymap<OpenTUIKeymapHost<Renderer>>,
    renderer: Renderer
) throws -> @Sendable () -> Void {
    try keymap.acquireResource(key: TEXTAREA_MAPPING_SUSPENSION_RESOURCE) {
        if renderer.isDestroyed {
            throw KeymapHostError.hostDestroyed
        }
        let tracker = SuspensionTracker()
        let off = renderer.onFocusedEditorChange { current, previous in
            tracker.restore(previous)
            tracker.suspend(current)
        }
        tracker.suspend(renderer.currentFocusedEditor)
        return {
            off()
            tracker.restore(tracker.suspendedEditor)
        }
    }
}

/// Registers the standard edit-buffer commands targeting `renderer.currentFocusedEditor`.
// parity: keymap/src/addons/opentui/edit-buffer-bindings.ts#registerEditBufferCommands [status=implemented hash=ce32e60ee2dc]
@discardableResult
public func registerEditBufferCommands<Renderer: OpenTUIRendererLike>(
    _ keymap: Keymap<OpenTUIKeymapHost<Renderer>>,
    renderer: Renderer,
    options: EditBufferCommandOptions? = nil
) throws -> @Sendable () -> Void {
    let names = try resolveEditBufferCommandNames(options)
    let descriptions = try resolveEditBufferDescriptions(options)
    let category = try normalizeEditBufferMeta(field: "category", value: options?.category)

    return try keymap.acquireResource(key: EDIT_BUFFER_COMMANDS_RESOURCE) {
        let commands: [Command<Renderer.Renderable, Renderer.Event>] = EditBufferCommandName.allCases.map { action in
            Command(
                name: names[action]!,
                fields: [
                    "desc": .string(descriptions[action]!),
                    "category": .string(category),
                ]
            ) { [weak renderer] _ in
                guard let renderer, !renderer.isDestroyed,
                    let editor = renderer.currentFocusedEditor, !editor.isDestroyed
                else {
                    return false
                }
                return runEditBufferAction(action, on: editor)
            }
        }
        return keymap.registerLayer(Layer(commands: commands))
    }
}

/// High-level global textarea integration: registers edit-buffer commands, suspends managed
/// textarea key handling while focused, and installs default bindings plus overrides.
// parity: keymap/src/addons/opentui/edit-buffer-bindings.ts#registerManagedTextareaLayer [status=implemented hash=87bc4e4c61c8]
@discardableResult
public func registerManagedTextareaLayer<Renderer: OpenTUIRendererLike>(
    _ keymap: Keymap<OpenTUIKeymapHost<Renderer>>,
    renderer: Renderer,
    layer: ManagedTextareaLayer<Renderer.Renderable, Renderer.Event>,
    options: EditBufferCommandOptions? = nil
) throws -> @Sendable () -> Void {
    let bindings: [Binding<Renderer.Renderable, Renderer.Event>] = try createTextareaBindings(
        overrides: layer.bindings,
        options: options
    )
    let offCommands = try registerEditBufferCommands(keymap, renderer: renderer, options: options)
    let offSuspension: @Sendable () -> Void
    do {
        offSuspension = try registerTextareaMappingSuspension(keymap, renderer: renderer)
    } catch {
        offCommands()
        throw error
    }

    let offLayer = keymap.registerLayer(
        Layer(
            target: nil,
            priority: layer.priority,
            bindings: bindings,
            commands: layer.commands,
            targetMode: nil,
            fields: layer.fields
        )
    )

    return {
        offLayer()
        offSuspension()
        offCommands()
    }
}

// MARK: - Portable Web / DOM KeyboardEvent Adapter (src/html.ts)

/// Portable representation of a browser DOM `KeyboardEvent`, usable on macOS, Linux, Windows, and WASI/web.
public struct DOMKeyboardEventLike: Equatable, Hashable, Sendable {
    public let key: String
    public let ctrlKey: Bool
    public let shiftKey: Bool
    public let altKey: Bool
    public let metaKey: Bool

    public init(
        key: String,
        ctrlKey: Bool = false,
        shiftKey: Bool = false,
        altKey: Bool = false,
        metaKey: Bool = false
    ) {
        self.key = key
        self.ctrlKey = ctrlKey
        self.shiftKey = shiftKey
        self.altKey = altKey
        self.metaKey = metaKey
    }
}

/// Portable DOM element protocol for WASI/web or headless DOM trees.
public protocol DOMElementLike: AnyObject, Hashable, Sendable {
    var parentElement: Self? { get }
    var isConnected: Bool { get }
    var activeElement: Self? { get }
    func containsElement(_ element: Self) -> Bool
    func addKeyDownListener(_ listener: @escaping @Sendable (DOMKeyboardEventLike) -> Void) -> @Sendable () -> Void
    func addKeyUpListener(_ listener: @escaping @Sendable (DOMKeyboardEventLike) -> Void) -> @Sendable () -> Void
    func addFocusChangeListener(_ listener: @escaping @Sendable (Self?) -> Void) -> @Sendable () -> Void
    func addDisconnectListener(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void
}

/// Headless in-memory DOM element implementation for testing and WASI/embedded host wiring.
public final class InMemoryDOMElement: DOMElementLike, @unchecked Sendable {
    public let id: String
    public weak var parentElement: InMemoryDOMElement?
    public var children: [InMemoryDOMElement] = []
    public var isConnected: Bool = true
    public weak var activeElement: InMemoryDOMElement?

    private var nextID: Int = 0
    private var keyDownListeners: [(Int, @Sendable (DOMKeyboardEventLike) -> Void)] = []
    private var keyUpListeners: [(Int, @Sendable (DOMKeyboardEventLike) -> Void)] = []
    private var focusListeners: [(Int, @Sendable (InMemoryDOMElement?) -> Void)] = []
    private var disconnectListeners: [(Int, @Sendable () -> Void)] = []

    public init(id: String) {
        self.id = id
    }

    public static func == (lhs: InMemoryDOMElement, rhs: InMemoryDOMElement) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public func appendChild(_ child: InMemoryDOMElement) {
        child.parentElement = self
        child.isConnected = isConnected
        children.append(child)
    }

    public func removeChild(_ child: InMemoryDOMElement) {
        children.removeAll { $0 === child }
        child.parentElement = nil
        child.disconnect()
    }

    public func disconnect() {
        isConnected = false
        let listeners = disconnectListeners
        disconnectListeners.removeAll()
        for (_, fn) in listeners { fn() }
        for child in children { child.disconnect() }
    }

    public func containsElement(_ element: InMemoryDOMElement) -> Bool {
        var current: InMemoryDOMElement? = element
        while let node = current {
            if node === self { return true }
            current = node.parentElement
        }
        return false
    }

    public func dispatchKeyDown(_ event: DOMKeyboardEventLike) {
        for (_, fn) in keyDownListeners { fn(event) }
    }

    public func dispatchKeyUp(_ event: DOMKeyboardEventLike) {
        for (_, fn) in keyUpListeners { fn(event) }
    }

    public func setActiveElement(_ element: InMemoryDOMElement?) {
        activeElement = element
        for (_, fn) in focusListeners { fn(element) }
    }

    public func addKeyDownListener(
        _ listener: @escaping @Sendable (DOMKeyboardEventLike) -> Void
    ) -> @Sendable () -> Void {
        let id = nextID
        nextID += 1
        keyDownListeners.append((id, listener))
        return { [weak self] in self?.keyDownListeners.removeAll { $0.0 == id } }
    }

    public func addKeyUpListener(
        _ listener: @escaping @Sendable (DOMKeyboardEventLike) -> Void
    ) -> @Sendable () -> Void {
        let id = nextID
        nextID += 1
        keyUpListeners.append((id, listener))
        return { [weak self] in self?.keyUpListeners.removeAll { $0.0 == id } }
    }

    public func addFocusChangeListener(
        _ listener: @escaping @Sendable (InMemoryDOMElement?) -> Void
    ) -> @Sendable () -> Void {
        let id = nextID
        nextID += 1
        focusListeners.append((id, listener))
        return { [weak self] in self?.focusListeners.removeAll { $0.0 == id } }
    }

    public func addDisconnectListener(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = nextID
        nextID += 1
        disconnectListeners.append((id, listener))
        return { [weak self] in self?.disconnectListeners.removeAll { $0.0 == id } }
    }
}

// parity: keymap/src/html.ts#HtmlKeymapEvent [status=implemented hash=93013ba506b3]
public final class HtmlKeymapEvent: KeymapEvent, @unchecked Sendable {
    public let name: String
    public let ctrl: Bool
    public let shift: Bool
    public let meta: Bool
    public let `super`: Bool?
    public let hyper: Bool? = nil
    public let originalEvent: DOMKeyboardEventLike?
    public private(set) var defaultPrevented: Bool = false
    public private(set) var propagationStopped: Bool = false

    public init(
        name: String,
        ctrl: Bool = false,
        shift: Bool = false,
        meta: Bool = false,
        super isSuper: Bool = false,
        originalEvent: DOMKeyboardEventLike? = nil
    ) {
        self.name = name
        self.ctrl = ctrl
        self.shift = shift
        self.meta = meta
        self.`super` = isSuper
        self.originalEvent = originalEvent
    }

    public func preventDefault() {
        defaultPrevented = true
    }

    public func stopPropagation() {
        propagationStopped = true
    }
}

private let HTML_KEY_NAME_ALIASES: [String: String] = [
    " ": "space",
    "Spacebar": "space",
    "ArrowUp": "up",
    "ArrowDown": "down",
    "ArrowLeft": "left",
    "ArrowRight": "right",
    "Escape": "escape",
    "Esc": "escape",
    "Enter": "return",
    "Backspace": "backspace",
    "Delete": "delete",
    "Tab": "tab",
    "Home": "home",
    "End": "end",
    "PageUp": "pageup",
    "PageDown": "pagedown",
    "Insert": "insert",
    "CapsLock": "capslock",
    "NumLock": "numlock",
    "ScrollLock": "scrolllock",
    "ContextMenu": "menu",
    "Meta": "super",
    "OS": "super",
    "Alt": "alt",
    "Control": "control",
    "Shift": "shift",
]

private func isHtmlFunctionKey(_ key: String) -> Bool {
    let units = Array(key.utf16)
    guard units.count == 2 || units.count == 3 else { return false }
    guard units[0] == 70 || units[0] == 102 else { return false } // 'F' or 'f'
    for i in 1..<units.count {
        if units[i] < 48 || units[i] > 57 { return false }
    }
    return true
}

private func isHtmlPrintableSymbol(_ name: String) -> Bool {
    let units = Array(name.utf16)
    guard units.count == 1 else { return false }
    let c = units[0]
    let isDigit = c >= 48 && c <= 57
    let isUpper = c >= 65 && c <= 90
    let isLower = c >= 97 && c <= 122
    return !isDigit && !isUpper && !isLower
}

// parity: keymap/src/html.ts#normalizeHtmlKeyName [status=implemented hash=de6027f82fdf]
public func normalizeHtmlKeyName(_ key: String) -> String {
    if let aliased = HTML_KEY_NAME_ALIASES[key] {
        return aliased
    }
    if isHtmlFunctionKey(key) {
        return key.lowercased()
    }
    if key.utf16.count == 1 {
        return key.lowercased()
    }
    let trimmed = keymapTrimWhitespace(key).lowercased()
    var compact = ""
    compact.reserveCapacity(trimmed.count)
    for scalar in trimmed.unicodeScalars {
        if scalar.value == 0x20 || scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D {
            continue
        }
        compact.unicodeScalars.append(scalar)
    }
    return compact
}

// parity: keymap/src/html.ts#createHtmlKeymapEvent [status=implemented hash=7458e3a4c59d]
public func createHtmlKeymapEvent(_ event: DOMKeyboardEventLike? = nil) -> HtmlKeymapEvent {
    guard let event else {
        return HtmlKeymapEvent(name: "command", ctrl: false, shift: false, meta: false, super: false)
    }
    // Keymap uses `meta` for Alt/Option and `super` for the platform Meta key.
    return HtmlKeymapEvent(
        name: normalizeHtmlKeyName(event.key),
        ctrl: event.ctrlKey,
        shift: event.shiftKey,
        meta: event.altKey,
        super: event.metaKey,
        originalEvent: event
    )
}

public final class HtmlKeymapHost<Element: DOMElementLike>: InteractiveKeymapHost, @unchecked Sendable {
    public typealias Target = Element
    public typealias Event = HtmlKeymapEvent

    public let metadata: HostMetadata
    public let rootTarget: Element
    public let isDestroyed: Bool = false

    public init(root: Element, platform: HostPlatform = .unknown) {
        self.rootTarget = root
        let primary: HostPrimaryModifier =
            switch platform {
            case .macos: .super
            case .windows, .linux: .ctrl
            case .unknown: .unknown
            }
        self.metadata = HostMetadata(
            platform: platform,
            primaryModifier: primary,
            modifiers: [
                .ctrl: .supported,
                .shift: .supported,
                .meta: .supported,
                .super: .supported,
                .hyper: .unsupported,
            ]
        )
    }

    public func getFocusedTarget() -> Element? {
        guard let active = rootTarget.activeElement else { return nil }
        if active == rootTarget || rootTarget.containsElement(active) {
            return active
        }
        return nil
    }

    public func getParentTarget(_ target: Element) -> Element? {
        target.parentElement
    }

    public func isTargetDestroyed(_ target: Element) -> Bool {
        if target == rootTarget {
            return false
        }
        return !target.isConnected || !rootTarget.containsElement(target)
    }

    public func onKeyPress(_ listener: @escaping @Sendable (HtmlKeymapEvent) -> Void) -> @Sendable () -> Void {
        rootTarget.addKeyDownListener { event in
            listener(createHtmlKeymapEvent(event))
        }
    }

    public func onKeyRelease(_ listener: @escaping @Sendable (HtmlKeymapEvent) -> Void) -> @Sendable () -> Void {
        rootTarget.addKeyUpListener { event in
            listener(createHtmlKeymapEvent(event))
        }
    }

    public func onFocusChange(_ listener: @escaping @Sendable (Element?) -> Void) -> @Sendable () -> Void {
        rootTarget.addFocusChangeListener { [weak self] _ in
            listener(self?.getFocusedTarget())
        }
    }

    public func onTargetDestroy(_ target: Element, _ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        if isTargetDestroyed(target) {
            listener()
            return {}
        }
        return target.addDisconnectListener(listener)
    }

    public func createCommandEvent() -> HtmlKeymapEvent {
        createHtmlKeymapEvent()
    }
}

// parity: keymap/src/html.ts#createHtmlKeymapHost [status=implemented hash=1b9c26232c11]
public func createHtmlKeymapHost<Element: DOMElementLike>(
    _ root: Element,
    platform: HostPlatform = .unknown
) -> HtmlKeymapHost<Element> {
    HtmlKeymapHost(root: root, platform: platform)
}

// parity: keymap/src/html.ts#htmlEventMatchResolver [status=implemented hash=439dc5b0cd5a]
public let htmlEventMatchResolver: EventMatchResolver<HtmlKeymapEvent> = { event, ctx in
    let primary = KeyStrokeInput(
        name: event.name,
        ctrl: event.ctrl,
        shift: event.shift,
        meta: event.meta,
        super: event.`super` ?? false,
        hyper: event.hyper == true ? true : nil
    )

    if primary.shift != true || !isHtmlPrintableSymbol(primary.name) {
        return [try ctx.resolveKey(.stroke(primary))]
    }

    let unshifted = KeyStrokeInput(
        name: primary.name,
        ctrl: primary.ctrl,
        shift: false,
        meta: primary.meta,
        super: primary.`super`,
        hyper: primary.hyper
    )
    return [
        try ctx.resolveKey(.stroke(primary)),
        try ctx.resolveKey(.stroke(unshifted)),
    ]
}

// parity: keymap/src/html.ts#createHtmlKeymap [status=implemented hash=9104142eb6d9]
public func createHtmlKeymap<Element: DOMElementLike>(
    _ root: Element,
    platform: HostPlatform = .unknown
) throws -> Keymap<HtmlKeymapHost<Element>> {
    try Keymap(host: createHtmlKeymapHost(root, platform: platform))
}

// parity: keymap/src/html.ts#createDefaultHtmlKeymap [status=implemented hash=52e691cd3109]
public func createDefaultHtmlKeymap<Element: DOMElementLike>(
    _ root: Element,
    platform: HostPlatform = .unknown
) throws -> Keymap<HtmlKeymapHost<Element>> {
    let keymap = try Keymap(host: createHtmlKeymapHost(root, platform: platform))
    keymap.clearBindingParsers()
    keymap.clearEventMatchResolvers()
    _ = registerDefaultKeys(keymap)
    _ = try registerEnabledFields(keymap)
    _ = try registerMetadataFields(keymap)
    _ = keymap.prependEventMatchResolver(htmlEventMatchResolver)
    return keymap
}

// MARK: - Declarative Swift Reactive Scope Hooks (Adapted from src/react/index.ts & src/solid/index.ts)

public enum KeymapScopeError: Error, Equatable, Sendable, KeymapDescribedError {
    case missingProvider
    case missingTargetRef
    case missingTargetAccessor

    public var errorMessage: String {
        switch self {
        case .missingProvider:
            return "Keymap not found. Wrap the tree in KeymapProvider."
        case .missingTargetRef:
            return "useBindings local bindings need a targetRef"
        case .missingTargetAccessor:
            return "useBindings local bindings need a target accessor"
        }
    }
}

private enum ActiveKeymapScope {
    @TaskLocal static var current: (any AnyObject & Sendable)?
}

/// Disposable handle returned by `useBindings` / `useSolidBindings` for updating or tearing down a scoped layer.
public final class KeymapScopeHook<Target: Hashable & Sendable, Event: KeymapEvent>: @unchecked Sendable {
    private let replaceSlot: @Sendable (Layer<Target, Event>?) -> RegisteredLayer<Target, Event>?

    internal init(replaceSlot: @escaping @Sendable (Layer<Target, Event>?) -> RegisteredLayer<Target, Event>?) {
        self.replaceSlot = replaceSlot
    }

    @discardableResult
    public func update(_ layer: Layer<Target, Event>?) -> RegisteredLayer<Target, Event>? {
        replaceSlot(layer)
    }

    public func dispose() {
        _ = replaceSlot(nil)
    }
}

// parity: keymap/src/react/index.ts#KeymapProviderProps [status=adapted hash=6173dfc7dea8]
public struct KeymapProviderProps<Host: KeymapHost>: Sendable {
    public let keymap: Keymap<Host>

    public init(keymap: Keymap<Host>) {
        self.keymap = keymap
    }
}

/// Scopes `props.keymap` as the active keymap for all nested hook calls (`useKeymap`, `useActiveKeys`,
/// `usePendingSequence`, `useBindings`).
// parity: keymap/src/react/index.ts#KeymapProvider [status=adapted hash=269e4a41a3c0]
public func KeymapProvider<Host: KeymapHost, Result>(
    _ props: KeymapProviderProps<Host>,
    content: () throws -> Result
) rethrows -> Result {
    try ActiveKeymapScope.$current.withValue(props.keymap) {
        try content()
    }
}

// parity: keymap/src/react/index.ts#UseBindingsTargetRef [status=adapted hash=f39170191ec1]
public final class UseBindingsTargetRef<Target: Hashable & Sendable>: @unchecked Sendable {
    public var current: Target?

    public init(_ current: Target? = nil) {
        self.current = current
    }
}

// parity: keymap/src/react/index.ts#UseBindingsLayer [status=adapted hash=d66f83cd97b4]
public struct UseBindingsLayer<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public var targetRef: UseBindingsTargetRef<Target>?
    public var targetMode: TargetMode?
    public var priority: Int?
    public var bindings: [Binding<Target, Event>]?
    public var commands: [Command<Target, Event>]?
    public var fields: [String: KeymapValue]

    public init(
        targetRef: UseBindingsTargetRef<Target>? = nil,
        targetMode: TargetMode? = nil,
        priority: Int? = nil,
        bindings: [Binding<Target, Event>]? = nil,
        commands: [Command<Target, Event>]? = nil,
        fields: [String: KeymapValue] = [:]
    ) {
        self.targetRef = targetRef
        self.targetMode = targetMode
        self.priority = priority
        self.bindings = bindings
        self.commands = commands
        self.fields = fields
    }
}

// parity: keymap/src/react/index.ts#useKeymap [status=adapted hash=142e01ba6838]
public func useKeymap<Host: KeymapHost>(_ type: Host.Type = Host.self) throws(KeymapScopeError) -> Keymap<Host> {
    guard let scoped = ActiveKeymapScope.current as? Keymap<Host> else {
        throw .missingProvider
    }
    return scoped
}

// parity: keymap/src/react/index.ts#useActiveKeys [status=adapted hash=242b8ff6c6cc]
public func useActiveKeys<Host: KeymapHost>(
    _ type: Host.Type = Host.self,
    options: ActiveKeyOptions? = nil
) throws(KeymapScopeError) -> [ActiveKey<Host.Target, Host.Event>] {
    let keymap = try useKeymap(type)
    return keymap.getActiveKeys(options)
}

// parity: keymap/src/react/index.ts#usePendingSequence [status=adapted hash=105c0aad0393]
public func usePendingSequence<Host: KeymapHost>(
    _ type: Host.Type = Host.self
) throws(KeymapScopeError) -> [KeySequencePart] {
    let keymap = try useKeymap(type)
    return keymap.getPendingSequence()
}

// parity: keymap/src/react/index.ts#useBindings [status=adapted hash=d8a72440772b]
@discardableResult
public func useBindings<Host: KeymapHost>(
    _ type: Host.Type = Host.self,
    createLayer: () -> UseBindingsLayer<Host.Target, Host.Event>
) throws(KeymapScopeError) -> KeymapScopeHook<Host.Target, Host.Event> {
    let keymap = try useKeymap(type)
    let replace = createLayerSlot(keymap)
    let spec = createLayer()

    let hasExplicitTarget = spec.targetRef != nil
    let targetMode = spec.targetMode ?? (hasExplicitTarget ? .focusWithin : nil)
    if !hasExplicitTarget && targetMode != nil {
        throw .missingTargetRef
    }

    if let targetMode {
        if let target = spec.targetRef?.current {
            _ = replace(
                Layer(
                    target: target,
                    priority: spec.priority,
                    bindings: spec.bindings,
                    commands: spec.commands,
                    targetMode: targetMode,
                    fields: spec.fields
                )
            )
        } else {
            _ = replace(nil)
        }
    } else {
        _ = replace(
            Layer(
                target: nil,
                priority: spec.priority,
                bindings: spec.bindings,
                commands: spec.commands,
                targetMode: nil,
                fields: spec.fields
            )
        )
    }

    return KeymapScopeHook(replaceSlot: replace)
}

/// Adapts any `subscribe` + `getSnapshot` store into a `ReactiveMatcher`.
// parity: keymap/src/react/index.ts#reactiveMatcherFromStore [status=adapted hash=140c0ae91ff4]
public func reactiveMatcherFromStore<Value: Sendable>(
    subscribe: @escaping @Sendable (@escaping @Sendable () -> Void) throws -> (@Sendable () -> Void),
    getSnapshot: @escaping @Sendable () throws -> Value,
    predicate: @escaping @Sendable (Value) -> Bool
) -> ReactiveMatcher {
    ReactiveMatcher(
        get: { predicate(try getSnapshot()) },
        subscribe: subscribe
    )
}

/// Boolean store convenience overload for `reactiveMatcherFromStore`.
public func reactiveMatcherFromStore(
    subscribe: @escaping @Sendable (@escaping @Sendable () -> Void) throws -> (@Sendable () -> Void),
    getSnapshot: @escaping @Sendable () throws -> Bool
) -> ReactiveMatcher {
    reactiveMatcherFromStore(subscribe: subscribe, getSnapshot: getSnapshot, predicate: { $0 })
}

// MARK: - Solid-Style Reactive Signal Primitives & Hooks (Adapted from src/solid/index.ts)

/// Minimal reactive signal primitive backing `useKeymapSelector` and `reactiveMatcherFromSignal`.
public final class KeymapSignal<Value: Sendable>: @unchecked Sendable {
    private var currentValue: Value
    private var nextID: Int = 0
    private var subscribers: [(Int, @Sendable () -> Void)] = []

    public init(_ initialValue: Value) {
        self.currentValue = initialValue
    }

    public func get() -> Value {
        currentValue
    }

    public func set(_ next: Value) {
        currentValue = next
        let snapshot = subscribers
        for (_, listener) in snapshot {
            listener()
        }
    }

    @discardableResult
    public func subscribe(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = nextID
        nextID += 1
        subscribers.append((id, listener))
        return { [weak self] in
            self?.subscribers.removeAll { $0.0 == id }
        }
    }
}

/// Disposable derived selector signal that re-evaluates on batched keymap `state` changes.
public final class KeymapSelectorHandle<Value: Sendable>: @unchecked Sendable {
    private var cachedValue: Value
    private var disposeSubscription: @Sendable () -> Void

    internal init(initial: Value, dispose: @escaping @Sendable () -> Void = {}) {
        self.cachedValue = initial
        self.disposeSubscription = dispose
    }

    public func get() -> Value {
        cachedValue
    }

    internal func update(_ next: Value) {
        cachedValue = next
    }

    internal func setDispose(_ dispose: @escaping @Sendable () -> Void) {
        disposeSubscription = dispose
    }

    public func dispose() {
        disposeSubscription()
    }
}

// parity: keymap/src/solid/index.ts#KeymapProviderProps [status=adapted hash=20f0e5b52aae]
public struct SolidKeymapProviderProps<Host: KeymapHost>: Sendable {
    public let keymap: Keymap<Host>

    public init(keymap: Keymap<Host>) {
        self.keymap = keymap
    }
}

// parity: keymap/src/solid/index.ts#KeymapProvider [status=adapted hash=2afcf4f39d8d]
public func SolidKeymapProvider<Host: KeymapHost, Result>(
    _ props: SolidKeymapProviderProps<Host>,
    content: () throws -> Result
) rethrows -> Result {
    try ActiveKeymapScope.$current.withValue(props.keymap) {
        try content()
    }
}

// parity: keymap/src/solid/index.ts#UseBindingsTarget [status=adapted hash=328a5e677476]
public typealias UseBindingsTarget<Target: Hashable & Sendable> = @Sendable () -> Target?

// parity: keymap/src/solid/index.ts#UseBindingsLayer [status=adapted hash=d66f83cd97b4]
public struct SolidUseBindingsLayer<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public var target: UseBindingsTarget<Target>?
    public var targetMode: TargetMode?
    public var priority: Int?
    public var bindings: [Binding<Target, Event>]?
    public var commands: [Command<Target, Event>]?
    public var fields: [String: KeymapValue]

    public init(
        target: UseBindingsTarget<Target>? = nil,
        targetMode: TargetMode? = nil,
        priority: Int? = nil,
        bindings: [Binding<Target, Event>]? = nil,
        commands: [Command<Target, Event>]? = nil,
        fields: [String: KeymapValue] = [:]
    ) {
        self.target = target
        self.targetMode = targetMode
        self.priority = priority
        self.bindings = bindings
        self.commands = commands
        self.fields = fields
    }
}

// parity: keymap/src/solid/index.ts#useKeymap [status=adapted hash=142e01ba6838]
public func useSolidKeymap<Host: KeymapHost>(_ type: Host.Type = Host.self) throws(KeymapScopeError) -> Keymap<Host> {
    try useKeymap(type)
}

/// Reactively derives a value from the scoped keymap by re-running `selector` on each batched `state` event.
// parity: keymap/src/solid/index.ts#useKeymapSelector [status=adapted hash=17d5d53df445]
public func useKeymapSelector<Host: KeymapHost, Value: Sendable>(
    _ type: Host.Type = Host.self,
    selector: @escaping @Sendable (Keymap<Host>) -> Value
) throws(KeymapScopeError) -> KeymapSelectorHandle<Value> {
    let keymap = try useKeymap(type)
    let handle = KeymapSelectorHandle(initial: selector(keymap))
    let off = keymap.on(
        .state { [weak keymap, weak handle] in
            guard let keymap, !keymap.host.isDestroyed else { return }
            handle?.update(selector(keymap))
        }
    )
    handle.setDispose(off)
    return handle
}

// parity: keymap/src/solid/index.ts#useBindings [status=adapted hash=5ab8d82d1f0d]
@discardableResult
public func useSolidBindings<Host: KeymapHost>(
    _ type: Host.Type = Host.self,
    createLayer: () -> SolidUseBindingsLayer<Host.Target, Host.Event>
) throws(KeymapScopeError) -> KeymapScopeHook<Host.Target, Host.Event> {
    let keymap = try useKeymap(type)
    let replace = createLayerSlot(keymap)
    let spec = createLayer()

    let hasExplicitTarget = spec.target != nil
    let targetMode = spec.targetMode ?? (hasExplicitTarget ? .focusWithin : nil)
    if !hasExplicitTarget && targetMode != nil {
        throw .missingTargetAccessor
    }

    if let targetMode {
        if let target = spec.target?() {
            _ = replace(
                Layer(
                    target: target,
                    priority: spec.priority,
                    bindings: spec.bindings,
                    commands: spec.commands,
                    targetMode: targetMode,
                    fields: spec.fields
                )
            )
        } else {
            _ = replace(nil)
        }
    } else {
        _ = replace(
            Layer(
                target: nil,
                priority: spec.priority,
                bindings: spec.bindings,
                commands: spec.commands,
                targetMode: nil,
                fields: spec.fields
            )
        )
    }

    return KeymapScopeHook(replaceSlot: replace)
}

/// Adapts a `KeymapSignal` accessor into a `ReactiveMatcher`.
// parity: keymap/src/solid/index.ts#reactiveMatcherFromSignal [status=adapted hash=91ece7cc8ad4]
public func reactiveMatcherFromSignal<Value: Sendable>(
    _ signal: KeymapSignal<Value>,
    predicate: @escaping @Sendable (Value) -> Bool
) -> ReactiveMatcher {
    ReactiveMatcher(
        get: { predicate(signal.get()) },
        subscribe: { onChange in signal.subscribe(onChange) }
    )
}

/// Boolean signal convenience overload for `reactiveMatcherFromSignal`.
public func reactiveMatcherFromSignal(_ signal: KeymapSignal<Bool>) -> ReactiveMatcher {
    reactiveMatcherFromSignal(signal, predicate: { $0 })
}

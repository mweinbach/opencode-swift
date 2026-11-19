#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - TUI Plugin SDK (`packages/plugin/src/tui/*`)

/// Swift 6.2 port of the OpenCode Terminal UI plugin SDK (`packages/plugin/src/tui/*`).
public enum PluginTui {
    /// Type-erased render output descriptor returned by TUI plugin render closures.
    public struct RenderNode: Equatable, Hashable, Sendable, Codable {
        public let kind: String
        public let text: String?
        public let props: [String: JSONValue]

        public init(kind: String = "fragment", text: String? = nil, props: [String: JSONValue] = [:]) {
            self.kind = kind
            self.text = text
            self.props = props
        }
    }

    // MARK: - tui/context.ts

    /// Durable & ephemeral hot-reload-safe plugin storage for TUI plugins.
    // parity: plugin/src/tui/context.ts#Storage [status=adapted hash=4b5e64473907]
    public struct Storage: Sendable {
        public let getStore: @Sendable (String) async -> JSONValue?
        public let setStore: @Sendable (String, JSONValue) async -> Void
        public let getMemory: @Sendable (String) -> AnySendableValue?
        public let setMemory: @Sendable (String, AnySendableValue) -> Void

        public init(
            getStore: @escaping @Sendable (String) async -> JSONValue?,
            setStore: @escaping @Sendable (String, JSONValue) async -> Void,
            getMemory: @escaping @Sendable (String) -> AnySendableValue?,
            setMemory: @escaping @Sendable (String, AnySendableValue) -> Void
        ) {
            self.getStore = getStore
            self.setStore = setStore
            self.getMemory = getMemory
            self.setMemory = setMemory
        }
    }

    /// Synchronized TUI data snapshot & event listener handle.
    // parity: plugin/src/tui/context.ts#Data [status=adapted hash=c22b9e3f790b]
    public struct Data: Sendable {
        public let on: @Sendable (_ type: String, _ handler: @escaping @Sendable (PluginSDK.EventPayload) -> Void) -> @Sendable () -> Void
        public let listen: @Sendable (_ handler: @escaping @Sendable (PluginSDK.EventPayload) -> Void) -> @Sendable () -> Void
        public let sessionList: @Sendable () -> [SessionSchema.Info]
        public let sessionStatus: @Sendable (SessionID) -> String
        public let defaultLocation: @Sendable () -> LocationSchema.Ref

        public init(
            on: @escaping @Sendable (_ type: String, _ handler: @escaping @Sendable (PluginSDK.EventPayload) -> Void) -> @Sendable () -> Void,
            listen: @escaping @Sendable (_ handler: @escaping @Sendable (PluginSDK.EventPayload) -> Void) -> @Sendable () -> Void,
            sessionList: @escaping @Sendable () -> [SessionSchema.Info],
            sessionStatus: @escaping @Sendable (SessionID) -> String,
            defaultLocation: @escaping @Sendable () -> LocationSchema.Ref
        ) {
            self.on = on
            self.listen = listen
            self.sessionList = sessionList
            self.sessionStatus = sessionStatus
            self.defaultLocation = defaultLocation
        }
    }

    /// Active route in the TUI router (`home`, `session`, or `plugin`).
    // parity: plugin/src/tui/context.ts#Route [status=implemented hash=5f3addd4d5ed]
    public enum Route: Equatable, Hashable, Sendable, Codable {
        case home
        case session(sessionID: String)
        case plugin(id: String, name: String, data: [String: JSONValue]? = nil)
    }

    /// Navigation destination (either a full `Route` or a plugin-local named page).
    // parity: plugin/src/tui/context.ts#Destination [status=implemented hash=4d81fbc1a405]
    public enum Destination: Equatable, Hashable, Sendable, Codable {
        case route(Route)
        case pluginPage(name: String, data: [String: JSONValue]? = nil)
    }

    /// Named full-screen page registered by a TUI plugin.
    // parity: plugin/src/tui/context.ts#Page [status=adapted hash=bb5ba0edda0d]
    public struct Page: Sendable {
        public let name: String
        public let render: @Sendable ([String: JSONValue]?) -> RenderNode

        public init(name: String, render: @escaping @Sendable ([String: JSONValue]?) -> RenderNode) {
            self.name = name
            self.render = render
        }
    }

    /// Presentation mode of the TUI session side panel.
    // parity: plugin/src/tui/context.ts#PanelPresentation [status=implemented hash=cb7dbe4e0bc2]
    public enum PanelPresentation: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case panel
        case fullscreen
    }

    /// Client-local state published to `session.panel` slot claims.
    // parity: plugin/src/tui/context.ts#PanelInput [status=implemented hash=5f0050b41f03]
    public struct PanelInput: Sendable {
        public let name: String
        public let sessionID: String
        public let width: Int
        public let presentation: PanelPresentation
        public let focused: Bool
        public let focus: @Sendable () -> Void
        public let close: @Sendable () -> Void
        public let toggleFullscreen: @Sendable () -> Void

        public init(
            name: String,
            sessionID: String,
            width: Int,
            presentation: PanelPresentation,
            focused: Bool,
            focus: @escaping @Sendable () -> Void = {},
            close: @escaping @Sendable () -> Void = {},
            toggleFullscreen: @escaping @Sendable () -> Void = {}
        ) {
            self.name = name
            self.sessionID = sessionID
            self.width = width
            self.presentation = presentation
            self.focused = focused
            self.focus = focus
            self.close = close
            self.toggleFullscreen = toggleFullscreen
        }
    }

    /// Input published to `prompt.footer*` TUI slots.
    public struct PromptFooterInput: Equatable, Hashable, Sendable, Codable {
        public enum Mode: String, Equatable, Hashable, Sendable, Codable {
            case normal
            case shell
        }

        public let sessionID: String?
        public let mode: Mode
        public let showDetails: Bool

        public init(sessionID: String? = nil, mode: Mode = .normal, showDetails: Bool = false) {
            self.sessionID = sessionID
            self.mode = mode
            self.showDetails = showDetails
        }
    }

    /// Typed map of all stable TUI host UI slot inputs.
    // parity: plugin/src/tui/context.ts#SlotMap [status=implemented hash=db0e27b146aa]
    public enum SlotMap: Sendable {
        case app
        case homeFooter
        case homeFooterStatus
        case promptFooter(PromptFooterInput)
        case promptFooterStatus(PromptFooterInput)
        case promptFooterFile(PromptFooterInput)
        case sessionComposerTop(sessionID: String)
        case sessionPanel(PanelInput)
        case sidebarContent(sessionID: String)
        case sidebarFooter(sessionID: String)

        public var path: SlotPath {
            switch self {
            case .app: return .app
            case .homeFooter: return .homeFooter
            case .homeFooterStatus: return .homeFooterStatus
            case .promptFooter: return .promptFooter
            case .promptFooterStatus: return .promptFooterStatus
            case .promptFooterFile: return .promptFooterFile
            case .sessionComposerTop: return .sessionComposerTop
            case .sessionPanel: return .sessionPanel
            case .sidebarContent: return .sidebarContent
            case .sidebarFooter: return .sidebarFooter
            }
        }
    }

    /// Canonical dot-separated slot path in the TUI slot tree.
    // parity: plugin/src/tui/context.ts#SlotPath [status=implemented hash=8f37f10dc446]
    public enum SlotPath: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case app = "app"
        case homeFooter = "home.footer"
        case homeFooterStatus = "home.footer.status"
        case promptFooter = "prompt.footer"
        case promptFooterStatus = "prompt.footer.status"
        case promptFooterFile = "prompt.footer.file"
        case sessionComposerTop = "session.composer.top"
        case sessionPanel = "session.panel"
        case sidebarContent = "sidebar.content"
        case sidebarFooter = "sidebar.footer"

        /// Returns whether `self` is an ancestor path of `descendant` (e.g., `prompt.footer` contains `prompt.footer.status`).
        public func contains(_ descendant: SlotPath) -> Bool {
            descendant.rawValue.hasPrefix(rawValue + ".")
        }
    }

    /// One mutually exclusive placement contribution to the TUI slot tree (`prepend`, `append`, `before`, `after`, `replace`).
    // parity: plugin/src/tui/context.ts#SlotClaim [status=implemented hash=397123af400d]
    public struct SlotClaim: Sendable {
        public enum Placement: Equatable, Hashable, Sendable, Codable {
            case prepend(SlotPath)
            case append(SlotPath)
            case before(SlotPath)
            case after(SlotPath)
            case replace(SlotPath)

            public var target: SlotPath {
                switch self {
                case .prepend(let p), .append(let p), .before(let p), .after(let p), .replace(let p):
                    return p
                }
            }
        }

        public let placement: Placement
        public let render: @Sendable (SlotMap) -> RenderNode

        public init(placement: Placement, render: @escaping @Sendable (SlotMap) -> RenderNode) {
            self.placement = placement
            self.render = render
        }
    }

    /// Running TUI application version & release channel.
    // parity: plugin/src/tui/context.ts#App [status=implemented hash=bee76a4c6531]
    public struct App: Equatable, Hashable, Sendable, Codable {
        public let version: String
        public let channel: String

        public init(version: String, channel: String) {
            self.version = version
            self.channel = channel
        }
    }

    /// Visual tone of a TUI toast notification.
    // parity: plugin/src/tui/context.ts#ToastVariant [status=implemented hash=b031a5c8f77e]
    public enum ToastVariant: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case info
        case success
        case warning
        case error
    }

    /// Options passed to `ui.toast.show(...)`.
    // parity: plugin/src/tui/context.ts#ToastOptions [status=implemented hash=1b5dd814b48a]
    public struct ToastOptions: Equatable, Hashable, Sendable, Codable {
        public let title: String?
        public let message: String
        public let variant: ToastVariant?
        public let duration: Int?
        public let sessionID: String?

        public init(
            title: String? = nil,
            message: String,
            variant: ToastVariant? = nil,
            duration: Int? = nil,
            sessionID: String? = nil
        ) {
            self.title = title
            self.message = message
            self.variant = variant
            self.duration = duration
            self.sessionID = sessionID
        }
    }

    /// TUI toast presenter service.
    // parity: plugin/src/tui/context.ts#Toast [status=implemented hash=d70888d74f75]
    public struct Toast: Sendable {
        public let show: @Sendable (ToastOptions) -> Void

        public init(show: @escaping @Sendable (ToastOptions) -> Void) {
            self.show = show
        }
    }

    /// Focus condition under which an attention notification or sound fires.
    // parity: plugin/src/tui/context.ts#AttentionWhen [status=implemented hash=5e97d5e64428]
    public enum AttentionWhen: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case always
        case focused
        case blurred
    }

    /// Named sound cues supported by the TUI attention system.
    // parity: plugin/src/tui/context.ts#AttentionSoundName [status=implemented hash=8d44730a0228]
    public enum AttentionSoundName: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case `default`
        case question
        case permission
        case error
        case done
        case subagentDone = "subagent_done"
    }

    /// Attention notification delivery preference.
    // parity: plugin/src/tui/context.ts#AttentionNotification [status=implemented hash=0a8af15ef807]
    public enum AttentionNotification: Equatable, Hashable, Sendable, Codable {
        case enabled(Bool)
        case configured(when: AttentionWhen?)
    }

    /// Attention sound delivery preference.
    // parity: plugin/src/tui/context.ts#AttentionSound [status=implemented hash=4b32608bba53]
    public enum AttentionSound: Equatable, Hashable, Sendable, Codable {
        case enabled(Bool)
        case configured(name: AttentionSoundName?, volume: Double?, when: AttentionWhen?)
    }

    /// Options passed to `attention.notify(...)`.
    // parity: plugin/src/tui/context.ts#AttentionNotifyOptions [status=implemented hash=8768fb935775]
    public struct AttentionNotifyOptions: Equatable, Hashable, Sendable, Codable {
        public let title: String?
        public let message: String
        public let notification: AttentionNotification?
        public let sound: AttentionSound?

        public init(
            title: String? = nil,
            message: String,
            notification: AttentionNotification? = nil,
            sound: AttentionSound? = nil
        ) {
            self.title = title
            self.message = message
            self.notification = notification
            self.sound = sound
        }
    }

    /// Reason an attention notification was skipped.
    // parity: plugin/src/tui/context.ts#AttentionNotifySkipReason [status=implemented hash=ee26e7f1736d]
    public enum AttentionNotifySkipReason: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case attentionDisabled = "attention_disabled"
        case emptyMessage = "empty_message"
        case blurred
        case focused
        case focusUnknown = "focus_unknown"
        case rendererDestroyed = "renderer_destroyed"
    }

    /// Result returned from `attention.notify(...)`.
    // parity: plugin/src/tui/context.ts#AttentionNotifyResult [status=implemented hash=2ff5c01afe2a]
    public struct AttentionNotifyResult: Equatable, Hashable, Sendable, Codable {
        public let ok: Bool
        public let notification: Bool
        public let sound: Bool
        public let skipped: AttentionNotifySkipReason?

        public init(ok: Bool, notification: Bool, sound: Bool, skipped: AttentionNotifySkipReason? = nil) {
            self.ok = ok
            self.notification = notification
            self.sound = sound
            self.skipped = skipped
        }
    }

    /// Terminal attention notification & sound service.
    // parity: plugin/src/tui/context.ts#Attention [status=implemented hash=1e9932fe98d8]
    public struct Attention: Sendable {
        public let notify: @Sendable (AttentionNotifyOptions) async -> AttentionNotifyResult

        public init(notify: @escaping @Sendable (AttentionNotifyOptions) async -> AttentionNotifyResult) {
            self.notify = notify
        }
    }

    /// TUI modal dialog size preset.
    // parity: plugin/src/tui/context.ts#DialogSize [status=implemented hash=ea7c2ff6a00a]
    public enum DialogSize: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case medium
        case large
        case xlarge
    }

    /// Presentation options for the active TUI dialog.
    // parity: plugin/src/tui/context.ts#DialogOptions [status=implemented hash=0190038d8d12]
    public struct DialogOptions: Equatable, Hashable, Sendable, Codable {
        public let size: DialogSize?
        public let centered: Bool?

        public init(size: DialogSize? = nil, centered: Bool? = nil) {
            self.size = size
            self.centered = centered
        }
    }

    /// Options for `dialog.alert(...)`.
    // parity: plugin/src/tui/context.ts#DialogAlertOptions [status=implemented hash=fc09c3c7b181]
    public struct DialogAlertOptions: Equatable, Hashable, Sendable, Codable {
        public let title: String
        public let message: String

        public init(title: String, message: String) {
            self.title = title
            self.message = message
        }
    }

    /// Options for `dialog.confirm(...)`.
    // parity: plugin/src/tui/context.ts#DialogConfirmOptions [status=implemented hash=efd464b2e912]
    public struct DialogConfirmOptions: Equatable, Hashable, Sendable, Codable {
        public let title: String
        public let message: String
        public let confirmLabel: String?
        public let cancelLabel: String?

        public init(title: String, message: String, confirmLabel: String? = nil, cancelLabel: String? = nil) {
            self.title = title
            self.message = message
            self.confirmLabel = confirmLabel
            self.cancelLabel = cancelLabel
        }
    }

    /// Options for `dialog.prompt(...)`.
    // parity: plugin/src/tui/context.ts#DialogPromptOptions [status=implemented hash=8a7e25dbdc49]
    public struct DialogPromptOptions: Equatable, Hashable, Sendable, Codable {
        public let title: String
        public let description: String?
        public let placeholder: String?
        public let value: String?

        public init(title: String, description: String? = nil, placeholder: String? = nil, value: String? = nil) {
            self.title = title
            self.description = description
            self.placeholder = placeholder
            self.value = value
        }
    }

    /// Selectable item inside `dialog.select(...)`.
    // parity: plugin/src/tui/context.ts#DialogSelectOption [status=implemented hash=41a75cc189ac]
    public struct DialogSelectOption<Value: Sendable>: Sendable {
        public let title: String
        public let value: Value
        public let description: String?
        public let footer: String?
        public let category: String?
        public let disabled: Bool?

        public init(
            title: String,
            value: Value,
            description: String? = nil,
            footer: String? = nil,
            category: String? = nil,
            disabled: Bool? = nil
        ) {
            self.title = title
            self.value = value
            self.description = description
            self.footer = footer
            self.category = category
            self.disabled = disabled
        }
    }

    /// Footer action attached to a TUI select dialog.
    // parity: plugin/src/tui/context.ts#DialogSelectAction [status=implemented hash=1220e61fd107]
    public enum DialogSelectAction<Value: Sendable>: Sendable {
        case selectionRequired(bind: String, title: String, side: String?, onTrigger: @Sendable (Value) -> Void)
        case noSelection(bind: String, title: String, side: String?, onTrigger: @Sendable () -> Void)
    }

    /// Configuration for `dialog.select(...)`.
    // parity: plugin/src/tui/context.ts#DialogSelectOptions [status=implemented hash=f6447073f179]
    public struct DialogSelectOptions<Value: Sendable>: Sendable {
        public let title: String
        public let placeholder: String?
        public let options: [DialogSelectOption<Value>]
        public let current: Value?
        public let search: (@Sendable (String, [DialogSelectOption<Value>]) -> [DialogSelectOption<Value>])?
        public let actions: [DialogSelectAction<Value>]?

        public init(
            title: String,
            placeholder: String? = nil,
            options: [DialogSelectOption<Value>],
            current: Value? = nil,
            search: (@Sendable (String, [DialogSelectOption<Value>]) -> [DialogSelectOption<Value>])? = nil,
            actions: [DialogSelectAction<Value>]? = nil
        ) {
            self.title = title
            self.placeholder = placeholder
            self.options = options
            self.current = current
            self.search = search
            self.actions = actions
        }
    }

    /// TUI modal dialog controller.
    // parity: plugin/src/tui/context.ts#Dialog [status=adapted hash=2ff6812ca5aa]
    public struct Dialog: Sendable {
        public let show: @Sendable (_ render: @escaping @Sendable () -> RenderNode, _ onClose: (@Sendable () -> Void)?) -> Void
        public let set: @Sendable (DialogOptions) -> Void
        public let clear: @Sendable () -> Void
        public let alert: @Sendable (DialogAlertOptions) async -> Void
        public let confirm: @Sendable (DialogConfirmOptions) async -> Bool?
        public let prompt: @Sendable (DialogPromptOptions) async -> String?

        public init(
            show: @escaping @Sendable (_ render: @escaping @Sendable () -> RenderNode, _ onClose: (@Sendable () -> Void)?) -> Void = { _, _ in },
            set: @escaping @Sendable (DialogOptions) -> Void = { _ in },
            clear: @escaping @Sendable () -> Void = {},
            alert: @escaping @Sendable (DialogAlertOptions) async -> Void = { _ in },
            confirm: @escaping @Sendable (DialogConfirmOptions) async -> Bool? = { _ in nil },
            prompt: @escaping @Sendable (DialogPromptOptions) async -> String? = { _ in nil }
        ) {
            self.show = show
            self.set = set
            self.clear = clear
            self.alert = alert
            self.confirm = confirm
            self.prompt = prompt
        }
    }

    /// Slash-command metadata on a `KeymapCommand`.
    public struct KeymapSlash: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let aliases: [String]?
        public let arguments: Bool?

        public init(name: String, aliases: [String]? = nil, arguments: Bool? = nil) {
            self.name = name
            self.aliases = aliases
            self.arguments = arguments
        }
    }

    /// Command registered in a TUI keymap layer.
    // parity: plugin/src/tui/context.ts#KeymapCommand [status=implemented hash=11a8b28ffb1f]
    public struct KeymapCommand: Sendable {
        public let id: String?
        public let title: String?
        public let description: String?
        public let group: String?
        public let enabled: @Sendable () -> Bool
        public let bind: String?
        public let bindDisabled: Bool
        public let palette: Bool
        public let slash: KeymapSlash?
        public let suggested: @Sendable () -> Bool
        public let run: @Sendable (_ input: String?) async -> Bool

        public init(
            id: String? = nil,
            title: String? = nil,
            description: String? = nil,
            group: String? = nil,
            enabled: @escaping @Sendable () -> Bool = { true },
            bind: String? = nil,
            bindDisabled: Bool = false,
            palette: Bool = false,
            slash: KeymapSlash? = nil,
            suggested: @escaping @Sendable () -> Bool = { false },
            run: @escaping @Sendable (_ input: String?) async -> Bool = { _ in true }
        ) {
            self.id = id
            self.title = title
            self.description = description
            self.group = group
            self.enabled = enabled
            self.bind = bind
            self.bindDisabled = bindDisabled
            self.palette = palette
            self.slash = slash
            self.suggested = suggested
            self.run = run
        }
    }

    /// Reactive keymap layer descriptor.
    // parity: plugin/src/tui/context.ts#KeymapLayer [status=implemented hash=e45a1a0dda86]
    public struct KeymapLayer: Sendable {
        public let mode: String?
        public let enabled: @Sendable () -> Bool
        public let priority: Int?
        public let commands: [KeymapCommand]
        public let bindings: [String]

        public init(
            mode: String? = nil,
            enabled: @escaping @Sendable () -> Bool = { true },
            priority: Int? = nil,
            commands: [KeymapCommand] = [],
            bindings: [String] = []
        ) {
            self.mode = mode
            self.enabled = enabled
            self.priority = priority
            self.commands = commands
            self.bindings = bindings
        }
    }

    /// Pending prefix key sequence entry.
    // parity: plugin/src/tui/context.ts#KeymapPending [status=implemented hash=fa4c931bdc25]
    public struct KeymapPending: Equatable, Hashable, Sendable, Codable {
        public let key: String
        public let token: String?

        public init(key: String, token: String? = nil) {
            self.key = key
            self.token = token
        }
    }

    /// Reachable key binding entry from the current pending sequence.
    // parity: plugin/src/tui/context.ts#KeymapActive [status=implemented hash=f6a3d50235be]
    public struct KeymapActive: Equatable, Hashable, Sendable, Codable {
        public let key: String
        public let title: String?
        public let description: String?
        public let group: String?
        public let continues: Bool

        public init(
            key: String,
            title: String? = nil,
            description: String? = nil,
            group: String? = nil,
            continues: Bool = false
        ) {
            self.key = key
            self.title = title
            self.description = description
            self.group = group
            self.continues = continues
        }
    }

    /// TUI keymap service supporting reactive layers, command dispatch, and input mode stack.
    // parity: plugin/src/tui/context.ts#Keymap [status=implemented hash=7d0799284d5a]
    public struct Keymap: Sendable {
        public let layer: @Sendable (@escaping @Sendable () -> KeymapLayer) -> Void
        public let dispatch: @Sendable (String, String?) -> Void
        public let shortcuts: @Sendable (String) -> [String]
        public let commands: @Sendable () -> [KeymapCommand]
        public let pending: @Sendable () -> [KeymapPending]
        public let active: @Sendable () -> [KeymapActive]
        public let currentMode: @Sendable () -> String
        public let pushMode: @Sendable (String) -> @Sendable () -> Void

        public init(
            layer: @escaping @Sendable (@escaping @Sendable () -> KeymapLayer) -> Void,
            dispatch: @escaping @Sendable (String, String?) -> Void,
            shortcuts: @escaping @Sendable (String) -> [String],
            commands: @escaping @Sendable () -> [KeymapCommand],
            pending: @escaping @Sendable () -> [KeymapPending],
            active: @escaping @Sendable () -> [KeymapActive],
            currentMode: @escaping @Sendable () -> String,
            pushMode: @escaping @Sendable (String) -> @Sendable () -> Void
        ) {
            self.layer = layer
            self.dispatch = dispatch
            self.shortcuts = shortcuts
            self.commands = commands
            self.pending = pending
            self.active = active
            self.currentMode = currentMode
            self.pushMode = pushMode
        }
    }

    /// TUI UI API exposing dialogs, toasts, router, panels, tabs, model picker, and slot claims.
    // parity: plugin/src/tui/context.ts#UI [status=adapted hash=6f762e71eeac]
    public struct UI: Sendable {
        public let dialog: Dialog
        public let toast: Toast
        public let formatPath: @Sendable (String) -> String
        public let registerPage: @Sendable (Page) -> @Sendable () -> Void
        public let navigate: @Sendable (Destination) -> Void
        public let currentRoute: @Sendable () -> Route
        public let openPanel: @Sendable (String, PanelPresentation?) -> Bool
        public let closePanel: @Sendable () -> Void
        public let slot: @Sendable (SlotClaim) -> @Sendable () -> Void

        public init(
            dialog: Dialog = Dialog(),
            toast: Toast = Toast(show: { _ in }),
            formatPath: @escaping @Sendable (String) -> String = { $0 },
            registerPage: @escaping @Sendable (Page) -> @Sendable () -> Void = { _ in {} },
            navigate: @escaping @Sendable (Destination) -> Void = { _ in },
            currentRoute: @escaping @Sendable () -> Route = { .home },
            openPanel: @escaping @Sendable (String, PanelPresentation?) -> Bool = { _, _ in false },
            closePanel: @escaping @Sendable () -> Void = {},
            slot: @escaping @Sendable (SlotClaim) -> @Sendable () -> Void = { _ in {} }
        ) {
            self.dialog = dialog
            self.toast = toast
            self.formatPath = formatPath
            self.registerPage = registerPage
            self.navigate = navigate
            self.currentRoute = currentRoute
            self.openPanel = openPanel
            self.closePanel = closePanel
            self.slot = slot
        }
    }

    /// Full context provided to a TUI plugin's `setup` entrypoint.
    // parity: plugin/src/tui/context.ts#Context [status=adapted hash=9fcc5178f0e1]
    public struct Context: Sendable {
        public let options: PluginContract.PluginOptions
        public let location: LocationSchema.Ref?
        public let app: App
        public let data: Data
        public let attention: Attention
        public let themeMode: String
        public let registerCodeBlockRenderer: @Sendable (String, @escaping @Sendable (String) -> RenderNode) -> @Sendable () -> Void
        public let keymap: Keymap
        public let storage: Storage
        public let ui: UI

        public init(
            options: PluginContract.PluginOptions = [:],
            location: LocationSchema.Ref? = nil,
            app: App,
            data: Data,
            attention: Attention,
            themeMode: String = "dark",
            registerCodeBlockRenderer: @escaping @Sendable (String, @escaping @Sendable (String) -> RenderNode) -> @Sendable () -> Void = { _, _ in {} },
            keymap: Keymap,
            storage: Storage,
            ui: UI
        ) {
            self.options = options
            self.location = location
            self.app = app
            self.data = data
            self.attention = attention
            self.themeMode = themeMode
            self.registerCodeBlockRenderer = registerCodeBlockRenderer
            self.keymap = keymap
            self.storage = storage
            self.ui = ui
        }
    }

    // MARK: - tui/plugin.ts

    /// Optional async cleanup closure returned by a TUI plugin's `setup`.
    // parity: plugin/src/tui/plugin.ts#Cleanup [status=implemented hash=ebf6dc2dbce3]
    public typealias Cleanup = @Sendable () async -> Void

    /// TUI plugin descriptor definition.
    // parity: plugin/src/tui/plugin.ts#Definition [status=implemented hash=9668c411aee4]
    public struct Definition: Sendable {
        public let id: String
        public let setup: @Sendable (Context) async throws -> Cleanup?

        public init(id: String, setup: @escaping @Sendable (Context) async throws -> Cleanup?) {
            self.id = id
            self.setup = setup
        }
    }

    /// Identity helper defining a TUI plugin.
    // parity: plugin/src/tui/plugin.ts#define [status=implemented hash=6f90ea07f865]
    public static func define(_ plugin: Definition) -> Definition {
        plugin
    }

    // MARK: - tui/solid.ts

    public enum TuiContextError: Error, Equatable, Sendable, CustomStringConvertible {
        case missingContextProvider

        public var description: String {
            "PluginContextProvider is missing"
        }
    }

    @TaskLocal
    private static var currentTuiContext: Context?

    /// Runs `body` with `context` bound as the active TUI plugin context (Swift equivalent of Solid's `PluginContextProvider`).
    // parity: plugin/src/tui/solid.ts#PluginContextProvider [status=adapted hash=8e9b8b1c8c07]
    public static func PluginContextProvider<T: Sendable>(
        value: Context,
        children: () throws -> T
    ) rethrows -> T {
        try $currentTuiContext.withValue(value, operation: children)
    }

    /// Reads the active TUI plugin context bound by `PluginContextProvider`.
    // parity: plugin/src/tui/solid.ts#usePlugin [status=adapted hash=0047bcc91856]
    public static func usePlugin() throws(TuiContextError) -> Context {
        guard let ctx = currentTuiContext else {
            throw .missingContextProvider
        }
        return ctx
    }

    // MARK: - TUI Plugin Descriptor Host Registry

    /// In-process registry backing TUI plugin descriptor registration (pages, slots, keymap layers, code-block renderers).
    public final class DescriptorRegistry: Sendable {
        private struct State: Sendable {
            var nextToken: UInt64 = 1
            var pages: [(token: UInt64, pluginID: String, page: Page)] = []
            var slots: [(token: UInt64, pluginID: String, claim: SlotClaim)] = []
            var keymapLayers: [(token: UInt64, pluginID: String, factory: @Sendable () -> KeymapLayer)] = []
            var codeBlockRenderers: [(token: UInt64, pluginID: String, language: String, render: @Sendable (String) -> RenderNode)] = []
            var modes: [(token: UInt64, mode: String)] = []
            var route: Route = .home
            var activePanel: (pluginID: String, name: String, presentation: PanelPresentation)? = nil
            var memory: [String: AnySendableValue] = [:]
            var persisted: [String: JSONValue] = [:]
        }

        private let state = Mutex(State())

        public init() {}

        /// Registers a TUI plugin descriptor, executing its `setup` and returning a cleanup handle.
        @discardableResult
        public func register(
            _ definition: Definition,
            app: App = App(version: "0.0.0", channel: "local"),
            options: PluginContract.PluginOptions = [:]
        ) async throws -> Cleanup {
            let pluginID = definition.id
            let pluginCleanups = Mutex<[@Sendable () -> Void]>([])

            let registerPage: @Sendable (Page) -> @Sendable () -> Void = { [self] page in
                let token = self.state.withLock { s -> UInt64 in
                    let id = s.nextToken
                    s.nextToken &+= 1
                    s.pages.append((id, pluginID, page))
                    return id
                }
                let remove: @Sendable () -> Void = { [self] in
                    self.state.withLock { s in
                        s.pages.removeAll { $0.token == token }
                    }
                }
                pluginCleanups.withLock { $0.append(remove) }
                return remove
            }

            let registerSlot: @Sendable (SlotClaim) -> @Sendable () -> Void = { [self] claim in
                let token = self.state.withLock { s -> UInt64 in
                    let id = s.nextToken
                    s.nextToken &+= 1
                    s.slots.append((id, pluginID, claim))
                    return id
                }
                let remove: @Sendable () -> Void = { [self] in
                    self.state.withLock { s in
                        s.slots.removeAll { $0.token == token }
                    }
                }
                pluginCleanups.withLock { $0.append(remove) }
                return remove
            }

            let registerCodeBlock: @Sendable (String, @escaping @Sendable (String) -> RenderNode) -> @Sendable () -> Void = {
                [self] language, renderer in
                let token = self.state.withLock { s -> UInt64 in
                    let id = s.nextToken
                    s.nextToken &+= 1
                    s.codeBlockRenderers.append((id, pluginID, language.lowercased(), renderer))
                    return id
                }
                let remove: @Sendable () -> Void = { [self] in
                    self.state.withLock { s in
                        s.codeBlockRenderers.removeAll { $0.token == token }
                    }
                }
                pluginCleanups.withLock { $0.append(remove) }
                return remove
            }

            let keymap = Keymap(
                layer: { [self] factory in
                    let token = self.state.withLock { s -> UInt64 in
                        let id = s.nextToken
                        s.nextToken &+= 1
                        s.keymapLayers.append((id, pluginID, factory))
                        return id
                    }
                    pluginCleanups.withLock { list in
                        list.append { [self] in
                            self.state.withLock { s in
                                s.keymapLayers.removeAll { $0.token == token }
                            }
                        }
                    }
                },
                dispatch: { _, _ in },
                shortcuts: { [self] commandID in
                    self.state.withLock { s in
                        s.keymapLayers.flatMap { entry in
                            entry.factory().commands.compactMap { cmd in
                                (cmd.id == commandID && !cmd.bindDisabled) ? cmd.bind : nil
                            }
                        }
                    }
                },
                commands: { [self] in
                    self.state.withLock { s in
                        s.keymapLayers.flatMap { $0.factory().commands }
                    }
                },
                pending: { [] },
                active: { [] },
                currentMode: { [self] in
                    self.state.withLock { $0.modes.last?.mode ?? "base" }
                },
                pushMode: { [self] mode in
                    let token = self.state.withLock { s -> UInt64 in
                        let id = s.nextToken
                        s.nextToken &+= 1
                        s.modes.append((id, mode))
                        return id
                    }
                    let pop: @Sendable () -> Void = { [self] in
                        self.state.withLock { s in
                            s.modes.removeAll { $0.token == token }
                        }
                    }
                    pluginCleanups.withLock { $0.append(pop) }
                    return pop
                }
            )

            let storage = Storage(
                getStore: { [self] key in
                    self.state.withLock { $0.persisted["\(pluginID):\(key)"] }
                },
                setStore: { [self] key, value in
                    self.state.withLock { $0.persisted["\(pluginID):\(key)"] = value }
                },
                getMemory: { [self] key in
                    self.state.withLock { $0.memory["\(pluginID):\(key)"] }
                },
                setMemory: { [self] key, value in
                    self.state.withLock { $0.memory["\(pluginID):\(key)"] = value }
                }
            )

            let ui = UI(
                registerPage: registerPage,
                navigate: { [self] dest in
                    self.state.withLock { s in
                        switch dest {
                        case .route(let r):
                            s.route = r
                        case .pluginPage(let name, let data):
                            s.route = .plugin(id: pluginID, name: name, data: data)
                        }
                    }
                },
                currentRoute: { [self] in
                    self.state.withLock { $0.route }
                },
                openPanel: { [self] name, presentation in
                    self.state.withLock { s in
                        s.activePanel = (pluginID, name, presentation ?? .panel)
                    }
                    return true
                },
                closePanel: { [self] in
                    self.state.withLock { s in
                        if s.activePanel?.pluginID == pluginID {
                            s.activePanel = nil
                        }
                    }
                },
                slot: registerSlot
            )

            let data = Data(
                on: { _, _ in {} },
                listen: { _ in {} },
                sessionList: { [] },
                sessionStatus: { _ in "idle" },
                defaultLocation: { LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: "/")) }
            )

            let context = Context(
                options: options,
                location: nil,
                app: app,
                data: data,
                attention: Attention(notify: { opts in
                    if opts.message.isEmpty {
                        return AttentionNotifyResult(ok: false, notification: false, sound: false, skipped: .emptyMessage)
                    }
                    return AttentionNotifyResult(ok: true, notification: true, sound: false)
                }),
                themeMode: "dark",
                registerCodeBlockRenderer: registerCodeBlock,
                keymap: keymap,
                storage: storage,
                ui: ui
            )

            let userCleanup = try await definition.setup(context)
            return {
                if let userCleanup {
                    await userCleanup()
                }
                let toUndo = pluginCleanups.withLock { list -> [@Sendable () -> Void] in
                    let copy = list
                    list.removeAll()
                    return copy
                }
                for fn in toUndo.reversed() {
                    fn()
                }
            }
        }

        public func registeredPages() -> [(pluginID: String, name: String)] {
            state.withLock { s in s.pages.map { ($0.pluginID, $0.page.name) } }
        }

        public func slotClaims(for path: SlotPath) -> [SlotClaim] {
            state.withLock { s in s.slots.map(\.claim).filter { $0.placement.target == path } }
        }

        public func commands() -> [KeymapCommand] {
            state.withLock { s in s.keymapLayers.flatMap { $0.factory().commands } }
        }

        public func codeBlockLanguages() -> [String] {
            state.withLock { s in s.codeBlockRenderers.map(\.language) }
        }

        public func currentRoute() -> Route {
            state.withLock { $0.route }
        }
    }
}

// MARK: - GUI Plugin SDK (`packages/plugin/src/gui/*`)

/// Swift 6.2 port of the OpenCode Desktop/Web GUI plugin SDK (`packages/plugin/src/gui/*`).
public enum PluginGui {
    /// Type-erased UI view output for Swift representations of GUI plugin render callbacks.
    public struct ViewNode: Equatable, Hashable, Sendable, Codable {
        public let component: String
        public let label: String?
        public let props: [String: JSONValue]

        public init(component: String = "view", label: String? = nil, props: [String: JSONValue] = [:]) {
            self.component = component
            self.label = label
            self.props = props
        }
    }

    // MARK: - gui/core.ts

    /// Teardown closure withdrawing a contribution or cleaning up resources.
    // parity: plugin/src/gui/core.ts#Cleanup [status=implemented hash=0cd4fd7bb58b]
    public typealias Cleanup = @Sendable () async -> Void

    /// Desktop operating system identifier.
    // parity: plugin/src/gui/core.ts#OS [status=implemented hash=3737c89b1a7b]
    public enum OS: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case macos
        case windows
        case linux
    }

    /// Interpolation values for i18n message templates (`{{name}}`).
    // parity: plugin/src/gui/core.ts#Params [status=implemented hash=873e9ffc7344]
    public typealias Params = [String: JSONValue]

    /// One locale's message catalog (`key -> template`).
    // parity: plugin/src/gui/core.ts#Messages [status=implemented hash=beff00062eaf]
    public typealias Messages = [String: String]

    /// Inline i18n catalog keyed by locale code (always carrying English fallback `"en"`).
    // parity: plugin/src/gui/core.ts#Catalog [status=implemented hash=7a80cca9ace1]
    public struct Catalog: Equatable, Hashable, Sendable, Codable {
        public let en: Messages
        public let locales: [String: Messages]

        public init(en: Messages = [:], locales: [String: Messages] = [:]) {
            self.en = en
            var all = locales
            all["en"] = en
            self.locales = all
        }
    }

    /// JSON value type for GUI plugin options.
    // parity: plugin/src/gui/core.ts#Json [status=implemented hash=19d8743f455c]
    public typealias Json = JSONValue

    /// Plugin options dictionary supplied to GUI plugins.
    // parity: plugin/src/gui/core.ts#PluginOptions [status=implemented hash=45569e4d7cab]
    public typealias PluginOptions = [String: Json]

    /// Running desktop or web host application metadata.
    // parity: plugin/src/gui/core.ts#App [status=implemented hash=4db8698f31a2]
    public struct App: Equatable, Hashable, Sendable, Codable {
        public enum Channel: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
            case local
            case dev
            case beta
            case prod
        }

        public enum PlatformKind: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
            case web
            case desktop
        }

        public let name: String
        public let version: String
        public let channel: Channel
        public let platform: PlatformKind
        public let packaged: Bool

        public init(
            name: String = "opencode",
            version: String = "",
            channel: Channel = .local,
            platform: PlatformKind = .desktop,
            packaged: Bool = false
        ) {
            self.name = name
            self.version = version
            self.channel = channel
            self.platform = platform
            self.packaged = packaged
        }
    }

    /// Typed contribution list token defined via `Registry.define(id)`.
    // parity: plugin/src/gui/core.ts#Registry [status=implemented hash=c591f943d3b4]
    public struct Registry<T: Sendable>: Equatable, Hashable, Sendable {
        public let kind: String = "registry"
        public let id: String

        public init(id: String) {
            self.id = id
        }

        public static func define(_ id: String) -> Registry<T> {
            Registry<T>(id: id)
        }
    }

    /// In-process window contract token defined via `Contract.define(id)`.
    // parity: plugin/src/gui/core.ts#Contract [status=implemented hash=4f6a5a308411]
    public struct Contract<T: Sendable>: Equatable, Hashable, Sendable {
        public let kind: String = "contract"
        public let id: String

        public init(id: String) {
            self.id = id
        }

        public static func define(_ id: String) -> Contract<T> {
            Contract<T>(id: id)
        }
    }

    /// Schema description for one method on an `IpcSpec`.
    // parity: plugin/src/gui/core.ts#IpcMethod [status=implemented hash=2ff288b47e74]
    public struct IpcMethod: Equatable, Hashable, Sendable, Codable {
        public let input: ToolSchema.ValueSchema?
        public let output: ToolSchema.ValueSchema?

        public init(input: ToolSchema.ValueSchema? = nil, output: ToolSchema.ValueSchema? = nil) {
            self.input = input
            self.output = output
        }
    }

    /// Schema specification for a main-to-window IPC contract.
    // parity: plugin/src/gui/core.ts#IpcSpec [status=implemented hash=e97af7d22661]
    public struct IpcSpec: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let state: ToolSchema.ValueSchema?
        public let methods: [String: IpcMethod]
        public let events: [String: ToolSchema.ValueSchema]?

        public init(
            id: String,
            state: ToolSchema.ValueSchema? = nil,
            methods: [String: IpcMethod] = [:],
            events: [String: ToolSchema.ValueSchema]? = nil
        ) {
            self.id = id
            self.state = state
            self.methods = methods
            self.events = events
        }
    }

    /// Token for a main-process IPC service defined via `Ipc.define(spec)`.
    // parity: plugin/src/gui/core.ts#Ipc [status=implemented hash=8162ef5a2d87]
    public struct Ipc: Equatable, Hashable, Sendable, Codable {
        public let kind: String
        public let id: String
        public let spec: IpcSpec

        public init(spec: IpcSpec) {
            self.kind = "ipc"
            self.id = spec.id
            self.spec = spec
        }

        public static func define(_ spec: IpcSpec) -> Ipc {
            Ipc(spec: spec)
        }
    }

    /// Type-erased token union identifying either a `Contract` or an `Ipc`.
    // parity: plugin/src/gui/core.ts#Token [status=implemented hash=d017b1cfa3fb]
    public enum Token: Equatable, Hashable, Sendable {
        case contract(id: String)
        case ipc(Ipc)

        public var id: String {
            switch self {
            case .contract(let id): return id
            case .ipc(let ipc): return ipc.id
            }
        }
    }

    /// Per-call cancellation options for GUI IPC calls.
    // parity: plugin/src/gui/core.ts#IpcCallOptions [status=implemented hash=7df3954b7d02]
    public struct IpcCallOptions: Sendable {
        public let signal: AbortSignal?

        public init(signal: AbortSignal? = nil) {
            self.signal = signal
        }
    }

    /// Client handle used by window entries to invoke main-process IPC methods and read synced state.
    // parity: plugin/src/gui/core.ts#IpcClient [status=adapted hash=eaca1beffd24]
    public struct IpcClient: Sendable {
        public let id: String
        public let call: @Sendable (_ method: String, _ input: JSONValue?, _ options: IpcCallOptions?) async throws -> JSONValue
        public let state: @Sendable () -> JSONValue?
        public let on: @Sendable (_ event: String, _ listener: @escaping @Sendable (JSONValue) -> Void) -> Cleanup

        public init(
            id: String,
            call: @escaping @Sendable (_ method: String, _ input: JSONValue?, _ options: IpcCallOptions?) async throws -> JSONValue,
            state: @escaping @Sendable () -> JSONValue? = { nil },
            on: @escaping @Sendable (_ event: String, _ listener: @escaping @Sendable (JSONValue) -> Void) -> Cleanup = { _, _ in {} }
        ) {
            self.id = id
            self.call = call
            self.state = state
            self.on = on
        }
    }

    /// Value yielded by resolving a `Token` (either an `IpcClient` or a contract value).
    // parity: plugin/src/gui/core.ts#TokenValue [status=adapted hash=ac064ccdb5c6]
    public typealias TokenValue<V: Sendable> = V

    /// Live provider lifecycle state observed via `ctx.use(token)`.
    // parity: plugin/src/gui/core.ts#Live [status=implemented hash=86ab478c9d02]
    public enum Live<T: Sendable>: Sendable {
        public enum InactiveReason: String, Equatable, Hashable, Sendable, Codable {
            case disabled
            case failed
        }

        case pending
        case active(value: T, generation: Int)
        case inactive(reason: InactiveReason)
    }

    /// Identifies the window that initiated an IPC call into main.
    // parity: plugin/src/gui/core.ts#Caller [status=implemented hash=22ad7b2087a1]
    public struct Caller: Sendable {
        public let window: Int
        public let signal: AbortSignal

        public init(window: Int, signal: AbortSignal = AbortController().signal) {
            self.window = window
            self.signal = signal
        }
    }

    /// Main-process implementation of an IPC contract.
    // parity: plugin/src/gui/core.ts#IpcImpl [status=adapted hash=6bd8abb812f5]
    public struct IpcImpl: Sendable {
        public let methods: [String: @Sendable (JSONValue?, Caller) async throws -> JSONValue]
        public let state: (@Sendable (Int) -> JSONValue)?

        public init(
            methods: [String: @Sendable (JSONValue?, Caller) async throws -> JSONValue],
            state: (@Sendable (Int) -> JSONValue)? = nil
        ) {
            self.methods = methods
            self.state = state
        }
    }

    /// Handle returned by `mainContext.provide(ipc, impl)` to push state updates and emit events.
    // parity: plugin/src/gui/core.ts#IpcProvider [status=implemented hash=eaca85105790]
    public struct IpcProvider: Sendable {
        public let changed: @Sendable (_ window: Int?) -> Void
        public let emit: @Sendable (_ name: String, _ data: JSONValue, _ window: Int?) -> Void
        public let dispose: @Sendable () -> Void

        public init(
            changed: @escaping @Sendable (_ window: Int?) -> Void = { _ in },
            emit: @escaping @Sendable (_ name: String, _ data: JSONValue, _ window: Int?) -> Void = { _, _, _ in },
            dispose: @escaping @Sendable () -> Void = {}
        ) {
            self.changed = changed
            self.emit = emit
            self.dispose = dispose
        }
    }

    /// Shared context base exposed to both window and main GUI plugin setups.
    // parity: plugin/src/gui/core.ts#BaseContext [status=adapted hash=7fc9e60ccd82]
    public protocol BaseContext: Sendable {
        var options: PluginOptions { get }
        var id: String { get }
        var signal: AbortSignal { get }
        func t(_ key: String, params: Params?) -> String
        func plural(_ key: String, count: Int, params: Params?) -> String
    }

    /// Older stored key imported once when migrating persisted state.
    // parity: plugin/src/gui/core.ts#StoreFrom [status=implemented hash=432f70329a61]
    public typealias StoreFrom = String

    /// Declaration of a persisted global or per-session plugin store.
    // parity: plugin/src/gui/core.ts#StoreDeclaration [status=implemented hash=8dd3cfb28089]
    public struct StoreDeclaration: Equatable, Hashable, Sendable, Codable {
        public enum ScopeKind: String, Equatable, Hashable, Sendable, Codable {
            case global
            case session
        }

        public let scope: ScopeKind
        public let schema: ToolSchema.ValueSchema
        public let initial: JSONValue
        public let from: [StoreFrom]

        public init(
            scope: ScopeKind,
            schema: ToolSchema.ValueSchema = .jsonSchema([:]),
            initial: JSONValue,
            from: [StoreFrom] = []
        ) {
            self.scope = scope
            self.schema = schema
            self.initial = initial
            self.from = from
        }
    }

    /// Factory namespace matching upstream `Store.global(...)` and `Store.session(...)`.
    // parity: plugin/src/gui/core.ts#Store [status=implemented hash=d5a088765ee5]
    public enum Store {
        public static func global(
            schema: ToolSchema.ValueSchema = .jsonSchema([:]),
            initial: JSONValue,
            from: [StoreFrom] = []
        ) -> StoreDeclaration {
            StoreDeclaration(scope: .global, schema: schema, initial: initial, from: from)
        }

        public static func session(
            schema: ToolSchema.ValueSchema = .jsonSchema([:]),
            initial: JSONValue,
            from: [StoreFrom] = []
        ) -> StoreDeclaration {
            StoreDeclaration(scope: .session, schema: schema, initial: initial, from: from)
        }
    }

    /// Reactive persisted store handle used in both window and main processes.
    // parity: plugin/src/gui/core.ts#Persisted [status=implemented hash=656ff4d7e28f]
    public struct Persisted<T: Sendable>: Sendable {
        public let read: @Sendable () -> T?
        public let ready: @Sendable () -> Bool
        public let update: @Sendable (@Sendable (inout T) -> Void) -> Void
        public let set: @Sendable (T) -> Void

        public init(
            read: @escaping @Sendable () -> T?,
            ready: @escaping @Sendable () -> Bool = { true },
            update: @escaping @Sendable (@Sendable (inout T) -> Void) -> Void,
            set: @escaping @Sendable (T) -> Void
        ) {
            self.read = read
            self.ready = ready
            self.update = update
            self.set = set
        }
    }

    /// Writable draft alias for persisted store mutations.
    // parity: plugin/src/gui/core.ts#Mutable [status=adapted hash=e5ae3a96c866]
    public typealias Mutable<T> = T

    /// Map of declared stores by name.
    // parity: plugin/src/gui/core.ts#DeclaredStores [status=implemented hash=81b09e209540]
    public typealias DeclaredStores = [String: StoreDeclaration]

    /// Branded icon name `<plugin id>:<name>` declared in `Plugin.define({ icons })`.
    // parity: plugin/src/gui/core.ts#PluginIconName [status=implemented hash=0731259babef]
    public struct PluginIconName: RawRepresentable, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }
    }

    /// Map of declared icon SVG documents by local icon name.
    // parity: plugin/src/gui/core.ts#DeclaredIcons [status=implemented hash=a6c4fd73694b]
    public typealias DeclaredIcons = [String: String]

    // MARK: - gui/declarations.ts

    // parity: plugin/src/gui/declarations.ts#Stores [status=implemented hash=0302dd7e6bf4]
    public typealias Stores = [String: StoreDeclaration]

    // parity: plugin/src/gui/declarations.ts#Icons [status=implemented hash=c380310c3c5d]
    public typealias Icons = [String: String]

    /// Static declarations inspected by the host before running a GUI plugin's setups.
    // parity: plugin/src/gui/declarations.ts#Declarations [status=implemented hash=6d1bc4993e35]
    public struct Declarations: Equatable, Hashable, Sendable, Codable {
        public let os: [OS]?
        public let i18n: Catalog?
        public let stores: Stores?
        public let icons: Icons?

        public init(
            os: [OS]? = nil,
            i18n: Catalog? = nil,
            stores: Stores? = nil,
            icons: Icons? = nil
        ) {
            self.os = os
            self.i18n = i18n
            self.stores = stores
            self.icons = icons
        }
    }

    // MARK: - gui/icon-name.ts

    /// Complete catalog of built-in app icon names (`packages/plugin/src/gui/icon-name.ts`).
    // parity: plugin/src/gui/icon-name.ts#AppIconName [status=implemented hash=c7806394bc14]
    public enum AppIconName: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case alignRight = "align-right"
        case appearance = "appearance"
        case archive = "archive"
        case arrowDownToLine = "arrow-down-to-line"
        case arrowLeft = "arrow-left"
        case arrowRight = "arrow-right"
        case arrowUndoDown = "arrow-undo-down"
        case arrowUp = "arrow-up"
        case arrowUpRight = "arrow-up-right"
        case brain = "brain"
        case branch = "branch"
        case branchOut = "branch-out"
        case bubble5 = "bubble-5"
        case bulletList = "bullet-list"
        case check = "check"
        case checkSmall = "check-small"
        case checklist = "checklist"
        case chevronDoubleRight = "chevron-double-right"
        case chevronDown = "chevron-down"
        case chevronGrabberVertical = "chevron-grabber-vertical"
        case chevronLeft = "chevron-left"
        case chevronRight = "chevron-right"
        case circleBanSign = "circle-ban-sign"
        case circleCheck = "circle-check"
        case circleExclamation = "circle-exclamation"
        case circleX = "circle-x"
        case circleXmark = "circle-xmark"
        case close = "close"
        case closeSmall = "close-small"
        case cloudUpload = "cloud-upload"
        case code = "code"
        case codeLines = "code-lines"
        case codeSlash = "code-slash"
        case collapse = "collapse"
        case comment = "comment"
        case console = "console"
        case copy = "copy"
        case cube = "cube"
        case dash = "dash"
        case discord = "discord"
        case dotGrid = "dot-grid"
        case download = "download"
        case edit = "edit"
        case editSmall2 = "edit-small-2"
        case enter = "enter"
        case expand = "expand"
        case extensions = "extensions"
        case eye = "eye"
        case fileDocument = "file-document"
        case fileTree = "file-tree"
        case fileTreeActive = "file-tree-active"
        case filetree = "filetree"
        case fillTriangleDown = "fill-triangle-down"
        case flask = "flask"
        case folder = "folder"
        case folderAddLeft = "folder-add-left"
        case fork = "fork"
        case github = "github"
        case glasses = "glasses"
        case globe = "globe"
        case graduationCap = "graduation-cap"
        case gridPlus = "grid-plus"
        case help = "help"
        case info = "info"
        case keyboard = "keyboard"
        case layoutBottom = "layout-bottom"
        case layoutBottomFull = "layout-bottom-full"
        case layoutBottomPartial = "layout-bottom-partial"
        case layoutLeft = "layout-left"
        case layoutLeftFull = "layout-left-full"
        case layoutLeftPartial = "layout-left-partial"
        case layoutRight = "layout-right"
        case layoutRightFull = "layout-right-full"
        case layoutRightPartial = "layout-right-partial"
        case link = "link"
        case lock = "lock"
        case magnifyingGlass = "magnifying-glass"
        case magnifyingGlassMenu = "magnifying-glass-menu"
        case mcp = "mcp"
        case menu = "menu"
        case minus = "minus"
        case models = "models"
        case monitor = "monitor"
        case newSession = "new-session"
        case newSessionActive = "new-session-active"
        case notifications = "notifications"
        case openFile = "open-file"
        case outlineArrowLeft = "outline-arrow-left"
        case outlineArrowRight = "outline-arrow-right"
        case outlineArrowToCornerTopRight = "outline-arrow-to-corner-top-right"
        case outlineArrowUpRight = "outline-arrow-up-right"
        case outlineAudio = "outline-audio"
        case outlineBrain = "outline-brain"
        case outlineBrowserAnnotate = "outline-browser-annotate"
        case outlineChevronDown = "outline-chevron-down"
        case outlineChevronRight = "outline-chevron-right"
        case outlineCodeBrackets = "outline-code-brackets"
        case outlineConsole = "outline-console"
        case outlineCookie = "outline-cookie"
        case outlineCopy = "outline-copy"
        case outlineDots = "outline-dots"
        case outlineExpand = "outline-expand"
        case outlineEye = "outline-eye"
        case outlineEyeSlash = "outline-eye-slash"
        case outlineGlobe = "outline-globe"
        case outlineGlobePlus = "outline-globe-plus"
        case outlineHexagonalWarning = "outline-hexagonal-warning"
        case outlineListChangelog = "outline-list-changelog"
        case outlineMagnifierMinus = "outline-magnifier-minus"
        case outlineMagnifierPlus = "outline-magnifier-plus"
        case outlineMaximize = "outline-maximize"
        case outlinePhoto = "outline-photo"
        case outlineQuote = "outline-quote"
        case outlineReset = "outline-reset"
        case outlineRotateClockwise = "outline-rotate-clockwise"
        case outlineShare = "outline-share"
        case outlineSliders = "outline-sliders"
        case outlineSquareArrow = "outline-square-arrow"
        case outlineText = "outline-text"
        case outlineTrash = "outline-trash"
        case outlineUndo = "outline-undo"
        case outlineVideo = "outline-video"
        case outlineWaveAudio = "outline-wave-audio"
        case outlineWorktree = "outline-worktree"
        case outlineXmark = "outline-xmark"
        case pencilLine = "pencil-line"
        case photo = "photo"
        case plus = "plus"
        case plusSmall = "plus-small"
        case postSkill = "post-skill"
        case prompt = "prompt"
        case providers = "providers"
        case refresh = "refresh"
        case reset = "reset"
        case review = "review"
        case reviewActive = "review-active"
        case selectElement = "select-element"
        case selector = "selector"
        case server = "server"
        case sessionsStack = "sessions-stack"
        case settingsGear = "settings-gear"
        case share = "share"
        case shield = "shield"
        case sidebar = "sidebar"
        case sidebarActive = "sidebar-active"
        case sliders = "sliders"
        case speechBubble = "speech-bubble"
        case split = "split"
        case squareArrowTopRight = "square-arrow-top-right"
        case status = "status"
        case statusActive = "status-active"
        case stop = "stop"
        case task = "task"
        case terminal = "terminal"
        case terminalActive = "terminal-active"
        case textWrap = "text-wrap"
        case trash = "trash"
        case unified = "unified"
        case warning = "warning"
        case waveform = "waveform"
        case windowAnalytics = "window-analytics"
        case windowCursor = "window-cursor"
        case workspace = "workspace"
        case workspaceIsolated = "workspace-isolated"
        case workspaceNew = "workspace-new"
        case xmarkSmall = "xmark-small"
    }

    // MARK: - gui/modules.ts

    /// Modules provided by both main and window hosts to plugin GUI bundles.
    // parity: plugin/src/gui/modules.ts#pluginSharedModules [status=implemented hash=95cd0a566645]
    public static let pluginSharedModules: [String] = [
        "effect",
        "@opencode/plugin/gui",
        "@opencode/plugin/gui/main",
        "@opencode/plugin/rpc",
        "@opencode/schema/rpc",
        "@opencode/client",
        "@opencode/client/effect",
    ]

    /// Modules provided exclusively by desktop/web window hosts.
    // parity: plugin/src/gui/modules.ts#pluginWindowModules [status=implemented hash=6bc41a557453]
    public static let pluginWindowModules: [String] = [
        "solid-js",
        "solid-js/web",
        "solid-js/store",
        "@opencode/plugin/gui/file",
        "@opencode/plugin/gui/review",
        "@opencode/plugin/gui/browser",
        "@opencode/client/solid",
    ]

    /// Any module name in `pluginSharedModules` or `pluginWindowModules`.
    // parity: plugin/src/gui/modules.ts#PluginModule [status=implemented hash=b9830253939a]
    public typealias PluginModule = String

    // MARK: - gui/scope.ts

    /// Structured teardown scope matching upstream `gui/scope.ts`: aborts `signal`, runs finalizers in reverse order
    /// with error isolation and deadline enforcement, and supports nested child scopes via `fork`.
    // parity: plugin/src/gui/scope.ts#Scope [status=implemented hash=b4a7ed0b4e00]
    public final class Scope: Sendable {
        public struct Options: Sendable {
            public let timeoutMs: Int
            public let log: @Sendable (_ message: String, _ data: [String: JSONValue]) -> Void

            public init(
                timeoutMs: Int = 3_000,
                log: @escaping @Sendable (_ message: String, _ data: [String: JSONValue]) -> Void = { _, _ in }
            ) {
                self.timeoutMs = timeoutMs
                self.log = log
            }
        }

        private struct FinalizerEntry: Sendable {
            let id: UInt64
            let label: String?
            let run: Cleanup
        }

        private struct State: Sendable {
            var nextID: UInt64 = 1
            var closed: Bool = false
            var finalizers: [FinalizerEntry] = []
        }

        public let name: String
        private let options: Options
        private let controller = AbortController()
        private let detach: (@Sendable () -> Void)?
        private let state = Mutex(State())

        public var signal: AbortSignal { controller.signal }

        private init(name: String, options: Options, detach: (@Sendable () -> Void)? = nil) {
            self.name = name
            self.options = options
            self.detach = detach
        }

        public static func make(_ name: String, options: Options = Options()) -> Scope {
            Scope(name: name, options: options)
        }

        /// Registers `fn` to run when this scope closes (or immediately if already closed).
        /// Returns an early-teardown handle that runs `fn` once and removes it from the scope.
        @discardableResult
        public func addFinalizer(label: String? = "anonymous", _ fn: @escaping Cleanup) -> Cleanup {
            let entry: FinalizerEntry? = state.withLock { s in
                if s.closed { return nil }
                let id = s.nextID
                s.nextID &+= 1
                let item = FinalizerEntry(id: id, label: label, run: fn)
                s.finalizers.append(item)
                return item
            }
            guard let entry else {
                Task { await fn() }
                return {}
            }
            let entryID = entry.id
            return { [self] in
                let removed: FinalizerEntry? = self.state.withLock { s in
                    guard let idx = s.finalizers.firstIndex(where: { $0.id == entryID }) else { return nil }
                    return s.finalizers.remove(at: idx)
                }
                if let removed {
                    await removed.run()
                }
            }
        }

        /// Forks a child scope that automatically closes in reverse order when this parent closes.
        public func fork(_ child: String) -> Scope {
            let tokenBox = Mutex<UInt64?>(nil)
            let forked = Scope(name: "\(name)/\(child)", options: options) { [self] in
                if let id = tokenBox.withLock({ $0 }) {
                    self.state.withLock { s in
                        s.finalizers.removeAll { $0.id == id }
                    }
                }
            }
            let alreadyClosed: Bool = state.withLock { s in
                if s.closed { return true }
                let id = s.nextID
                s.nextID &+= 1
                tokenBox.withLock { $0 = id }
                s.finalizers.append(FinalizerEntry(id: id, label: nil, run: { await forked.close() }))
                return false
            }
            if alreadyClosed {
                Task { await forked.close() }
            }
            return forked
        }

        /// Aborts `signal` immediately and executes registered finalizers in LIFO order under the configured deadline.
        public func close() async {
            let ordered: [FinalizerEntry] = state.withLock { s in
                if s.closed { return [] }
                s.closed = true
                let list = Array(s.finalizers.reversed())
                s.finalizers.removeAll()
                return list
            }
            detach?()
            controller.abort()
            let timeoutNs = UInt64(max(1, options.timeoutMs)) * 1_000_000
            for entry in ordered {
                let completed = await runWithDeadline(timeoutNs: timeoutNs, operation: entry.run)
                if !completed, let label = entry.label {
                    options.log("scope finalizer timed out", [
                        "scope": .string(name),
                        "finalizer": .string(label),
                    ])
                }
            }
        }

        private func runWithDeadline(timeoutNs: UInt64, operation: @escaping Cleanup) async -> Bool {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await operation()
                    return true
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: timeoutNs)
                    return false
                }
                let first = await group.next() ?? true
                group.cancelAll()
                return first
            }
        }
    }

    // MARK: - gui/host-apis.ts (40 manifest symbols)

    /// Live reference to an OpenCode server listed by the GUI host.
    // parity: plugin/src/gui/host-apis.ts#ServerRef [status=implemented hash=74ff0bed9f6a]
    public struct ServerRef: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let name: String
        public let url: String
        public let password: String?
        public let local: Bool
        public let builtin: Bool
        public let compatible: Bool
        public let connected: Bool

        public init(
            id: String,
            name: String,
            url: String,
            password: String? = nil,
            local: Bool = true,
            builtin: Bool = false,
            compatible: Bool = true,
            connected: Bool = true
        ) {
            self.id = id
            self.name = name
            self.url = url
            self.password = password
            self.local = local
            self.builtin = builtin
            self.compatible = compatible
            self.connected = connected
        }
    }

    /// Reference to a session owned by an open shell tab.
    // parity: plugin/src/gui/host-apis.ts#SessionRef [status=implemented hash=34e042e4d8cf]
    public struct SessionRef: Equatable, Hashable, Sendable, Codable {
        public let key: String
        public let id: String
        public let tab: String
        public let server: ServerRef
        public let pending: Bool
        public let location: LocationSchema.Ref?

        public init(
            key: String,
            id: String,
            tab: String,
            server: ServerRef,
            pending: Bool = false,
            location: LocationSchema.Ref? = nil
        ) {
            self.key = key
            self.id = id
            self.tab = tab
            self.server = server
            self.pending = pending
            self.location = location
        }
    }

    /// Project entry as shown in the GUI sidebar.
    // parity: plugin/src/gui/host-apis.ts#Project [status=implemented hash=ec5651ff790b]
    public struct Project: Equatable, Hashable, Sendable, Codable {
        public let id: ProjectID
        public let name: String?
        public let worktree: String
        public let worktrees: [WorktreeSchema.Directory]
        public let icon: ProjectSchema.Icon?

        public init(
            id: ProjectID,
            name: String? = nil,
            worktree: String,
            worktrees: [WorktreeSchema.Directory] = [],
            icon: ProjectSchema.Icon? = nil
        ) {
            self.id = id
            self.name = name
            self.worktree = worktree
            self.worktrees = worktrees
            self.icon = icon
        }
    }

    /// File content loaded by the GUI file model.
    // parity: plugin/src/gui/host-apis.ts#FileContent [status=implemented hash=07242d584cdf]
    public struct FileContent: Equatable, Hashable, Sendable, Codable {
        public enum ContentType: String, Equatable, Hashable, Sendable, Codable {
            case text
            case binary
        }

        public let type: ContentType
        public let content: String
        public let bytes: [UInt8]?
        public let diff: String?
        public let encoding: String?
        public let mimeType: String?
        public let size: Int?
        public let url: String?

        public init(
            type: ContentType,
            content: String,
            bytes: [UInt8]? = nil,
            diff: String? = nil,
            encoding: String? = nil,
            mimeType: String? = nil,
            size: Int? = nil,
            url: String? = nil
        ) {
            self.type = type
            self.content = content
            self.bytes = bytes
            self.diff = diff
            self.encoding = encoding
            self.mimeType = mimeType
            self.size = size
            self.url = url
        }
    }

    /// Line selection range in a file or diff.
    // parity: plugin/src/gui/host-apis.ts#LineRange [status=implemented hash=19a4c9d3ba4c]
    public struct LineRange: Equatable, Hashable, Sendable, Codable {
        public enum DiffSide: String, Equatable, Hashable, Sendable, Codable {
            case additions
            case deletions
        }

        public let start: Int
        public let end: Int
        public let side: DiffSide?
        public let endSide: DiffSide?

        public init(start: Int, end: Int, side: DiffSide? = nil, endSide: DiffSide? = nil) {
            self.start = start
            self.end = end
            self.side = side
            self.endSide = endSide
        }
    }

    /// Loaded state of one workspace file in the GUI.
    // parity: plugin/src/gui/host-apis.ts#FileState [status=implemented hash=2d5b6cf1035d]
    public struct FileState: Equatable, Hashable, Sendable, Codable {
        public let path: String
        public let name: String
        public let loaded: Bool?
        public let loading: Bool?
        public let notFound: Bool?
        public let error: String?
        public let content: FileContent?

        public init(
            path: String,
            name: String,
            loaded: Bool? = nil,
            loading: Bool? = nil,
            notFound: Bool? = nil,
            error: String? = nil,
            content: FileContent? = nil
        ) {
            self.path = path
            self.name = name
            self.loaded = loaded
            self.loading = loading
            self.notFound = notFound
            self.error = error
            self.content = content
        }
    }

    /// Workspace file tree entry.
    // parity: plugin/src/gui/host-apis.ts#FileNode [status=implemented hash=61814a5d456b]
    public struct FileNode: Equatable, Hashable, Sendable, Codable {
        public enum NodeType: String, Equatable, Hashable, Sendable, Codable {
            case file
            case directory
        }

        public let name: String
        public let path: String
        public let absolute: String
        public let type: NodeType
        public let ignored: Bool

        public init(name: String, path: String, absolute: String, type: NodeType, ignored: Bool = false) {
            self.name = name
            self.path = path
            self.absolute = absolute
            self.type = type
            self.ignored = ignored
        }
    }

    /// Session screen workspace file model API.
    // parity: plugin/src/gui/host-apis.ts#Files [status=adapted hash=85dfac63aa8e]
    public struct Files: Sendable {
        public let root: String
        public let ready: @Sendable () -> Bool
        public let resolve: @Sendable (String) -> String
        public let isAbsolute: @Sendable (String) -> Bool
        public let get: @Sendable (String) -> FileState?
        public let missing: @Sendable (String) -> Bool
        public let sync: @Sendable (String, Bool, Bool) async -> Void
        public let unwatch: @Sendable (String) -> Void
        public let exists: @Sendable (String) async -> Bool
        public let search: @Sendable (String, Int?) async -> [String]

        public init(
            root: String = "/",
            ready: @escaping @Sendable () -> Bool = { true },
            resolve: @escaping @Sendable (String) -> String = { $0 },
            isAbsolute: @escaping @Sendable (String) -> Bool = { $0.hasPrefix("/") },
            get: @escaping @Sendable (String) -> FileState? = { _ in nil },
            missing: @escaping @Sendable (String) -> Bool = { _ in false },
            sync: @escaping @Sendable (String, Bool, Bool) async -> Void = { _, _, _ in },
            unwatch: @escaping @Sendable (String) -> Void = { _ in },
            exists: @escaping @Sendable (String) async -> Bool = { _ in false },
            search: @escaping @Sendable (String, Int?) async -> [String] = { _, _ in [] }
        ) {
            self.root = root
            self.ready = ready
            self.resolve = resolve
            self.isAbsolute = isAbsolute
            self.get = get
            self.missing = missing
            self.sync = sync
            self.unwatch = unwatch
            self.exists = exists
            self.search = search
        }
    }

    /// Line comment left on a workspace file before sending.
    // parity: plugin/src/gui/host-apis.ts#Comment [status=implemented hash=cb2831904699]
    public struct Comment: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let time: Int64
        public let file: String
        public let selection: LineRange
        public let comment: String

        public init(id: String, time: Int64, file: String, selection: LineRange, comment: String) {
            self.id = id
            self.time = time
            self.file = file
            self.selection = selection
            self.comment = comment
        }
    }

    /// Session screen line-comment controller.
    // parity: plugin/src/gui/host-apis.ts#Comments [status=adapted hash=e489e8ab991a]
    public struct Comments: Sendable {
        public let list: @Sendable (String?) -> [Comment]
        public let add: @Sendable (_ file: String, _ selection: LineRange, _ comment: String) -> Comment
        public let update: @Sendable (String, String) -> Void
        public let remove: @Sendable (String) -> Void

        public init(
            list: @escaping @Sendable (String?) -> [Comment] = { _ in [] },
            add: @escaping @Sendable (_ file: String, _ selection: LineRange, _ comment: String) -> Comment = { file, sel, text in
                Comment(id: UUID().uuidString, time: 0, file: file, selection: sel, comment: text)
            },
            update: @escaping @Sendable (String, String) -> Void = { _, _ in },
            remove: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            self.list = list
            self.add = add
            self.update = update
            self.remove = remove
        }
    }

    /// File attachment in the session composer.
    // parity: plugin/src/gui/host-apis.ts#ComposerFile [status=implemented hash=e103b84602b4]
    public struct ComposerFile: Equatable, Hashable, Sendable, Codable {
        public let path: String
        public let preview: String?
        public let comment: String?
        public let commentID: String?
        public let commentOrigin: String?

        public init(
            path: String,
            preview: String? = nil,
            comment: String? = nil,
            commentID: String? = nil,
            commentOrigin: String? = nil
        ) {
            self.path = path
            self.preview = preview
            self.comment = comment
            self.commentID = commentID
            self.commentOrigin = commentOrigin
        }
    }

    /// Note attachment in the session composer.
    // parity: plugin/src/gui/host-apis.ts#ComposerNote [status=implemented hash=87ad304f83bd]
    public struct ComposerNote: Equatable, Hashable, Sendable, Codable {
        public let origin: String
        public let commentID: String
        public let label: String
        public let title: String?
        public let subtitle: String?
        public let icon: IconName
        public let subject: String
        public let comment: String
        public let href: String?

        public init(
            origin: String,
            commentID: String,
            label: String,
            title: String? = nil,
            subtitle: String? = nil,
            icon: IconName,
            subject: String,
            comment: String = "",
            href: String? = nil
        ) {
            self.origin = origin
            self.commentID = commentID
            self.label = label
            self.title = title
            self.subtitle = subtitle
            self.icon = icon
            self.subject = subject
            self.comment = comment
            self.href = href
        }
    }

    /// Quoted text attachment in the session composer.
    // parity: plugin/src/gui/host-apis.ts#ComposerQuote [status=implemented hash=ec4c6305a15e]
    public struct ComposerQuote: Equatable, Hashable, Sendable, Codable {
        public struct Source: Equatable, Hashable, Sendable, Codable {
            public let label: String
            public let icon: IconName
            public let subject: String

            public init(label: String, icon: IconName, subject: String) {
                self.label = label
                self.icon = icon
                self.subject = subject
            }
        }

        public let commentID: String
        public let text: String
        public let comment: String?
        public let source: Source

        public init(commentID: String, text: String, comment: String? = nil, source: Source) {
            self.commentID = commentID
            self.text = text
            self.comment = comment
            self.source = source
        }
    }

    /// Anchor computation positioning a quote comment editor in viewport pixels.
    // parity: plugin/src/gui/host-apis.ts#ComposerQuoteAnchor [status=implemented hash=e5b74cf7785c]
    public typealias ComposerQuoteAnchor = @Sendable (_ width: Double, _ height: Double) -> (top: Double, left: Double)?

    /// Optional focus placement for an attached composer quote.
    // parity: plugin/src/gui/host-apis.ts#ComposerFocusOptions [status=implemented hash=d99af7bcdc6b]
    public struct ComposerFocusOptions: Sendable {
        public let anchor: ComposerQuoteAnchor?

        public init(anchor: ComposerQuoteAnchor? = nil) {
            self.anchor = anchor
        }
    }

    /// Model selection in the GUI composer.
    // parity: plugin/src/gui/host-apis.ts#ComposerModel [status=implemented hash=d744997e9c7f]
    public struct ComposerModel: Equatable, Hashable, Sendable, Codable {
        public let providerID: String
        public let modelID: String
        public let variant: String?

        public init(providerID: String, modelID: String, variant: String? = nil) {
            self.providerID = providerID
            self.modelID = modelID
            self.variant = variant
        }
    }

    /// Session screen prompt composer controller.
    // parity: plugin/src/gui/host-apis.ts#Composer [status=adapted hash=b6ec04586a4c]
    public struct Composer: Sendable {
        public enum Attachment: Equatable, Hashable, Sendable, Codable {
            case file(ComposerFile)
            case note(ComposerNote)
            case quote(ComposerQuote)
        }

        public let text: @Sendable () -> String
        public let insert: @Sendable (String) -> Void
        public let setText: @Sendable (String) -> Void
        public let model: @Sendable () -> ComposerModel?
        public let setModel: @Sendable (ComposerModel) -> Bool
        public let setVariant: @Sendable (String?) -> Bool
        public let attach: @Sendable (Attachment) -> Void
        public let quotable: @Sendable () -> Bool
        public let focus: @Sendable (String?, ComposerFocusOptions?) -> Void
        public let detach: @Sendable (String) -> Void
        public let focused: @Sendable () -> Bool

        public init(
            text: @escaping @Sendable () -> String = { "" },
            insert: @escaping @Sendable (String) -> Void = { _ in },
            setText: @escaping @Sendable (String) -> Void = { _ in },
            model: @escaping @Sendable () -> ComposerModel? = { nil },
            setModel: @escaping @Sendable (ComposerModel) -> Bool = { _ in false },
            setVariant: @escaping @Sendable (String?) -> Bool = { _ in false },
            attach: @escaping @Sendable (Attachment) -> Void = { _ in },
            quotable: @escaping @Sendable () -> Bool = { true },
            focus: @escaping @Sendable (String?, ComposerFocusOptions?) -> Void = { _, _ in },
            detach: @escaping @Sendable (String) -> Void = { _ in },
            focused: @escaping @Sendable () -> Bool = { false }
        ) {
            self.text = text
            self.insert = insert
            self.setText = setText
            self.model = model
            self.setModel = setModel
            self.setVariant = setVariant
            self.attach = attach
            self.quotable = quotable
            self.focus = focus
            self.detach = detach
            self.focused = focused
        }
    }

    /// Active background shell or subagent task displayed in a session.
    // parity: plugin/src/gui/host-apis.ts#BackgroundTask [status=implemented hash=25d6c51be94a]
    public struct BackgroundTask: Equatable, Hashable, Sendable, Codable {
        public enum TaskType: String, Equatable, Hashable, Sendable, Codable {
            case shell
            case subagent
        }

        public let id: String
        public let type: TaskType
        public let label: String
        public let agent: String?

        public init(id: String, type: TaskType, label: String, agent: String? = nil) {
            self.id = id
            self.type = type
            self.label = label
            self.agent = agent
        }
    }

    /// Routed session mounted on the session screen.
    // parity: plugin/src/gui/host-apis.ts#MountedSession [status=implemented hash=7cbb7d9bd0f4]
    public struct MountedSession: Equatable, Hashable, Sendable, Codable {
        public let session: SessionRef
        public let visitID: String
        public let project: Project?
        public let directory: String
        public let local: Bool
        public let background: [BackgroundTask]

        public init(
            session: SessionRef,
            visitID: String = UUID().uuidString,
            project: Project? = nil,
            directory: String,
            local: Bool = true,
            background: [BackgroundTask] = []
        ) {
            self.session = session
            self.visitID = visitID
            self.project = project
            self.directory = directory
            self.local = local
            self.background = background
        }
    }

    /// Route-following session screen owning workspace files, comments, and composer.
    // parity: plugin/src/gui/host-apis.ts#SessionScreen [status=implemented hash=5a2145a0becd]
    public struct SessionScreen: Sendable {
        public let file: Files
        public let comment: Comments
        public let composer: Composer

        public init(file: Files = Files(), comment: Comments = Comments(), composer: Composer = Composer()) {
            self.file = file
            self.comment = comment
            self.composer = composer
        }
    }

    /// Accessor for the currently mounted session screen.
    // parity: plugin/src/gui/host-apis.ts#Screen [status=implemented hash=9cafd3c24665]
    public struct Screen: Sendable {
        public let current: @Sendable () -> SessionScreen?

        public init(current: @escaping @Sendable () -> SessionScreen? = { nil }) {
            self.current = current
        }
    }

    /// Open shell-tab sessions accessor.
    // parity: plugin/src/gui/host-apis.ts#Sessions [status=implemented hash=558212a9de7e]
    public struct Sessions: Sendable {
        public let list: @Sendable () -> [SessionRef]
        public let current: @Sendable () -> MountedSession?

        public init(
            list: @escaping @Sendable () -> [SessionRef] = { [] },
            current: @escaping @Sendable () -> MountedSession? = { nil }
        ) {
            self.list = list
            self.current = current
        }
    }

    /// Visibility state of a panel key in a session strip.
    // parity: plugin/src/gui/host-apis.ts#PanelState [status=implemented hash=f67e47e549f2]
    public enum PanelState: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case closed
        case open
        case active
        case visible
    }

    /// Tab placement options passed to `Layout.open`.
    // parity: plugin/src/gui/host-apis.ts#OpenOptions [status=implemented hash=f303a66d4d56]
    public struct OpenOptions: Equatable, Hashable, Sendable, Codable {
        public enum TabMode: String, Equatable, Hashable, Sendable, Codable {
            case open
            case preview
            case append
            case select
        }

        public let tab: TabMode?
        public let background: Bool?

        public init(tab: TabMode? = nil, background: Bool? = nil) {
            self.tab = tab
            self.background = background
        }
    }

    /// Session layout controller managing side panel tabs, scroll offsets, settings, and drafts.
    // parity: plugin/src/gui/host-apis.ts#Layout [status=adapted hash=3497c0fa0e9c]
    public struct Layout: Sendable {
        public let narrow: @Sendable () -> Bool
        public let ready: @Sendable () -> Bool
        public let open: @Sendable (String, SessionRef, OpenOptions?) -> Void
        public let close: @Sendable (String, SessionRef) -> Void
        public let toggle: @Sendable (String, SessionRef) -> Void
        public let hide: @Sendable (String, SessionRef) -> Void
        public let state: @Sendable (String, SessionRef) -> PanelState
        public let stored: @Sendable (SessionRef) -> [String]
        public let settings: @Sendable (String?) -> Void

        public init(
            narrow: @escaping @Sendable () -> Bool = { false },
            ready: @escaping @Sendable () -> Bool = { true },
            open: @escaping @Sendable (String, SessionRef, OpenOptions?) -> Void = { _, _, _ in },
            close: @escaping @Sendable (String, SessionRef) -> Void = { _, _ in },
            toggle: @escaping @Sendable (String, SessionRef) -> Void = { _, _ in },
            hide: @escaping @Sendable (String, SessionRef) -> Void = { _, _ in },
            state: @escaping @Sendable (String, SessionRef) -> PanelState = { _, _ in .closed },
            stored: @escaping @Sendable (SessionRef) -> [String] = { _ in [] },
            settings: @escaping @Sendable (String?) -> Void = { _ in }
        ) {
            self.narrow = narrow
            self.ready = ready
            self.open = open
            self.close = close
            self.toggle = toggle
            self.hide = hide
            self.state = state
            self.stored = stored
            self.settings = settings
        }
    }

    /// Storage isolation scope for `Storage.store`.
    // parity: plugin/src/gui/host-apis.ts#StorageScope [status=implemented hash=1c2a6920eb40]
    public enum StorageScope: Equatable, Hashable, Sendable, Codable {
        case global
        case server(id: String, directory: String? = nil)
        case session(SessionRef)
    }

    /// Configuration options passed to `Storage.store`.
    // parity: plugin/src/gui/host-apis.ts#StoreOptions [status=implemented hash=7201cb5c5239]
    public struct StoreOptions: Equatable, Hashable, Sendable, Codable {
        public let schema: ToolSchema.ValueSchema
        public let initial: JSONValue
        public let scope: StorageScope?
        public let from: [StoreFrom]

        public init(
            schema: ToolSchema.ValueSchema = .jsonSchema([:]),
            initial: JSONValue,
            scope: StorageScope? = nil,
            from: [StoreFrom] = []
        ) {
            self.schema = schema
            self.initial = initial
            self.scope = scope
            self.from = from
        }
    }

    /// Window-scoped persistent and in-memory storage API (`plugin.<id>.<key>`).
    // parity: plugin/src/gui/host-apis.ts#Storage [status=adapted hash=be49567e85a1]
    public struct Storage: Sendable {
        public let store: @Sendable (String, StoreOptions) -> Persisted<JSONValue>
        public let remove: @Sendable (String, StorageScope?) -> Void

        public init(
            store: @escaping @Sendable (String, StoreOptions) -> Persisted<JSONValue>,
            remove: @escaping @Sendable (String, StorageScope?) -> Void
        ) {
            self.store = store
            self.remove = remove
        }
    }

    /// Cross-platform clipboard, file save, and external URL opening services.
    // parity: plugin/src/gui/host-apis.ts#System [status=implemented hash=3bde05ec8a8a]
    public struct System: Sendable {
        public let copy: @Sendable (String) async throws -> Void
        public let save: @Sendable (_ name: String, _ content: String) async throws -> Bool
        public let openExternal: @Sendable (String) -> Void

        public init(
            copy: @escaping @Sendable (String) async throws -> Void = { _ in },
            save: @escaping @Sendable (_ name: String, _ content: String) async throws -> Bool = { _, _ in true },
            openExternal: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            self.copy = copy
            self.save = save
            self.openExternal = openExternal
        }
    }

    /// Native file/folder picker options for `Desktop.pick`.
    // parity: plugin/src/gui/host-apis.ts#PickOptions [status=implemented hash=e36880421286]
    public struct PickOptions: Equatable, Hashable, Sendable, Codable {
        public let directory: Bool?
        public let multiple: Bool?
        public let title: String?
        public let extensions: [String]?

        public init(
            directory: Bool? = nil,
            multiple: Bool? = nil,
            title: String? = nil,
            extensions: [String]? = nil
        ) {
            self.directory = directory
            self.multiple = multiple
            self.title = title
            self.extensions = extensions
        }
    }

    /// Desktop-only OS integration capabilities.
    // parity: plugin/src/gui/host-apis.ts#Desktop [status=implemented hash=ae348d7f56c4]
    public struct Desktop: Sendable {
        public let os: OS
        public let zoom: @Sendable () -> Double
        public let launch: @Sendable (String, String?) async throws -> Void
        public let reveal: @Sendable (String) async -> Bool
        public let installed: @Sendable (String) async -> Bool
        public let pick: @Sendable (PickOptions?) async throws -> [String]

        public init(
            os: OS = .macos,
            zoom: @escaping @Sendable () -> Double = { 1.0 },
            launch: @escaping @Sendable (String, String?) async throws -> Void = { _, _ in },
            reveal: @escaping @Sendable (String) async -> Bool = { _ in false },
            installed: @escaping @Sendable (String) async -> Bool = { _ in false },
            pick: @escaping @Sendable (PickOptions?) async throws -> [String] = { _ in [] }
        ) {
            self.os = os
            self.zoom = zoom
            self.launch = launch
            self.reveal = reveal
            self.installed = installed
            self.pick = pick
        }
    }

    /// Active BCP 47 locale and writing direction.
    // parity: plugin/src/gui/host-apis.ts#Locale [status=implemented hash=57cd4fbfdd60]
    public struct Locale: Sendable {
        public enum Direction: String, Equatable, Hashable, Sendable, Codable {
            case ltr
            case rtl
        }

        public let locale: @Sendable () -> String
        public let direction: @Sendable () -> Direction

        public init(
            locale: @escaping @Sendable () -> String = { "en-US" },
            direction: @escaping @Sendable () -> Direction = { .ltr }
        ) {
            self.locale = locale
            self.direction = direction
        }
    }

    /// User appearance settings (mono font family and resolved color scheme).
    // parity: plugin/src/gui/host-apis.ts#Appearance [status=implemented hash=265da56e9aab]
    public struct Appearance: Sendable {
        public enum Mode: String, Equatable, Hashable, Sendable, Codable {
            case light
            case dark
        }

        public let font: @Sendable (String) -> String
        public let mode: @Sendable () -> Mode

        public init(
            font: @escaping @Sendable (String) -> String = { _ in "monospace" },
            mode: @escaping @Sendable () -> Mode = { .dark }
        ) {
            self.font = font
            self.mode = mode
        }
    }

    /// Current GUI router path and transition status.
    // parity: plugin/src/gui/host-apis.ts#Router [status=implemented hash=7368f5b6227e]
    public struct Router: Sendable {
        public let routing: @Sendable () -> Bool
        public let path: @Sendable () -> String

        public init(
            routing: @escaping @Sendable () -> Bool = { false },
            path: @escaping @Sendable () -> String = { "/" }
        ) {
            self.routing = routing
            self.path = path
        }
    }

    /// Effective command keybind inspection service.
    // parity: plugin/src/gui/host-apis.ts#Keybinds [status=implemented hash=e399133d3bd9]
    public struct Keybinds: Sendable {
        public let keybind: @Sendable (String) -> [String]
        public let keys: @Sendable (String) -> [String]
        public let matches: @Sendable (String, String) -> Bool

        public init(
            keybind: @escaping @Sendable (String) -> [String] = { _ in [] },
            keys: @escaping @Sendable (String) -> [String] = { $0.split(separator: "+").map(String.init) },
            matches: @escaping @Sendable (String, String) -> Bool = { _, _ in false }
        ) {
            self.keybind = keybind
            self.keys = keys
            self.matches = matches
        }
    }

    /// Listed OpenCode servers accessor.
    // parity: plugin/src/gui/host-apis.ts#Servers [status=implemented hash=8c71ba11d1b4]
    public struct Servers: Sendable {
        public let list: @Sendable () -> [String]
        public let get: @Sendable (String) -> ServerRef?

        public init(
            list: @escaping @Sendable () -> [String] = { [] },
            get: @escaping @Sendable (String) -> ServerRef? = { _ in nil }
        ) {
            self.list = list
            self.get = get
        }
    }

    /// Workspace lifecycle event subscription service.
    // parity: plugin/src/gui/host-apis.ts#Workspaces [status=implemented hash=b5fc77978bd0]
    public struct Workspaces: Sendable {
        public let onRemove: @Sendable (@escaping @Sendable (_ server: String, _ directory: String) -> Void) -> Cleanup

        public init(
            onRemove: @escaping @Sendable (@escaping @Sendable (_ server: String, _ directory: String) -> Void) -> Cleanup = { _ in {} }
        ) {
            self.onRemove = onRemove
        }
    }

    /// Local link routing service backed by `LinkHandler` contributions.
    // parity: plugin/src/gui/host-apis.ts#Links [status=implemented hash=5fe1de6ecf06]
    public struct Links: Sendable {
        public let open: @Sendable (Link) -> Bool
        public let exists: @Sendable (Link) async -> Bool

        public init(
            open: @escaping @Sendable (Link) -> Bool = { _ in false },
            exists: @escaping @Sendable (Link) async -> Bool = { _ in false }
        ) {
            self.open = open
            self.exists = exists
        }
    }

    /// Handle closing a single opened GUI dialog.
    // parity: plugin/src/gui/host-apis.ts#DialogHandle [status=implemented hash=82b86865816a]
    public struct DialogHandle: Sendable {
        public let close: @Sendable () -> Void

        public init(close: @escaping @Sendable () -> Void = {}) {
            self.close = close
        }
    }

    /// GUI modal dialogs controller.
    // parity: plugin/src/gui/host-apis.ts#Dialogs [status=adapted hash=0d0bd4100153]
    public struct Dialogs: Sendable {
        public let open: @Sendable (_ render: @escaping @Sendable (DialogHandle) -> ViewNode, _ replace: Bool) -> DialogHandle
        public let active: @Sendable () -> Bool
        public let confirm: @Sendable (_ title: String, _ description: String?) async -> Bool
        public let alert: @Sendable (_ title: String, _ description: String?) async -> Void
        public let prompt: @Sendable (_ title: String, _ placeholder: String?) async -> String?

        public init(
            open: @escaping @Sendable (_ render: @escaping @Sendable (DialogHandle) -> ViewNode, _ replace: Bool) -> DialogHandle = { _, _ in DialogHandle() },
            active: @escaping @Sendable () -> Bool = { false },
            confirm: @escaping @Sendable (_ title: String, _ description: String?) async -> Bool = { _, _ in false },
            alert: @escaping @Sendable (_ title: String, _ description: String?) async -> Void = { _, _ in },
            prompt: @escaping @Sendable (_ title: String, _ placeholder: String?) async -> String? = { _, _ in nil }
        ) {
            self.open = open
            self.active = active
            self.confirm = confirm
            self.alert = alert
            self.prompt = prompt
        }
    }

    // MARK: - gui/registries.ts

    /// Either a built-in app icon name or a plugin-declared `<plugin>:<name>` icon.
    // parity: plugin/src/gui/registries.ts#IconName [status=implemented hash=cc62a02fe23e]
    public enum IconName: Equatable, Hashable, Sendable, Codable {
        case app(AppIconName)
        case plugin(PluginIconName)

        public var rawString: String {
            switch self {
            case .app(let name): return name.rawValue
            case .plugin(let name): return name.rawValue
            }
        }
    }

    /// Palette command contribution (`Command` registry).
    // parity: plugin/src/gui/registries.ts#Command [status=implemented hash=5224acd2fd58]
    public struct Command: Sendable {
        public static let registry = Registry<Command>.define("command")

        public let id: String
        public let title: String
        public let description: String?
        public let keywords: String?
        public let group: String?
        public let section: String?
        public let bind: String?
        public let hidden: Bool
        public let suggested: Bool
        public let featured: Bool
        public let enabled: Bool
        public let scope: String?
        public let editable: Bool
        public let run: @Sendable (String?) async -> Bool

        public init(
            id: String,
            title: String,
            description: String? = nil,
            keywords: String? = nil,
            group: String? = nil,
            section: String? = nil,
            bind: String? = nil,
            hidden: Bool = false,
            suggested: Bool = false,
            featured: Bool = false,
            enabled: Bool = true,
            scope: String? = nil,
            editable: Bool = false,
            run: @escaping @Sendable (String?) async -> Bool = { _ in true }
        ) {
            self.id = id
            self.title = title
            self.description = description
            self.keywords = keywords
            self.group = group
            self.section = section
            self.bind = bind
            self.hidden = hidden
            self.suggested = suggested
            self.featured = featured
            self.enabled = enabled
            self.scope = scope
            self.editable = editable
            self.run = run
        }
    }

    /// Item contributed to the `session.panel` launcher menu.
    // parity: plugin/src/gui/registries.ts#SessionPanelMenuItem [status=implemented hash=bf6fb57f4007]
    public struct SessionPanelMenuItem: Sendable {
        public let id: String
        public let title: String
        public let order: Int
        public let icon: IconName?
        public let keybind: String?
        public let description: String?
        public let opened: Bool?
        public let primary: Bool
        public let run: @Sendable () -> Void

        public init(
            id: String,
            title: String,
            order: Int = 0,
            icon: IconName? = nil,
            keybind: String? = nil,
            description: String? = nil,
            opened: Bool? = nil,
            primary: Bool = false,
            run: @escaping @Sendable () -> Void = {}
        ) {
            self.id = id
            self.title = title
            self.order = order
            self.icon = icon
            self.keybind = keybind
            self.description = description
            self.opened = opened
            self.primary = primary
            self.run = run
        }
    }

    /// Item contributed to the `server.add` menu.
    // parity: plugin/src/gui/registries.ts#ServerAddMenuItem [status=implemented hash=fdd8f04d66df]
    public struct ServerAddMenuItem: Sendable {
        public let id: String
        public let title: String
        public let order: Int
        public let run: @Sendable () -> Void

        public init(id: String, title: String, order: Int = 0, run: @escaping @Sendable () -> Void = {}) {
            self.id = id
            self.title = title
            self.order = order
            self.run = run
        }
    }

    /// Item contributed to each Settings `server.row` menu.
    // parity: plugin/src/gui/registries.ts#ServerRowMenuItem [status=implemented hash=fb36beb0ce3f]
    public struct ServerRowMenuItem: Sendable {
        public let id: String
        public let title: String
        public let order: Int
        public let when: (@Sendable (String) -> Bool)?
        public let enabled: (@Sendable (String) -> Bool)?
        public let run: @Sendable (String) -> Void

        public init(
            id: String,
            title: String,
            order: Int = 0,
            when: (@Sendable (String) -> Bool)? = nil,
            enabled: (@Sendable (String) -> Bool)? = nil,
            run: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            self.id = id
            self.title = title
            self.order = order
            self.when = when
            self.enabled = enabled
            self.run = run
        }
    }

    /// Tagged union of all host menu item contributions (`MenuItem` registry).
    // parity: plugin/src/gui/registries.ts#MenuItem [status=implemented hash=ecaa191162f9]
    public enum MenuItem: Sendable {
        public static let registry = Registry<MenuItem>.define("menu-item")

        case sessionPanel(SessionPanelMenuItem)
        case serverAdd(ServerAddMenuItem)
        case serverRow(ServerRowMenuItem)
    }

    /// One tab descriptor listed by a side `Panel`.
    // parity: plugin/src/gui/registries.ts#PanelTab [status=implemented hash=82d51d395243]
    public struct PanelTab: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let title: String
        public let pinned: Bool?
        public let draggable: Bool?
        public let closable: String?
        public let transient: Bool?
        public let fallback: Bool?
        public let group: String?
        public let missing: Bool?
        public let hidden: Bool?
        public let file: String?
        public let tabbable: Bool?

        public init(
            id: String,
            title: String,
            pinned: Bool? = nil,
            draggable: Bool? = nil,
            closable: String? = nil,
            transient: Bool? = nil,
            fallback: Bool? = nil,
            group: String? = nil,
            missing: Bool? = nil,
            hidden: Bool? = nil,
            file: String? = nil,
            tabbable: Bool? = nil
        ) {
            self.id = id
            self.title = title
            self.pinned = pinned
            self.draggable = draggable
            self.closable = closable
            self.transient = transient
            self.fallback = fallback
            self.group = group
            self.missing = missing
            self.hidden = hidden
            self.file = file
            self.tabbable = tabbable
        }
    }

    /// Narrow-screen mobile presentation metadata for a `Panel`.
    // parity: plugin/src/gui/registries.ts#MobileView [status=implemented hash=d33d1e1edb26]
    public struct MobileView: Equatable, Hashable, Sendable, Codable {
        public enum Kind: String, Equatable, Hashable, Sendable, Codable {
            case tab
            case menu
            case drawer
        }

        public let title: String
        public let order: Int
        public let kind: Kind
        public let icon: IconName?
        public let cached: Bool?

        public init(title: String, order: Int, kind: Kind, icon: IconName? = nil, cached: Bool? = nil) {
            self.title = title
            self.order = order
            self.kind = kind
            self.icon = icon
            self.cached = cached
        }
    }

    /// Props passed to a `Panel`'s render and lifecycle callbacks.
    // parity: plugin/src/gui/registries.ts#PanelProps [status=implemented hash=b998a1c73b46]
    public struct PanelProps: Sendable {
        public let tab: PanelTab
        public let session: MountedSession
        public let screen: SessionScreen

        public init(tab: PanelTab, session: MountedSession, screen: SessionScreen) {
            self.tab = tab
            self.session = session
            self.screen = screen
        }
    }

    /// Reopenable closed-tab descriptor recorded when a user closes a panel tab.
    // parity: plugin/src/gui/registries.ts#ClosedPanelTab [status=implemented hash=bb873fb2c60c]
    public struct ClosedPanelTab: Equatable, Hashable, Sendable, Codable {
        public let title: String
        public let file: String?
        public let icon: IconName?
        public let data: String?

        public init(title: String, file: String? = nil, icon: IconName? = nil, data: String? = nil) {
            self.title = title
            self.file = file
            self.icon = icon
            self.data = data
        }
    }

    /// Side-region panel contribution (`Panel` registry).
    // parity: plugin/src/gui/registries.ts#Panel [status=implemented hash=d983c6702b88]
    public struct Panel: Sendable {
        public static let registry = Registry<Panel>.define("panel")

        public let id: String
        public let region: String
        public let transient: Bool?
        public let mobile: MobileView?
        public let list: @Sendable (MountedSession, SessionScreen, [String]) -> [PanelTab]
        public let render: @Sendable (PanelProps) -> ViewNode

        public init(
            id: String,
            region: String = "side",
            transient: Bool? = nil,
            mobile: MobileView? = nil,
            list: @escaping @Sendable (MountedSession, SessionScreen, [String]) -> [PanelTab],
            render: @escaping @Sendable (PanelProps) -> ViewNode
        ) {
            self.id = id
            self.region = region
            self.transient = transient
            self.mobile = mobile
            self.list = list
            self.render = render
        }
    }

    /// Search index entry of a contributed `SettingsPage`.
    // parity: plugin/src/gui/registries.ts#SettingEntry [status=implemented hash=d7bd9469590c]
    public struct SettingEntry: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let title: String
        public let description: String?
        public let keywords: String?

        public init(id: String, title: String, description: String? = nil, keywords: String? = nil) {
            self.id = id
            self.title = title
            self.description = description
            self.keywords = keywords
        }
    }

    /// Settings page, host-page section, or host-section rows contribution (`SettingsPage` registry).
    // parity: plugin/src/gui/registries.ts#SettingsPage [status=implemented hash=e9b5d2d5cd26]
    public struct SettingsPage: Sendable {
        public static let registry = Registry<SettingsPage>.define("settings-page")

        public let id: String
        public let page: String?
        public let section: String?
        public let group: String?
        public let title: String
        public let icon: IconName?
        public let entries: [SettingEntry]
        public let render: @Sendable (_ target: String?) -> ViewNode

        public init(
            id: String,
            page: String? = nil,
            section: String? = nil,
            group: String? = nil,
            title: String,
            icon: IconName? = nil,
            entries: [SettingEntry] = [],
            render: @escaping @Sendable (_ target: String?) -> ViewNode = { _ in ViewNode(component: "settings") }
        ) {
            self.id = id
            self.page = page
            self.section = section
            self.group = group
            self.title = title
            self.icon = icon
            self.entries = entries
            self.render = render
        }
    }

    /// Lifecycle state of a plugin-contributed server entry.
    // parity: plugin/src/gui/registries.ts#ServerState [status=implemented hash=45f64616956c]
    public enum ServerState: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case stopped
        case starting
        case auth
        case ready
        case failed
        case incompatible
    }

    /// Latest health probe result for a server entry.
    // parity: plugin/src/gui/registries.ts#ServerHealth [status=implemented hash=214903e829a2]
    public struct ServerHealth: Equatable, Hashable, Sendable, Codable {
        public let healthy: Bool
        public let version: String?
        public let incompatible: Bool?
        public let checking: Bool?

        public init(healthy: Bool, version: String? = nil, incompatible: Bool? = nil, checking: Bool? = nil) {
            self.healthy = healthy
            self.version = version
            self.incompatible = incompatible
            self.checking = checking
        }
    }

    /// Host parts provided to a contributed server's settings row.
    // parity: plugin/src/gui/registries.ts#ServerRow [status=adapted hash=a749b7df927a]
    public struct ServerRow: Sendable {
        public let key: String
        public let health: @Sendable () -> ServerHealth?
        public let remove: @Sendable () async -> Void

        public init(
            key: String,
            health: @escaping @Sendable () -> ServerHealth? = { nil },
            remove: @escaping @Sendable () async -> Void = {}
        ) {
            self.key = key
            self.health = health
            self.remove = remove
        }
    }

    /// One server entry contributed through a `Server` source.
    // parity: plugin/src/gui/registries.ts#ServerEntry [status=implemented hash=e45a7d0eedcd]
    public struct ServerEntry: Sendable {
        public struct HttpEndpoint: Equatable, Hashable, Sendable, Codable {
            public let url: String
            public let password: String?

            public init(url: String, password: String? = nil) {
                self.url = url
                self.password = password
            }
        }

        public let id: String
        public let name: String
        public let label: String?
        public let state: ServerState
        public let listed: Bool?
        public let http: HttpEndpoint?

        public init(
            id: String,
            name: String,
            label: String? = nil,
            state: ServerState,
            listed: Bool? = nil,
            http: HttpEndpoint? = nil
        ) {
            self.id = id
            self.name = name
            self.label = label
            self.state = state
            self.listed = listed
            self.http = http
        }
    }

    /// Source of contributed servers (`Server` registry).
    // parity: plugin/src/gui/registries.ts#Server [status=implemented hash=8c5b2fc5f859]
    public struct Server: Sendable {
        public static let registry = Registry<Server>.define("server")

        public let ready: Bool
        public let order: Int
        public let entries: [ServerEntry]

        public init(ready: Bool, order: Int = 0, entries: [ServerEntry]) {
            self.ready = ready
            self.order = order
            self.entries = entries
        }
    }

    /// Local link routed by `Links.open` to a matching `LinkHandler`.
    // parity: plugin/src/gui/registries.ts#Link [status=implemented hash=840deb75de6f]
    public struct Link: Equatable, Hashable, Sendable, Codable {
        public let href: String
        public let origin: String?
        public let exact: Bool?
        public let background: Bool?
        public let base: String?
        public let session: SessionRef?

        public init(
            href: String,
            origin: String? = nil,
            exact: Bool? = nil,
            background: Bool? = nil,
            base: String? = nil,
            session: SessionRef? = nil
        ) {
            self.href = href
            self.origin = origin
            self.exact = exact
            self.background = background
            self.base = base
            self.session = session
        }
    }

    /// Priority-ordered handler opening local links (`LinkHandler` registry).
    // parity: plugin/src/gui/registries.ts#LinkHandler [status=implemented hash=052ba3b139ba]
    public struct LinkHandler: Sendable {
        public static let registry = Registry<LinkHandler>.define("link-handler")

        public let priority: Int
        public let match: @Sendable (Link) -> Bool
        public let open: @Sendable (Link) -> Void
        public let exists: (@Sendable (Link) async -> Bool)?

        public init(
            priority: Int = 0,
            match: @escaping @Sendable (Link) -> Bool,
            open: @escaping @Sendable (Link) -> Void,
            exists: (@Sendable (Link) async -> Bool)? = nil
        ) {
            self.priority = priority
            self.match = match
            self.open = open
            self.exists = exists
        }
    }

    /// Pill contributed to the window titlebar or tabs footer (`TitlebarItem` registry).
    // parity: plugin/src/gui/registries.ts#TitlebarItem [status=implemented hash=fcc1a6eed85d]
    public struct TitlebarItem: Sendable {
        public static let registry = Registry<TitlebarItem>.define("titlebar-item")

        public let id: String
        public let label: String
        public let title: String?
        public let icon: IconName?
        public let busy: Bool?
        public let pressed: Bool?
        public let run: (@Sendable () -> Void)?

        public init(
            id: String,
            label: String,
            title: String? = nil,
            icon: IconName? = nil,
            busy: Bool? = nil,
            pressed: Bool? = nil,
            run: (@Sendable () -> Void)? = nil
        ) {
            self.id = id
            self.label = label
            self.title = title
            self.icon = icon
            self.busy = busy
            self.pressed = pressed
            self.run = run
        }
    }

    /// Semantic icon tone for a composer pill or row.
    // parity: plugin/src/gui/registries.ts#ComposerPillTone [status=implemented hash=a3cd5469e2c6]
    public enum ComposerPillTone: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case success
        case warning
        case danger
    }

    /// Input received by a `ComposerPill`'s `show` function.
    // parity: plugin/src/gui/registries.ts#ComposerPillProps [status=implemented hash=8abcdd0b6612]
    public struct ComposerPillProps: Sendable {
        public let session: MountedSession
        public let screen: SessionScreen

        public init(session: MountedSession, screen: SessionScreen) {
            self.session = session
            self.screen = screen
        }
    }

    /// Row inside a `ComposerPill` menu popover.
    // parity: plugin/src/gui/registries.ts#ComposerPillRow [status=implemented hash=20ecc73035ae]
    public struct ComposerPillRow: Sendable {
        public let id: String
        public let label: String
        public let icon: IconName?
        public let tone: ComposerPillTone?
        public let detail: String?
        public let run: (@Sendable () -> Void)?

        public init(
            id: String,
            label: String,
            icon: IconName? = nil,
            tone: ComposerPillTone? = nil,
            detail: String? = nil,
            run: (@Sendable () -> Void)? = nil
        ) {
            self.id = id
            self.label = label
            self.icon = icon
            self.tone = tone
            self.detail = detail
            self.run = run
        }
    }

    /// Input received by a custom `ComposerPill.menu` popover renderer.
    // parity: plugin/src/gui/registries.ts#ComposerPillMenuProps [status=implemented hash=344b31e110f8]
    public struct ComposerPillMenuProps: Sendable {
        public let session: MountedSession
        public let screen: SessionScreen
        public let close: @Sendable () -> Void

        public init(session: MountedSession, screen: SessionScreen, close: @escaping @Sendable () -> Void = {}) {
            self.session = session
            self.screen = screen
            self.close = close
        }
    }

    /// Rendered view descriptor of a composer pill.
    // parity: plugin/src/gui/registries.ts#ComposerPillView [status=implemented hash=56739e2fcd6f]
    public struct ComposerPillView: Sendable {
        public let label: String
        public let icon: IconName?
        public let tone: ComposerPillTone?
        public let title: String?
        public let rows: [ComposerPillRow]?
        public let run: (@Sendable () -> Void)?

        public init(
            label: String,
            icon: IconName? = nil,
            tone: ComposerPillTone? = nil,
            title: String? = nil,
            rows: [ComposerPillRow]? = nil,
            run: (@Sendable () -> Void)? = nil
        ) {
            self.label = label
            self.icon = icon
            self.tone = tone
            self.title = title
            self.rows = rows
            self.run = run
        }
    }

    /// Pill contributed above a session's composer (`ComposerPill` registry).
    // parity: plugin/src/gui/registries.ts#ComposerPill [status=implemented hash=59c0e5180085]
    public struct ComposerPill: Sendable {
        public static let registry = Registry<ComposerPill>.define("composer-pill")

        public let id: String
        public let order: Int
        public let show: @Sendable (ComposerPillProps) -> ComposerPillView?
        public let menu: (@Sendable (ComposerPillMenuProps) -> ViewNode)?

        public init(
            id: String,
            order: Int = 0,
            show: @escaping @Sendable (ComposerPillProps) -> ComposerPillView?,
            menu: (@Sendable (ComposerPillMenuProps) -> ViewNode)? = nil
        ) {
            self.id = id
            self.order = order
            self.show = show
            self.menu = menu
        }
    }

    /// Props passed to a fenced `CodeBlock` renderer or `CodeBlockAction`.
    // parity: plugin/src/gui/registries.ts#CodeBlockProps [status=implemented hash=1c2f5113e493]
    public struct CodeBlockProps: Equatable, Hashable, Sendable, Codable {
        public let code: String
        public let language: String
        public let session: MountedSession?

        public init(code: String, language: String, session: MountedSession? = nil) {
            self.code = code
            self.language = language
            self.session = session
        }
    }

    /// Custom fenced code-block renderer contribution (`CodeBlock` registry).
    // parity: plugin/src/gui/registries.ts#CodeBlock [status=implemented hash=eca92bc67444]
    public struct CodeBlock: Sendable {
        public static let registry = Registry<CodeBlock>.define("code-block")

        public let languages: [String]
        public let render: @Sendable (CodeBlockProps) -> ViewNode?

        public init(languages: [String], render: @escaping @Sendable (CodeBlockProps) -> ViewNode?) {
            self.languages = languages
            self.render = render
        }
    }

    /// Button beside a fenced code block's Copy button (`CodeBlockAction` registry).
    // parity: plugin/src/gui/registries.ts#CodeBlockAction [status=implemented hash=a8030c831cb7]
    public struct CodeBlockAction: Sendable {
        public static let registry = Registry<CodeBlockAction>.define("code-block-action")

        public let id: String
        public let languages: [String]
        public let icon: IconName
        public let title: String
        public let order: Int
        public let run: @Sendable (CodeBlockProps) async -> Void

        public init(
            id: String,
            languages: [String],
            icon: IconName,
            title: String,
            order: Int = 0,
            run: @escaping @Sendable (CodeBlockProps) async -> Void = { _ in }
        ) {
            self.id = id
            self.languages = languages
            self.icon = icon
            self.title = title
            self.order = order
            self.run = run
        }
    }

    /// Seed colors from which a desktop theme variant generates color scales.
    // parity: plugin/src/gui/registries.ts#ThemeSeedColors [status=implemented hash=e15507365232]
    public struct ThemeSeedColors: Equatable, Hashable, Sendable, Codable {
        public let neutral: String
        public let primary: String
        public let success: String
        public let warning: String
        public let error: String
        public let info: String
        public let interactive: String
        public let diffAdd: String
        public let diffDelete: String

        public init(
            neutral: String,
            primary: String,
            success: String,
            warning: String,
            error: String,
            info: String,
            interactive: String,
            diffAdd: String,
            diffDelete: String
        ) {
            self.neutral = neutral
            self.primary = primary
            self.success = success
            self.warning = warning
            self.error = error
            self.info = info
            self.interactive = interactive
            self.diffAdd = diffAdd
            self.diffDelete = diffDelete
        }
    }

    /// Palette colors from which a desktop theme variant derives tokens.
    // parity: plugin/src/gui/registries.ts#ThemePaletteColors [status=implemented hash=d48f05147d51]
    public struct ThemePaletteColors: Equatable, Hashable, Sendable, Codable {
        public let neutral: String
        public let ink: String
        public let primary: String
        public let success: String
        public let warning: String
        public let error: String
        public let info: String
        public let accent: String?
        public let interactive: String?
        public let diffAdd: String?
        public let diffDelete: String?

        public init(
            neutral: String,
            ink: String,
            primary: String,
            success: String,
            warning: String,
            error: String,
            info: String,
            accent: String? = nil,
            interactive: String? = nil,
            diffAdd: String? = nil,
            diffDelete: String? = nil
        ) {
            self.neutral = neutral
            self.ink = ink
            self.primary = primary
            self.success = success
            self.warning = warning
            self.error = error
            self.info = info
            self.accent = accent
            self.interactive = interactive
            self.diffAdd = diffAdd
            self.diffDelete = diffDelete
        }
    }

    /// One color-scheme variant of a `Theme` (mutually exclusive: either `seeds` or `palette`).
    // parity: plugin/src/gui/registries.ts#ThemeVariant [status=implemented hash=afa6ae5a0cd5]
    public enum ThemeVariant: Equatable, Hashable, Sendable, Codable {
        case seeds(ThemeSeedColors, overrides: [String: String]? = nil, v2Overrides: [String: String]? = nil)
        case palette(ThemePaletteColors, overrides: [String: String]? = nil, v2Overrides: [String: String]? = nil)
    }

    /// Color theme contribution listed in Settings › Appearance › Theme (`Theme` registry).
    // parity: plugin/src/gui/registries.ts#Theme [status=implemented hash=0b32e4eee324]
    public struct Theme: Equatable, Hashable, Sendable, Codable {
        public static let registry = Registry<Theme>.define("theme")

        public let schemaURL: String?
        public let name: String
        public let id: String
        public let light: ThemeVariant
        public let dark: ThemeVariant

        public init(
            schemaURL: String? = nil,
            name: String,
            id: String,
            light: ThemeVariant,
            dark: ThemeVariant
        ) {
            self.schemaURL = schemaURL
            self.name = name
            self.id = id
            self.light = light
            self.dark = dark
        }
    }

    /// Places a GUI `Slot` contribution renders with typed slot inputs.
    // parity: plugin/src/gui/registries.ts#SlotMap [status=implemented hash=12f5f8960d04]
    public enum SlotMap: Sendable {
        case windowBottom
        case sessionHeader(screen: SessionScreen, session: MountedSession, active: Bool, compact: Bool)
        case sessionLocationMenu(screen: SessionScreen, session: MountedSession, shown: Bool)
        case sessionPanelEnd(screen: SessionScreen, session: MountedSession)

        public var slotName: String {
            switch self {
            case .windowBottom: return "window.bottom"
            case .sessionHeader: return "session.header"
            case .sessionLocationMenu: return "session.location.menu"
            case .sessionPanelEnd: return "session.panel.end"
            }
        }
    }

    /// Slot contribution (`Slot` registry).
    // parity: plugin/src/gui/registries.ts#Slot [status=implemented hash=0a5982820cd6]
    public struct Slot: Sendable {
        public static let registry = Registry<Slot>.define("slot")

        public let at: String
        public let order: Int
        public let render: @Sendable (SlotMap) -> ViewNode

        public init(at: String, order: Int = 0, render: @escaping @Sendable (SlotMap) -> ViewNode) {
            self.at = at
            self.order = order
            self.render = render
        }
    }

    /// Registry token for inline CSS stylesheets contributed by GUI plugins.
    // parity: plugin/src/gui/registries.ts#Style [status=implemented hash=add43d1c9fc1]
    public static let Style = Registry<String>.define("style")

    // MARK: - gui/browser.ts

    /// Built-in browser contract (`browser`) exposed via `ctx.use(Browser.contract)`.
    // parity: plugin/src/gui/browser.ts#Browser [status=implemented hash=eabc313a3831]
    public struct Browser: Sendable {
        public static let contract = Contract<Browser>.define("browser")

        public let attached: @Sendable (SessionRef) -> Bool
        public let canOpen: @Sendable (SessionRef, String?) -> Bool
        public let open: @Sendable (SessionRef, String) -> Void
        public let openFile: @Sendable (SessionRef, String) -> Void

        public init(
            attached: @escaping @Sendable (SessionRef) -> Bool = { _ in false },
            canOpen: @escaping @Sendable (SessionRef, String?) -> Bool = { _, _ in false },
            open: @escaping @Sendable (SessionRef, String) -> Void = { _, _ in },
            openFile: @escaping @Sendable (SessionRef, String) -> Void = { _, _ in }
        ) {
            self.attached = attached
            self.canOpen = canOpen
            self.open = open
            self.openFile = openFile
        }
    }

    // MARK: - gui/review.ts

    /// Diff change kind of a file or directory in the review panel.
    // parity: plugin/src/gui/review.ts#ChangeKind [status=implemented hash=be17f3bd8bd3]
    public enum ChangeKind: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case add
        case del
        case mix
    }

    /// Built-in review changes contract (`review.changes`).
    // parity: plugin/src/gui/review.ts#Changes [status=implemented hash=39da9c0339ad]
    public struct Changes: Sendable {
        public static let contract = Contract<Changes>.define("review.changes")

        public let diffs: @Sendable (SessionRef) -> [FileDiffSchema.Info]
        public let ready: @Sendable (SessionRef) -> Bool
        public let kinds: @Sendable (SessionRef) -> [String: ChangeKind]
        public let active: @Sendable (SessionRef) -> String?
        public let details: @Sendable (SessionRef) -> [FileDiffSchema.Info]?
        public let focus: @Sendable (SessionRef, String) -> Void
        public let open: @Sendable (SessionRef) -> Void
        public let watch: @Sendable (SessionScreen, String) -> @Sendable () -> Void

        public init(
            diffs: @escaping @Sendable (SessionRef) -> [FileDiffSchema.Info] = { _ in [] },
            ready: @escaping @Sendable (SessionRef) -> Bool = { _ in false },
            kinds: @escaping @Sendable (SessionRef) -> [String: ChangeKind] = { _ in [:] },
            active: @escaping @Sendable (SessionRef) -> String? = { _ in nil },
            details: @escaping @Sendable (SessionRef) -> [FileDiffSchema.Info]? = { _ in nil },
            focus: @escaping @Sendable (SessionRef, String) -> Void = { _, _ in },
            open: @escaping @Sendable (SessionRef) -> Void = { _ in },
            watch: @escaping @Sendable (SessionScreen, String) -> @Sendable () -> Void = { _, _ in {} }
        ) {
            self.diffs = diffs
            self.ready = ready
            self.kinds = kinds
            self.active = active
            self.details = details
            self.focus = focus
            self.open = open
            self.watch = watch
        }
    }

    // MARK: - gui/file.ts

    /// Props passed to `FileTree.tree`.
    // parity: plugin/src/gui/file.ts#FileTreeProps [status=implemented hash=00e31e3a0a81]
    public struct FileTreeProps: Sendable {
        public let screen: SessionScreen
        public let session: MountedSession
        public let allowed: [String]
        public let kinds: [String: ChangeKind]?
        public let labels: [String: String]?
        public let active: String?
        public let onFileClick: @Sendable (String) -> Void

        public init(
            screen: SessionScreen,
            session: MountedSession,
            allowed: [String],
            kinds: [String: ChangeKind]? = nil,
            labels: [String: String]? = nil,
            active: String? = nil,
            onFileClick: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            self.screen = screen
            self.session = session
            self.allowed = allowed
            self.kinds = kinds
            self.labels = labels
            self.active = active
            self.onFileClick = onFileClick
        }
    }

    /// Props passed to `FileTree.list`.
    // parity: plugin/src/gui/file.ts#FileListProps [status=implemented hash=6cba1de293d8]
    public struct FileListProps: Sendable {
        public let screen: SessionScreen
        public let session: MountedSession
        public let files: [String]
        public let kinds: [String: ChangeKind]?
        public let active: String?
        public let highlighted: String?
        public let onFileClick: @Sendable (String) -> Void

        public init(
            screen: SessionScreen,
            session: MountedSession,
            files: [String],
            kinds: [String: ChangeKind]? = nil,
            active: String? = nil,
            highlighted: String? = nil,
            onFileClick: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            self.screen = screen
            self.session = session
            self.files = files
            self.kinds = kinds
            self.active = active
            self.highlighted = highlighted
            self.onFileClick = onFileClick
        }
    }

    /// Built-in file tree contract (`file.tree`).
    // parity: plugin/src/gui/file.ts#FileTree [status=implemented hash=9fb05c8c370a]
    public struct FileTree: Sendable {
        public static let contract = Contract<FileTree>.define("file.tree")

        public let tree: @Sendable (FileTreeProps) -> ViewNode
        public let list: @Sendable (FileListProps) -> ViewNode

        public init(
            tree: @escaping @Sendable (FileTreeProps) -> ViewNode = { _ in ViewNode(component: "file-tree") },
            list: @escaping @Sendable (FileListProps) -> ViewNode = { _ in ViewNode(component: "file-list") }
        ) {
            self.tree = tree
            self.list = list
        }
    }

    /// Props passed to `OpenInApp.button`.
    // parity: plugin/src/gui/file.ts#OpenInAppProps [status=implemented hash=521404ee3a22]
    public struct OpenInAppProps: Sendable {
        public let screen: SessionScreen
        public let session: MountedSession

        public init(screen: SessionScreen, session: MountedSession) {
            self.screen = screen
            self.session = session
        }
    }

    /// Built-in "Open in" button contract (`file.openInApp`).
    // parity: plugin/src/gui/file.ts#OpenInApp [status=implemented hash=e9eeed78417d]
    public struct OpenInApp: Sendable {
        public static let contract = Contract<OpenInApp>.define("file.openInApp")

        public let button: @Sendable (OpenInAppProps) -> ViewNode

        public init(button: @escaping @Sendable (OpenInAppProps) -> ViewNode = { _ in ViewNode(component: "open-in-app") }) {
            self.button = button
        }
    }

    /// Props passed to a custom `FileViewer` view component.
    // parity: plugin/src/gui/file.ts#FileViewerProps [status=implemented hash=5a188bf64bf8]
    public struct FileViewerProps: Sendable {
        public let bytes: [UInt8]
        public let onDetails: @Sendable ([String]) -> Void
        public let onError: @Sendable (String?) -> Void

        public init(
            bytes: [UInt8],
            onDetails: @escaping @Sendable ([String]) -> Void = { _ in },
            onError: @escaping @Sendable (String?) -> Void = { _ in }
        ) {
            self.bytes = bytes
            self.onDetails = onDetails
            self.onError = onError
        }
    }

    /// Custom viewer contribution for binary/office artifact kinds (`FileViewer` registry).
    // parity: plugin/src/gui/file.ts#FileViewer [status=implemented hash=39e0a7077d99]
    public struct FileViewer: Sendable {
        public static let registry = Registry<FileViewer>.define("file.viewer")

        public let kinds: [ArtifactKind]
        public let problem: (@Sendable ([UInt8]) -> String?)?
        public let view: @Sendable (FileViewerProps) -> ViewNode

        public init(
            kinds: [ArtifactKind],
            problem: (@Sendable ([UInt8]) -> String?)? = nil,
            view: @escaping @Sendable (FileViewerProps) -> ViewNode
        ) {
            self.kinds = kinds
            self.problem = problem
            self.view = view
        }
    }

    // MARK: - gui/context.ts

    /// Window plugin context passed to window `setup(ctx)` and returned by `usePlugin()`.
    // parity: plugin/src/gui/context.ts#Context [status=adapted hash=364c088fdac1]
    public struct Context: BaseContext, Sendable {
        public let id: String
        public let options: PluginOptions
        public let signal: AbortSignal
        public let app: App
        public let layout: Layout
        public let sessions: Sessions
        public let screen: Screen
        public let storage: Storage
        public let system: System
        public let desktop: Desktop?
        public let dialogs: Dialogs
        public let links: Links
        public let locale: Locale
        public let appearance: Appearance
        public let router: Router
        public let keybinds: Keybinds
        public let servers: Servers
        public let workspaces: Workspaces
        public let addContribution: @Sendable (_ registryID: String, _ item: any Sendable) -> Cleanup
        public let listContributions: @Sendable (_ registryID: String) -> [any Sendable]
        public let provideContract: @Sendable (_ contractID: String, _ impl: any Sendable) -> Cleanup
        public let useToken: @Sendable (_ tokenID: String) -> @Sendable () -> Live<any Sendable>
        public let mainIpc: @Sendable (Ipc) -> IpcClient
        private let translate: @Sendable (String, Params?) -> String
        private let translatePlural: @Sendable (String, Int, Params?) -> String

        public init(
            id: String,
            options: PluginOptions = [:],
            signal: AbortSignal = AbortController().signal,
            app: App = App(),
            layout: Layout = Layout(),
            sessions: Sessions = Sessions(),
            screen: Screen = Screen(),
            storage: Storage = Storage(
                store: { _, opts in Persisted(read: { opts.initial }, update: { _ in }, set: { _ in }) },
                remove: { _, _ in }
            ),
            system: System = System(),
            desktop: Desktop? = nil,
            dialogs: Dialogs = Dialogs(),
            links: Links = Links(),
            locale: Locale = Locale(),
            appearance: Appearance = Appearance(),
            router: Router = Router(),
            keybinds: Keybinds = Keybinds(),
            servers: Servers = Servers(),
            workspaces: Workspaces = Workspaces(),
            addContribution: @escaping @Sendable (_ registryID: String, _ item: any Sendable) -> Cleanup = { _, _ in {} },
            listContributions: @escaping @Sendable (_ registryID: String) -> [any Sendable] = { _ in [] },
            provideContract: @escaping @Sendable (_ contractID: String, _ impl: any Sendable) -> Cleanup = { _, _ in {} },
            useToken: @escaping @Sendable (_ tokenID: String) -> @Sendable () -> Live<any Sendable> = { _ in { .pending } },
            mainIpc: @escaping @Sendable (Ipc) -> IpcClient = { ipc in
                IpcClient(id: ipc.id, call: { _, _, _ in .null })
            },
            translate: @escaping @Sendable (String, Params?) -> String = { key, _ in key },
            translatePlural: @escaping @Sendable (String, Int, Params?) -> String = { key, count, _ in "\(count) \(key)" }
        ) {
            self.id = id
            self.options = options
            self.signal = signal
            self.app = app
            self.layout = layout
            self.sessions = sessions
            self.screen = screen
            self.storage = storage
            self.system = system
            self.desktop = desktop
            self.dialogs = dialogs
            self.links = links
            self.locale = locale
            self.appearance = appearance
            self.router = router
            self.keybinds = keybinds
            self.servers = servers
            self.workspaces = workspaces
            self.addContribution = addContribution
            self.listContributions = listContributions
            self.provideContract = provideContract
            self.useToken = useToken
            self.mainIpc = mainIpc
            self.translate = translate
            self.translatePlural = translatePlural
        }

        public func t(_ key: String, params: Params? = nil) -> String {
            translate(key, params)
        }

        public func plural(_ key: String, count: Int, params: Params? = nil) -> String {
            translatePlural(key, count, params)
        }

        @discardableResult
        public func add<T: Sendable>(_ registry: Registry<T>, _ item: T) -> Cleanup {
            addContribution(registry.id, item)
        }

        public func list<T: Sendable>(_ registry: Registry<T>) -> [T] {
            listContributions(registry.id).compactMap { $0 as? T }
        }
    }

    /// Window setup context enriched with declared stores and declared plugin icons.
    // parity: plugin/src/gui/context.ts#SetupContext [status=implemented hash=55ba9c3326f6]
    public struct SetupContext: Sendable {
        public let base: Context
        public let stores: [String: Persisted<JSONValue>]
        public let icons: [String: PluginIconName]

        public init(
            base: Context,
            stores: [String: Persisted<JSONValue>] = [:],
            icons: [String: PluginIconName] = [:]
        ) {
            self.base = base
            self.stores = stores
            self.icons = icons
        }
    }

    // MARK: - gui/main.ts

    /// Main-process open window inspector.
    // parity: plugin/src/gui/main.ts#Windows [status=adapted hash=0458ffeb921d]
    public struct Windows: Sendable {
        public let get: @Sendable (Int) -> String?
        public let list: @Sendable () -> [Int]
        public let focused: @Sendable () -> Int?
        public let on: @Sendable (String, @escaping @Sendable (Int) -> Void) -> Cleanup

        public init(
            get: @escaping @Sendable (Int) -> String? = { _ in nil },
            list: @escaping @Sendable () -> [Int] = { [] },
            focused: @escaping @Sendable () -> Int? = { nil },
            on: @escaping @Sendable (String, @escaping @Sendable (Int) -> Void) -> Cleanup = { _, _ in {} }
        ) {
            self.get = get
            self.list = list
            self.focused = focused
            self.on = on
        }
    }

    /// Embedded web-page view managed by the main process.
    // parity: plugin/src/gui/main.ts#Embed [status=adapted hash=ece9010af0aa]
    public struct Embed: Sendable {
        public let id: String
        public let show: @Sendable (Bool) -> Void
        public let onVisible: @Sendable (@escaping @Sendable (Bool) -> Void) -> Cleanup
        public let capture: @Sendable () async -> [UInt8]?
        public let dispose: @Sendable () -> Void

        public init(
            id: String,
            show: @escaping @Sendable (Bool) -> Void = { _ in },
            onVisible: @escaping @Sendable (@escaping @Sendable (Bool) -> Void) -> Cleanup = { _ in {} },
            capture: @escaping @Sendable () async -> [UInt8]? = { nil },
            dispose: @escaping @Sendable () -> Void = {}
        ) {
            self.id = id
            self.show = show
            self.onVisible = onVisible
            self.capture = capture
            self.dispose = dispose
        }
    }

    /// Main-process embed factory.
    // parity: plugin/src/gui/main.ts#Embeds [status=adapted hash=c9a2958e2aff]
    public struct Embeds: Sendable {
        public let create: @Sendable (_ viewID: String, _ windowID: Int) -> Embed

        public init(create: @escaping @Sendable (_ viewID: String, _ windowID: Int) -> Embed = { id, _ in Embed(id: id) }) {
            self.create = create
        }
    }

    /// Synchronous main-process persistent storage (`plugin.<id>`).
    // parity: plugin/src/gui/main.ts#Storage [status=adapted hash=5595e5c95930]
    public struct MainStorage: Sendable {
        public let store: @Sendable (_ key: String, _ initial: JSONValue) -> Persisted<JSONValue>
        public let remove: @Sendable (_ key: String) -> Void

        public init(
            store: @escaping @Sendable (_ key: String, _ initial: JSONValue) -> Persisted<JSONValue>,
            remove: @escaping @Sendable (_ key: String) -> Void
        ) {
            self.store = store
            self.remove = remove
        }
    }

    /// Resolved server endpoint with credentials accessible from main.
    // parity: plugin/src/gui/main.ts#ServerEndpoint [status=implemented hash=88bfef5a18e3]
    public struct ServerEndpoint: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let url: String
        public let headers: [String: String]
        public let sameMachine: Bool
        public let password: String?

        public init(
            id: String,
            url: String,
            headers: [String: String] = [:],
            sameMachine: Bool = true,
            password: String? = nil
        ) {
            self.id = id
            self.url = url
            self.headers = headers
            self.sameMachine = sameMachine
            self.password = password
        }
    }

    /// CLI executable descriptor used by the desktop host.
    // parity: plugin/src/gui/main.ts#Cli [status=implemented hash=a963bf09bbeb]
    public struct Cli: Equatable, Hashable, Sendable, Codable {
        public let version: String
        public let command: [String]
        public let binary: String?
        public let development: Bool

        public init(version: String, command: [String], binary: String? = nil, development: Bool = false) {
            self.version = version
            self.command = command
            self.binary = binary
            self.development = development
        }
    }

    /// Lookup table for server endpoints configured by open windows.
    // parity: plugin/src/gui/main.ts#ServerEndpoints [status=implemented hash=26ec7137bba6]
    public struct ServerEndpoints: Sendable {
        public let get: @Sendable (String) -> ServerEndpoint?

        public init(get: @escaping @Sendable (String) -> ServerEndpoint? = { _ in nil }) {
            self.get = get
        }
    }

    /// Desktop structured log writer exposed to main-process plugins.
    // parity: plugin/src/gui/main.ts#Log [status=implemented hash=8b8bc086b55a]
    public struct Log: Sendable {
        public let write: @Sendable (_ level: OpenCodeLogLevel, _ message: String, _ data: [String: JSONValue]?) -> Void

        public init(
            write: @escaping @Sendable (_ level: OpenCodeLogLevel, _ message: String, _ data: [String: JSONValue]?) -> Void = { _, _, _ in }
        ) {
            self.write = write
        }
    }

    /// Setup context provided to a GUI plugin's main-process entrypoint.
    // parity: plugin/src/gui/main.ts#MainContext [status=adapted hash=2282699ef2bb]
    public struct MainContext: BaseContext, Sendable {
        public let id: String
        public let options: PluginOptions
        public let signal: AbortSignal
        public let onCleanup: @Sendable (@escaping Cleanup) -> Void
        public let storage: MainStorage
        public let log: Log
        public let app: App
        public let serverEndpoints: ServerEndpoints
        public let windows: Windows
        public let embeds: Embeds
        public let cli: Cli
        public let provide: @Sendable (Ipc, IpcImpl) -> IpcProvider
        private let translate: @Sendable (String, Params?) -> String
        private let translatePlural: @Sendable (String, Int, Params?) -> String

        public init(
            id: String,
            options: PluginOptions = [:],
            signal: AbortSignal = AbortController().signal,
            onCleanup: @escaping @Sendable (@escaping Cleanup) -> Void = { _ in },
            storage: MainStorage = MainStorage(
                store: { _, initial in Persisted(read: { initial }, update: { _ in }, set: { _ in }) },
                remove: { _ in }
            ),
            log: Log = Log(),
            app: App = App(platform: .desktop),
            serverEndpoints: ServerEndpoints = ServerEndpoints(),
            windows: Windows = Windows(),
            embeds: Embeds = Embeds(),
            cli: Cli = Cli(version: "0.0.0", command: ["opencode"]),
            provide: @escaping @Sendable (Ipc, IpcImpl) -> IpcProvider = { _, _ in IpcProvider() },
            translate: @escaping @Sendable (String, Params?) -> String = { key, _ in key },
            translatePlural: @escaping @Sendable (String, Int, Params?) -> String = { key, count, _ in "\(count) \(key)" }
        ) {
            self.id = id
            self.options = options
            self.signal = signal
            self.onCleanup = onCleanup
            self.storage = storage
            self.log = log
            self.app = app
            self.serverEndpoints = serverEndpoints
            self.windows = windows
            self.embeds = embeds
            self.cli = cli
            self.provide = provide
            self.translate = translate
            self.translatePlural = translatePlural
        }

        public func t(_ key: String, params: Params? = nil) -> String {
            translate(key, params)
        }

        public func plural(_ key: String, count: Int, params: Params? = nil) -> String {
            translatePlural(key, count, params)
        }
    }

    /// Native desktop menubar item contribution (`MenubarItem` registry).
    // parity: plugin/src/gui/main.ts#MenubarItem [status=implemented hash=6079e52fff2e]
    public struct MenubarItem: Sendable {
        public static let registry = Registry<MenubarItem>.define("menubar-item")

        public enum Menu: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
            case app
            case file
            case edit
            case view
            case go
            case window
            case help
        }

        public let menu: Menu
        public let id: String
        public let label: String
        public let after: String?
        public let enabled: (@Sendable () -> Bool)?
        public let run: @Sendable (_ windowID: Int?) -> Void

        public init(
            menu: Menu,
            id: String,
            label: String,
            after: String? = nil,
            enabled: (@Sendable () -> Bool)? = nil,
            run: @escaping @Sendable (_ windowID: Int?) -> Void = { _ in }
        ) {
            self.menu = menu
            self.id = id
            self.label = label
            self.after = after
            self.enabled = enabled
            self.run = run
        }
    }

    // MARK: - gui/plugin.ts

    /// Synchronous window setup function type.
    // parity: plugin/src/gui/plugin.ts#Setup [status=implemented hash=cf5c9157e457]
    public typealias Setup = @Sendable (SetupContext) -> Cleanup?

    /// Async main-process setup function type.
    // parity: plugin/src/gui/plugin.ts#MainSetup [status=implemented hash=121ef95d9704]
    public typealias MainSetup = @Sendable (MainContext) async throws -> Cleanup?

    /// Complete GUI plugin definition (`declarations` plus optional `setup` and/or `main`).
    // parity: plugin/src/gui/plugin.ts#Definition [status=implemented hash=3b26207b8042]
    public struct Definition: Sendable {
        public let declarations: Declarations
        public let setup: Setup?
        public let main: MainSetup?

        public init(
            declarations: Declarations = Declarations(),
            setup: Setup? = nil,
            main: MainSetup? = nil
        ) {
            self.declarations = declarations
            self.setup = setup
            self.main = main
        }
    }

    /// Identity helper defining a GUI plugin.
    // parity: plugin/src/gui/plugin.ts#define [status=implemented hash=0d174f5acfdb]
    public static func define(_ plugin: Definition) -> Definition {
        plugin
    }

    // MARK: - gui/internal.ts & gui/solid.ts

    /// Inner sidebar preference shared across side panels.
    // parity: plugin/src/gui/solid.ts#PanelSidebar [status=implemented hash=5d44551bb0f2]
    public struct PanelSidebar: Sendable {
        public let opened: @Sendable () -> Bool
        public let width: @Sendable () -> Double
        public let transition: @Sendable () -> Bool
        public let resize: @Sendable (Double) -> Void
        public let toggle: @Sendable () -> Void

        public init(
            opened: @escaping @Sendable () -> Bool = { true },
            width: @escaping @Sendable () -> Double = { 260 },
            transition: @escaping @Sendable () -> Bool = { false },
            resize: @escaping @Sendable (Double) -> Void = { _ in },
            toggle: @escaping @Sendable () -> Void = {}
        ) {
            self.opened = opened
            self.width = width
            self.transition = transition
            self.resize = resize
            self.toggle = toggle
        }
    }

    /// Active panel placement frame read via `usePanel()`.
    // parity: plugin/src/gui/solid.ts#PanelFrame [status=implemented hash=502c6cf9a66b]
    public struct PanelFrame: Sendable {
        public enum Placement: String, Equatable, Hashable, Sendable, Codable {
            case side
            case mobile
        }

        public let visible: @Sendable () -> Bool
        public let present: @Sendable () -> Bool
        public let placement: @Sendable () -> Placement
        public let reserve: @Sendable () -> Bool
        public let animate: @Sendable () -> Bool
        public let sidebar: PanelSidebar
        public let open: @Sendable () -> [String]

        public init(
            visible: @escaping @Sendable () -> Bool = { true },
            present: @escaping @Sendable () -> Bool = { true },
            placement: @escaping @Sendable () -> Placement = { .side },
            reserve: @escaping @Sendable () -> Bool = { false },
            animate: @escaping @Sendable () -> Bool = { true },
            sidebar: PanelSidebar = PanelSidebar(),
            open: @escaping @Sendable () -> [String] = { [] }
        ) {
            self.visible = visible
            self.present = present
            self.placement = placement
            self.reserve = reserve
            self.animate = animate
            self.sidebar = sidebar
            self.open = open
        }
    }

    /// Context handle for narrow-screen drawers (`DrawerContext` / `useDrawer`).
    public struct DrawerHandle: Sendable {
        public let close: @Sendable () -> Void
        public let open: @Sendable (_ title: String, _ content: ViewNode) -> Void

        public init(
            close: @escaping @Sendable () -> Void = {},
            open: @escaping @Sendable (_ title: String, _ content: ViewNode) -> Void = { _, _ in }
        ) {
            self.close = close
            self.open = open
        }
    }

    /// Lifetime state cell marking when a reactive scope has ended.
    public final class LifetimeMarker: Sendable {
        private let flag = Mutex(false)

        public init(ended: Bool = false) {
            self.flag.withLock { $0 = ended }
        }

        public var ended: Bool {
            flag.withLock { $0 }
        }

        public func end() {
            flag.withLock { $0 = true }
        }
    }

    public enum GuiContextError: Error, Equatable, Sendable, CustomStringConvertible {
        case missingPluginContext
        case missingPanelContext

        public var description: String {
            switch self {
            case .missingPluginContext: return "usePlugin must run inside a plugin contribution"
            case .missingPanelContext: return "usePanel must run inside a panel render"
            }
        }
    }

    /// Task-local context binding for the active GUI plugin context.
    // parity: plugin/src/gui/internal.ts#PluginContext [status=adapted hash=499b39c73f71]
    @TaskLocal
    public static var PluginContext: Context?

    /// Task-local context binding for scoped reactive lifetime markers.
    // parity: plugin/src/gui/internal.ts#LifetimeContext [status=adapted hash=5f53a0ddd380]
    @TaskLocal
    public static var LifetimeContext: LifetimeMarker?

    /// Task-local context binding for the active panel render frame.
    // parity: plugin/src/gui/internal.ts#PanelContext [status=adapted hash=0a468aeeae82]
    @TaskLocal
    public static var PanelContext: PanelFrame?

    /// Task-local context binding for the active narrow-screen drawer.
    // parity: plugin/src/gui/internal.ts#DrawerContext [status=adapted hash=dc4ee4975b2c]
    @TaskLocal
    public static var DrawerContext: DrawerHandle?

    /// Protocol marker identifying any `LiveAccessorBox<T>` instance regardless of element type.
    public protocol LiveAccessorMarker: Sendable {
        var isLiveMarked: Bool { get }
    }

    /// Wrapper marking a reactive accessor returned by `ctx.use(token)` so `createKeyed` tracks generations.
    public struct LiveAccessorBox<T: Sendable>: LiveAccessorMarker, Sendable {
        public let isLiveMarked: Bool = true
        public let read: @Sendable () -> Live<T>

        public init(_ read: @escaping @Sendable () -> Live<T>) {
            self.read = read
        }

        public func callAsFunction() -> Live<T> {
            read()
        }
    }

    /// Marks an accessor returned by `ctx.use` so `createKeyed` follows provider generations.
    // parity: plugin/src/gui/internal.ts#liveAccessor [status=adapted hash=090390be46c7]
    public static func liveAccessor<T: Sendable>(_ read: @escaping @Sendable () -> Live<T>) -> LiveAccessorBox<T> {
        LiveAccessorBox(read)
    }

    /// Checks whether a source value is a live accessor produced by `liveAccessor`.
    // parity: plugin/src/gui/internal.ts#isLiveAccessor [status=adapted hash=10c7cd6bcc62]
    public static func isLiveAccessor(_ source: Any) -> Bool {
        source is any LiveAccessorMarker
    }

    /// Reads the active GUI plugin context bound via `$PluginContext.withValue(...)`.
    // parity: plugin/src/gui/solid.ts#usePlugin [status=adapted hash=e73663287711]
    public static func usePlugin() throws(GuiContextError) -> Context {
        guard let ctx = PluginContext else {
            throw .missingPluginContext
        }
        return ctx
    }

    /// Binds a component render closure to the currently active provider's plugin context.
    // parity: plugin/src/gui/solid.ts#bindPlugin [status=adapted hash=d5f1cd2dcd80]
    public static func bindPlugin<Props: Sendable>(
        _ component: @escaping @Sendable (Props) -> ViewNode
    ) throws(GuiContextError) -> @Sendable (Props) -> ViewNode {
        let boundContext = try usePlugin()
        return { props in
            $PluginContext.withValue(boundContext) {
                component(props)
            }
        }
    }

    /// Reads the active panel frame inside a `Panel.render` execution.
    // parity: plugin/src/gui/solid.ts#usePanel [status=adapted hash=f3f944ee9231]
    public static func usePanel() throws(GuiContextError) -> PanelFrame {
        guard let frame = PanelContext else {
            throw .missingPanelContext
        }
        return frame
    }

    /// Reads the active drawer handle inside a drawer render, or `nil` outside one.
    // parity: plugin/src/gui/solid.ts#useDrawer [status=adapted hash=3b58475650ad]
    public static func useDrawer() -> DrawerHandle? {
        DrawerContext
    }

    // MARK: - gui/reactive.ts

    /// Reactive accessor source accepted by `createKeyed` and `createLatest`.
    // parity: plugin/src/gui/reactive.ts#KeyedSource [status=adapted hash=577a25166cc6]
    public typealias KeyedSource<T: Sendable> = @Sendable () -> T?

    /// Active unwrapped value type produced by a `KeyedSource`.
    // parity: plugin/src/gui/reactive.ts#KeyedValue [status=adapted hash=9f387f0d9f13]
    public typealias KeyedValue<T: Sendable> = T

    /// Runs `fn` when `source()` yields a value (with a dedicated `LifetimeMarker`), or `otherwise` when `nil`.
    // parity: plugin/src/gui/reactive.ts#createKeyed [status=adapted hash=7e1911576e27]
    @discardableResult
    public static func createKeyed<T: Sendable>(
        _ source: KeyedSource<T>,
        _ fn: @Sendable (T) -> Void,
        otherwise: (@Sendable () -> Void)? = nil
    ) -> LifetimeMarker {
        let marker = LifetimeMarker()
        $LifetimeContext.withValue(marker) {
            if let value = source() {
                fn(value)
            } else {
                otherwise?()
            }
        }
        return marker
    }

    /// Latest async fetch state snapshot returned by `createLatest`.
    public struct LatestState<T: Sendable>: Sendable {
        public let latest: T?
        public let loading: Bool
        public let error: String?

        public init(latest: T? = nil, loading: Bool = false, error: String? = nil) {
            self.latest = latest
            self.loading = loading
            self.error = error
        }
    }

    /// Fetches the latest result for `source()` with cooperative `AbortSignal` cancellation.
    // parity: plugin/src/gui/reactive.ts#createLatest [status=adapted hash=ad5307b8106e]
    public static func createLatest<S: Sendable, T: Sendable>(
        _ source: KeyedSource<S>,
        fetch: @escaping @Sendable (S, AbortSignal) async throws -> T
    ) async -> LatestState<T> {
        guard let value = source() else {
            return LatestState(latest: nil, loading: false, error: nil)
        }
        let controller = AbortController()
        do {
            let result = try await fetch(value, controller.signal)
            if controller.signal.isAborted {
                return LatestState(latest: nil, loading: false, error: nil)
            }
            return LatestState(latest: result, loading: false, error: nil)
        } catch {
            if controller.signal.isAborted {
                return LatestState(latest: nil, loading: false, error: nil)
            }
            return LatestState(latest: nil, loading: false, error: String(describing: error))
        }
    }

    /// Visit-scoped state resetting to `initial` whenever `MountedSession.visitID` changes.
    // parity: plugin/src/gui/reactive.ts#createVisitState [status=adapted hash=65aa578f12ed]
    public static func createVisitState<T: Sendable>(
        _ initial: T,
        currentVisitID: @escaping @Sendable () -> String?
    ) -> (get: @Sendable () -> T, set: @Sendable (T) -> Void) {
        let box = Mutex<(visitID: String?, value: T)>((nil, initial))
        let get: @Sendable () -> T = {
            let visit = currentVisitID()
            return box.withLock { s in
                if let savedVisit = s.visitID, savedVisit == visit {
                    return s.value
                }
                return initial
            }
        }
        let set: @Sendable (T) -> Void = { next in
            let visit = currentVisitID()
            box.withLock { s in
                s = (visit, next)
            }
        }
        return (get, set)
    }

    // MARK: - gui/builtin.ts

    /// Schedules idle work asynchronously and returns a cancellation handle.
    // parity: plugin/src/gui/builtin.ts#onIdle [status=adapted hash=26d34fce192e]
    @discardableResult
    public static func onIdle(_ fn: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let task = Task(priority: .utility) {
            guard !Task.isCancelled else { return }
            fn()
        }
        return { task.cancel() }
    }

    /// Built-in command contribution supporting `follows` shortcut inheritance.
    // parity: plugin/src/gui/builtin.ts#BuiltinCommand [status=implemented hash=3e63ca19eadd]
    public struct BuiltinCommand: Sendable {
        public static let registry = Registry<BuiltinCommand>.define("command")

        public let command: Command
        public let follows: String?

        public init(command: Command, follows: String? = nil) {
            self.command = command
            self.follows = follows
        }
    }

    /// Built-in panel tab supporting `first` placement and stable DOM IDs.
    // parity: plugin/src/gui/builtin.ts#BuiltinPanelTab [status=implemented hash=ea98df5e43fd]
    public struct BuiltinPanelTab: Equatable, Hashable, Sendable, Codable {
        public let tab: PanelTab
        public let first: Bool?
        public let domTabID: String?
        public let domPanelID: String?

        public init(tab: PanelTab, first: Bool? = nil, domTabID: String? = nil, domPanelID: String? = nil) {
            self.tab = tab
            self.first = first
            self.domTabID = domTabID
            self.domPanelID = domPanelID
        }
    }

    /// Built-in panel contribution supporting legacy key migrations.
    // parity: plugin/src/gui/builtin.ts#BuiltinPanel [status=implemented hash=68d9dcffccf8]
    public struct BuiltinPanel: Sendable {
        public static let registry = Registry<BuiltinPanel>.define("panel")

        public let panel: Panel
        public let legacy: [String: String]?

        public init(panel: Panel, legacy: [String: String]? = nil) {
            self.panel = panel
            self.legacy = legacy
        }
    }

    /// Built-in extended GUI slot map.
    // parity: plugin/src/gui/builtin.ts#BuiltinSlotMap [status=implemented hash=4a56ec0b6314]
    public enum BuiltinSlotMap: Sendable {
        case publicSlot(SlotMap)
        case sessionLocationBranchMenu(screen: SessionScreen, session: MountedSession, shown: Bool)
        case sessionLocationPathMenu(screen: SessionScreen, session: MountedSession, shown: Bool)
        case sessionLocationWorkspace(screen: SessionScreen, session: MountedSession, shown: Bool, label: String, icon: IconName)
    }

    /// Built-in slot contribution (`BuiltinSlot` registry).
    // parity: plugin/src/gui/builtin.ts#BuiltinSlot [status=implemented hash=e52149587836]
    public struct BuiltinSlot: Sendable {
        public static let registry = Registry<BuiltinSlot>.define("slot")

        public let at: String
        public let order: Int
        public let render: @Sendable (BuiltinSlotMap) -> ViewNode

        public init(at: String, order: Int = 0, render: @escaping @Sendable (BuiltinSlotMap) -> ViewNode) {
            self.at = at
            self.order = order
            self.render = render
        }
    }

    /// Legacy migration source for built-in window stores.
    // parity: plugin/src/gui/builtin.ts#BuiltinStoreFrom [status=implemented hash=af590a140ffb]
    public enum BuiltinStoreFrom: Sendable {
        case key(StoreFrom)
        case shared(key: String, sessions: String?, pick: @Sendable (JSONValue?) -> JSONValue?)
    }

    /// Built-in window store declaration supporting `builtinFrom` migrations.
    // parity: plugin/src/gui/builtin.ts#BuiltinStoreDeclaration [status=implemented hash=d3bd07638ace]
    public struct BuiltinStoreDeclaration: Sendable {
        public let base: StoreDeclaration
        public let builtinFrom: [BuiltinStoreFrom]

        public init(base: StoreDeclaration, builtinFrom: [BuiltinStoreFrom] = []) {
            self.base = base
            self.builtinFrom = builtinFrom
        }
    }

    /// Factory namespace for built-in window stores (`BuiltinStore.global`, `BuiltinStore.session`).
    // parity: plugin/src/gui/builtin.ts#BuiltinStore [status=implemented hash=5a08dfeeb223]
    public enum BuiltinStore {
        public static func global(
            schema: ToolSchema.ValueSchema = .jsonSchema([:]),
            initial: JSONValue,
            from: [BuiltinStoreFrom] = []
        ) -> BuiltinStoreDeclaration {
            BuiltinStoreDeclaration(
                base: Store.global(schema: schema, initial: initial),
                builtinFrom: from
            )
        }

        public static func session(
            schema: ToolSchema.ValueSchema = .jsonSchema([:]),
            initial: JSONValue,
            from: [BuiltinStoreFrom] = []
        ) -> BuiltinStoreDeclaration {
            BuiltinStoreDeclaration(
                base: Store.session(schema: schema, initial: initial),
                builtinFrom: from
            )
        }
    }

    /// Options for opening a built-in window store.
    // parity: plugin/src/gui/builtin.ts#BuiltinStoreOptions [status=implemented hash=96e05a92efc5]
    public struct BuiltinStoreOptions: Sendable {
        public let base: StoreOptions
        public let from: [BuiltinStoreFrom]

        public init(base: StoreOptions, from: [BuiltinStoreFrom] = []) {
            self.base = base
            self.from = from
        }
    }

    /// Window storage surface extended for built-in plugins.
    // parity: plugin/src/gui/builtin.ts#BuiltinStorage [status=adapted hash=06348d1a7387]
    public struct BuiltinStorage: Sendable {
        public let base: Storage
        public let store: @Sendable (String, BuiltinStoreOptions) -> Persisted<JSONValue>

        public init(base: Storage, store: @escaping @Sendable (String, BuiltinStoreOptions) -> Persisted<JSONValue>) {
            self.base = base
            self.store = store
        }
    }

    /// Desktop API extended with `forceFocus` for built-in plugins.
    // parity: plugin/src/gui/builtin.ts#BuiltinDesktop [status=implemented hash=da867bbf1c4c]
    public struct BuiltinDesktop: Sendable {
        public let base: Desktop
        public let forceFocus: @Sendable (Bool) async -> Void

        public init(base: Desktop, forceFocus: @escaping @Sendable (Bool) async -> Void = { _ in }) {
            self.base = base
            self.forceFocus = forceFocus
        }
    }

    /// Layout API extended with `command` dispatch for built-in plugins.
    // parity: plugin/src/gui/builtin.ts#BuiltinLayout [status=implemented hash=700caa394088]
    public struct BuiltinLayout: Sendable {
        public let base: Layout
        public let command: @Sendable (String) -> Void

        public init(base: Layout, command: @escaping @Sendable (String) -> Void = { _ in }) {
            self.base = base
            self.command = command
        }
    }

    /// Locale API extended with `setDirection` for built-in plugins.
    // parity: plugin/src/gui/builtin.ts#BuiltinLocale [status=implemented hash=1cb6873e8b80]
    public struct BuiltinLocale: Sendable {
        public let base: Locale
        public let setDirection: @Sendable (Locale.Direction) -> Void

        public init(base: Locale, setDirection: @escaping @Sendable (Locale.Direction) -> Void = { _ in }) {
            self.base = base
            self.setDirection = setDirection
        }
    }

    /// Built-in window context with desktop/locale/layout/storage extensions.
    // parity: plugin/src/gui/builtin.ts#BuiltinContext [status=implemented hash=b5f0895298dd]
    public struct BuiltinContext: Sendable {
        public let base: Context
        public let desktop: BuiltinDesktop?
        public let locale: BuiltinLocale
        public let layout: BuiltinLayout
        public let storage: BuiltinStorage

        public init(
            base: Context,
            desktop: BuiltinDesktop? = nil,
            locale: BuiltinLocale? = nil,
            layout: BuiltinLayout? = nil,
            storage: BuiltinStorage? = nil
        ) {
            self.base = base
            self.desktop = desktop ?? base.desktop.map { BuiltinDesktop(base: $0) }
            self.locale = locale ?? BuiltinLocale(base: base.locale)
            self.layout = layout ?? BuiltinLayout(base: base.layout)
            self.storage = storage ?? BuiltinStorage(base: base.storage, store: { key, opts in
                base.storage.store(key, opts.base)
            })
        }
    }

    /// Projects a window `Context` into `BuiltinContext` for built-in plugins.
    // parity: plugin/src/gui/builtin.ts#builtinContext [status=implemented hash=b9b766135a80]
    public static func builtinContext(_ ctx: Context) -> BuiltinContext {
        BuiltinContext(base: ctx)
    }

    /// Legacy migration source for built-in main-process stores.
    // parity: plugin/src/gui/builtin.ts#MainStoreFrom [status=implemented hash=5b3dee3587af]
    public enum MainStoreFrom: Equatable, Hashable, Sendable, Codable {
        case settings(key: String, file: String? = nil)
        case state(namespace: String, key: String)
    }

    /// Main-process storage extended with legacy migration sources.
    // parity: plugin/src/gui/builtin.ts#BuiltinMainStorage [status=adapted hash=3860a502d762]
    public struct BuiltinMainStorage: Sendable {
        public let base: MainStorage
        public let store: @Sendable (_ key: String, _ initial: JSONValue, _ from: [MainStoreFrom]) -> Persisted<JSONValue>

        public init(
            base: MainStorage,
            store: @escaping @Sendable (_ key: String, _ initial: JSONValue, _ from: [MainStoreFrom]) -> Persisted<JSONValue>
        ) {
            self.base = base
            self.store = store
        }
    }

    /// App restart & handoff lifecycle controller for built-in main plugins.
    // parity: plugin/src/gui/builtin.ts#Lifecycle [status=implemented hash=79481aa19a8e]
    public struct Lifecycle: Sendable {
        public let restart: @Sendable ((@Sendable () async throws -> Void)?) async throws -> Void

        public init(restart: @escaping @Sendable ((@Sendable () async throws -> Void)?) async throws -> Void = { handoff in
            if let handoff { try await handoff() }
        }) {
            self.restart = restart
        }
    }

    /// Built-in main context with storage migrations and restart lifecycle.
    // parity: plugin/src/gui/builtin.ts#BuiltinMainContext [status=implemented hash=fa8ae92687ce]
    public struct BuiltinMainContext: Sendable {
        public let base: MainContext
        public let storage: BuiltinMainStorage
        public let lifecycle: Lifecycle

        public init(base: MainContext, storage: BuiltinMainStorage? = nil, lifecycle: Lifecycle = Lifecycle()) {
            self.base = base
            self.storage = storage ?? BuiltinMainStorage(base: base.storage, store: { key, initial, _ in
                base.storage.store(key, initial)
            })
            self.lifecycle = lifecycle
        }
    }

    /// Projects a `MainContext` into `BuiltinMainContext`.
    // parity: plugin/src/gui/builtin.ts#builtinMainContext [status=implemented hash=2cbbb2508c0f]
    public static func builtinMainContext(_ ctx: MainContext) -> BuiltinMainContext {
        BuiltinMainContext(base: ctx)
    }

    /// Built-in i18n catalog supporting lazy async locale loaders.
    // parity: plugin/src/gui/builtin.ts#BuiltinCatalog [status=implemented hash=76cd3fa6a4f1]
    public struct BuiltinCatalog: Sendable {
        public let en: Messages
        public let inlineLocales: [String: Messages]
        public let lazyLocales: [String: @Sendable () async throws -> Messages]

        public init(
            en: Messages,
            inlineLocales: [String: Messages] = [:],
            lazyLocales: [String: @Sendable () async throws -> Messages] = [:]
        ) {
            self.en = en
            self.inlineLocales = inlineLocales
            self.lazyLocales = lazyLocales
        }
    }

    /// Converts a `BuiltinCatalog` into an eager `Catalog` snapshot.
    // parity: plugin/src/gui/builtin.ts#builtinCatalog [status=adapted hash=a0d3829c2787]
    public static func builtinCatalog(_ catalog: BuiltinCatalog) -> Catalog {
        Catalog(en: catalog.en, locales: catalog.inlineLocales)
    }

    // MARK: - gui/host.ts

    /// Composed GUI plugin entry managed by the desktop/web host.
    // parity: plugin/src/gui/host.ts#Entry [status=implemented hash=ea7fb5a56b1a]
    public struct Entry: Sendable {
        public let id: String
        public let declarations: Declarations
        public let builtinStores: [String: BuiltinStoreDeclaration]?
        public let windowEntry: (@Sendable () async throws -> Setup)?
        public let mainEntry: (@Sendable () async throws -> MainSetup)?

        public init(
            id: String,
            declarations: Declarations = Declarations(),
            builtinStores: [String: BuiltinStoreDeclaration]? = nil,
            windowEntry: (@Sendable () async throws -> Setup)? = nil,
            mainEntry: (@Sendable () async throws -> MainSetup)? = nil
        ) {
            self.id = id
            self.declarations = declarations
            self.builtinStores = builtinStores
            self.windowEntry = windowEntry
            self.mainEntry = mainEntry
        }
    }

    /// Composes built-in GUI plugin entries in deterministic order, binding each entry's `id`.
    // parity: plugin/src/gui/host.ts#compose [status=implemented hash=16a1b14097e3]
    public static func compose(_ entries: [(id: String, entry: Entry)]) -> [Entry] {
        entries.map { pair in
            Entry(
                id: pair.id,
                declarations: pair.entry.declarations,
                builtinStores: pair.entry.builtinStores,
                windowEntry: pair.entry.windowEntry,
                mainEntry: pair.entry.mainEntry
            )
        }
    }

    /// Returns whether a plugin runs on the given `os` (`nil` on web means only OS-agnostic plugins run).
    // parity: plugin/src/gui/host.ts#runsOn [status=implemented hash=5db43a2b463c]
    public static func runsOn(_ declarations: Declarations, os: OS?) -> Bool {
        guard let supported = declarations.os else { return true }
        guard let os else { return false }
        return supported.contains(os)
    }

    /// Formats the canonical app-wide icon name `<plugin>:<name>`.
    // parity: plugin/src/gui/host.ts#pluginIconName [status=implemented hash=b75a98f1243b]
    public static func pluginIconName(plugin: String, name: String) -> PluginIconName {
        PluginIconName(rawValue: "\(plugin):\(name)")
    }

    /// Explicit saved enable/disable state row for a GUI plugin.
    // parity: plugin/src/gui/host.ts#EnableState [status=implemented hash=d2435eae5533]
    public struct EnableState: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let enabled: Bool

        public init(id: String, enabled: Bool) {
            self.id = id
            self.enabled = enabled
        }
    }

    /// Resolves GUI enable state: built-ins always run; other plugins follow saved rows (defaulting to enabled).
    // parity: plugin/src/gui/host.ts#pluginEnabled [status=implemented hash=e4c847bdd9ac]
    public static func pluginEnabled(id: String, builtin: Bool, state: [EnableState]) -> Bool {
        if builtin { return true }
        return state.first(where: { $0.id == id })?.enabled ?? true
    }

    private static let nodeBuiltins: Set<String> = [
        "assert", "assert/strict", "async_hooks", "buffer", "child_process", "cluster", "console", "constants",
        "crypto", "dgram", "diagnostics_channel", "dns", "dns/promises", "domain", "events", "fs", "fs/promises",
        "http", "http2", "https", "inspector", "inspector/promises", "module", "net", "os", "path", "path/posix",
        "path/win32", "perf_hooks", "process", "punycode", "querystring", "readline", "readline/promises", "repl",
        "stream", "stream/consumers", "stream/promises", "stream/web", "string_decoder", "sys", "timers",
        "timers/promises", "tls", "trace_events", "tty", "url", "util", "util/types", "v8", "vm", "wasi",
        "worker_threads", "zlib",
    ]

    /// Returns true for `electron`, `node:*` specifiers, and Node.js built-in modules only available in main.
    // parity: plugin/src/gui/host.ts#mainOnlyModule [status=implemented hash=dab6dcd2bf91]
    public static func mainOnlyModule(_ name: String) -> Bool {
        name == "electron" || name.hasPrefix("node:") || nodeBuiltins.contains(name)
    }

    /// Placeholder value returned by `inertModule(_:)` for modules unavailable in the current process.
    // parity: plugin/src/gui/host.ts#InertModule [status=adapted hash=f49ab048179a]
    public struct InertModule: Equatable, Hashable, Sendable, CustomStringConvertible {
        public let moduleName: String

        public init(moduleName: String) {
            self.moduleName = moduleName
        }

        public var description: String {
            "[inert module \(moduleName)]"
        }
    }

    /// Constructs an inert module placeholder labeled `[inert module <name>]`.
    // parity: plugin/src/gui/host.ts#inertModule [status=adapted hash=22770286913e]
    public static func inertModule(_ name: String) -> InertModule {
        InertModule(moduleName: name)
    }

    /// Checked result of evaluating a plugin's `./gui-experimental` bundle.
    // parity: plugin/src/gui/host.ts#PluginBundle [status=implemented hash=52aa8dfecbdc]
    public struct PluginBundle: Sendable {
        public let definition: Declarations
        public let setup: Setup?
        public let main: MainSetup?

        public init(definition: Declarations, setup: Setup? = nil, main: MainSetup? = nil) {
            self.definition = definition
            self.setup = setup
            self.main = main
        }
    }

    /// Evaluating host context passed to `evaluatePluginBundle`.
    // parity: plugin/src/gui/host.ts#PluginBundleHost [status=adapted hash=fab817db03d4]
    public struct PluginBundleHost: Sendable {
        public enum ProcessKind: String, Equatable, Hashable, Sendable, Codable {
            case window
            case main
        }

        public let process: ProcessKind
        public let requireModule: @Sendable (String) throws -> AnySendableValue
        public let evaluate: (@Sendable (_ code: String) throws -> PluginBundle)?

        public init(
            process: ProcessKind,
            requireModule: @escaping @Sendable (String) throws -> AnySendableValue = { name in
                .string("[inert module \(name)]")
            },
            evaluate: (@Sendable (_ code: String) throws -> PluginBundle)? = nil
        ) {
            self.process = process
            self.requireModule = requireModule
            self.evaluate = evaluate
        }
    }

    public enum BundleEvaluationError: Error, Equatable, Sendable, CustomStringConvertible {
        case emptyBundle
        case missingSetupOrMain
        case invalidDescriptor(String)

        public var description: String {
            switch self {
            case .emptyBundle:
                return "A plugin's ./gui-experimental bundle cannot be empty"
            case .missingSetupOrMain:
                return "A plugin's GUI must have a window `setup`, a `main` setup, or both"
            case .invalidDescriptor(let reason):
                return "A plugin's ./gui-experimental bundle must default-export a `Plugin.define`: \(reason)"
            }
        }
    }

    /// Evaluates and validates a plugin's `./gui-experimental` bundle via the host evaluator or JSON descriptor manifest.
    // parity: plugin/src/gui/host.ts#evaluatePluginBundle [status=adapted hash=cb8c247d3c8c]
    public static func evaluatePluginBundle(_ code: String, host: PluginBundleHost) throws -> PluginBundle {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BundleEvaluationError.emptyBundle
        }
        if let evaluator = host.evaluate {
            let bundle = try evaluator(trimmed)
            guard bundle.setup != nil || bundle.main != nil else {
                throw BundleEvaluationError.missingSetupOrMain
            }
            return bundle
        }
        // Support declarative JSON bundle descriptors directly in pure Swift runtimes.
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) {
            let declarations = try JSONDecoder().decode(Declarations.self, from: data)
            return PluginBundle(
                definition: declarations,
                setup: { _ in nil },
                main: nil
            )
        }
        throw BundleEvaluationError.invalidDescriptor("No JS evaluator attached to \(host.process.rawValue) host")
    }

    /// Returns whether `id` is free to be claimed by a third-party GUI plugin (cannot collide with `"opencode"` or any built-in prefix).
    // parity: plugin/src/gui/host.ts#pluginIdAvailable [status=implemented hash=ecd527fa7c83]
    public static func pluginIdAvailable(_ id: String, builtins: [Entry]) -> Bool {
        let reservedIDs = ["opencode"] + builtins.map(\.id)
        return reservedIDs.allSatisfy { taken in
            id != taken && !id.hasPrefix("\(taken).") && !taken.hasPrefix("\(id).")
        }
    }

    /// Layout rectangle and visual chrome measured for an embedded view.
    // parity: plugin/src/gui/host.ts#BridgeLayout [status=implemented hash=fc33f273a054]
    public struct BridgeLayout: Equatable, Hashable, Sendable, Codable {
        public struct Rect: Equatable, Hashable, Sendable, Codable {
            public let x: Double
            public let y: Double
            public let width: Double
            public let height: Double

            public init(x: Double, y: Double, width: Double, height: Double) {
                self.x = x
                self.y = y
                self.width = width
                self.height = height
            }
        }

        public struct Viewport: Equatable, Hashable, Sendable, Codable {
            public let width: Double
            public let height: Double

            public init(width: Double, height: Double) {
                self.width = width
                self.height = height
            }
        }

        public struct Border: Equatable, Hashable, Sendable, Codable {
            public let color: [Double]
            public let width: Double

            public init(color: [Double], width: Double) {
                self.color = color
                self.width = width
            }
        }

        public let visible: Bool
        public let bounds: Rect?
        public let clip: Rect?
        public let viewport: Viewport?
        public let background: [Double]?
        public let radius: Double?
        public let border: Border?

        public init(
            visible: Bool,
            bounds: Rect? = nil,
            clip: Rect? = nil,
            viewport: Viewport? = nil,
            background: [Double]? = nil,
            radius: Double? = nil,
            border: Border? = nil
        ) {
            self.visible = visible
            self.bounds = bounds
            self.clip = clip
            self.viewport = viewport
            self.background = background
            self.radius = radius
            self.border = border
        }
    }

    /// Installed GUI plugin inventory row published by main.
    // parity: plugin/src/gui/host.ts#Installed [status=implemented hash=77c094bf170b]
    public struct Installed: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let builtin: Bool
        public let enabled: Bool
        public let error: String?
        public let server: Bool?
        public let tui: Bool?
        public let unsupported: Bool?

        public init(
            id: String,
            builtin: Bool,
            enabled: Bool,
            error: String? = nil,
            server: Bool? = nil,
            tui: Bool? = nil,
            unsupported: Bool? = nil
        ) {
            self.id = id
            self.builtin = builtin
            self.enabled = enabled
            self.error = error
            self.server = server
            self.tui = tui
            self.unsupported = unsupported
        }
    }

    /// Returns whether a server `PluginSchema.Info` ships an active non-builtin `./gui-experimental` bundle.
    // parity: plugin/src/gui/host.ts#shipsPluginGui [status=implemented hash=fc761aabb003]
    public static func shipsPluginGui(_ plugin: PluginSchema.Info) -> Bool {
        guard let id = plugin.id, !id.rawValue.isEmpty else { return false }
        if case .builtin = plugin.source { return false }
        guard case .active = plugin.state else { return false }
        return plugin.features.gui == true
    }

    /// Server plugin GUI bundle transferred over the desktop bridge.
    // parity: plugin/src/gui/host.ts#BridgePluginGui [status=implemented hash=5c378c23d39a]
    public struct BridgePluginGui: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let revision: String
        public let code: String
        public let options: PluginOptions

        public init(id: String, revision: String, code: String, options: PluginOptions = [:]) {
            self.id = id
            self.revision = revision
            self.code = code
            self.options = options
        }
    }

    /// Active server plugin GUIs and reserved-ID conflicts reported by main.
    // parity: plugin/src/gui/host.ts#BridgePluginGuis [status=implemented hash=009c347c0395]
    public struct BridgePluginGuis: Equatable, Hashable, Sendable, Codable {
        public let plugins: [BridgePluginGui]
        public let reserved: [String]

        public init(plugins: [BridgePluginGui] = [], reserved: [String] = []) {
            self.plugins = plugins
            self.reserved = reserved
        }
    }

    /// Published native menubar item sent to renderer windows.
    // parity: plugin/src/gui/host.ts#BridgeMenubarItem [status=implemented hash=b55fd6a32bce]
    public struct BridgeMenubarItem: Equatable, Hashable, Sendable, Codable {
        public let menu: String
        public let id: String
        public let label: String
        public let after: String?
        public let enabled: Bool

        public init(menu: String, id: String, label: String, after: String? = nil, enabled: Bool = true) {
            self.menu = menu
            self.id = id
            self.label = label
            self.after = after
            self.enabled = enabled
        }
    }

    /// Push message sent from desktop main process to renderer windows.
    // parity: plugin/src/gui/host.ts#BridgeMessage [status=implemented hash=d3f8620c16bb]
    public enum BridgeMessage: Equatable, Hashable, Sendable, Codable {
        case state(ipc: String, state: JSONValue)
        case event(ipc: String, name: String, data: JSONValue)
        case available(ipc: String, available: Bool)
        case installed(list: [Installed])
        case focus(focused: Bool)
        case pluginGuis(BridgePluginGuis)
        case menubarItems(items: [BridgeMenubarItem])
    }

    /// Preload bridge interface connecting desktop main and renderer hosts.
    // parity: plugin/src/gui/host.ts#Bridge [status=adapted hash=191b953cb4f6]
    public struct Bridge: Sendable {
        public let packaged: Bool
        public let call: @Sendable (_ ipc: String, _ method: String, _ input: JSONValue?, _ signal: AbortSignal?) async throws -> JSONValue
        public let subscribe: @Sendable (_ ipc: String) async throws -> (available: Bool, state: JSONValue?)
        public let on: @Sendable (@escaping @Sendable (BridgeMessage) -> Void) -> @Sendable () -> Void
        public let embed: @Sendable (_ id: String, _ layout: BridgeLayout?) -> Void
        public let capture: @Sendable (_ id: String) async -> [UInt8]?
        public let runMenubarItem: @Sendable (_ id: String) -> Void
        public let pluginGuis: @Sendable () async throws -> BridgePluginGuis
        public let listInstalled: @Sendable () async throws -> [Installed]
        public let enable: @Sendable (String) async throws -> Void
        public let disable: @Sendable (String) async throws -> Void
        public let reload: @Sendable (String) async throws -> Void

        public init(
            packaged: Bool = false,
            call: @escaping @Sendable (_ ipc: String, _ method: String, _ input: JSONValue?, _ signal: AbortSignal?) async throws -> JSONValue = { _, _, _, _ in .null },
            subscribe: @escaping @Sendable (_ ipc: String) async throws -> (available: Bool, state: JSONValue?) = { _ in (false, nil) },
            on: @escaping @Sendable (@escaping @Sendable (BridgeMessage) -> Void) -> @Sendable () -> Void = { _ in {} },
            embed: @escaping @Sendable (_ id: String, _ layout: BridgeLayout?) -> Void = { _, _ in },
            capture: @escaping @Sendable (_ id: String) async -> [UInt8]? = { _ in nil },
            runMenubarItem: @escaping @Sendable (_ id: String) -> Void = { _ in },
            pluginGuis: @escaping @Sendable () async throws -> BridgePluginGuis = { BridgePluginGuis() },
            listInstalled: @escaping @Sendable () async throws -> [Installed] = { [] },
            enable: @escaping @Sendable (String) async throws -> Void = { _ in },
            disable: @escaping @Sendable (String) async throws -> Void = { _ in },
            reload: @escaping @Sendable (String) async throws -> Void = { _ in }
        ) {
            self.packaged = packaged
            self.call = call
            self.subscribe = subscribe
            self.on = on
            self.embed = embed
            self.capture = capture
            self.runMenubarItem = runMenubarItem
            self.pluginGuis = pluginGuis
            self.listInstalled = listInstalled
            self.enable = enable
            self.disable = disable
            self.reload = reload
        }
    }

    // MARK: - gui/updater.ts

    /// App-wide updater state synchronized across all desktop windows.
    // parity: plugin/src/gui/updater.ts#UpdaterState [status=implemented hash=7ecc227aa3cc]
    public enum UpdaterState: Equatable, Hashable, Sendable, Codable {
        case disabled
        case idle
        case checking
        case downloading(version: String)
        case ready(version: String)
        case downloadRequired(version: String)
        case upToDate
        case installing(version: String)
        case error(message: String)
    }

    /// Built-in IPC contract for the desktop app updater (`updater`).
    // parity: plugin/src/gui/updater.ts#Updater [status=implemented hash=2314dcad14e9]
    public static let Updater = Ipc.define(
        IpcSpec(
            id: "updater",
            state: .named("UpdaterState"),
            methods: [
                "check": IpcMethod(output: .named("UpdaterState")),
                "install": IpcMethod(),
            ],
            events: [
                "check": .named("Null"),
            ]
        )
    )

    // MARK: - gui/vite.ts

    /// Build configuration options for bundling a plugin's `./gui-experimental` CJS output.
    // parity: plugin/src/gui/vite.ts#GuiOptions [status=implemented hash=8bf211e40665]
    public struct GuiOptions: Equatable, Hashable, Sendable, Codable {
        public let entry: String?
        public let outFile: String?

        public init(entry: String? = nil, outFile: String? = nil) {
            self.entry = entry
            self.outFile = outFile
        }
    }

    /// Descriptor returned by `gui(options:)` modeling the Vite build preset's external module policy.
    public struct ViteGuiPreset: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let entry: String
        public let outFile: String
        public let format: String
        public let externalModules: [String]

        public init(name: String, entry: String, outFile: String, format: String, externalModules: [String]) {
            self.name = name
            self.entry = entry
            self.outFile = outFile
            self.format = format
            self.externalModules = externalModules
        }

        /// Validates whether `source` is allowed to be resolved as external or raises an error for forbidden unprovided modules.
        public func isAllowedExternal(_ source: String) -> Bool {
            externalModules.contains(source) || mainOnlyModule(source)
        }

        public func isForbiddenUnprovided(_ source: String) -> Bool {
            if isAllowedExternal(source) { return false }
            return source.hasPrefix("effect/") || source.hasPrefix("solid-js/") || source.hasPrefix("@opencode/")
        }
    }

    /// Constructs the Vite GUI plugin bundle preset descriptor (`entry`, `outFile`, external module rules).
    // parity: plugin/src/gui/vite.ts#gui [status=adapted hash=509105fa50a8]
    public static func gui(options: GuiOptions = GuiOptions()) -> ViteGuiPreset {
        ViteGuiPreset(
            name: "opencode-gui",
            entry: options.entry ?? "src/gui.tsx",
            outFile: options.outFile ?? "dist/gui-experimental.cjs",
            format: "cjs",
            externalModules: pluginSharedModules + pluginWindowModules
        )
    }

    // MARK: - GUI Plugin Descriptor Host Registry

    /// In-process host managing GUI plugin registration, OS filtering, enable state, reserved IDs, and registry contributions.
    public final class DescriptorHost: Sendable {
        private struct Contribution: Sendable {
            let token: UInt64
            let pluginID: String
            let item: any Sendable
        }

        private struct ActivePlugin: Sendable {
            let entry: Entry
            let scope: Scope
            let builtin: Bool
        }

        private struct State: Sendable {
            var nextToken: UInt64 = 1
            var active: [String: ActivePlugin] = [:]
            var registries: [String: [Contribution]] = [:]
            var contracts: [String: (pluginID: String, value: any Sendable, generation: Int)] = [:]
            var enableState: [EnableState] = []
        }

        private let state = Mutex(State())
        public let os: OS?

        public init(os: OS? = .macos) {
            self.os = os
        }

        /// Activates a GUI plugin `Entry` if supported on `self.os`, enabled, and not colliding with a reserved/builtin ID.
        @discardableResult
        public func activate(
            _ entry: Entry,
            builtin: Bool = false,
            builtins: [Entry] = [],
            options: PluginOptions = [:]
        ) async throws -> Bool {
            if !builtin && !pluginIdAvailable(entry.id, builtins: builtins) {
                return false
            }
            guard runsOn(entry.declarations, os: os) else {
                return false
            }
            let isEnabled = state.withLock { s in
                pluginEnabled(id: entry.id, builtin: builtin, state: s.enableState)
            }
            guard isEnabled else {
                return false
            }

            let scope = Scope.make(entry.id)
            let pluginID = entry.id

            let addContrib: @Sendable (String, any Sendable) -> Cleanup = { [self, scope] registryID, item in
                let token = self.state.withLock { s -> UInt64 in
                    let id = s.nextToken
                    s.nextToken &+= 1
                    s.registries[registryID, default: []].append(
                        Contribution(token: id, pluginID: pluginID, item: item)
                    )
                    return id
                }
                let withdraw: Cleanup = { [self] in
                    self.state.withLock { s in
                        s.registries[registryID]?.removeAll { $0.token == token }
                    }
                }
                scope.addFinalizer(label: "registry:\(registryID)", withdraw)
                return withdraw
            }

            let listContrib: @Sendable (String) -> [any Sendable] = { [self] registryID in
                self.state.withLock { s in
                    (s.registries[registryID] ?? []).map(\.item)
                }
            }

            let provideContract: @Sendable (String, any Sendable) -> Cleanup = { [self, scope] contractID, impl in
                self.state.withLock { s in
                    let nextGen = (s.contracts[contractID]?.generation ?? 0) + 1
                    s.contracts[contractID] = (pluginID, impl, nextGen)
                }
                let withdraw: Cleanup = { [self] in
                    self.state.withLock { s in
                        if s.contracts[contractID]?.pluginID == pluginID {
                            s.contracts.removeValue(forKey: contractID)
                        }
                    }
                }
                scope.addFinalizer(label: "contract:\(contractID)", withdraw)
                return withdraw
            }

            let useToken: @Sendable (String) -> @Sendable () -> Live<any Sendable> = { [self] tokenID in
                { [self] in
                    self.state.withLock { s in
                        if let entry = s.contracts[tokenID] {
                            return .active(value: entry.value, generation: entry.generation)
                        }
                        return .inactive(reason: .disabled)
                    }
                }
            }

            let context = Context(
                id: pluginID,
                options: options,
                signal: scope.signal,
                app: App(platform: os == nil ? .web : .desktop),
                addContribution: addContrib,
                listContributions: listContrib,
                provideContract: provideContract,
                useToken: useToken
            )

            var icons: [String: PluginIconName] = [:]
            for iconKey in (entry.declarations.icons ?? [:]).keys {
                icons[iconKey] = pluginIconName(plugin: pluginID, name: iconKey)
            }
            let setupCtx = SetupContext(base: context, stores: [:], icons: icons)

            if let loadWindow = entry.windowEntry {
                let setup = try await loadWindow()
                let cleanup = $PluginContext.withValue(context) {
                    setup(setupCtx)
                }
                if let cleanup {
                    scope.addFinalizer(label: "window-setup", cleanup)
                }
            }

            if let loadMain = entry.mainEntry {
                let mainSetup = try await loadMain()
                let mainCtx = MainContext(
                    id: pluginID,
                    options: options,
                    signal: scope.signal,
                    onCleanup: { fn in scope.addFinalizer(label: "main-cleanup", fn) }
                )
                if let cleanup = try await mainSetup(mainCtx) {
                    scope.addFinalizer(label: "main-setup", cleanup)
                }
            }

            state.withLock { s in
                s.active[pluginID] = ActivePlugin(entry: entry, scope: scope, builtin: builtin)
            }
            return true
        }

        /// Deactivates a GUI plugin and runs its scope finalizers (withdrawing all contributions).
        public func deactivate(id: String) async {
            let active = state.withLock { s in s.active.removeValue(forKey: id) }
            if let active {
                await active.scope.close()
            }
        }

        public func setEnableState(_ rows: [EnableState]) {
            state.withLock { s in s.enableState = rows }
        }

        public func list<T: Sendable>(_ registry: Registry<T>) -> [T] {
            state.withLock { s in
                (s.registries[registry.id] ?? []).compactMap { $0.item as? T }
            }
        }

        public func activePluginIDs() -> [String] {
            state.withLock { s in Array(s.active.keys).sorted() }
        }
    }
}

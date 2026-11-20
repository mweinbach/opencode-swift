#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil
import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables
import OpenTUITerminal
import OpenTUIView

// MARK: - TUI Config & Keybinds (`packages/tui/src/config/*`)

/// TUI configuration schemas, keybind definitions, V1 config/keybind compatibility, and runtime resolution.
public enum TUIConfig {
    public typealias KeymapTarget = String
    public typealias KeymapEventType = OpenTUIKeyEventAdapter

    public enum ConfigError: Error, Equatable, Sendable, CustomStringConvertible {
        case unrecognizedKeybinds([String])
        case missingContext(String)
        case invalidStorageSegment(String)
        case updatesUnavailable

        public var description: String {
            switch self {
            case .unrecognizedKeybinds(let keys):
                let plural = keys.count == 1 ? "" : "s"
                return "Unrecognized keybind\(plural): \(keys.joined(separator: ", "))"
            case .missingContext(let name):
                return "\(name) is missing"
            case .invalidStorageSegment(let seg):
                return "Invalid storage segment: \(seg)"
            case .updatesUnavailable:
                return "Config updates are not available"
            }
        }
    }

    // MARK: - Keybind (`packages/tui/src/config/keybind.ts`)

    public enum Keybind {
        public struct BindingObject: Equatable, Hashable, Sendable, Codable {
            public var key: String
            public var event: String?
            public var preventDefault: Bool?
            public var `fallthrough`: Bool?

            public init(
                key: String,
                event: String? = nil,
                preventDefault: Bool? = nil,
                fallthrough isFallthrough: Bool? = nil
            ) {
                self.key = key
                self.event = event
                self.preventDefault = preventDefault
                self.`fallthrough` = isFallthrough
            }
        }

        public enum BindingItem: Equatable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
            case sequence(String)
            case stroke(KeyStrokeInput)
            case object(BindingObject)

            public init(stringLiteral value: String) {
                self = .sequence(value)
            }

            func toConfigItem() -> BindingConfigItem<KeymapTarget, KeymapEventType> {
                switch self {
                case .sequence(let s):
                    return .key(.string(s))
                case .stroke(let st):
                    return .key(.stroke(st))
                case .object(let obj):
                    return .binding(Binding<KeymapTarget, KeymapEventType>(
                        key: .string(obj.key),
                        event: obj.event == "release" ? .release : .press,
                        preventDefault: obj.preventDefault,
                        fallthrough: obj.`fallthrough`
                    ))
                }
            }
        }

        /// Schema value accepted for each keybind entry (`false`, `"none"`, single item, or array of items).
        // parity: tui/src/config/keybind.ts#BindingValueSchema [status=implemented hash=62192661d78a]
        public enum BindingValueSchema: Equatable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, ExpressibleByBooleanLiteral {
            case disabled
            case item(BindingItem)
            case items([BindingItem])

            public init(stringLiteral value: String) {
                if value == "none" {
                    self = .disabled
                } else {
                    self = .item(.sequence(value))
                }
            }

            public init(booleanLiteral value: Bool) {
                self = value ? .items([]) : .disabled
            }

            public static let none: BindingValueSchema = .disabled

            public var stringValue: String? {
                switch self {
                case .disabled: return "none"
                case .item(.sequence(let s)): return s
                case .item(.object(let o)): return o.key
                default: return nil
                }
            }

            func toOpenTUIBindingValue() -> BindingValue<KeymapTarget, KeymapEventType> {
                switch self {
                case .disabled:
                    return .disabled
                case .item(let item):
                    return .item(item.toConfigItem())
                case .items(let items):
                    return .items(items.map { $0.toConfigItem() })
                }
            }
        }

        public struct Definition: Equatable, Hashable, Sendable {
            public let defaultValue: BindingValueSchema
            public let description: String

            public init(_ defaultValue: BindingValueSchema, _ description: String) {
                self.defaultValue = defaultValue
                self.description = description
            }
        }

        // parity: tui/src/config/keybind.ts#LeaderDefault [status=implemented hash=83ca3f4e2efe]
        public static let LeaderDefault = "ctrl+x"

        // parity: tui/src/config/keybind.ts#Definitions [status=implemented hash=889162884343]
        public static let Definitions: [String: Definition] = [
            "leader": Definition(.item(.sequence(LeaderDefault)), "Leader key for keybind combinations"),
            "app.exit": Definition("ctrl+c,ctrl+d,<leader>q", "Exit the application"),
            "app.clear": Definition("ctrl+l", "Clear the screen in mini"),
            "app.debug": Definition("none", "Toggle debug panel"),
            "app.console": Definition("none", "Toggle console"),
            "app.scrap": Definition("none", "Open scrap screen"),
            "app.toggle.animations": Definition("none", "Toggle animations"),
            "app.toggle.file_context": Definition("none", "Toggle file context"),
            "app.toggle.diffwrap": Definition("none", "Toggle diff wrapping"),
            "app.toggle.paste_summary": Definition("none", "Toggle paste summary"),
            "command.palette.show": Definition("ctrl+p", "List available commands"),
            "help.show": Definition("none", "Open help dialog"),
            "docs.open": Definition("none", "Open documentation"),
            "opencode.settings": Definition("none", "Open settings"),
            "server.pair": Definition("none", "Pair device"),
            "service.restart": Definition("none", "Restart service"),
            "location.reload": Definition("none", "Reload configuration"),
            "diff.open": Definition("none", "Open diff viewer"),
            "diff.close": Definition("escape,q", "Close diff viewer"),
            "diff.down": Definition("j,down", "Move diff viewer down"),
            "diff.up": Definition("k,up", "Move diff viewer up"),
            "diff.page.down": Definition("pagedown,ctrl+f", "Page diff viewer down"),
            "diff.page.up": Definition("pageup,ctrl+b", "Page diff viewer up"),
            "diff.half_page.down": Definition("ctrl+d", "Scroll diff viewer down half a page"),
            "diff.half_page.up": Definition("ctrl+u", "Scroll diff viewer up half a page"),
            "diff.first": Definition("gg,home", "Go to the start of the diff"),
            "diff.last": Definition("shift+g,end", "Go to the end of the diff"),
            "diff.toggle": Definition("none", "Deprecated: file tree is mouse-controlled"),
            "diff.expand": Definition("none", "Deprecated: file tree is mouse-controlled"),
            "diff.expand_all": Definition("none", "Deprecated: file tree is mouse-controlled"),
            "diff.collapse": Definition("none", "Deprecated: file tree is mouse-controlled"),
            "diff.switch_focus": Definition("none", "Deprecated: keyboard navigation always controls the diff"),
            "diff.next_hunk": Definition("]", "Jump to next diff hunk"),
            "diff.previous_hunk": Definition("[", "Jump to previous diff hunk"),
            "diff.next_file": Definition("n,alt+down", "Jump to next diff file"),
            "diff.previous_file": Definition("p,alt+up", "Jump to previous diff file"),
            "diff.toggle_file_tree": Definition("b", "Toggle diff viewer file tree"),
            "diff.single_patch": Definition("s", "Toggle single patch view"),
            "diff.switch_source": Definition("d", "Switch diff viewer source"),
            "diff.toggle_view": Definition("v", "Toggle diff viewer split or unified view"),
            "diff.toggle_fullscreen": Definition("f", "Toggle diff viewer full screen"),
            "diff.mark_reviewed": Definition("m", "Toggle selected diff file reviewed"),
            "diff.help": Definition("?,shift+?,shift+/", "Show more diff viewer shortcuts"),
            "prompt.editor": Definition("<leader>e", "Open external editor"),
            "theme.switch": Definition("none", "List available themes"),
            "theme.switch_mode": Definition("none", "Switch between light and dark theme mode"),
            "theme.mode.lock": Definition("none", "Lock or unlock theme mode"),
            "session.sidebar.toggle": Definition("<leader>b", "Toggle sidebar"),
            "pane.focus.left": Definition("<leader>left", "Focus session pane"),
            "pane.focus.right": Definition("<leader>right", "Focus right pane"),
            "terminal.select": Definition("<leader>down", "Select terminal"),
            "terminal.toggle": Definition("<leader>t", "Toggle terminal pane"),
            "terminal.close": Definition("<leader>up", "Close terminal pane"),
            "session.toggle.scrollbar": Definition("none", "Toggle session scrollbar"),
            "opencode.status": Definition("<leader>s", "View status"),
            "opencode.debug": Definition("none", "View debug info"),
            "session.export": Definition("<leader>x", "Export session to editor"),
            "session.copy": Definition("none", "Copy session transcript"),
            "session.copy.id": Definition("none", "Copy session ID"),
            "session.move": Definition("none", "Manage workspaces"),
            "session.new": Definition("<leader>n", "Create a new session"),
            "session.list": Definition("<leader>l", "List all sessions"),
            "open.menu": Definition("ctrl+o", "Open recent sessions and projects"),
            "session.tab.next": Definition("ctrl+tab,alt+down", "Switch to next open session tab"),
            "session.tab.previous": Definition("ctrl+shift+tab,alt+up", "Switch to previous open session tab"),
            "session.tab.history.back": Definition("none", "Go back in session tab history"),
            "session.tab.history.forward": Definition("ctrl+i", "Go forward in session tab history"),
            "session.tab.next_unread": Definition("alt+shift+down", "Switch to next unread session tab"),
            "session.tab.previous_unread": Definition("alt+shift+up", "Switch to previous unread session tab"),
            "session.tab.close": Definition("<leader>w", "Close current session tab"),
            "session.tab.reopen": Definition("ctrl+shift+t", "Reopen last closed session tab"),
            "session.timeline": Definition("<leader>g", "Show session timeline"),
            "session.fork": Definition("none", "Fork session from message"),
            "session.rename": Definition("ctrl+r", "Rename session"),
            "session.delete": Definition("ctrl+d", "Delete session"),
            "session.share": Definition("none", "Deprecated: session sharing was removed"),
            "session.unshare": Definition("none", "Deprecated: session sharing was removed"),
            "session.interrupt": Definition("escape", "Interrupt current session"),
            "session.background": Definition("ctrl+b", "Background blocking session tools"),
            "session.compact": Definition("<leader>c", "Compact the session"),
            "session.aside": Definition("none", "Ask a side question"),
            "session.cd": Definition("none", "Change working directory"),
            "session.queued_prompts": Definition("<leader>q", "Manage queued prompts"),
            "queued_prompt.undo": Definition("ctrl+u", "Undo queued prompt"),
            "queued_prompt.delete": Definition("ctrl+d", "Delete queued prompt"),
            "session.toggle.exploration_grouping": Definition("none", "Toggle related tool call grouping"),
            "session.verbosity.cycle": Definition("none", "Cycle transcript verbosity"),
            "session.child.first": Definition("down", "Toggle subagent picker"),
            "session.child.next": Definition("right", "Go to next child session"),
            "session.child.previous": Definition("left", "Go to previous child session"),
            "session.parent": Definition("up", "Go to parent session"),
            "session.pin.toggle": Definition("ctrl+f", "Pin or unpin session in the session list"),
            "session.quick_switch.1": Definition("<leader>1", "Switch to session in quick slot 1"),
            "session.quick_switch.2": Definition("<leader>2", "Switch to session in quick slot 2"),
            "session.quick_switch.3": Definition("<leader>3", "Switch to session in quick slot 3"),
            "session.quick_switch.4": Definition("<leader>4", "Switch to session in quick slot 4"),
            "session.quick_switch.5": Definition("<leader>5", "Switch to session in quick slot 5"),
            "session.quick_switch.6": Definition("<leader>6", "Switch to session in quick slot 6"),
            "session.quick_switch.7": Definition("<leader>7", "Switch to session in quick slot 7"),
            "session.quick_switch.8": Definition("<leader>8", "Switch to session in quick slot 8"),
            "session.quick_switch.9": Definition("<leader>9", "Switch to session in quick slot 9"),
            "session.tab.select.1": Definition("<leader>1,ctrl+1", "Switch to session tab 1"),
            "session.tab.select.2": Definition("<leader>2,ctrl+2", "Switch to session tab 2"),
            "session.tab.select.3": Definition("<leader>3,ctrl+3", "Switch to session tab 3"),
            "session.tab.select.4": Definition("<leader>4,ctrl+4", "Switch to session tab 4"),
            "session.tab.select.5": Definition("<leader>5,ctrl+5", "Switch to session tab 5"),
            "session.tab.select.6": Definition("<leader>6,ctrl+6", "Switch to session tab 6"),
            "session.tab.select.7": Definition("<leader>7,ctrl+7", "Switch to session tab 7"),
            "session.tab.select.8": Definition("<leader>8,ctrl+8", "Switch to session tab 8"),
            "session.tab.select.9": Definition("<leader>9,ctrl+9", "Switch to session tab 9"),
            "session.tab.select.10": Definition("<leader>0,ctrl+0", "Switch to session tab 10"),
            "stash.delete": Definition("ctrl+d", "Delete stash entry"),
            "model.dialog.provider": Definition("ctrl+a", "Open provider list from model dialog"),
            "model.dialog.favorite": Definition("ctrl+f", "Toggle model favorite status"),
            "model.dialog.usage": Definition("ctrl+u", "Open usage limits from model dialog"),
            "model.list": Definition("<leader>m", "List available models"),
            "model.cycle_recent": Definition("f2", "Next recently used model"),
            "model.cycle_recent_reverse": Definition("shift+f2", "Previous recently used model"),
            "model.cycle_favorite": Definition("none", "Next favorite model"),
            "model.cycle_favorite_reverse": Definition("none", "Previous favorite model"),
            "mcp.list": Definition("none", "List MCP servers"),
            "usage.show": Definition("none", "View usage limits"),
            "provider.connect": Definition("none", "Connect integration"),
            "agent.list": Definition("<leader>a", "List agents"),
            "agent.cycle": Definition("shift+tab", "Next agent"),
            "agent.cycle.reverse": Definition("none", "Previous agent"),
            "variant.cycle": Definition("ctrl+t", "Cycle model variants"),
            "variant.list": Definition("none", "List model variants"),
            "session.page.up": Definition("pageup,ctrl+alt+b,kppageup", "Scroll messages up by one page"),
            "session.page.down": Definition("pagedown,ctrl+alt+f,kppagedown", "Scroll messages down by one page"),
            "session.line.up": Definition("ctrl+alt+y", "Scroll messages up by one line"),
            "session.line.down": Definition("ctrl+alt+e", "Scroll messages down by one line"),
            "session.half.page.up": Definition("ctrl+alt+u", "Scroll messages up by half page"),
            "session.half.page.down": Definition("ctrl+alt+d", "Scroll messages down by half page"),
            "session.first": Definition("ctrl+g,home,alt+home,kphome", "Navigate to first message"),
            "session.last": Definition("ctrl+alt+g,end,kpend", "Navigate to last message"),
            "session.message.next": Definition("none", "Navigate to next message"),
            "session.message.previous": Definition("none", "Navigate to previous message"),
            "session.message.user.next": Definition("none", "Navigate to next user message"),
            "session.message.user.previous": Definition("none", "Navigate to previous user message"),
            "session.messages_last_user": Definition("alt+end", "Navigate to last user message"),
            "messages.copy": Definition("<leader>y", "Copy message"),
            "session.undo": Definition("<leader>u", "Undo message"),
            "session.redo": Definition("<leader>r", "Redo message"),
            "session.toggle.thinking": Definition("none", "Toggle thinking blocks visibility"),
            "prompt.submit": Definition("none", "Submit prompt"),
            "prompt.queue": Definition("<leader>return", "Queue prompt"),
            "prompt.editor_context.clear": Definition("none", "Clear editor context"),
            "prompt.images.view": Definition("<leader>i", "View image attachments"),
            "prompt.skills": Definition("none", "Open skill selector"),
            "prompt.stash": Definition("none", "Stash prompt"),
            "prompt.stash.pop": Definition("none", "Pop stashed prompt"),
            "prompt.stash.list": Definition("none", "List stashed prompts"),
            "prompt.clear": Definition("ctrl+c", "Clear input field"),
            "prompt.paste": Definition(.item(.object(BindingObject(key: "ctrl+v", preventDefault: false))), "Paste from clipboard"),
            "input.submit": Definition("return", "Submit input"),
            "input.newline": Definition("shift+return,ctrl+return,alt+return,ctrl+j", "Insert newline in input"),
            "input.move.left": Definition("left,ctrl+b", "Move cursor left in input"),
            "input.move.right": Definition("right,ctrl+f", "Move cursor right in input"),
            "input.move.up": Definition("up", "Move cursor up in input"),
            "input.move.down": Definition("down", "Move cursor down in input"),
            "input.select.left": Definition("shift+left", "Select left in input"),
            "input.select.right": Definition("shift+right", "Select right in input"),
            "input.select.up": Definition("shift+up", "Select up in input"),
            "input.select.down": Definition("shift+down", "Select down in input"),
            "input.line.home": Definition("ctrl+a", "Move to start of line in input"),
            "input.line.end": Definition("ctrl+e", "Move to end of line in input"),
            "input.select.line.home": Definition("ctrl+shift+a", "Select to start of line in input"),
            "input.select.line.end": Definition("ctrl+shift+e", "Select to end of line in input"),
            "input.visual.line.home": Definition("alt+a", "Move to start of visual line in input"),
            "input.visual.line.end": Definition("alt+e", "Move to end of visual line in input"),
            "input.select.visual.line.home": Definition("alt+shift+a", "Select to start of visual line in input"),
            "input.select.visual.line.end": Definition("alt+shift+e", "Select to end of visual line in input"),
            "input.buffer.home": Definition("none", "Move to start of buffer in input"),
            "input.buffer.end": Definition("none", "Move to end of buffer in input"),
            "input.select.buffer.home": Definition("shift+home", "Select to start of buffer in input"),
            "input.select.buffer.end": Definition("shift+end", "Select to end of buffer in input"),
            "input.delete.line": Definition("ctrl+shift+d", "Delete line in input"),
            "input.delete.to.line.end": Definition("ctrl+k", "Delete to end of line in input"),
            "input.delete.to.line.start": Definition("ctrl+u", "Delete to start of line in input"),
            "input.backspace": Definition("backspace,shift+backspace", "Backspace in input"),
            "input.delete": Definition("ctrl+d,delete,shift+delete", "Delete character in input"),
            "input.undo": Definition("ctrl+-,super+z", "Undo in input"),
            "input.redo": Definition("ctrl+.,super+shift+z", "Redo in input"),
            "input.word.forward": Definition("alt+f,alt+right,ctrl+right", "Move word forward in input"),
            "input.word.backward": Definition("alt+b,alt+left,ctrl+left", "Move word backward in input"),
            "input.select.word.forward": Definition("alt+shift+f,alt+shift+right", "Select word forward in input"),
            "input.select.word.backward": Definition("alt+shift+b,alt+shift+left", "Select word backward in input"),
            "input.delete.word.forward": Definition("alt+d,alt+delete,ctrl+delete", "Delete word forward in input"),
            "input.delete.word.backward": Definition("ctrl+w,ctrl+backspace,alt+backspace", "Delete word backward in input"),
            "input.select.all": Definition("super+a", "Select all in input"),
            "prompt.history.previous": Definition("up", "Previous history item"),
            "prompt.history.next": Definition("down", "Next history item"),
            "composer.subagent.up": Definition("up", "Previous subagent"),
            "composer.subagent.down": Definition("down", "Next subagent"),
            "composer.subagent.select": Definition("return", "Navigate to subagent"),
            "composer.subagent.interrupt": Definition("ctrl+d", "Interrupt subagent"),
            "composer.shell.up": Definition("up", "Previous shell"),
            "composer.shell.down": Definition("down", "Next shell"),
            "composer.shell.select": Definition("return", "View shell output"),
            "composer.shell.kill": Definition("ctrl+d", "Kill shell command"),
            "composer.script.up": Definition("up", "Previous script"),
            "composer.script.down": Definition("down", "Next script"),
            "composer.script.cancel": Definition("ctrl+d", "Cancel script"),
            "composer.terminal.up": Definition("up,k", "Previous terminal"),
            "composer.terminal.down": Definition("down,j", "Next terminal"),
            "composer.terminal.select": Definition("return", "Select terminal"),
            "dialog.select.prev": Definition("up,ctrl+p", "Move to previous dialog item"),
            "dialog.select.next": Definition("down,ctrl+n", "Move to next dialog item"),
            "dialog.select.page_up": Definition("pageup", "Move up one page in dialog"),
            "dialog.select.page_down": Definition("pagedown", "Move down one page in dialog"),
            "dialog.select.home": Definition("home", "Move to first dialog item"),
            "dialog.select.end": Definition("end", "Move to last dialog item"),
            "dialog.select.submit": Definition("return", "Submit selected dialog item"),
            "dialog.prompt.submit": Definition("return", "Submit dialog prompt"),
            "dialog.integration.rename": Definition("ctrl+r", "Rename integration account"),
            "dialog.integration.delete": Definition("ctrl+d", "Delete integration account"),
            "dialog.integration.copy": Definition("tab", "Copy authorization link"),
            "dialog.worktree.generate": Definition("tab", "Generate worktree name"),
            "dialog.move_session.new": Definition("ctrl+a", "New worktree"),
            "dialog.move_session.move": Definition("ctrl+m", "Move session to worktree"),
            "dialog.move_session.delete": Definition("ctrl+d", "Delete worktree"),
            "dialog.move_session.refresh": Definition("ctrl+r", "Refresh worktrees"),
            "prompt.autocomplete.prev": Definition("up,ctrl+p", "Move to previous autocomplete item"),
            "prompt.autocomplete.next": Definition("down,ctrl+n", "Move to next autocomplete item"),
            "prompt.autocomplete.hide": Definition("escape", "Hide autocomplete"),
            "prompt.autocomplete.select": Definition("return", "Select autocomplete item"),
            "prompt.autocomplete.complete": Definition("tab", "Complete autocomplete item"),
            "permission.prompt.fullscreen": Definition("ctrl+f", "Toggle permission prompt fullscreen"),
            "plugins.toggle": Definition("return", "Toggle plugin"),
            "dialog.mcp.toggle": Definition("space", "Toggle MCP server"),
            "dialog.plugins.error": Definition("space", "View plugin error"),
            "dialog.plugins.update": Definition("ctrl+u", "Update plugin from plugin dialog"),
            "dialog.plugins.check": Definition("ctrl+r", "Check for plugin updates from plugin dialog"),
            "terminal.suspend": Definition("ctrl+z", "Suspend terminal"),
            "terminal.title.toggle": Definition("none", "Toggle terminal title"),
            "plugins.list": Definition("none", "Open plugin manager dialog"),
            "which-key.toggle": Definition("ctrl+alt+k", "Toggle which-key panel"),
            "which-key.layout.toggle": Definition("ctrl+alt+shift+k", "Switch which-key layout"),
            "which-key.pending.toggle": Definition("ctrl+alt+shift+p", "Toggle which-key pending preview"),
            "which-key.group.previous": Definition("ctrl+alt+left,ctrl+alt+[", "Previous which-key group"),
            "which-key.group.next": Definition("ctrl+alt+right,ctrl+alt+]", "Next which-key group"),
            "which-key.scroll.up": Definition("ctrl+alt+up,ctrl+alt+p", "Scroll which-key up"),
            "which-key.scroll.down": Definition("ctrl+alt+down,ctrl+alt+n", "Scroll which-key down"),
            "which-key.page.up": Definition("ctrl+alt+pageup", "Page which-key up"),
            "which-key.page.down": Definition("ctrl+alt+pagedown", "Page which-key down"),
            "which-key.home": Definition("ctrl+alt+home", "Jump to first which-key binding"),
            "which-key.end": Definition("ctrl+alt+end", "Jump to last which-key binding"),
        ]

        // parity: tui/src/config/keybind.ts#KeybindOverrides [status=implemented hash=1475d09db8a4]
        public typealias KeybindOverrides = [String: BindingValueSchema]

        // parity: tui/src/config/keybind.ts#Descriptions [status=implemented hash=a2bf3990b34a]
        public static let Descriptions: [String: String] = Definitions.mapValues(\.description)

        // parity: tui/src/config/keybind.ts#Keybinds [status=implemented hash=88ec7ad81c3c]
        public typealias Keybinds = [String: BindingValueSchema]

        /// Read-only view over a compiled `OpenTUIKeymap.BindingLookup`.
        // parity: tui/src/config/keybind.ts#BindingLookupView [status=implemented hash=56be9ef08051]
        public struct BindingLookupView: Sendable, Equatable {
            private let lookup: any BindingLookup<KeymapTarget, KeymapEventType>
            public let rawKeybinds: Keybinds

            public init(lookup: any BindingLookup<KeymapTarget, KeymapEventType>, rawKeybinds: Keybinds) {
                self.lookup = lookup
                self.rawKeybinds = rawKeybinds
            }

            public var bindings: [Binding<KeymapTarget, KeymapEventType>] { lookup.bindings }
            public func get(_ command: String) -> [Binding<KeymapTarget, KeymapEventType>] { lookup.get(command) }
            public func has(_ command: String) -> Bool { lookup.has(command) }
            public func gather(_ name: String, commands: [String]) -> [Binding<KeymapTarget, KeymapEventType>] {
                lookup.gather(name, commands: commands)
            }
            public func pick(_ name: String, commands: [String]) -> [Binding<KeymapTarget, KeymapEventType>] {
                lookup.pick(name, commands: commands)
            }
            public func omit(_ name: String, commands: [String]) -> [Binding<KeymapTarget, KeymapEventType>] {
                lookup.omit(name, commands: commands)
            }

            public static func == (lhs: BindingLookupView, rhs: BindingLookupView) -> Bool {
                lhs.rawKeybinds == rhs.rawKeybinds
            }
        }

        // parity: tui/src/config/keybind.ts#toBindingConfig [status=implemented hash=155c3ece2171]
        public static func toBindingConfig(_ keybinds: Keybinds) -> BindingConfig<KeymapTarget, KeymapEventType> {
            keybinds.mapValues { $0.toOpenTUIBindingValue() }
        }

        // parity: tui/src/config/keybind.ts#defaultValue [status=implemented hash=439cfa7cfb7b]
        public static func defaultValue(_ name: String) -> BindingValueSchema? {
            Definitions[name]?.defaultValue
        }

        // parity: tui/src/config/keybind.ts#parse [status=implemented hash=68e0785969e4]
        public static func parse(_ keybinds: KeybindOverrides) throws(ConfigError) -> Keybinds {
            let invalid = unknownKeys(keybinds)
            if !invalid.isEmpty {
                throw .unrecognizedKeybinds(invalid)
            }
            var result: Keybinds = [:]
            result.reserveCapacity(Definitions.count)
            for (name, def) in Definitions {
                result[name] = keybinds[name] ?? def.defaultValue
            }
            return result
        }

        // parity: tui/src/config/keybind.ts#unknownKeys [status=implemented hash=8a4e526c64d3]
        public static func unknownKeys(_ input: [String: BindingValueSchema]) -> [String] {
            input.keys.filter { Definitions[$0] == nil }.sorted()
        }

        // parity: tui/src/config/keybind.ts#bindingDefaults [status=implemented hash=da623b8b3042]
        public static func bindingDefaults() -> BindingDefaults<KeymapTarget, KeymapEventType> {
            { context in
                if context.binding.fields["desc"] != nil { return nil }
                guard let desc = Descriptions[context.command] else { return nil }
                return ["desc": .string(desc)]
            }
        }
    }

    // MARK: - Main TUI Config (`packages/tui/src/config/index.tsx`)

    // parity: tui/src/config/index.tsx#Interface [status=implemented hash=745c14ec51fc]
    public protocol Interface: Sendable {
        var path: String? { get }
        func get() async throws -> Info
        func update(_ mutate: @escaping @Sendable (inout Info) -> Void) async throws -> Info
    }

    /// In-memory `TUIConfig.Interface` implementation useful for tests and embedded hosts.
    public final class InMemoryConfigService: Interface, @unchecked Sendable {
        public let path: String?
        private let state: Mutex<Info>

        public init(initial: Info = Info(), path: String? = nil) {
            self.path = path
            self.state = Mutex(initial)
        }

        public func get() async throws -> Info {
            state.withLock { $0 }
        }

        public func update(_ mutate: @escaping @Sendable (inout Info) -> Void) async throws -> Info {
            state.withLock { info in
                mutate(&info)
                return info
            }
        }
    }

    // parity: tui/src/config/index.tsx#AttentionSoundName [status=implemented hash=618aa02fcd91]
    public typealias AttentionSoundName = PluginTui.AttentionSoundName

    // parity: tui/src/config/index.tsx#AttentionSoundPaths [status=implemented hash=ce809cd005aa]
    public typealias AttentionSoundPaths = [AttentionSoundName: String]

    // parity: tui/src/config/index.tsx#MiniWorkSpinner [status=implemented hash=0f8f8c9e756a]
    public enum MiniWorkSpinner: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case blockSoftSlide = "block-soft-slide"
        case blockSoftSweep = "block-soft-sweep"
        case blockLowComet = "block-low-comet"
        case blockLowDuet = "block-low-duet"
        case blockShuttle = "block-shuttle"
        case blockBridge = "block-bridge"
        case blockSqueeze = "block-squeeze"
        case smallToggle = "small-toggle"
        case squareToggle = "square-toggle"
        case growShrink = "grow-shrink"
        case quadrantOrbit = "quadrant-orbit"
        case crosshatch = "crosshatch"
        case densityWave = "density-wave"
        case seed = "seed"
    }

    // parity: tui/src/config/index.tsx#Plugin [status=implemented hash=7eb73974b282]
    public enum Plugin: Equatable, Hashable, Sendable, Codable {
        case specifier(String)
        case configured(package: String, options: [String: JSONValue]?)
    }

    // parity: tui/src/config/index.tsx#DiffSource [status=implemented hash=7a8bd237c7a6]
    public enum DiffSource: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case working
        case branch
        case committed
        case turn
    }

    // parity: tui/src/config/index.tsx#Cursor [status=implemented hash=a4bb6c53ae94]
    public struct Cursor: Equatable, Hashable, Sendable, Codable {
        public var style: CursorStyle?
        public var blinking: Bool?

        public init(style: CursorStyle? = nil, blinking: Bool? = nil) {
            self.style = style
            self.blinking = blinking
        }
    }

    public struct ThemeConfig: Equatable, Hashable, Sendable, Codable {
        public enum ModePreference: String, Equatable, Hashable, Sendable, Codable {
            case system
            case dark
            case light
        }

        public var name: String?
        public var mode: ModePreference?

        public init(name: String? = nil, mode: ModePreference? = nil) {
            self.name = name
            self.mode = mode
        }
    }

    public struct LeaderConfig: Equatable, Hashable, Sendable, Codable {
        public var timeout: Int?

        public init(timeout: Int? = nil) {
            self.timeout = timeout
        }
    }

    public struct ScrollConfig: Equatable, Hashable, Sendable, Codable {
        public var speed: Double?
        public var acceleration: Bool?

        public init(speed: Double? = nil, acceleration: Bool? = nil) {
            self.speed = speed
            self.acceleration = acceleration
        }
    }

    public struct AttentionConfig: Equatable, Hashable, Sendable, Codable {
        public var notifications: Bool?
        public var sound: Bool?
        public var volume: Double?
        public var soundPack: String?
        public var sounds: AttentionSoundPaths?

        public init(
            notifications: Bool? = nil,
            sound: Bool? = nil,
            volume: Double? = nil,
            soundPack: String? = nil,
            sounds: AttentionSoundPaths? = nil
        ) {
            self.notifications = notifications
            self.sound = sound
            self.volume = volume
            self.soundPack = soundPack
            self.sounds = sounds
        }

        enum CodingKeys: String, CodingKey {
            case notifications, sound, volume, sounds
            case soundPack = "sound_pack"
        }
    }

    public struct DiffsConfig: Equatable, Hashable, Sendable, Codable {
        public var source: DiffSource?
        public var wrap: String?
        public var tree: Bool?
        public var single: Bool?
        public var fullscreen: Bool?
        public var view: String?

        public init(
            source: DiffSource? = nil,
            wrap: String? = nil,
            tree: Bool? = nil,
            single: Bool? = nil,
            fullscreen: Bool? = nil,
            view: String? = nil
        ) {
            self.source = source
            self.wrap = wrap
            self.tree = tree
            self.single = single
            self.fullscreen = fullscreen
            self.view = view
        }
    }

    public struct TerminalConfig: Equatable, Hashable, Sendable, Codable {
        public var title: Bool?
        public var copy: String?

        public init(title: Bool? = nil, copy: String? = nil) {
            self.title = title
            self.copy = copy
        }
    }

    public struct PromptConfig: Equatable, Hashable, Sendable, Codable {
        public var editor: Bool?
        public var paste: String?
        public var imagePreview: Bool?

        public init(editor: Bool? = nil, paste: String? = nil, imagePreview: Bool? = nil) {
            self.editor = editor
            self.paste = paste
            self.imagePreview = imagePreview
        }

        enum CodingKeys: String, CodingKey {
            case editor, paste
            case imagePreview = "image_preview"
        }
    }

    public struct SessionConfig: Equatable, Hashable, Sendable, Codable {
        public var sidebar: String?
        public var scrollbar: Bool?
        public var submitScroll: String?
        public var thinking: TUIContext.ThinkingMode?
        public var grouping: String?
        public var verbosity: TUIRoutes.Verbosity?
        public var imagePreview: Bool?
        public var tps: Bool?
        public var markdown: String?
        public var newLocation: NewSessionLocationMode?
        public var permissions: TUIContext.PermissionMode?

        public init(
            sidebar: String? = nil,
            scrollbar: Bool? = nil,
            submitScroll: String? = nil,
            thinking: TUIContext.ThinkingMode? = nil,
            grouping: String? = nil,
            verbosity: TUIRoutes.Verbosity? = nil,
            imagePreview: Bool? = nil,
            tps: Bool? = nil,
            markdown: String? = nil,
            newLocation: NewSessionLocationMode? = nil,
            permissions: TUIContext.PermissionMode? = nil
        ) {
            self.sidebar = sidebar
            self.scrollbar = scrollbar
            self.submitScroll = submitScroll
            self.thinking = thinking
            self.grouping = grouping
            self.verbosity = verbosity
            self.imagePreview = imagePreview
            self.tps = tps
            self.markdown = markdown
            self.newLocation = newLocation
            self.permissions = permissions
        }

        enum CodingKeys: String, CodingKey {
            case sidebar, scrollbar, thinking, grouping, verbosity, tps, markdown, permissions
            case submitScroll = "submit_scroll"
            case imagePreview = "image_preview"
            case newLocation = "new_location"
        }
    }

    public enum NewSessionLocationMode: String, Equatable, Hashable, Sendable, Codable {
        case launch
        case inherit
    }

    public struct TabsConfig: Equatable, Hashable, Sendable, Codable {
        public enum Mode: String, Equatable, Hashable, Sendable, Codable {
            case auto, on, off
        }
        public enum Scope: String, Equatable, Hashable, Sendable, Codable {
            case global, cwd
        }
        public enum Layout: String, Equatable, Hashable, Sendable, Codable {
            case horizontal, vertical
        }
        public enum Indicators: String, Equatable, Hashable, Sendable, Codable {
            case status, numbers
        }

        public var mode: Mode?
        public var enabled: Bool?
        public var scope: Scope?
        public var layout: Layout?
        public var indicators: Indicators?

        public init(
            mode: Mode? = nil,
            enabled: Bool? = nil,
            scope: Scope? = nil,
            layout: Layout? = nil,
            indicators: Indicators? = nil
        ) {
            self.mode = mode
            self.enabled = enabled
            self.scope = scope
            self.layout = layout
            self.indicators = indicators
        }
    }

    public struct MiniConfig: Equatable, Hashable, Sendable, Codable {
        public var thinking: TUIContext.ThinkingMode?
        public var tools: TUIContext.ThinkingMode?
        public var shellOutput: TUIContext.ThinkingMode?
        public var turnSummary: TUIContext.ThinkingMode?
        public var footer: TUIContext.ThinkingMode?
        public var splash: TUIContext.ThinkingMode?
        public var workSpinner: MiniWorkSpinner?
        public var mono: Bool?
        public var replay: Bool?
        public var replayLimit: Int?

        public init(
            thinking: TUIContext.ThinkingMode? = nil,
            tools: TUIContext.ThinkingMode? = nil,
            shellOutput: TUIContext.ThinkingMode? = nil,
            turnSummary: TUIContext.ThinkingMode? = nil,
            footer: TUIContext.ThinkingMode? = nil,
            splash: TUIContext.ThinkingMode? = nil,
            workSpinner: MiniWorkSpinner? = nil,
            mono: Bool? = nil,
            replay: Bool? = nil,
            replayLimit: Int? = nil
        ) {
            self.thinking = thinking
            self.tools = tools
            self.shellOutput = shellOutput
            self.turnSummary = turnSummary
            self.footer = footer
            self.splash = splash
            self.workSpinner = workSpinner
            self.mono = mono
            self.replay = replay
            self.replayLimit = replayLimit
        }

        enum CodingKeys: String, CodingKey {
            case thinking, tools, footer, splash, mono, replay
            case shellOutput = "shell_output"
            case turnSummary = "turn_summary"
            case workSpinner = "work_spinner"
            case replayLimit = "replay_limit"
        }
    }

    public struct DebugConfig: Equatable, Hashable, Sendable, Codable {
        public var devtools: Bool?
        public var timing: Bool?
        public var turnTokens: String?

        public init(devtools: Bool? = nil, timing: Bool? = nil, turnTokens: String? = nil) {
            self.devtools = devtools
            self.timing = timing
            self.turnTokens = turnTokens
        }

        enum CodingKeys: String, CodingKey {
            case devtools, timing
            case turnTokens = "turn_tokens"
        }
    }

    // parity: tui/src/config/index.tsx#Info [status=implemented hash=986443cb7e52]
    public struct Info: Equatable, Sendable, Codable {
        public var theme: ThemeConfig?
        public var keybinds: Keybind.KeybindOverrides?
        public var plugins: [Plugin]?
        public var leader: LeaderConfig?
        public var scroll: ScrollConfig?
        public var attention: AttentionConfig?
        public var diffs: DiffsConfig?
        public var terminal: TerminalConfig?
        public var prompt: PromptConfig?
        public var session: SessionConfig?
        public var tabs: TabsConfig?
        public var mini: MiniConfig?
        public var debug: DebugConfig?
        public var experimental: [String: Bool]?
        public var animations: Bool?
        public var highlights: Bool?
        public var mouse: Bool?
        public var cursor: Cursor?

        public init(
            theme: ThemeConfig? = nil,
            keybinds: Keybind.KeybindOverrides? = nil,
            plugins: [Plugin]? = nil,
            leader: LeaderConfig? = nil,
            scroll: ScrollConfig? = nil,
            attention: AttentionConfig? = nil,
            diffs: DiffsConfig? = nil,
            terminal: TerminalConfig? = nil,
            prompt: PromptConfig? = nil,
            session: SessionConfig? = nil,
            tabs: TabsConfig? = nil,
            mini: MiniConfig? = nil,
            debug: DebugConfig? = nil,
            experimental: [String: Bool]? = nil,
            animations: Bool? = nil,
            highlights: Bool? = nil,
            mouse: Bool? = nil,
            cursor: Cursor? = nil
        ) {
            self.theme = theme
            self.keybinds = keybinds
            self.plugins = plugins
            self.leader = leader
            self.scroll = scroll
            self.attention = attention
            self.diffs = diffs
            self.terminal = terminal
            self.prompt = prompt
            self.session = session
            self.tabs = tabs
            self.mini = mini
            self.debug = debug
            self.experimental = experimental
            self.animations = animations
            self.highlights = highlights
            self.mouse = mouse
            self.cursor = cursor
        }
    }

    public struct ResolvedAttention: Equatable, Hashable, Sendable {
        public var notifications: Bool
        public var sound: Bool
        public var volume: Double
        public var soundPack: String
        public var sounds: AttentionSoundPaths

        public init(
            notifications: Bool = false,
            sound: Bool = false,
            volume: Double = 0.4,
            soundPack: String = "opencode.default",
            sounds: AttentionSoundPaths = [:]
        ) {
            self.notifications = notifications
            self.sound = sound
            self.volume = volume
            self.soundPack = soundPack
            self.sounds = sounds
        }
    }

    public struct ResolvedCursor: Equatable, Hashable, Sendable {
        public var style: CursorStyle
        public var blinking: Bool

        public init(style: CursorStyle = .block, blinking: Bool = true) {
            self.style = style
            self.blinking = blinking
        }
    }

    public struct ResolvedSession: Equatable, Hashable, Sendable {
        public var sidebar: String?
        public var scrollbar: Bool?
        public var submitScroll: String?
        public var thinking: TUIContext.ThinkingMode?
        public var grouping: String?
        public var verbosity: TUIRoutes.Verbosity?
        public var imagePreview: Bool?
        public var tps: Bool
        public var markdown: String?
        public var newLocation: NewSessionLocationMode
        public var permissions: TUIContext.PermissionMode

        public init(
            sidebar: String? = nil,
            scrollbar: Bool? = nil,
            submitScroll: String? = nil,
            thinking: TUIContext.ThinkingMode? = nil,
            grouping: String? = nil,
            verbosity: TUIRoutes.Verbosity? = nil,
            imagePreview: Bool? = nil,
            tps: Bool = true,
            markdown: String? = nil,
            newLocation: NewSessionLocationMode = .launch,
            permissions: TUIContext.PermissionMode = .prompt
        ) {
            self.sidebar = sidebar
            self.scrollbar = scrollbar
            self.submitScroll = submitScroll
            self.thinking = thinking
            self.grouping = grouping
            self.verbosity = verbosity
            self.imagePreview = imagePreview
            self.tps = tps
            self.markdown = markdown
            self.newLocation = newLocation
            self.permissions = permissions
        }
    }

    public struct ResolvedTabs: Equatable, Hashable, Sendable {
        public var mode: TabsConfig.Mode
        public var enabled: Bool
        public var scope: TabsConfig.Scope
        public var layout: TabsConfig.Layout
        public var indicators: TabsConfig.Indicators

        public init(
            mode: TabsConfig.Mode = .auto,
            enabled: Bool = true,
            scope: TabsConfig.Scope = .cwd,
            layout: TabsConfig.Layout = .horizontal,
            indicators: TabsConfig.Indicators = .status
        ) {
            self.mode = mode
            self.enabled = enabled
            self.scope = scope
            self.layout = layout
            self.indicators = indicators
        }
    }

    // parity: tui/src/config/index.tsx#Resolved [status=implemented hash=be1494ee15ac]
    public struct Resolved: Equatable, Sendable {
        public var theme: ThemeConfig?
        public var plugins: [Plugin]?
        public var scroll: ScrollConfig?
        public var diffs: DiffsConfig?
        public var terminal: TerminalConfig?
        public var prompt: PromptConfig?
        public var mini: MiniConfig?
        public var debug: DebugConfig?
        public var experimental: [String: Bool]?
        public var animations: Bool?
        public var highlights: Bool?
        public var attention: ResolvedAttention
        public var keybinds: Keybind.BindingLookupView
        public var leaderTimeout: Int
        public var mouse: Bool
        public var cursor: ResolvedCursor
        public var session: ResolvedSession
        public var tabs: ResolvedTabs

        public init(
            theme: ThemeConfig? = nil,
            plugins: [Plugin]? = nil,
            scroll: ScrollConfig? = nil,
            diffs: DiffsConfig? = nil,
            terminal: TerminalConfig? = nil,
            prompt: PromptConfig? = nil,
            mini: MiniConfig? = nil,
            debug: DebugConfig? = nil,
            experimental: [String: Bool]? = nil,
            animations: Bool? = nil,
            highlights: Bool? = nil,
            attention: ResolvedAttention,
            keybinds: Keybind.BindingLookupView,
            leaderTimeout: Int,
            mouse: Bool,
            cursor: ResolvedCursor,
            session: ResolvedSession,
            tabs: ResolvedTabs
        ) {
            self.theme = theme
            self.plugins = plugins
            self.scroll = scroll
            self.diffs = diffs
            self.terminal = terminal
            self.prompt = prompt
            self.mini = mini
            self.debug = debug
            self.experimental = experimental
            self.animations = animations
            self.highlights = highlights
            self.attention = attention
            self.keybinds = keybinds
            self.leaderTimeout = leaderTimeout
            self.mouse = mouse
            self.cursor = cursor
            self.session = session
            self.tabs = tabs
        }
    }

    public struct ResolveOptions: Equatable, Sendable {
        public var terminalSuspend: Bool
        public var environment: [String: String]?

        public init(terminalSuspend: Bool = true, environment: [String: String]? = nil) {
            self.terminalSuspend = terminalSuspend
            self.environment = environment
        }
    }

    // parity: tui/src/config/index.tsx#resolve [status=implemented hash=e39d7dd24a8e]
    public static func resolve(_ input: Info, options: ResolveOptions = ResolveOptions()) -> Resolved {
        let tabsMode: TabsConfig.Mode
        if let m = input.tabs?.mode {
            tabsMode = m
        } else if let legacy = input.tabs?.enabled {
            tabsMode = legacy ? .on : .off
        } else {
            tabsMode = .auto
        }

        var overrides = input.keybinds ?? [:]
        if !options.terminalSuspend {
            overrides["terminal.suspend"] = .disabled
            if overrides["input.undo"] == nil {
                var parts = ["ctrl+z"]
                if let def = Keybind.defaultValue("input.undo")?.stringValue, def != "none" {
                    for item in def.split(separator: ",").map(String.init) where !parts.contains(item) {
                        parts.append(item)
                    }
                }
                overrides["input.undo"] = .item(.sequence(parts.joined(separator: ",")))
            }
        }

        let parsed = (try? Keybind.parse(overrides)) ?? Keybind.Definitions.mapValues(\.defaultValue)
        let lookup = (try? createBindingLookup(
            Keybind.toBindingConfig(parsed),
            options: CreateBindingLookupOptions(bindingDefaults: Keybind.bindingDefaults())
        )) ?? (try! createBindingLookup([:]))

        let herdr = options.environment?["HERDR_ENV"] ?? SystemEnvironment.shared.variable("HERDR_ENV")
        let tabsEnabled = tabsMode == .on || (tabsMode == .auto && herdr != "1")

        return Resolved(
            theme: input.theme,
            plugins: input.plugins,
            scroll: input.scroll,
            diffs: input.diffs,
            terminal: input.terminal,
            prompt: input.prompt,
            mini: input.mini,
            debug: input.debug,
            experimental: input.experimental,
            animations: input.animations,
            highlights: input.highlights,
            attention: ResolvedAttention(
                notifications: input.attention?.notifications ?? false,
                sound: input.attention?.sound ?? false,
                volume: input.attention?.volume ?? 0.4,
                soundPack: input.attention?.soundPack ?? "opencode.default",
                sounds: input.attention?.sounds ?? [:]
            ),
            keybinds: Keybind.BindingLookupView(lookup: lookup, rawKeybinds: parsed),
            leaderTimeout: input.leader?.timeout ?? 2000,
            mouse: input.mouse ?? true,
            cursor: ResolvedCursor(
                style: input.cursor?.style ?? .block,
                blinking: input.cursor?.blinking ?? true
            ),
            session: ResolvedSession(
                sidebar: input.session?.sidebar,
                scrollbar: input.session?.scrollbar,
                submitScroll: input.session?.submitScroll,
                thinking: input.session?.thinking,
                grouping: input.session?.grouping,
                verbosity: input.session?.verbosity,
                imagePreview: input.session?.imagePreview,
                tps: input.session?.tps ?? true,
                markdown: input.session?.markdown,
                newLocation: input.session?.newLocation ?? .launch,
                permissions: input.session?.permissions ?? .prompt
            ),
            tabs: ResolvedTabs(
                mode: tabsMode,
                enabled: tabsEnabled,
                scope: input.tabs?.scope ?? .cwd,
                layout: input.tabs?.layout ?? .horizontal,
                indicators: input.tabs?.indicators ?? .status
            )
        )
    }

    /// Runtime config store backing `ConfigProvider` and `useConfig`.
    public final class ConfigState: @unchecked Sendable {
        private let state: Mutex<Resolved>
        private let service: (any Interface)?
        private let options: ResolveOptions
        public var path: String? { service?.path }

        public init(config: Resolved, service: (any Interface)? = nil, options: ResolveOptions = ResolveOptions()) {
            self.state = Mutex(config)
            self.service = service
            self.options = options
        }

        public var data: Resolved {
            state.withLock { $0 }
        }

        public func apply(_ info: Info) {
            let next = TUIConfig.resolve(info, options: options)
            state.withLock { $0 = next }
        }

        public func update(_ mutate: @escaping @Sendable (inout Info) -> Void) async throws -> Info {
            guard let service else { throw ConfigError.updatesUnavailable }
            let updated = try await service.update(mutate)
            apply(updated)
            return updated
        }
    }

    @TaskLocal private static var currentConfig: ConfigState?

    // parity: tui/src/config/index.tsx#ConfigProvider [status=adapted hash=abdb10dbed6f]
    public static func ConfigProvider<R>(
        config: Resolved,
        service: (any Interface)? = nil,
        options: ResolveOptions = ResolveOptions(),
        body: () throws -> R
    ) rethrows -> R {
        let state = ConfigState(config: config, service: service, options: options)
        return try $currentConfig.withValue(state, operation: body)
    }

    // parity: tui/src/config/index.tsx#useConfig [status=adapted hash=d351c4bf7de8]
    public static func useConfig() throws(ConfigError) -> ConfigState {
        guard let value = currentConfig else { throw .missingContext("ConfigProvider") }
        return value
    }

    // parity: tui/src/config/index.tsx#useCursorStyle [status=adapted hash=57252e08b366]
    public static func useCursorStyle() throws(ConfigError) -> ResolvedCursor {
        try useConfig().data.cursor
    }

    /// Reactive accessor for the temporary "new-designs" experiment. On unless the config turns it off.
    // parity: tui/src/config/index.tsx#useNewDesigns [status=adapted hash=97c19b0bc140]
    public static func useNewDesigns() throws(ConfigError) -> Bool {
        try useConfig().data.experimental?["new-designs"] != false
    }

    // parity: tui/src/config/index.tsx#useClientMcpExperiment [status=adapted hash=59580d51c9f0]
    public static func useClientMcpExperiment() throws(ConfigError) -> Bool {
        try useConfig().data.experimental?["client-mcp"] == true
    }

    // MARK: - New Session Location (`packages/tui/src/config/new-session-location.ts`)

    // parity: tui/src/config/new-session-location.ts#newSessionLocation [status=implemented hash=c1885f6141c1]
    public static func newSessionLocation(
        mode: NewSessionLocationMode,
        launchDirectory: String,
        current: LocationSchema.Ref? = nil,
        unavailable: LocationSchema.Ref? = nil
    ) -> LocationSchema.Ref {
        if mode == .inherit,
           let current,
           current.directory != unavailable?.directory || current.workspaceID != unavailable?.workspaceID
        {
            return current
        }
        return LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: launchDirectory))
    }

    // MARK: - V1 Config & Keybind Compatibility (`packages/tui/src/config/v1/*`)

    public enum V1 {
        public enum Keybind {
            // parity: tui/src/config/v1/keybind.ts#BindingValueSchema [status=implemented hash=16f14e551ca7]
            public typealias BindingValueSchema = TUIConfig.Keybind.BindingValueSchema

            // parity: tui/src/config/v1/keybind.ts#LeaderDefault [status=implemented hash=83ca3f4e2efe]
            public static let LeaderDefault = "ctrl+x"

            public typealias Definition = TUIConfig.Keybind.Definition

            // parity: tui/src/config/v1/keybind.ts#Definitions [status=implemented hash=36aaf4026f80]
            public static let Definitions: [String: Definition] = [
                "leader": Definition(.item(.sequence(LeaderDefault)), "Leader key for keybind combinations"),
                "app_exit": Definition("ctrl+c,ctrl+d,<leader>q", "Exit the application"),
                "app_debug": Definition("none", "Toggle debug panel"),
                "app_console": Definition("none", "Toggle console"),
                "app_heap_snapshot": Definition("none", "Write heap snapshot"),
                "app_toggle_animations": Definition("none", "Toggle animations"),
                "app_toggle_file_context": Definition("none", "Toggle file context"),
                "app_toggle_diffwrap": Definition("none", "Toggle diff wrapping"),
                "app_toggle_paste_summary": Definition("none", "Toggle paste summary"),
                "command_list": Definition("ctrl+p", "List available commands"),
                "help_show": Definition("none", "Open help dialog"),
                "docs_open": Definition("none", "Open documentation"),
                "diff_open": Definition("none", "Open diff viewer"),
                "diff_close": Definition("escape,q", "Close diff viewer"),
                "diff_toggle": Definition("enter,space", "Toggle diff viewer item"),
                "diff_expand": Definition("right", "Expand diff viewer item"),
                "diff_expand_all": Definition("E", "Expand all diff viewer folders"),
                "diff_collapse": Definition("left", "Collapse diff viewer item"),
                "diff_switch_focus": Definition("tab", "Switch diff viewer focus"),
                "diff_next_hunk": Definition("]", "Jump to next diff hunk"),
                "diff_previous_hunk": Definition("[", "Jump to previous diff hunk"),
                "diff_next_file": Definition("n", "Jump to next diff file"),
                "diff_previous_file": Definition("p", "Jump to previous diff file"),
                "diff_toggle_file_tree": Definition("b", "Toggle diff viewer file tree"),
                "diff_single_patch": Definition("s", "Toggle single patch view"),
                "diff_switch_source": Definition("d", "Switch diff viewer source"),
                "diff_toggle_view": Definition("v", "Toggle diff viewer split or unified view"),
                "diff_help": Definition("?", "Show more diff viewer shortcuts"),
                "editor_open": Definition("<leader>e", "Open external editor"),
                "theme_list": Definition("<leader>t", "List available themes"),
                "theme_switch_mode": Definition("none", "Switch between light and dark theme mode"),
                "theme_mode_lock": Definition("none", "Lock or unlock theme mode"),
                "sidebar_toggle": Definition("<leader>b", "Toggle sidebar"),
                "scrollbar_toggle": Definition("none", "Toggle session scrollbar"),
                "status_view": Definition("<leader>s", "View status"),
                "debug_view": Definition("none", "View debug info"),
                "session_export": Definition("<leader>x", "Export session to editor"),
                "session_copy": Definition("none", "Copy session transcript"),
                "session_move": Definition("none", "Move session"),
                "session_new": Definition("<leader>n", "Create a new session"),
                "session_list": Definition("<leader>l", "List all sessions"),
                "open_menu": Definition("ctrl+o", "Open recent sessions and projects"),
                "session_tab_next": Definition("ctrl+tab,alt+down", "Switch to next open tab"),
                "session_tab_previous": Definition("ctrl+shift+tab,alt+up", "Switch to previous open tab"),
                "session_tab_next_unread": Definition("alt+shift+down", "Switch to next unread tab"),
                "session_tab_previous_unread": Definition("alt+shift+up", "Switch to previous unread tab"),
                "session_tab_close": Definition("<leader>w", "Close current tab"),
                "session_tab_reopen": Definition("ctrl+shift+t", "Reopen last closed tab"),
                "session_timeline": Definition("<leader>g", "Show session timeline"),
                "session_fork": Definition("none", "Fork session from message"),
                "session_rename": Definition("ctrl+r", "Rename session"),
                "session_delete": Definition("ctrl+d", "Delete session"),
                "session_share": Definition("none", "Deprecated: session sharing was removed"),
                "session_unshare": Definition("none", "Deprecated: session sharing was removed"),
                "session_interrupt": Definition("escape", "Interrupt current session"),
                "session_background": Definition("ctrl+b", "Background blocking session tools"),
                "session_compact": Definition("<leader>c", "Compact the session"),
                "session_queued_prompts": Definition("<leader>q", "View queued prompts"),
                "queued_prompt_delete": Definition("ctrl+d", "Delete queued prompt"),
                "session_child_first": Definition("down", "Toggle subagent picker"),
                "session_parent": Definition("up", "Go to parent session"),
                "session_pin_toggle": Definition("ctrl+f", "Pin or unpin session in the session list"),
                "session_quick_switch_1": Definition("<leader>1", "Switch to session in quick slot 1"),
                "session_quick_switch_2": Definition("<leader>2", "Switch to session in quick slot 2"),
                "session_quick_switch_3": Definition("<leader>3", "Switch to session in quick slot 3"),
                "session_quick_switch_4": Definition("<leader>4", "Switch to session in quick slot 4"),
                "session_quick_switch_5": Definition("<leader>5", "Switch to session in quick slot 5"),
                "session_quick_switch_6": Definition("<leader>6", "Switch to session in quick slot 6"),
                "session_quick_switch_7": Definition("<leader>7", "Switch to session in quick slot 7"),
                "session_quick_switch_8": Definition("<leader>8", "Switch to session in quick slot 8"),
                "session_quick_switch_9": Definition("<leader>9", "Switch to session in quick slot 9"),
                "session_tab_select_1": Definition("<leader>1,ctrl+1", "Switch to tab 1"),
                "session_tab_select_2": Definition("<leader>2,ctrl+2", "Switch to tab 2"),
                "session_tab_select_3": Definition("<leader>3,ctrl+3", "Switch to tab 3"),
                "session_tab_select_4": Definition("<leader>4,ctrl+4", "Switch to tab 4"),
                "session_tab_select_5": Definition("<leader>5,ctrl+5", "Switch to tab 5"),
                "session_tab_select_6": Definition("<leader>6,ctrl+6", "Switch to tab 6"),
                "session_tab_select_7": Definition("<leader>7,ctrl+7", "Switch to tab 7"),
                "session_tab_select_8": Definition("<leader>8,ctrl+8", "Switch to tab 8"),
                "session_tab_select_9": Definition("<leader>9,ctrl+9", "Switch to tab 9"),
                "session_tab_select_10": Definition("<leader>0,ctrl+0", "Switch to tab 10"),
                "stash_delete": Definition("ctrl+d", "Delete stash entry"),
                "model_provider_list": Definition("ctrl+a", "Open provider list from model dialog"),
                "model_favorite_toggle": Definition("ctrl+f", "Toggle model favorite status"),
                "model_list": Definition("<leader>m", "List available models"),
                "model_cycle_recent": Definition("f2", "Next recently used model"),
                "model_cycle_recent_reverse": Definition("shift+f2", "Previous recently used model"),
                "model_cycle_favorite": Definition("none", "Next favorite model"),
                "model_cycle_favorite_reverse": Definition("none", "Previous favorite model"),
                "mcp_list": Definition("none", "List MCP servers"),
                "provider_connect": Definition("none", "Connect an integration"),
                "agent_list": Definition("<leader>a", "List agents"),
                "agent_cycle": Definition("shift+tab", "Next agent"),
                "agent_cycle_reverse": Definition("none", "Previous agent"),
                "variant_cycle": Definition("ctrl+t", "Cycle model variants"),
                "variant_list": Definition("none", "List model variants"),
                "messages_page_up": Definition("pageup,ctrl+alt+b", "Scroll messages up by one page"),
                "messages_page_down": Definition("pagedown,ctrl+alt+f", "Scroll messages down by one page"),
                "messages_line_up": Definition("ctrl+alt+y", "Scroll messages up by one line"),
                "messages_line_down": Definition("ctrl+alt+e", "Scroll messages down by one line"),
                "messages_half_page_up": Definition("ctrl+alt+u", "Scroll messages up by half page"),
                "messages_half_page_down": Definition("ctrl+alt+d", "Scroll messages down by half page"),
                "messages_first": Definition("ctrl+g,home,alt+home", "Navigate to first message"),
                "messages_last": Definition("ctrl+alt+g,end", "Navigate to last message"),
                "messages_next": Definition("none", "Navigate to next message"),
                "messages_previous": Definition("none", "Navigate to previous message"),
                "messages_next_user": Definition("none", "Navigate to next user message"),
                "messages_previous_user": Definition("none", "Navigate to previous user message"),
                "messages_last_user": Definition("alt+end", "Navigate to last user message"),
                "messages_copy": Definition("<leader>y", "Copy message"),
                "messages_undo": Definition("<leader>u", "Undo message"),
                "messages_redo": Definition("<leader>r", "Redo message"),
                "display_thinking": Definition("none", "Toggle thinking blocks visibility"),
                "prompt_submit": Definition("none", "Submit prompt"),
                "prompt_queue": Definition("<leader>return", "Queue prompt"),
                "prompt_editor_context_clear": Definition("none", "Clear editor context"),
                "prompt_images_view": Definition("<leader>i", "View image attachments"),
                "prompt_skills": Definition("none", "Open skill selector"),
                "prompt_stash": Definition("none", "Stash prompt"),
                "prompt_stash_pop": Definition("none", "Pop stashed prompt"),
                "prompt_stash_list": Definition("none", "List stashed prompts"),
                "input_clear": Definition("ctrl+c", "Clear input field"),
                "input_paste": Definition(.item(.object(TUIConfig.Keybind.BindingObject(key: "ctrl+v", preventDefault: false))), "Paste from clipboard"),
                "input_submit": Definition("return", "Submit input"),
                "input_newline": Definition("shift+return,ctrl+return,alt+return,ctrl+j", "Insert newline in input"),
                "input_move_left": Definition("left,ctrl+b", "Move cursor left in input"),
                "input_move_right": Definition("right,ctrl+f", "Move cursor right in input"),
                "input_move_up": Definition("up", "Move cursor up in input"),
                "input_move_down": Definition("down", "Move cursor down in input"),
                "input_select_left": Definition("shift+left", "Select left in input"),
                "input_select_right": Definition("shift+right", "Select right in input"),
                "input_select_up": Definition("shift+up", "Select up in input"),
                "input_select_down": Definition("shift+down", "Select down in input"),
                "input_line_home": Definition("ctrl+a", "Move to start of line in input"),
                "input_line_end": Definition("ctrl+e", "Move to end of line in input"),
                "input_select_line_home": Definition("ctrl+shift+a", "Select to start of line in input"),
                "input_select_line_end": Definition("ctrl+shift+e", "Select to end of line in input"),
                "input_visual_line_home": Definition("alt+a", "Move to start of visual line in input"),
                "input_visual_line_end": Definition("alt+e", "Move to end of visual line in input"),
                "input_select_visual_line_home": Definition("alt+shift+a", "Select to start of visual line in input"),
                "input_select_visual_line_end": Definition("alt+shift+e", "Select to end of visual line in input"),
                "input_buffer_home": Definition("none", "Move to start of buffer in input"),
                "input_buffer_end": Definition("none", "Move to end of buffer in input"),
                "input_select_buffer_home": Definition("shift+home", "Select to start of buffer in input"),
                "input_select_buffer_end": Definition("shift+end", "Select to end of buffer in input"),
                "input_delete_line": Definition("ctrl+shift+d", "Delete line in input"),
                "input_delete_to_line_end": Definition("ctrl+k", "Delete to end of line in input"),
                "input_delete_to_line_start": Definition("ctrl+u", "Delete to start of line in input"),
                "input_backspace": Definition("backspace,shift+backspace", "Backspace in input"),
                "input_delete": Definition("ctrl+d,delete,shift+delete", "Delete character in input"),
                "input_undo": Definition("ctrl+-,super+z", "Undo in input"),
                "input_redo": Definition("ctrl+.,super+shift+z", "Redo in input"),
                "input_word_forward": Definition("alt+f,alt+right,ctrl+right", "Move word forward in input"),
                "input_word_backward": Definition("alt+b,alt+left,ctrl+left", "Move word backward in input"),
                "input_select_word_forward": Definition("alt+shift+f,alt+shift+right", "Select word forward in input"),
                "input_select_word_backward": Definition("alt+shift+b,alt+shift+left", "Select word backward in input"),
                "input_delete_word_forward": Definition("alt+d,alt+delete,ctrl+delete", "Delete word forward in input"),
                "input_delete_word_backward": Definition("ctrl+w,ctrl+backspace,alt+backspace", "Delete word backward in input"),
                "input_select_all": Definition("super+a", "Select all in input"),
                "history_previous": Definition("up", "Previous history item"),
                "history_next": Definition("down", "Next history item"),
                "dialog.select.prev": Definition("up,ctrl+p", "Move to previous dialog item"),
                "dialog.select.next": Definition("down,ctrl+n", "Move to next dialog item"),
                "dialog.select.page_up": Definition("pageup", "Move up one page in dialog"),
                "dialog.select.page_down": Definition("pagedown", "Move down one page in dialog"),
                "dialog.select.home": Definition("home", "Move to first dialog item"),
                "dialog.select.end": Definition("end", "Move to last dialog item"),
                "dialog.select.submit": Definition("return", "Submit selected dialog item"),
                "dialog.prompt.submit": Definition("return", "Submit dialog prompt"),
                "dialog.project_copy.generate": Definition("tab", "Generate project copy name"),
                "dialog.move_session.new": Definition("ctrl+m", "New project copy"),
                "dialog.move_session.delete": Definition("ctrl+d", "Delete project copy"),
                "dialog.move_session.refresh": Definition("ctrl+r", "Refresh project copies"),
                "prompt.autocomplete.prev": Definition("up,ctrl+p", "Move to previous autocomplete item"),
                "prompt.autocomplete.next": Definition("down,ctrl+n", "Move to next autocomplete item"),
                "prompt.autocomplete.hide": Definition("escape", "Hide autocomplete"),
                "prompt.autocomplete.select": Definition("return", "Select autocomplete item"),
                "prompt.autocomplete.complete": Definition("tab", "Complete autocomplete item"),
                "permission.prompt.fullscreen": Definition("ctrl+f", "Toggle permission prompt fullscreen"),
                "plugins.toggle": Definition("return", "Toggle plugin"),
                "dialog.mcp.toggle": Definition("space", "Toggle MCP server"),
                "terminal_suspend": Definition("ctrl+z", "Suspend terminal"),
                "terminal_title_toggle": Definition("none", "Toggle terminal title"),
            ]

            // parity: tui/src/config/v1/keybind.ts#KeybindOverrides [status=implemented hash=1475d09db8a4]
            public typealias KeybindOverrides = [String: BindingValueSchema]

            // parity: tui/src/config/v1/keybind.ts#CommandMap [status=implemented hash=432a132a50b8]
            public static let CommandMap: BindingCommandMap = [
                "app_exit": "app.exit",
                "app_debug": "app.debug",
                "app_console": "app.console",
                "app_heap_snapshot": "app.heap_snapshot",
                "app_toggle_animations": "app.toggle.animations",
                "app_toggle_file_context": "app.toggle.file_context",
                "app_toggle_diffwrap": "app.toggle.diffwrap",
                "app_toggle_paste_summary": "app.toggle.paste_summary",
                "command_list": "command.palette.show",
                "help_show": "help.show",
                "docs_open": "docs.open",
                "diff_open": "diff.open",
                "diff_close": "diff.close",
                "diff_toggle": "diff.toggle",
                "diff_expand": "diff.expand",
                "diff_expand_all": "diff.expand_all",
                "diff_collapse": "diff.collapse",
                "diff_switch_focus": "diff.switch_focus",
                "diff_next_hunk": "diff.next_hunk",
                "diff_previous_hunk": "diff.previous_hunk",
                "diff_next_file": "diff.next_file",
                "diff_previous_file": "diff.previous_file",
                "diff_toggle_file_tree": "diff.toggle_file_tree",
                "diff_single_patch": "diff.single_patch",
                "diff_switch_source": "diff.switch_source",
                "diff_toggle_view": "diff.toggle_view",
                "diff_help": "diff.help",
                "editor_open": "prompt.editor",
                "theme_list": "theme.switch",
                "theme_switch_mode": "theme.switch_mode",
                "theme_mode_lock": "theme.mode.lock",
                "sidebar_toggle": "session.sidebar.toggle",
                "scrollbar_toggle": "session.toggle.scrollbar",
                "status_view": "opencode.status",
                "debug_view": "opencode.debug",
                "session_export": "session.export",
                "session_copy": "session.copy",
                "session_move": "session.move",
                "session_new": "session.new",
                "session_list": "session.list",
                "open_menu": "open.menu",
                "session_tab_next": "session.tab.next",
                "session_tab_previous": "session.tab.previous",
                "session_tab_next_unread": "session.tab.next_unread",
                "session_tab_previous_unread": "session.tab.previous_unread",
                "session_tab_close": "session.tab.close",
                "session_tab_reopen": "session.tab.reopen",
                "session_timeline": "session.timeline",
                "session_fork": "session.fork",
                "session_rename": "session.rename",
                "session_delete": "session.delete",
                "session_share": "session.share",
                "session_unshare": "session.unshare",
                "session_interrupt": "session.interrupt",
                "session_background": "session.background",
                "session_compact": "session.compact",
                "session_queued_prompts": "session.queued_prompts",
                "queued_prompt_delete": "queued_prompt.delete",
                "session_child_first": "session.child.first",
                "session_parent": "session.parent",
                "session_pin_toggle": "session.pin.toggle",
                "session_quick_switch_1": "session.quick_switch.1",
                "session_quick_switch_2": "session.quick_switch.2",
                "session_quick_switch_3": "session.quick_switch.3",
                "session_quick_switch_4": "session.quick_switch.4",
                "session_quick_switch_5": "session.quick_switch.5",
                "session_quick_switch_6": "session.quick_switch.6",
                "session_quick_switch_7": "session.quick_switch.7",
                "session_quick_switch_8": "session.quick_switch.8",
                "session_quick_switch_9": "session.quick_switch.9",
                "session_tab_select_1": "session.tab.select.1",
                "session_tab_select_2": "session.tab.select.2",
                "session_tab_select_3": "session.tab.select.3",
                "session_tab_select_4": "session.tab.select.4",
                "session_tab_select_5": "session.tab.select.5",
                "session_tab_select_6": "session.tab.select.6",
                "session_tab_select_7": "session.tab.select.7",
                "session_tab_select_8": "session.tab.select.8",
                "session_tab_select_9": "session.tab.select.9",
                "session_tab_select_10": "session.tab.select.10",
                "stash_delete": "stash.delete",
                "model_provider_list": "model.dialog.provider",
                "model_favorite_toggle": "model.dialog.favorite",
                "model_list": "model.list",
                "model_cycle_recent": "model.cycle_recent",
                "model_cycle_recent_reverse": "model.cycle_recent_reverse",
                "model_cycle_favorite": "model.cycle_favorite",
                "model_cycle_favorite_reverse": "model.cycle_favorite_reverse",
                "mcp_list": "mcp.list",
                "provider_connect": "provider.connect",
                "agent_list": "agent.list",
                "agent_cycle": "agent.cycle",
                "agent_cycle_reverse": "agent.cycle.reverse",
                "variant_cycle": "variant.cycle",
                "variant_list": "variant.list",
                "messages_page_up": "session.page.up",
                "messages_page_down": "session.page.down",
                "messages_line_up": "session.line.up",
                "messages_line_down": "session.line.down",
                "messages_half_page_up": "session.half.page.up",
                "messages_half_page_down": "session.half.page.down",
                "messages_first": "session.first",
                "messages_last": "session.last",
                "messages_next": "session.message.next",
                "messages_previous": "session.message.previous",
                "messages_next_user": "session.message.user.next",
                "messages_previous_user": "session.message.user.previous",
                "messages_last_user": "session.messages_last_user",
                "messages_copy": "messages.copy",
                "messages_undo": "session.undo",
                "messages_redo": "session.redo",
                "display_thinking": "session.toggle.thinking",
                "prompt_submit": "prompt.submit",
                "prompt_queue": "prompt.queue",
                "prompt_editor_context_clear": "prompt.editor_context.clear",
                "prompt_images_view": "prompt.images.view",
                "prompt_skills": "prompt.skills",
                "prompt_stash": "prompt.stash",
                "prompt_stash_pop": "prompt.stash.pop",
                "prompt_stash_list": "prompt.stash.list",
                "input_clear": "prompt.clear",
                "input_paste": "prompt.paste",
                "input_submit": "input.submit",
                "input_newline": "input.newline",
                "input_move_left": "input.move.left",
                "input_move_right": "input.move.right",
                "input_move_up": "input.move.up",
                "input_move_down": "input.move.down",
                "input_select_left": "input.select.left",
                "input_select_right": "input.select.right",
                "input_select_up": "input.select.up",
                "input_select_down": "input.select.down",
                "input_line_home": "input.line.home",
                "input_line_end": "input.line.end",
                "input_select_line_home": "input.select.line.home",
                "input_select_line_end": "input.select.line.end",
                "input_visual_line_home": "input.visual.line.home",
                "input_visual_line_end": "input.visual.line.end",
                "input_select_visual_line_home": "input.select.visual.line.home",
                "input_select_visual_line_end": "input.select.visual.line.end",
                "input_buffer_home": "input.buffer.home",
                "input_buffer_end": "input.buffer.end",
                "input_select_buffer_home": "input.select.buffer.home",
                "input_select_buffer_end": "input.select.buffer.end",
                "input_delete_line": "input.delete.line",
                "input_delete_to_line_end": "input.delete.to.line.end",
                "input_delete_to_line_start": "input.delete.to.line.start",
                "input_backspace": "input.backspace",
                "input_delete": "input.delete",
                "input_undo": "input.undo",
                "input_redo": "input.redo",
                "input_word_forward": "input.word.forward",
                "input_word_backward": "input.word.backward",
                "input_select_word_forward": "input.select.word.forward",
                "input_select_word_backward": "input.select.word.backward",
                "input_delete_word_forward": "input.delete.word.forward",
                "input_delete_word_backward": "input.delete.word.backward",
                "input_select_all": "input.select.all",
                "history_previous": "prompt.history.previous",
                "history_next": "prompt.history.next",
                "terminal_suspend": "terminal.suspend",
                "terminal_title_toggle": "terminal.title.toggle",
            ]

            private static let commandDescriptions: [String: String] = {
                var out: [String: String] = [:]
                for (name, item) in Definitions {
                    out[CommandMap[name] ?? name] = item.description
                }
                return out
            }()

            // parity: tui/src/config/v1/keybind.ts#Keybinds [status=implemented hash=88ec7ad81c3c]
            public typealias Keybinds = [String: BindingValueSchema]

            // parity: tui/src/config/v1/keybind.ts#BindingLookupView [status=implemented hash=56be9ef08051]
            public typealias BindingLookupView = TUIConfig.Keybind.BindingLookupView

            // parity: tui/src/config/v1/keybind.ts#toBindingConfig [status=implemented hash=155c3ece2171]
            public static func toBindingConfig(_ keybinds: Keybinds) -> BindingConfig<KeymapTarget, KeymapEventType> {
                keybinds.mapValues { $0.toOpenTUIBindingValue() }
            }

            // parity: tui/src/config/v1/keybind.ts#defaultValue [status=implemented hash=439cfa7cfb7b]
            public static func defaultValue(_ name: String) -> BindingValueSchema? {
                Definitions[name]?.defaultValue
            }

            // parity: tui/src/config/v1/keybind.ts#parse [status=implemented hash=68e0785969e4]
            public static func parse(_ keybinds: KeybindOverrides) throws(ConfigError) -> Keybinds {
                let invalid = unknownKeys(keybinds)
                if !invalid.isEmpty {
                    throw .unrecognizedKeybinds(invalid)
                }
                var result: Keybinds = [:]
                result.reserveCapacity(Definitions.count)
                for (name, def) in Definitions {
                    result[name] = keybinds[name] ?? def.defaultValue
                }
                return result
            }

            // parity: tui/src/config/v1/keybind.ts#unknownKeys [status=implemented hash=8a4e526c64d3]
            public static func unknownKeys(_ input: [String: BindingValueSchema]) -> [String] {
                input.keys.filter { Definitions[$0] == nil }.sorted()
            }

            // parity: tui/src/config/v1/keybind.ts#bindingDefaults [status=implemented hash=3e94d7c0b8cc]
            public static func bindingDefaults() -> BindingDefaults<KeymapTarget, KeymapEventType> {
                { context in
                    if context.binding.fields["desc"] != nil { return nil }
                    guard let desc = commandDescriptions[context.command] else { return nil }
                    return ["desc": .string(desc)]
                }
            }
        }

        // parity: tui/src/config/v1/index.tsx#AttentionSoundName [status=implemented hash=618aa02fcd91]
        public typealias AttentionSoundName = PluginTui.AttentionSoundName

        // parity: tui/src/config/v1/index.tsx#PluginOptions [status=implemented hash=7067645cf89d]
        public typealias PluginOptions = [String: JSONValue]

        // parity: tui/src/config/v1/index.tsx#PluginSpec [status=implemented hash=3827f585f8c9]
        public enum PluginSpec: Equatable, Hashable, Sendable, Codable {
            case name(String)
            case tuple(name: String, options: PluginOptions)
        }

        // parity: tui/src/config/v1/index.tsx#LeaderTimeoutDefault [status=implemented hash=3ff7674555cc]
        public static let LeaderTimeoutDefault = 2000

        // parity: tui/src/config/v1/index.tsx#LeaderTimeout [status=implemented hash=8ab0603f0fa9]
        public struct LeaderTimeout: Equatable, Hashable, Sendable, Codable {
            public let rawValue: Int

            public init?(_ value: Int) {
                guard value > 0 else { return nil }
                self.rawValue = value
            }
        }

        // parity: tui/src/config/v1/index.tsx#ScrollSpeed [status=implemented hash=c046691d8a55]
        public struct ScrollSpeed: Equatable, Hashable, Sendable, Codable {
            public let rawValue: Double

            public init?(_ value: Double) {
                guard value.isFinite && value >= 0.001 else { return nil }
                self.rawValue = value
            }
        }

        // parity: tui/src/config/v1/index.tsx#ScrollAcceleration [status=implemented hash=2bdb47c3b783]
        public struct ScrollAcceleration: Equatable, Hashable, Sendable, Codable {
            public var enabled: Bool

            public init(enabled: Bool) {
                self.enabled = enabled
            }
        }

        // parity: tui/src/config/v1/index.tsx#DiffStyle [status=implemented hash=94dc9fc04300]
        public enum DiffStyle: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
            case auto
            case stacked
        }

        // parity: tui/src/config/v1/index.tsx#AttentionSounds [status=implemented hash=41b9be79e928]
        public typealias AttentionSounds = [AttentionSoundName: String]

        // parity: tui/src/config/v1/index.tsx#AttentionSoundPaths [status=implemented hash=d4c34a90e310]
        public typealias AttentionSoundPaths = AttentionSounds

        // parity: tui/src/config/v1/index.tsx#Attention [status=implemented hash=184754f89ff5]
        public struct Attention: Equatable, Hashable, Sendable, Codable {
            public var enabled: Bool?
            public var notifications: Bool?
            public var sound: Bool?
            public var volume: Double?
            public var soundPack: String?
            public var sounds: AttentionSounds?

            public init(
                enabled: Bool? = nil,
                notifications: Bool? = nil,
                sound: Bool? = nil,
                volume: Double? = nil,
                soundPack: String? = nil,
                sounds: AttentionSounds? = nil
            ) {
                self.enabled = enabled
                self.notifications = notifications
                self.sound = sound
                self.volume = volume
                self.soundPack = soundPack
                self.sounds = sounds
            }

            enum CodingKeys: String, CodingKey {
                case enabled, notifications, sound, volume, sounds
                case soundPack = "sound_pack"
            }
        }

        // parity: tui/src/config/v1/index.tsx#Cursor [status=implemented hash=a4bb6c53ae94]
        public typealias Cursor = TUIConfig.Cursor

        // parity: tui/src/config/v1/index.tsx#Prompt [status=implemented hash=563e5804aa64]
        public struct Prompt: Equatable, Hashable, Sendable, Codable {
            public enum MaxWidth: Equatable, Hashable, Sendable, Codable {
                case fixed(Int)
                case auto
            }

            public var maxHeight: Int?
            public var maxWidth: MaxWidth?

            public init(maxHeight: Int? = nil, maxWidth: MaxWidth? = nil) {
                self.maxHeight = maxHeight
                self.maxWidth = maxWidth
            }

            enum CodingKeys: String, CodingKey {
                case maxHeight = "max_height"
                case maxWidth = "max_width"
            }
        }

        // parity: tui/src/config/v1/index.tsx#Info [status=implemented hash=5c3a557d673d]
        public struct Info: Equatable, Sendable, Codable {
            public var schema: String?
            public var theme: String?
            public var keybinds: Keybind.KeybindOverrides?
            public var plugin: [PluginSpec]?
            public var pluginEnabled: [String: Bool]?
            public var leaderTimeout: Int?
            public var attention: Attention?
            public var prompt: Prompt?
            public var scrollSpeed: Double?
            public var scrollAcceleration: ScrollAcceleration?
            public var diffStyle: DiffStyle?
            public var mouse: Bool?
            public var cursor: Cursor?

            public init(
                schema: String? = nil,
                theme: String? = nil,
                keybinds: Keybind.KeybindOverrides? = nil,
                plugin: [PluginSpec]? = nil,
                pluginEnabled: [String: Bool]? = nil,
                leaderTimeout: Int? = nil,
                attention: Attention? = nil,
                prompt: Prompt? = nil,
                scrollSpeed: Double? = nil,
                scrollAcceleration: ScrollAcceleration? = nil,
                diffStyle: DiffStyle? = nil,
                mouse: Bool? = nil,
                cursor: Cursor? = nil
            ) {
                self.schema = schema
                self.theme = theme
                self.keybinds = keybinds
                self.plugin = plugin
                self.pluginEnabled = pluginEnabled
                self.leaderTimeout = leaderTimeout
                self.attention = attention
                self.prompt = prompt
                self.scrollSpeed = scrollSpeed
                self.scrollAcceleration = scrollAcceleration
                self.diffStyle = diffStyle
                self.mouse = mouse
                self.cursor = cursor
            }

            enum CodingKeys: String, CodingKey {
                case schema = "$schema"
                case theme, keybinds, plugin, attention, prompt, mouse, cursor
                case pluginEnabled = "plugin_enabled"
                case leaderTimeout = "leader_timeout"
                case scrollSpeed = "scroll_speed"
                case scrollAcceleration = "scroll_acceleration"
                case diffStyle = "diff_style"
            }
        }

        public struct ResolvedAttention: Equatable, Hashable, Sendable {
            public var enabled: Bool
            public var notifications: Bool
            public var sound: Bool
            public var volume: Double
            public var soundPack: String
            public var sounds: AttentionSoundPaths

            public init(
                enabled: Bool = false,
                notifications: Bool = true,
                sound: Bool = true,
                volume: Double = 0.4,
                soundPack: String = "opencode.default",
                sounds: AttentionSoundPaths = [:]
            ) {
                self.enabled = enabled
                self.notifications = notifications
                self.sound = sound
                self.volume = volume
                self.soundPack = soundPack
                self.sounds = sounds
            }
        }

        // parity: tui/src/config/v1/index.tsx#Resolved [status=implemented hash=ece161cec1d7]
        public struct Resolved: Equatable, Sendable {
            public var schema: String?
            public var theme: String?
            public var plugin: [PluginSpec]?
            public var pluginEnabled: [String: Bool]?
            public var prompt: Prompt?
            public var scrollSpeed: Double?
            public var scrollAcceleration: ScrollAcceleration?
            public var diffStyle: DiffStyle?
            public var attention: ResolvedAttention
            public var keybinds: Keybind.BindingLookupView
            public var leaderTimeout: Int
            public var mouse: Bool
            public var cursor: TUIConfig.ResolvedCursor?

            /// Migrates a resolved V1 configuration into a V2 `TUIConfig.Info` payload.
            public func migrateToV2() -> TUIConfig.Info {
                var v2Keybinds: TUIConfig.Keybind.KeybindOverrides = [:]
                for (k, v) in keybinds.rawKeybinds {
                    let mapped = Keybind.CommandMap[k] ?? k
                    if TUIConfig.Keybind.Definitions[mapped] != nil {
                        v2Keybinds[mapped] = v
                    }
                }
                let v2Plugins: [TUIConfig.Plugin]? = plugin?.map { spec in
                    switch spec {
                    case .name(let s): return .specifier(s)
                    case .tuple(let s, let opts): return .configured(package: s, options: opts)
                    }
                }
                let v2DiffView: String? = diffStyle.map { $0 == .stacked ? "unified" : "auto" }
                return TUIConfig.Info(
                    theme: theme.map { ThemeConfig(name: $0) },
                    keybinds: v2Keybinds,
                    plugins: v2Plugins,
                    leader: LeaderConfig(timeout: leaderTimeout),
                    scroll: (scrollSpeed != nil || scrollAcceleration != nil)
                        ? ScrollConfig(speed: scrollSpeed, acceleration: scrollAcceleration?.enabled)
                        : nil,
                    attention: AttentionConfig(
                        notifications: attention.enabled && attention.notifications,
                        sound: attention.enabled && attention.sound,
                        volume: attention.volume,
                        soundPack: attention.soundPack,
                        sounds: attention.sounds
                    ),
                    diffs: v2DiffView.map { DiffsConfig(view: $0) },
                    mouse: mouse,
                    cursor: cursor.map { Cursor(style: $0.style, blinking: $0.blinking) }
                )
            }
        }

        // parity: tui/src/config/v1/index.tsx#ResolveOptions [status=implemented hash=78dc4a81e6de]
        public struct ResolveOptions: Equatable, Hashable, Sendable, Codable {
            public var terminalSuspend: Bool

            public init(terminalSuspend: Bool = true) {
                self.terminalSuspend = terminalSuspend
            }
        }

        // parity: tui/src/config/v1/index.tsx#resolve [status=implemented hash=469bfc9acf18]
        public static func resolve(_ input: Info, options: ResolveOptions = ResolveOptions()) -> Resolved {
            var overrides = input.keybinds ?? [:]
            if !options.terminalSuspend {
                overrides["terminal_suspend"] = .disabled
                if overrides["input_undo"] == nil {
                    var parts = ["ctrl+z"]
                    if let def = Keybind.defaultValue("input_undo")?.stringValue, def != "none" {
                        for item in def.split(separator: ",").map(String.init) where !parts.contains(item) {
                            parts.append(item)
                        }
                    }
                    overrides["input_undo"] = .item(.sequence(parts.joined(separator: ",")))
                }
            }
            let parsed = (try? Keybind.parse(overrides)) ?? Keybind.Definitions.mapValues(\.defaultValue)
            let lookup = (try? createBindingLookup(
                Keybind.toBindingConfig(parsed),
                options: CreateBindingLookupOptions(
                    commandMap: Keybind.CommandMap,
                    bindingDefaults: Keybind.bindingDefaults()
                )
            )) ?? (try! createBindingLookup([:]))

            return Resolved(
                schema: input.schema,
                theme: input.theme,
                plugin: input.plugin,
                pluginEnabled: input.pluginEnabled,
                prompt: input.prompt,
                scrollSpeed: input.scrollSpeed,
                scrollAcceleration: input.scrollAcceleration,
                diffStyle: input.diffStyle,
                attention: ResolvedAttention(
                    enabled: input.attention?.enabled ?? false,
                    notifications: input.attention?.notifications ?? true,
                    sound: input.attention?.sound ?? true,
                    volume: input.attention?.volume ?? 0.4,
                    soundPack: input.attention?.soundPack ?? "opencode.default",
                    sounds: input.attention?.sounds ?? [:]
                ),
                keybinds: Keybind.BindingLookupView(lookup: lookup, rawKeybinds: parsed),
                leaderTimeout: input.leaderTimeout ?? LeaderTimeoutDefault,
                mouse: input.mouse ?? true,
                cursor: input.cursor.map {
                    TUIConfig.ResolvedCursor(style: $0.style ?? .block, blinking: $0.blinking ?? true)
                }
            )
        }

        @TaskLocal private static var currentV1Config: Resolved?

        // parity: tui/src/config/v1/index.tsx#TuiConfigProvider [status=adapted hash=cb1566bcb8e1]
        public static func TuiConfigProvider<R>(config: Resolved, body: () throws -> R) rethrows -> R {
            try $currentV1Config.withValue(config, operation: body)
        }

        // parity: tui/src/config/v1/index.tsx#useTuiConfig [status=adapted hash=97ee1edcc5da]
        public static func useTuiConfig() throws(ConfigError) -> Resolved {
            guard let value = currentV1Config else { throw .missingContext("TuiConfigProvider") }
            return value
        }
    }
}

// MARK: - TUI Contexts (`packages/tui/src/context/*`)

/// Scoped reactive contexts powering the OpenCode TUI host (args, attention, clipboard, editor, keymap,
/// location, log, panel, program status, routes, runtime, session tabs, storage, theme, thinking, updates).
public enum TUIContext {
    // MARK: - Context Helper (`packages/tui/src/context/helper.tsx`)

    public final class SimpleContext<T: Sendable>: @unchecked Sendable {
        public let name: String
        private let state = Mutex<[T]>([])

        public init(name: String) {
            self.name = name
        }

        public func provide<R>(_ value: T, body: () throws -> R) rethrows -> R {
            state.withLock { $0.append(value) }
            defer { _ = state.withLock { $0.popLast() } }
            return try body()
        }

        public func use() throws(TUIConfig.ConfigError) -> T {
            guard let value = state.withLock({ $0.last }) else {
                throw .missingContext("\(name) context")
            }
            return value
        }

        public func useOptional() -> T? {
            state.withLock { $0.last }
        }
    }

    // parity: tui/src/context/helper.tsx#createSimpleContext [status=adapted hash=dda8dd5933a8]
    public static func createSimpleContext<T: Sendable>(name: String) -> SimpleContext<T> {
        SimpleContext<T>(name: name)
    }

    // MARK: - Args (`packages/tui/src/context/args.tsx`)

    // parity: tui/src/context/args.tsx#Args [status=implemented hash=95661db031e7]
    public struct Args: Equatable, Hashable, Sendable, Codable {
        public var model: String?
        public var agent: String?
        public var prompt: String?
        public var `continue`: Bool?
        public var sessionID: String?
        public var newSessionID: String?
        public var fork: Bool?
        public var auto: Bool?

        public init(
            model: String? = nil,
            agent: String? = nil,
            prompt: String? = nil,
            continue shouldContinue: Bool? = nil,
            sessionID: String? = nil,
            newSessionID: String? = nil,
            fork: Bool? = nil,
            auto: Bool? = nil
        ) {
            self.model = model
            self.agent = agent
            self.prompt = prompt
            self.`continue` = shouldContinue
            self.sessionID = sessionID
            self.newSessionID = newSessionID
            self.fork = fork
            self.auto = auto
        }
    }

    public final class ArgsController: @unchecked Sendable {
        public let args: Args
        private let pending: Mutex<String?>

        public init(_ args: Args) {
            self.args = args
            self.pending = Mutex(args.newSessionID)
        }

        public var model: String? { args.model }
        public var agent: String? { args.agent }
        public var prompt: String? { args.prompt }
        public var `continue`: Bool? { args.`continue` }
        public var sessionID: String? { args.sessionID }
        public var fork: Bool? { args.fork }
        public var auto: Bool? { args.auto }

        public func takeNewSessionID() -> String? {
            pending.withLock { value in
                let id = value
                value = nil
                return id
            }
        }

        public func restoreNewSessionID(_ id: String) {
            pending.withLock { value in
                if value == nil { value = id }
            }
        }
    }

    @TaskLocal private static var currentArgs: ArgsController?

    // parity: tui/src/context/args.tsx#ArgsProvider [status=adapted hash=b7615a4e6956]
    public static func ArgsProvider<R>(_ args: Args = Args(), body: () throws -> R) rethrows -> R {
        try $currentArgs.withValue(ArgsController(args), operation: body)
    }

    // parity: tui/src/context/args.tsx#useArgs [status=adapted hash=b7615a4e6956]
    public static func useArgs() throws(TUIConfig.ConfigError) -> ArgsController {
        guard let value = currentArgs else { throw .missingContext("ArgsProvider") }
        return value
    }

    // MARK: - Client & Data Contexts (`packages/tui/src/context/client.tsx`, `data.tsx`)

    public final class ClientService: @unchecked Sendable {
        public let api: OpenCodeClient
        public let url: String?
        public let headers: [String: String]?
        public let media: TUIUtil.MediaCache
        public let eventBus: ClientDataEventBus
        public let reconnect: (@Sendable (AbortSignal) async throws -> OpenCodeClient)?
        public let restart: (@Sendable () async throws -> Void)?

        public init(
            api: OpenCodeClient,
            url: String? = nil,
            headers: [String: String]? = nil,
            media: TUIUtil.MediaCache? = nil,
            eventBus: ClientDataEventBus = ClientDataEventBus(),
            reconnect: (@Sendable (AbortSignal) async throws -> OpenCodeClient)? = nil,
            restart: (@Sendable () async throws -> Void)? = nil
        ) {
            self.api = api
            self.url = url
            self.headers = headers
            self.media = media ?? TUIUtil.createMediaCache(fetcher: { _ in [] })
            self.eventBus = eventBus
            self.reconnect = reconnect
            self.restart = restart
        }
    }

    // parity: tui/src/context/client.tsx#ClientContext [status=adapted hash=0791d9c697e6]
    public static let ClientContext: SimpleContext<ClientService> = createSimpleContext(name: "Client")

    @TaskLocal private static var currentClient: ClientService?

    // parity: tui/src/context/client.tsx#ClientProvider [status=adapted hash=0791d9c697e6]
    public static func ClientProvider<R>(_ service: ClientService, body: () throws -> R) rethrows -> R {
        try ClientContext.provide(service) {
            try $currentClient.withValue(service, operation: body)
        }
    }

    // parity: tui/src/context/client.tsx#useClient [status=adapted hash=0791d9c697e6]
    public static func useClient() throws(TUIConfig.ConfigError) -> ClientService {
        if let value = currentClient { return value }
        return try ClientContext.use()
    }

    public final class DataContextController: @unchecked Sendable {
        public let directory: String
        public let store: ClientDataStore

        public init(directory: String, store: ClientDataStore) {
            self.directory = directory
            self.store = store
        }

        public convenience init(
            directory: String,
            client: ClientService,
            initialMessageLimit: (@Sendable () -> Int)? = nil
        ) {
            let api = client.api
            let store = createData(CreateDataInput(
                api: { api },
                directory: directory,
                initialMessageLimit: initialMessageLimit,
                event: client.eventBus
            ))
            self.init(directory: directory, store: store)
        }
    }

    @TaskLocal private static var currentData: DataContextController?

    // parity: tui/src/context/data.tsx#DataProvider [status=adapted hash=1db89bbd0b9a]
    public static func DataProvider<R>(_ controller: DataContextController, body: () throws -> R) rethrows -> R {
        try $currentData.withValue(controller, operation: body)
    }

    public static func DataProvider<R>(directory: String, body: () throws -> R) throws -> R {
        let client = try useClient()
        let controller = DataContextController(directory: directory, client: client)
        return try $currentData.withValue(controller, operation: body)
    }

    // parity: tui/src/context/data.tsx#useData [status=adapted hash=1db89bbd0b9a]
    public static func useData() throws(TUIConfig.ConfigError) -> DataContextController {
        guard let value = currentData else { throw .missingContext("DataProvider") }
        return value
    }

    // MARK: - Attention Context (`packages/tui/src/context/attention.tsx`)

    @TaskLocal private static var currentAttention: PluginTui.Attention?

    // parity: tui/src/context/attention.tsx#AttentionProvider [status=adapted hash=f82dbf1be62e]
    public static func AttentionProvider<R>(
        renderer: any TUIAttention.AttentionRenderer,
        config: TUIConfig.ResolvedAttention,
        audio: TUIAttention.AudioBackend = TUIAttention.AudioBackend(),
        body: () throws -> R
    ) rethrows -> R {
        let host = TUIAttention.createTuiAttention(renderer: renderer, config: config, audio: audio)
        defer { host.dispose() }
        return try $currentAttention.withValue(host.attention, operation: body)
    }

    // parity: tui/src/context/attention.tsx#useAttention [status=adapted hash=0e6b343a9e85]
    public static func useAttention() throws(TUIConfig.ConfigError) -> PluginTui.Attention {
        guard let value = currentAttention else { throw .missingContext("AttentionProvider") }
        return value
    }

    // MARK: - Client MCP (`packages/tui/src/context/client-mcp.tsx`)

    public struct ClientMcpToolDescriptor: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let description: String

        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }
    }

    public struct ClientMcpHandle: Sendable {
        public let enabled: Bool
        public let directory: String
        public let tools: [ClientMcpToolDescriptor]
        public let close: @Sendable () -> Void

        public init(
            enabled: Bool,
            directory: String,
            tools: [ClientMcpToolDescriptor],
            close: @escaping @Sendable () -> Void = {}
        ) {
            self.enabled = enabled
            self.directory = directory
            self.tools = tools
            self.close = close
        }
    }

    /// Initializes the client-side `"tui"` MCP tool registration (`open_terminal`, `write_terminal`).
    // parity: tui/src/context/client-mcp.tsx#ClientMcp [status=adapted hash=403e9c96faed]
    public static func ClientMcp(enabled: Bool, directory: String) -> ClientMcpHandle {
        let tools: [ClientMcpToolDescriptor] = enabled
            ? [
                ClientMcpToolDescriptor(
                    name: "open_terminal",
                    description: "Open a terminal for the current session in the user's TUI, without taking keyboard focus."
                ),
                ClientMcpToolDescriptor(
                    name: "write_terminal",
                    description: "Type text into the current session's terminal in the user's TUI, opening one first if needed."
                ),
            ]
            : []
        return ClientMcpHandle(enabled: enabled, directory: directory, tools: tools)
    }

    // MARK: - Clipboard Context (`packages/tui/src/context/clipboard.tsx`)

    // parity: tui/src/context/clipboard.tsx#ClipboardContent [status=implemented hash=efbfd998cae3]
    public struct ClipboardContent: Equatable, Hashable, Sendable, Codable {
        public let data: String
        public let mime: String

        public init(data: String, mime: String) {
            self.data = data
            self.mime = mime
        }
    }

    // parity: tui/src/context/clipboard.tsx#ClipboardService [status=implemented hash=2ee33f84d704]
    public struct ClipboardService: Sendable {
        public let read: @Sendable () async throws -> ClipboardContent?
        public let write: @Sendable (String) async throws -> Void

        public init(
            read: @escaping @Sendable () async throws -> ClipboardContent? = { nil },
            write: @escaping @Sendable (String) async throws -> Void = { _ in }
        ) {
            self.read = read
            self.write = write
        }
    }

    @TaskLocal private static var currentClipboard: ClipboardService?

    // parity: tui/src/context/clipboard.tsx#ClipboardProvider [status=adapted hash=1753c29deabb]
    public static func ClipboardProvider<R>(value: ClipboardService, body: () throws -> R) rethrows -> R {
        try $currentClipboard.withValue(value, operation: body)
    }

    // parity: tui/src/context/clipboard.tsx#useClipboard [status=adapted hash=24ffad149e16]
    public static func useClipboard() throws(TUIConfig.ConfigError) -> ClipboardService {
        guard let value = currentClipboard else { throw .missingContext("ClipboardProvider") }
        return value
    }

    // MARK: - Editor Context (`packages/tui/src/context/editor.ts`)

    public struct EditorPosition: Equatable, Hashable, Sendable, Codable {
        public let line: Int
        public let character: Int

        public init(line: Int, character: Int) {
            self.line = line
            self.character = character
        }
    }

    public struct EditorSelectionSpan: Equatable, Hashable, Sendable, Codable {
        public let start: EditorPosition
        public let end: EditorPosition

        public init(start: EditorPosition, end: EditorPosition) {
            self.start = start
            self.end = end
        }
    }

    public struct EditorSelectionRange: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public let selection: EditorSelectionSpan

        public init(text: String, selection: EditorSelectionSpan) {
            self.text = text
            self.selection = selection
        }
    }

    public enum EditorSelectionSource: String, Equatable, Hashable, Sendable, Codable {
        case websocket
        case zed
    }

    // parity: tui/src/context/editor.ts#EditorSelection [status=implemented hash=a227335e1d0f]
    public struct EditorSelection: Equatable, Hashable, Sendable, Codable {
        public let filePath: String
        public let source: EditorSelectionSource?
        public let ranges: [EditorSelectionRange]

        public init(filePath: String, source: EditorSelectionSource? = nil, ranges: [EditorSelectionRange]) {
            self.filePath = filePath
            self.source = source
            self.ranges = ranges
        }
    }

    // parity: tui/src/context/editor.ts#EditorMention [status=implemented hash=154e33c2fc82]
    public struct EditorMention: Equatable, Hashable, Sendable, Codable {
        public let filePath: String
        public let lineStart: Int
        public let lineEnd: Int

        public init(filePath: String, lineStart: Int, lineEnd: Int) {
            self.filePath = filePath
            self.lineStart = lineStart
            self.lineEnd = lineEnd
        }
    }

    // parity: tui/src/context/editor.ts#EditorLabelState [status=implemented hash=6333a3125da9]
    public enum EditorLabelState: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case pending
        case sent
        case none
    }

    public struct EditorConnection: Equatable, Hashable, Sendable, Codable {
        public let url: String
        public let authToken: String?
        public let source: String

        public init(url: String, authToken: String? = nil, source: String) {
            self.url = url
            self.authToken = authToken
            self.source = source
        }
    }

    // parity: tui/src/context/editor.ts#EditorIntegration [status=implemented hash=19ed5eddfab1]
    public struct EditorIntegration: Sendable {
        public let connection: (@Sendable (String) -> EditorConnection?)?
        public let selection: (@Sendable (String) async -> TUIEditor.ZedSelectionResult)?

        public init(
            connection: (@Sendable (String) -> EditorConnection?)? = nil,
            selection: (@Sendable (String) async -> TUIEditor.ZedSelectionResult)? = nil
        ) {
            self.connection = connection
            self.selection = selection
        }
    }

    // parity: tui/src/context/editor.ts#editorSelectionKey [status=implemented hash=ff262f0009be]
    public static func editorSelectionKey(_ selection: EditorSelection?) -> String {
        guard let selection else { return "" }
        var parts = [selection.filePath]
        for range in selection.ranges {
            parts.append(String(range.selection.start.line))
            parts.append(String(range.selection.start.character))
            parts.append(String(range.selection.end.line))
            parts.append(String(range.selection.end.character))
            parts.append(range.text)
        }
        return parts.joined(separator: "\u{0}")
    }

    public final class EditorContextController: @unchecked Sendable {
        private struct Inner: Sendable {
            var selection: EditorSelection?
            var labelState: EditorLabelState
            var connected: Bool
            var editorName: String?
            var sentSelectionKey: String
        }

        private let state: Mutex<Inner>

        public init(
            selection: EditorSelection? = nil,
            labelState: EditorLabelState = .none,
            connected: Bool = false,
            editorName: String? = nil
        ) {
            self.state = Mutex(Inner(
                selection: selection,
                labelState: labelState,
                connected: connected,
                editorName: editorName,
                sentSelectionKey: ""
            ))
        }

        public var selection: EditorSelection? { state.withLock { $0.selection } }
        public var labelState: EditorLabelState { state.withLock { $0.labelState } }
        public var connected: Bool { state.withLock { $0.connected } }
        public var editorName: String? { state.withLock { $0.editorName } }

        public func setSelection(_ next: EditorSelection?, connected: Bool = true, editorName: String? = nil) {
            state.withLock { s in
                s.selection = next
                s.connected = connected
                if let editorName { s.editorName = editorName }
                guard let next else {
                    s.labelState = .none
                    return
                }
                let key = TUIContext.editorSelectionKey(next)
                s.labelState = (key == s.sentSelectionKey && !key.isEmpty) ? .sent : .pending
            }
        }

        public func markSent() {
            state.withLock { s in
                let key = TUIContext.editorSelectionKey(s.selection)
                s.sentSelectionKey = key
                s.labelState = key.isEmpty ? .none : .sent
            }
        }

        public func clearSelection() {
            setSelection(nil, connected: state.withLock { $0.connected })
        }

        public func currentMention() -> EditorMention? {
            guard let sel = selection, let first = sel.ranges.first else { return nil }
            return EditorMention(
                filePath: sel.filePath,
                lineStart: first.selection.start.line + 1,
                lineEnd: first.selection.end.line + 1
            )
        }
    }

    @TaskLocal private static var currentEditorContext: EditorContextController?

    // parity: tui/src/context/editor.ts#EditorContextProvider [status=adapted hash=3f02badb4ede]
    public static func EditorContextProvider<R>(
        controller: EditorContextController = EditorContextController(),
        body: () throws -> R
    ) rethrows -> R {
        try $currentEditorContext.withValue(controller, operation: body)
    }

    // parity: tui/src/context/editor.ts#useEditorContext [status=adapted hash=3f02badb4ede]
    public static func useEditorContext() throws(TUIConfig.ConfigError) -> EditorContextController {
        guard let value = currentEditorContext else { throw .missingContext("EditorContextProvider") }
        return value
    }

    // MARK: - Epilogue, Event & Exit (`epilogue.tsx`, `event.ts`, `exit.tsx`)

    public struct SessionEpilogueInfo: Equatable, Hashable, Sendable, Codable {
        public let sessionID: String
        public let title: String?

        public init(sessionID: String, title: String? = nil) {
            self.sessionID = sessionID
            self.title = title
        }
    }

    // parity: tui/src/context/epilogue.tsx#Epilogue [status=implemented hash=76e0f916c3de]
    public struct Epilogue: Sendable {
        public let session: @Sendable (SessionEpilogueInfo?) -> Void
        public let updatedVersion: @Sendable (String) -> Void

        public init(
            session: @escaping @Sendable (SessionEpilogueInfo?) -> Void = { _ in },
            updatedVersion: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            self.session = session
            self.updatedVersion = updatedVersion
        }
    }

    @TaskLocal private static var currentEpilogue: Epilogue?

    // parity: tui/src/context/epilogue.tsx#EpilogueProvider [status=adapted hash=7297edf78eb3]
    public static func EpilogueProvider<R>(value: Epilogue, body: () throws -> R) rethrows -> R {
        try $currentEpilogue.withValue(value, operation: body)
    }

    // parity: tui/src/context/epilogue.tsx#useEpilogue [status=adapted hash=7297edf78eb3]
    public static func useEpilogue() throws(TUIConfig.ConfigError) -> Epilogue {
        guard let value = currentEpilogue else { throw .missingContext("EpilogueProvider") }
        return value
    }

    public struct EventMetadata: Equatable, Hashable, Sendable {
        public let directory: String?

        public init(directory: String? = nil) {
            self.directory = directory
        }
    }

    public final class EventHub: @unchecked Sendable {
        private let listeners = Mutex<[UInt64: (type: String?, handler: @Sendable (PluginSDK.EventPayload, EventMetadata) -> Void)]>([:])
        private let nextID = Mutex<UInt64>(1)

        public init() {}

        public func subscribe(
            _ handler: @escaping @Sendable (PluginSDK.EventPayload, EventMetadata) -> Void
        ) -> @Sendable () -> Void {
            let id = nextID.withLock { v -> UInt64 in let c = v; v &+= 1; return c }
            listeners.withLock { $0[id] = (nil, handler) }
            return { [weak self] in _ = self?.listeners.withLock { $0.removeValue(forKey: id) } }
        }

        public func on(
            _ type: String,
            _ handler: @escaping @Sendable (PluginSDK.EventPayload, EventMetadata) -> Void
        ) -> @Sendable () -> Void {
            let id = nextID.withLock { v -> UInt64 in let c = v; v &+= 1; return c }
            listeners.withLock { $0[id] = (type, handler) }
            return { [weak self] in _ = self?.listeners.withLock { $0.removeValue(forKey: id) } }
        }

        public func emit(_ payload: PluginSDK.EventPayload, metadata: EventMetadata = EventMetadata()) {
            let snapshot = listeners.withLock { Array($0.values) }
            for entry in snapshot {
                if let expected = entry.type {
                    if payload.type == expected { entry.handler(payload, metadata) }
                } else if payload.type != "server.connected" {
                    entry.handler(payload, metadata)
                }
            }
        }
    }

    @TaskLocal private static var currentEventHub: EventHub?

    public static func EventProvider<R>(hub: EventHub, body: () throws -> R) rethrows -> R {
        try $currentEventHub.withValue(hub, operation: body)
    }

    // parity: tui/src/context/event.ts#useEvent [status=adapted hash=e5cf5e4e6d3f]
    public static func useEvent() -> EventHub {
        currentEventHub ?? EventHub()
    }

    // parity: tui/src/context/exit.tsx#Exit [status=implemented hash=f89607ea3849]
    public typealias Exit = @Sendable (String?) -> Void

    @TaskLocal private static var currentExit: Exit?

    // parity: tui/src/context/exit.tsx#ExitProvider [status=adapted hash=c88091f70682]
    public static func ExitProvider<R>(exit: @escaping Exit, body: () throws -> R) rethrows -> R {
        try $currentExit.withValue(exit, operation: body)
    }

    // parity: tui/src/context/exit.tsx#useExit [status=adapted hash=c88091f70682]
    public static func useExit() throws(TUIConfig.ConfigError) -> Exit {
        guard let value = currentExit else { throw .missingContext("ExitProvider") }
        return value
    }

    // MARK: - Interactivity (`packages/tui/src/context/interactivity.tsx`)

    @TaskLocal private static var currentInteractivity: (@Sendable () -> Bool)?

    // parity: tui/src/context/interactivity.tsx#InteractivityProvider [status=adapted hash=2a582fd223da]
    public static func InteractivityProvider<R>(enabled: Bool, body: () throws -> R) rethrows -> R {
        let parent = useInteractivity()
        let combined: @Sendable () -> Bool = { parent() && enabled }
        return try $currentInteractivity.withValue(combined, operation: body)
    }

    // parity: tui/src/context/interactivity.tsx#useInteractivity [status=adapted hash=6fcbfb21fc1e]
    public static func useInteractivity() -> @Sendable () -> Bool {
        currentInteractivity ?? { true }
    }

    // parity: tui/src/context/interactivity.tsx#resolveInteractivity [status=adapted hash=2e16f8e767ea]
    public static func resolveInteractivity(fallback: @escaping @Sendable () -> Bool) -> @Sendable () -> Bool {
        currentInteractivity ?? fallback
    }

    // MARK: - Keymap Context (`packages/tui/src/context/keymap.tsx`)

    // parity: tui/src/context/keymap.tsx#COMMAND_PALETTE_COMMAND [status=implemented hash=2ebbac71a085]
    public static let COMMAND_PALETTE_COMMAND = "command.palette.show"

    public struct KeymapModeController: Sendable {
        public let current: @Sendable () -> String
        public let push: @Sendable (_ mode: String, _ active: (@Sendable () -> Bool)?) -> @Sendable () -> Void

        public init(
            current: @escaping @Sendable () -> String,
            push: @escaping @Sendable (_ mode: String, _ active: (@Sendable () -> Bool)?) -> @Sendable () -> Void
        ) {
            self.current = current
            self.push = push
        }
    }

    // parity: tui/src/context/keymap.tsx#Keymap [status=adapted hash=dcf486c885b0]
    public protocol Keymap: Sendable {
        func dispatch(_ id: String, input: String?)
        var mode: KeymapModeController { get }
        func isLeader(_ event: OpenTUIKeyEventAdapter) -> Bool
    }

    /// Concrete `TUIContext.Keymap` runtime backed by `TUIConfig.Keybind.BindingLookupView` and a mode stack.
    public final class DefaultKeymapRuntime: Keymap, @unchecked Sendable {
        private struct ModeEntry: Sendable {
            let id: UInt64
            let mode: String
            let enabled: @Sendable () -> Bool
        }

        private let config: TUIConfig.Keybind.BindingLookupView
        private let handlers = Mutex<[String: @Sendable (String?) -> Void]>([:])
        private let modeStack = Mutex<[ModeEntry]>([])
        private let nextModeID = Mutex<UInt64>(1)

        public init(config: TUIConfig.Keybind.BindingLookupView) {
            self.config = config
        }

        public func registerCommand(_ id: String, handler: @escaping @Sendable (String?) -> Void) {
            handlers.withLock { $0[id] = handler }
        }

        public func dispatch(_ id: String, input: String? = nil) {
            let fn = handlers.withLock { $0[id] }
            fn?(input)
        }

        public var mode: KeymapModeController {
            KeymapModeController(
                current: { [weak self] in
                    guard let self else { return "base" }
                    return self.modeStack.withLock { stack in
                        stack.last(where: { $0.enabled() })?.mode ?? "base"
                    }
                },
                push: { [weak self] name, active in
                    guard let self else { return {} }
                    let id = self.nextModeID.withLock { v -> UInt64 in let c = v; v &+= 1; return c }
                    let pred = active ?? { true }
                    self.modeStack.withLock { $0.append(ModeEntry(id: id, mode: name, enabled: pred)) }
                    return { [weak self] in
                        self?.modeStack.withLock { $0.removeAll { $0.id == id } }
                    }
                }
            )
        }

        public func isLeader(_ event: OpenTUIKeyEventAdapter) -> Bool {
            guard let leaderKey = config.rawKeybinds["leader"]?.stringValue, leaderKey != "none" else {
                return false
            }
            let parts = leaderKey.lowercased().split(separator: "+").map(String.init)
            guard let keyName = parts.last, !keyName.isEmpty else { return false }
            let mods = Set(parts.dropLast())
            let wantCtrl = mods.contains("ctrl") || mods.contains("control")
            let wantShift = mods.contains("shift")
            let wantMeta = mods.contains("meta") || mods.contains("alt") || mods.contains("option")
            let wantSuper = mods.contains("super") || mods.contains("cmd") || mods.contains("command")
            return event.name.lowercased() == keyName
                && event.ctrl == wantCtrl
                && event.shift == wantShift
                && event.meta == wantMeta
                && (event.`super` ?? false) == wantSuper
        }
    }

    // MARK: - Location Context (`packages/tui/src/context/location.tsx`)

    public final class LocationState: @unchecked Sendable {
        public struct LocationError: Sendable {
            public let location: LocationSchema.Ref
            public let message: String

            public init(location: LocationSchema.Ref, message: String) {
                self.location = location
                self.message = message
            }
        }

        private struct Inner: Sendable {
            var current: LocationSchema.Ref?
            var ref: LocationSchema.Ref?
            var error: LocationError?
        }

        private let state: Mutex<Inner>

        public init(initial: LocationSchema.Ref? = nil) {
            self.state = Mutex(Inner(current: initial, ref: initial, error: nil))
        }

        public var current: LocationSchema.Ref? { state.withLock { $0.current } }
        public var ref: LocationSchema.Ref? { state.withLock { $0.ref } }
        public var error: LocationError? { state.withLock { $0.error } }

        public func set(_ location: LocationSchema.Ref?) {
            state.withLock {
                $0.ref = location
                $0.current = location
                $0.error = nil
            }
        }

        public func setError(_ error: LocationError?) {
            state.withLock { $0.error = error }
        }
    }

    @TaskLocal private static var currentLocation: LocationState?

    // parity: tui/src/context/location.tsx#LocationProvider [status=adapted hash=95a0a9712388]
    public static func LocationProvider<R>(initial: LocationSchema.Ref? = nil, body: () throws -> R) rethrows -> R {
        try $currentLocation.withValue(LocationState(initial: initial), operation: body)
    }

    // parity: tui/src/context/location.tsx#useLocation [status=adapted hash=82d6f116bb71]
    public static func useLocation() throws(TUIConfig.ConfigError) -> LocationState {
        guard let value = currentLocation else { throw .missingContext("LocationProvider") }
        return value
    }

    // MARK: - Local Context (`packages/tui/src/context/local.tsx`)

    public final class LocalStateController: @unchecked Sendable {
        private struct Inner: Sendable {
            var agents: [String]
            var currentAgent: String?
            var currentModel: TUIModelPreference.ModelPreferenceModel?
            var preference: TUIModelPreference.ModelPreference
            var variantByModel: [String: String]
        }

        private let state: Mutex<Inner>

        public init(
            agents: [String] = [],
            currentAgent: String? = nil,
            currentModel: TUIModelPreference.ModelPreferenceModel? = nil,
            preference: TUIModelPreference.ModelPreference = TUIModelPreference.ModelPreference(),
            variantByModel: [String: String] = [:]
        ) {
            self.state = Mutex(Inner(
                agents: agents,
                currentAgent: currentAgent ?? agents.first,
                currentModel: currentModel,
                preference: preference,
                variantByModel: variantByModel
            ))
        }

        public var agents: [String] { state.withLock { $0.agents } }
        public var currentAgent: String? { state.withLock { $0.currentAgent } }
        public var currentModel: TUIModelPreference.ModelPreferenceModel? { state.withLock { $0.currentModel } }
        public var recentModels: [TUIModelPreference.ModelPreferenceModel] { state.withLock { $0.preference.recent } }
        public var favoriteModels: [TUIModelPreference.ModelPreferenceModel] { state.withLock { $0.preference.favorite } }

        public func setAgents(_ next: [String]) {
            state.withLock { s in
                s.agents = next
                if let current = s.currentAgent, !next.contains(current) {
                    s.currentAgent = next.first
                } else if s.currentAgent == nil {
                    s.currentAgent = next.first
                }
            }
        }

        public func setAgent(_ name: String) {
            state.withLock { s in
                if s.agents.isEmpty || s.agents.contains(name) {
                    s.currentAgent = name
                }
            }
        }

        public func moveAgent(_ delta: Int) -> String? {
            state.withLock { s in
                guard !s.agents.isEmpty else { return nil }
                let idx = s.currentAgent.flatMap { s.agents.firstIndex(of: $0) } ?? 0
                let nextIdx = ((idx + delta) % s.agents.count + s.agents.count) % s.agents.count
                s.currentAgent = s.agents[nextIdx]
                return s.currentAgent
            }
        }

        public func setModel(_ model: TUIModelPreference.ModelPreferenceModel, addToRecent: Bool = true) {
            state.withLock { s in
                s.currentModel = model
                if addToRecent {
                    s.preference.recent = TUIModelPreference.recentModels(model, recent: s.preference.recent)
                }
            }
        }

        public func toggleFavorite(_ model: TUIModelPreference.ModelPreferenceModel) {
            state.withLock { s in
                let key = TUIModelPreference.modelPreferenceKey(model)
                let isFav = s.preference.favorite.contains { TUIModelPreference.modelPreferenceKey($0) == key }
                s.preference.favorite = TUIModelPreference.favoriteModels(model, favorite: s.preference.favorite, enabled: !isFav)
            }
        }

        public func variant(for model: TUIModelPreference.ModelPreferenceModel? = nil) -> String? {
            state.withLock { s in
                guard let target = model ?? s.currentModel else { return nil }
                return s.variantByModel[TUIModelPreference.modelPreferenceKey(target)]
            }
        }

        public func setVariant(_ value: String?, for model: TUIModelPreference.ModelPreferenceModel? = nil) {
            state.withLock { s in
                guard let target = model ?? s.currentModel else { return }
                let key = TUIModelPreference.modelPreferenceKey(target)
                if let normalized = TUIModelPreference.normalizeModelVariant(value) {
                    s.variantByModel[key] = normalized
                } else {
                    s.variantByModel.removeValue(forKey: key)
                }
            }
        }

        public func cycleVariant(available variants: [String]) -> String? {
            state.withLock { s in
                guard let target = s.currentModel else { return nil }
                let key = TUIModelPreference.modelPreferenceKey(target)
                let next = TUIModelPreference.cycleModelVariant(s.variantByModel[key], variants: variants)
                if let next {
                    s.variantByModel[key] = next
                } else {
                    s.variantByModel.removeValue(forKey: key)
                }
                return next
            }
        }
    }

    @TaskLocal private static var currentLocal: LocalStateController?

    // parity: tui/src/context/local.tsx#LocalProvider [status=adapted hash=5dfdbeabb063]
    public static func LocalProvider<R>(
        controller: LocalStateController = LocalStateController(),
        body: () throws -> R
    ) rethrows -> R {
        try $currentLocal.withValue(controller, operation: body)
    }

    // parity: tui/src/context/local.tsx#useLocal [status=adapted hash=5dfdbeabb063]
    public static func useLocal() throws(TUIConfig.ConfigError) -> LocalStateController {
        guard let value = currentLocal else { throw .missingContext("LocalProvider") }
        return value
    }

    // MARK: - Log Context (`packages/tui/src/context/log.tsx`)

    // parity: tui/src/context/log.tsx#LogLevel [status=implemented hash=3bb628801397]
    public enum LogLevel: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case debug
        case info
        case warn
        case error
    }

    // parity: tui/src/context/log.tsx#LogTags [status=implemented hash=32a631386685]
    public typealias LogTags = [String: JSONValue]

    // parity: tui/src/context/log.tsx#LogSink [status=implemented hash=86ec019caa9f]
    public typealias LogSink = @Sendable (LogLevel, String, LogTags) -> Void

    public struct Logger: Sendable {
        private let sink: LogSink
        private let tags: LogTags

        init(sink: @escaping LogSink, tags: LogTags) {
            self.sink = sink
            self.tags = tags
        }

        private func write(_ level: LogLevel, _ message: String, _ extra: LogTags) {
            var merged = tags
            for (k, v) in extra { merged[k] = v }
            sink(level, message, merged)
        }

        public func debug(_ message: String, _ extra: LogTags = [:]) { write(.debug, message, extra) }
        public func info(_ message: String, _ extra: LogTags = [:]) { write(.info, message, extra) }
        public func warn(_ message: String, _ extra: LogTags = [:]) { write(.warn, message, extra) }
        public func error(_ message: String, _ extra: LogTags = [:]) { write(.error, message, extra) }
    }

    @TaskLocal private static var currentLogSink: LogSink?

    // parity: tui/src/context/log.tsx#LogProvider [status=adapted hash=c5dcf0e24fd1]
    public static func LogProvider<R>(log: @escaping LogSink, body: () throws -> R) rethrows -> R {
        try $currentLogSink.withValue(log, operation: body)
    }

    // parity: tui/src/context/log.tsx#useLog [status=adapted hash=9777fe03699a]
    public static func useLog(tags: LogTags = [:]) throws(TUIConfig.ConfigError) -> Logger {
        guard let sink = currentLogSink else { throw .missingContext("LogProvider") }
        return Logger(sink: sink, tags: tags)
    }

    // MARK: - Panel Context (`packages/tui/src/context/panel.tsx`)

    public static let sessionPanelSplitMinWidth = 120

    // parity: tui/src/context/panel.tsx#PanelTarget [status=implemented hash=a281fb61c775]
    public struct PanelTarget: Equatable, Hashable, Sendable, Codable {
        public let plugin: String
        public let name: String
        public let sessionID: String

        public init(plugin: String, name: String, sessionID: String) {
            self.plugin = plugin
            self.name = name
            self.sessionID = sessionID
        }
    }

    public final class PanelState: @unchecked Sendable {
        private struct Inner: Sendable {
            var current: PanelTarget? = nil
            var requested: PluginTui.PanelPresentation = .panel
            var width: Int = 0
        }

        private let state = Mutex(Inner())

        public init() {}

        public var current: PanelTarget? { state.withLock { $0.current } }
        public var width: Int { state.withLock { $0.width } }
        public var canSplit: Bool { width >= sessionPanelSplitMinWidth }
        public var presentation: PluginTui.PanelPresentation {
            state.withLock { $0.width >= sessionPanelSplitMinWidth ? $0.requested : .fullscreen }
        }

        public func setWidth(_ width: Int) {
            state.withLock { $0.width = width }
        }

        public func open(_ target: PanelTarget, presentation: PluginTui.PanelPresentation = .panel) {
            state.withLock {
                $0.requested = presentation
                if $0.current != target {
                    $0.current = target
                }
            }
        }

        public func close() {
            state.withLock { $0.current = nil }
        }

        public func release(plugin: String) {
            state.withLock {
                if $0.current?.plugin == plugin {
                    $0.current = nil
                }
            }
        }

        public func toggleFullscreen() {
            state.withLock {
                guard $0.width >= sessionPanelSplitMinWidth else { return }
                $0.requested = ($0.requested == .panel) ? .fullscreen : .panel
            }
        }
    }

    // parity: tui/src/context/panel.tsx#createPanelState [status=implemented hash=38286f4aa4af]
    public static func createPanelState() -> PanelState {
        PanelState()
    }

    @TaskLocal private static var currentPanel: PanelState?

    // parity: tui/src/context/panel.tsx#PanelProvider [status=adapted hash=1f03d6f3b765]
    public static func PanelProvider<R>(state: PanelState = createPanelState(), body: () throws -> R) rethrows -> R {
        try $currentPanel.withValue(state, operation: body)
    }

    // parity: tui/src/context/panel.tsx#usePanel [status=adapted hash=0f471f87085d]
    public static func usePanel() throws(TUIConfig.ConfigError) -> PanelState {
        guard let value = currentPanel else { throw .missingContext("PanelProvider") }
        return value
    }

    // parity: tui/src/context/panel.tsx#useOptionalPanel [status=adapted hash=850d8abd3b68]
    public static func useOptionalPanel() -> PanelState? {
        currentPanel
    }

    // MARK: - Path Format & Permission (`path-format.tsx`, `permission.tsx`)

    public struct PathFormatter: Sendable {
        public let base: String
        public let home: String

        public init(base: String, home: String) {
            self.base = base
            self.home = home
        }

        public func format(_ input: String?) -> String {
            guard let input, !input.isEmpty else { return "" }
            if !base.isEmpty && containsDirectory(base, input) {
                let normBase = comparablePath(base)
                let normInput = comparablePath(input)
                if normBase == normInput { return "." }
                let prefix = normBase.hasSuffix("/") ? normBase : "\(normBase)/"
                if normInput.hasPrefix(prefix) {
                    return String(normInput.dropFirst(prefix.count))
                }
            }
            if !home.isEmpty && containsDirectory(home, input) {
                let normHome = comparablePath(home)
                let normInput = comparablePath(input)
                if normHome == normInput { return "~" }
                let prefix = normHome.hasSuffix("/") ? normHome : "\(normHome)/"
                if normInput.hasPrefix(prefix) {
                    return "~/\(normInput.dropFirst(prefix.count))"
                }
            }
            return input
        }
    }

    // parity: tui/src/context/path-format.tsx#usePathFormatter [status=adapted hash=bade06214614]
    public static func usePathFormatter() -> PathFormatter {
        let cwd = TUIEditor.currentWorkingDirectory()
        let paths = currentPaths ?? TuiPaths(
            cwd: cwd,
            home: SystemEnvironment.shared.homeDirectory ?? "",
            state: GlobalPaths.roots().state,
            worktree: cwd
        )
        let base = currentLocation?.current?.directory.rawValue ?? paths.cwd
        return PathFormatter(base: base, home: paths.home)
    }

    // parity: tui/src/context/permission.tsx#PermissionMode [status=implemented hash=beb2bf2d3f58]
    public enum PermissionMode: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case prompt
        case autoaccept
    }

    public struct PermissionContextValue: Equatable, Hashable, Sendable {
        public let mode: PermissionMode

        public init(mode: PermissionMode) {
            self.mode = mode
        }
    }

    @TaskLocal private static var currentPermission: PermissionContextValue?

    // parity: tui/src/context/permission.tsx#PermissionProvider [status=adapted hash=f9dc09a40e9e]
    public static func PermissionProvider<R>(
        mode: PermissionMode? = nil,
        body: () throws -> R
    ) rethrows -> R {
        let resolved: PermissionMode
        if let mode {
            resolved = mode
        } else if currentArgs?.auto == true {
            resolved = .autoaccept
        } else if let cfg = try? TUIConfig.useConfig() {
            resolved = cfg.data.session.permissions
        } else {
            resolved = .prompt
        }
        return try $currentPermission.withValue(PermissionContextValue(mode: resolved), operation: body)
    }

    // parity: tui/src/context/permission.tsx#usePermission [status=adapted hash=f9dc09a40e9e]
    public static func usePermission() throws(TUIConfig.ConfigError) -> PermissionContextValue {
        guard let value = currentPermission else { throw .missingContext("PermissionProvider") }
        return value
    }

    // MARK: - PromptRef Context (`packages/tui/src/context/prompt.tsx`)

    public final class PromptRefBox: @unchecked Sendable {
        private let ref: Mutex<TUIComponent.PromptRef?>

        public init(current: TUIComponent.PromptRef? = nil) {
            self.ref = Mutex(current)
        }

        public var current: TUIComponent.PromptRef? {
            ref.withLock { $0 }
        }

        public func set(_ value: TUIComponent.PromptRef?) {
            ref.withLock { $0 = value }
        }
    }

    @TaskLocal private static var currentPromptRef: PromptRefBox?

    // parity: tui/src/context/prompt.tsx#PromptRefProvider [status=adapted hash=181eaa23e70d]
    public static func PromptRefProvider<R>(
        box: PromptRefBox = PromptRefBox(),
        body: () throws -> R
    ) rethrows -> R {
        try $currentPromptRef.withValue(box, operation: body)
    }

    // parity: tui/src/context/prompt.tsx#usePromptRef [status=adapted hash=181eaa23e70d]
    public static func usePromptRef() throws(TUIConfig.ConfigError) -> PromptRefBox {
        guard let value = currentPromptRef else { throw .missingContext("PromptRefProvider") }
        return value
    }

    // MARK: - Program Status OSC 7501 (`packages/tui/src/context/program-status.ts`)

    // parity: tui/src/context/program-status.ts#PendingSession [status=implemented hash=9a35ecda575b]
    public struct PendingSession: Equatable, Hashable, Sendable, Codable {
        public enum State: Equatable, Hashable, Sendable, Codable {
            case working
            case blocked(kind: ProgramStatusKind, message: String?)
        }

        public let id: String
        public let title: String?
        public let state: State

        public init(id: String, title: String? = nil, state: State) {
            self.id = id
            self.title = title
            self.state = state
        }
    }

    private static let programStatusApp = "opencode"

    private static func programStatusRecordID(_ id: String) -> String {
        let bytes = Array(id.utf8)
        let valid = !bytes.isEmpty && bytes.count <= 32 && bytes.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
                || b == 0x5F || b == 0x2E || b == 0x2B || b == 0x2D
        }
        if valid { return id }
        return "ses_\(Hash.sha256(id).prefix(16))"
    }

    private static func programStatusClip(_ input: String?, bytes limit: Int) -> String? {
        guard let input else { return nil }
        var cleaned = ""
        var inSpace = false
        for scalar in input.unicodeScalars {
            let v = scalar.value
            if v <= 0x1F || (v >= 0x7F && v <= 0x9F) || scalar.properties.isWhitespace {
                if !cleaned.isEmpty && !inSpace {
                    cleaned.append(" ")
                    inSpace = true
                }
            } else {
                cleaned.unicodeScalars.append(scalar)
                inSpace = false
            }
        }
        if cleaned.hasSuffix(" ") { cleaned.removeLast() }
        if cleaned.isEmpty { return nil }
        let utf8 = Array(cleaned.utf8)
        if utf8.count <= limit { return cleaned }
        let target = max(0, limit - 3)
        var cut = target
        while cut > 0 && (utf8[cut] & 0xC0) == 0x80 { cut -= 1 }
        return String(decoding: utf8[0..<cut], as: UTF8.self) + "…"
    }

    private static func programStatusRecord(_ session: PendingSession, id: String? = nil) -> ProgramStatus {
        let title = programStatusClip(session.title, bytes: 192)
        switch session.state {
        case .working:
            return ProgramStatus(state: .working, id: id, app: programStatusApp, title: title)
        case .blocked(let kind, let message):
            return ProgramStatus(
                state: .blocked,
                id: id,
                app: programStatusApp,
                title: title,
                message: programStatusClip(message, bytes: 2048),
                kind: kind
            )
        }
    }

    /// Computes OSC 7501 `ProgramStatus` reports: root (`""`) summary plus per-session child records.
    // parity: tui/src/context/program-status.ts#programStatusReports [status=implemented hash=c4a898906bb5]
    public static func programStatusReports(_ sessions: [PendingSession]) -> [String: ProgramStatus] {
        var out: [String: ProgramStatus] = [:]
        let blocked = sessions.filter {
            if case .blocked = $0.state { return true }
            return false
        }
        let working = sessions.filter {
            if case .working = $0.state { return true }
            return false
        }

        let rootStatus: ProgramStatus
        if blocked.count == 1 {
            rootStatus = programStatusRecord(blocked[0])
        } else if blocked.count > 1 {
            let kinds = blocked.compactMap { s -> ProgramStatusKind? in
                if case .blocked(let k, _) = s.state { return k }
                return nil
            }
            let uniformKind = kinds.first.flatMap { first in kinds.allSatisfy { $0 == first } ? first : nil }
            rootStatus = ProgramStatus(
                state: .blocked,
                app: programStatusApp,
                message: "\(blocked.count) sessions need input",
                kind: uniformKind
            )
        } else if working.count == 1 {
            rootStatus = programStatusRecord(working[0])
        } else if working.count > 1 {
            rootStatus = ProgramStatus(
                state: .working,
                app: programStatusApp,
                message: "\(working.count) sessions working"
            )
        } else {
            rootStatus = ProgramStatus(state: .idle, app: programStatusApp)
        }
        out[""] = rootStatus
        for session in sessions {
            let id = programStatusRecordID(session.id)
            out[id] = programStatusRecord(session, id: id)
        }
        return out
    }

    public final class ProgramStatusController: @unchecked Sendable {
        private let sendStatus: @Sendable (ProgramStatus) -> Bool
        private let sent = Mutex<[String: ProgramStatus]>([:])

        public init(setProgramStatus: @escaping @Sendable (ProgramStatus) -> Bool) {
            self.sendStatus = setProgramStatus
        }

        public func update(sessions: [PendingSession]) {
            let reports = programStatusReports(sessions)
            let existingKeys = sent.withLock { Array($0.keys) }
            for key in existingKeys where !key.isEmpty && reports[key] == nil {
                let clear = ProgramStatus(state: .clear, id: key)
                if sendStatus(clear) {
                    _ = sent.withLock { $0.removeValue(forKey: key) }
                }
            }
            for (key, status) in reports {
                let prev = sent.withLock { $0[key] }
                if prev != status, sendStatus(status) {
                    sent.withLock { $0[key] = status }
                }
            }
        }

        public func clear() {
            let clearStatus = ProgramStatus(state: .clear)
            if sendStatus(clearStatus) {
                sent.withLock { $0.removeAll() }
            }
        }
    }

    // parity: tui/src/context/program-status.ts#createProgramStatus [status=implemented hash=5e14455c36ea]
    public static func createProgramStatus(
        renderer: CliRenderer
    ) -> ProgramStatusController {
        ProgramStatusController { status in
            renderer.setProgramStatus(status)
        }
    }

    // MARK: - Route Context (`packages/tui/src/context/route.tsx`)

    // parity: tui/src/context/route.tsx#HomeRoute [status=implemented hash=53af8bdd6570]
    public struct HomeRoute: Equatable, Sendable {
        public var prompt: TUIPrompt.PromptInfo?
        public var location: LocationSchema.Ref?

        public init(prompt: TUIPrompt.PromptInfo? = nil, location: LocationSchema.Ref? = nil) {
            self.prompt = prompt
            self.location = location
        }
    }

    // parity: tui/src/context/route.tsx#SessionRoute [status=implemented hash=34a08258f55a]
    public struct SessionRoute: Equatable, Sendable {
        public var sessionID: String
        public var prompt: TUIPrompt.PromptInfo?

        public init(sessionID: String, prompt: TUIPrompt.PromptInfo? = nil) {
            self.sessionID = sessionID
            self.prompt = prompt
        }
    }

    // parity: tui/src/context/route.tsx#PluginRoute [status=implemented hash=71159d8b39aa]
    public struct PluginRoute: Equatable, Sendable {
        public var id: String
        public var name: String
        public var data: [String: JSONValue]?

        public init(id: String, name: String, data: [String: JSONValue]? = nil) {
            self.id = id
            self.name = name
            self.data = data
        }
    }

    // parity: tui/src/context/route.tsx#Route [status=implemented hash=8303ba5456d2]
    public enum Route: Equatable, Sendable {
        case home(HomeRoute)
        case session(SessionRoute)
        case plugin(PluginRoute)

        public var typeName: String {
            switch self {
            case .home: return "home"
            case .session: return "session"
            case .plugin: return "plugin"
            }
        }
    }

    public final class RouteController: @unchecked Sendable {
        private let state: Mutex<Route>
        private let history: Mutex<[Route]>

        public init(initial: Route = .home(HomeRoute())) {
            self.state = Mutex(initial)
            self.history = Mutex([initial])
        }

        public var data: Route { state.withLock { $0 } }
        public var navigationHistory: [Route] { history.withLock { $0 } }

        public func navigate(_ route: Route) {
            state.withLock { $0 = route }
            history.withLock { $0.append(route) }
        }
    }

    @TaskLocal private static var currentRoute: RouteController?

    // parity: tui/src/context/route.tsx#RouteProvider [status=adapted hash=f44b9bf285c8]
    public static func RouteProvider<R>(controller: RouteController, body: () throws -> R) rethrows -> R {
        try $currentRoute.withValue(controller, operation: body)
    }

    // parity: tui/src/context/route.tsx#useRoute [status=adapted hash=f44b9bf285c8]
    public static func useRoute() throws(TUIConfig.ConfigError) -> RouteController {
        guard let value = currentRoute else { throw .missingContext("RouteProvider") }
        return value
    }

    // parity: tui/src/context/route.tsx#useRouteData [status=adapted hash=12b266bebe9e]
    public static func useRouteData() throws(TUIConfig.ConfigError) -> Route {
        try useRoute().data
    }

    // MARK: - Runtime Contexts (`packages/tui/src/context/runtime.tsx`)

    // parity: tui/src/context/runtime.tsx#TuiHighlight [status=implemented hash=00175613a35d]
    public struct TuiHighlight: Equatable, Hashable, Sendable, Codable {
        public let title: String
        public let body: String

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    // parity: tui/src/context/runtime.tsx#TuiApp [status=implemented hash=f115e1d6dfe4]
    public struct TuiApp: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let version: String
        public let channel: String
        public let highlights: [TuiHighlight]?

        public init(name: String, version: String, channel: String, highlights: [TuiHighlight]? = nil) {
            self.name = name
            self.version = version
            self.channel = channel
            self.highlights = highlights
        }
    }

    // parity: tui/src/context/runtime.tsx#TuiPaths [status=implemented hash=30d3685d16f5]
    public struct TuiPaths: Equatable, Hashable, Sendable, Codable {
        public let cwd: String
        public let home: String
        public let state: String
        public let worktree: String

        public init(cwd: String, home: String, state: String, worktree: String) {
            self.cwd = cwd
            self.home = home
            self.state = state
            self.worktree = worktree
        }
    }

    // parity: tui/src/context/runtime.tsx#TuiTerminalEnvironment [status=implemented hash=5c321e34897a]
    public struct TuiTerminalEnvironment: Equatable, Hashable, Sendable, Codable {
        public let platform: String
        public let variables: [String: String]?
        public let localServer: Bool?

        public init(platform: String, variables: [String: String]? = nil, localServer: Bool? = nil) {
            self.platform = platform
            self.variables = variables
            self.localServer = localServer
        }
    }

    // parity: tui/src/context/runtime.tsx#TuiStartup [status=implemented hash=424e9314f919]
    public struct TuiStartup: Equatable, Sendable {
        public let initialRoute: Route?
        public let skipInitialLoading: Bool

        public init(initialRoute: Route? = nil, skipInitialLoading: Bool = false) {
            self.initialRoute = initialRoute
            self.skipInitialLoading = skipInitialLoading
        }
    }

    // parity: tui/src/context/runtime.tsx#TuiLifecycle [status=implemented hash=8572c6e23701]
    public struct TuiLifecycle: Sendable {
        public let add: @Sendable (@escaping @Sendable () async -> Void) -> @Sendable () -> Void

        public init(add: @escaping @Sendable (@escaping @Sendable () async -> Void) -> @Sendable () -> Void) {
            self.add = add
        }
    }

    @TaskLocal private static var currentPaths: TuiPaths?
    @TaskLocal private static var currentApp: TuiApp?
    @TaskLocal private static var currentTerminalEnv: TuiTerminalEnvironment?
    @TaskLocal private static var currentStartup: TuiStartup?
    @TaskLocal private static var currentLifecycle: TuiLifecycle?

    // parity: tui/src/context/runtime.tsx#TuiPathsProvider [status=adapted hash=beb1c80dbb12]
    public static func TuiPathsProvider<R>(value: TuiPaths, body: () throws -> R) rethrows -> R {
        try $currentPaths.withValue(value, operation: body)
    }

    // parity: tui/src/context/runtime.tsx#TuiAppProvider [status=adapted hash=d849f207a6e7]
    public static func TuiAppProvider<R>(value: TuiApp, body: () throws -> R) rethrows -> R {
        try $currentApp.withValue(value, operation: body)
    }

    // parity: tui/src/context/runtime.tsx#TuiTerminalEnvironmentProvider [status=adapted hash=c101f47bf933]
    public static func TuiTerminalEnvironmentProvider<R>(
        value: TuiTerminalEnvironment,
        body: () throws -> R
    ) rethrows -> R {
        try $currentTerminalEnv.withValue(value, operation: body)
    }

    // parity: tui/src/context/runtime.tsx#TuiStartupProvider [status=adapted hash=271978f26316]
    public static func TuiStartupProvider<R>(value: TuiStartup, body: () throws -> R) rethrows -> R {
        try $currentStartup.withValue(value, operation: body)
    }

    // parity: tui/src/context/runtime.tsx#TuiLifecycleProvider [status=adapted hash=10b2c7843c7a]
    public static func TuiLifecycleProvider<R>(value: TuiLifecycle, body: () throws -> R) rethrows -> R {
        try $currentLifecycle.withValue(value, operation: body)
    }

    // parity: tui/src/context/runtime.tsx#useTuiPaths [status=adapted hash=7f83a471d54b]
    public static func useTuiPaths() throws(TUIConfig.ConfigError) -> TuiPaths {
        guard let v = currentPaths else { throw .missingContext("TuiPathsProvider") }
        return v
    }

    // parity: tui/src/context/runtime.tsx#useTuiApp [status=adapted hash=2d5d341e5ecb]
    public static func useTuiApp() throws(TUIConfig.ConfigError) -> TuiApp {
        guard let v = currentApp else { throw .missingContext("TuiAppProvider") }
        return v
    }

    // parity: tui/src/context/runtime.tsx#useTuiTerminalEnvironment [status=adapted hash=f8ab39a681b3]
    public static func useTuiTerminalEnvironment() throws(TUIConfig.ConfigError) -> TuiTerminalEnvironment {
        guard let v = currentTerminalEnv else { throw .missingContext("TuiTerminalEnvironmentProvider") }
        return v
    }

    // parity: tui/src/context/runtime.tsx#useTuiStartup [status=adapted hash=f3b9bc0d7d0c]
    public static func useTuiStartup() throws(TUIConfig.ConfigError) -> TuiStartup {
        guard let v = currentStartup else { throw .missingContext("TuiStartupProvider") }
        return v
    }

    // parity: tui/src/context/runtime.tsx#useTuiLifecycle [status=adapted hash=9976bdbf876d]
    public static func useTuiLifecycle() throws(TUIConfig.ConfigError) -> TuiLifecycle {
        guard let v = currentLifecycle else { throw .missingContext("TuiLifecycleProvider") }
        return v
    }

    // MARK: - Session Tabs Model & ScrollAnchor (`session-tabs-model.ts`, `session-tabs.tsx`)

    // parity: tui/src/context/session-tabs-model.ts#SessionTab [status=implemented hash=77612320b8c2]
    public struct SessionTab: Equatable, Hashable, Sendable, Codable {
        public var sessionID: String
        public var title: String?

        public init(sessionID: String, title: String? = nil) {
            self.sessionID = sessionID
            self.title = title
        }
    }

    // parity: tui/src/context/session-tabs-model.ts#SessionTabUnread [status=implemented hash=0fa0ab753c62]
    public enum SessionTabUnread: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case activity
        case error
    }

    // parity: tui/src/context/session-tabs-model.ts#NEW_SESSION_TAB_TITLE [status=implemented hash=42a888b52051]
    public static let NEW_SESSION_TAB_TITLE = "New session"

    // parity: tui/src/context/session-tabs-model.ts#sessionTabNumberLabel [status=implemented hash=9c41777db5bd]
    public static func sessionTabNumberLabel(_ index: Int) -> String {
        String(index + 1)
    }

    // parity: tui/src/context/session-tabs-model.ts#sessionTabDetail [status=implemented hash=cb7a39592741]
    public static func sessionTabDetail(
        project: String,
        current: String?,
        defaultBranch: String?,
        worktree: Bool
    ) -> String {
        let branch = (worktree && current != defaultBranch) ? current : nil
        if let branch, !branch.isEmpty, !project.isEmpty {
            return "\(project) ⎇ \(branch)"
        }
        return branch ?? project
    }

    // parity: tui/src/context/session-tabs-model.ts#SessionTabHistory [status=implemented hash=c2ca90bd51bf]
    public struct SessionTabHistory: Equatable, Hashable, Sendable, Codable {
        public var entries: [String]
        public var index: Int

        public init(entries: [String] = [], index: Int = -1) {
            self.entries = entries
            self.index = index
        }
    }

    // parity: tui/src/context/session-tabs-model.ts#sessionTabComplete [status=implemented hash=5c1d532c25ce]
    public static func sessionTabComplete(_ unread: SessionTabUnread?, busy: Bool) -> Bool {
        unread == .activity && !busy
    }

    // parity: tui/src/context/session-tabs-model.ts#SESSION_TAB_WIDTH [status=implemented hash=d71b714ee0e1]
    public static let SESSION_TAB_WIDTH = 22

    // parity: tui/src/context/session-tabs-model.ts#SESSION_TAB_MAX_WIDTH [status=implemented hash=f275e0eea51e]
    public static let SESSION_TAB_MAX_WIDTH = 32

    // parity: tui/src/context/session-tabs-model.ts#SESSION_TAB_MIN_WIDTH [status=implemented hash=f637edd30e54]
    public static let SESSION_TAB_MIN_WIDTH = 8

    // parity: tui/src/context/session-tabs-model.ts#sessionTabOverflowWidth [status=implemented hash=ae8655b9dff1]
    public static func sessionTabOverflowWidth(_ count: Int) -> Int {
        String(count).count + 2
    }

    // parity: tui/src/context/session-tabs-model.ts#openSessionTab [status=implemented hash=dfbf5d1d962f]
    public static func openSessionTab(_ tabs: [SessionTab], _ tab: SessionTab) -> [SessionTab] {
        guard let index = tabs.firstIndex(where: { $0.sessionID == tab.sessionID }) else {
            return tabs + [tab]
        }
        guard let title = tab.title, !title.isEmpty, tabs[index].title != title else {
            return tabs
        }
        var next = tabs
        next[index].title = title
        return next
    }

    // parity: tui/src/context/session-tabs-model.ts#closeSessionTab [status=implemented hash=200a5ba27f7d]
    public static func closeSessionTab(
        _ tabs: [SessionTab],
        sessionID: String,
        lastIndex: Int? = nil
    ) -> (tabs: [SessionTab], next: String?) {
        guard let index = tabs.firstIndex(where: { $0.sessionID == sessionID }) else {
            let nextID: String?
            if let lastIndex, !tabs.isEmpty {
                nextID = tabs[max(0, min(lastIndex, tabs.count - 1))].sessionID
            } else {
                nextID = nil
            }
            return (tabs, nextID)
        }
        let nextID = (index + 1 < tabs.count ? tabs[index + 1].sessionID : nil)
            ?? (index - 1 >= 0 ? tabs[index - 1].sessionID : nil)
        return (tabs.filter { $0.sessionID != sessionID }, nextID)
    }

    // parity: tui/src/context/session-tabs-model.ts#ClosedSessionTab [status=implemented hash=feb6a8a0d649]
    public struct ClosedSessionTab: Equatable, Hashable, Sendable, Codable {
        public let tab: SessionTab
        public let index: Int

        public init(tab: SessionTab, index: Int) {
            self.tab = tab
            self.index = index
        }
    }

    private static let closedSessionTabLimit = 25

    // parity: tui/src/context/session-tabs-model.ts#recordClosedSessionTab [status=implemented hash=9b99ea59cccb]
    public static func recordClosedSessionTab(
        _ stack: [ClosedSessionTab],
        tab: SessionTab,
        index: Int
    ) -> [ClosedSessionTab] {
        let filtered = stack.filter { $0.tab.sessionID != tab.sessionID } + [ClosedSessionTab(tab: tab, index: index)]
        return Array(filtered.suffix(closedSessionTabLimit))
    }

    // parity: tui/src/context/session-tabs-model.ts#reopenSessionTab [status=implemented hash=8c8e6433f3c6]
    public static func reopenSessionTab(
        _ stack: [ClosedSessionTab],
        tabs: [SessionTab],
        sessionID: String? = nil
    ) -> (stack: [ClosedSessionTab], tabs: [SessionTab]?, sessionID: String?) {
        var remaining = stack
        while !remaining.isEmpty {
            let index: Int
            if let sessionID {
                guard let found = remaining.firstIndex(where: { $0.tab.sessionID == sessionID }) else { break }
                index = found
            } else {
                index = remaining.count - 1
            }
            let entry = remaining.remove(at: index)
            if tabs.contains(where: { $0.sessionID == entry.tab.sessionID }) { continue }
            var next = tabs
            next.insert(entry.tab, at: max(0, min(entry.index, tabs.count)))
            return (remaining, next, entry.tab.sessionID)
        }
        return (remaining, nil, nil)
    }

    // parity: tui/src/context/session-tabs-model.ts#moveSessionTab [status=implemented hash=5006a3956009]
    public static func moveSessionTab(_ tabs: [SessionTab], sessionID: String, index: Int) -> [SessionTab] {
        guard let from = tabs.firstIndex(where: { $0.sessionID == sessionID }) else { return tabs }
        let to = max(0, min(tabs.count - 1, index))
        if from == to { return tabs }
        var next = tabs
        let item = next.remove(at: from)
        next.insert(item, at: to)
        return next
    }

    // parity: tui/src/context/session-tabs-model.ts#cycleSessionTab [status=implemented hash=e940204240ea]
    public static func cycleSessionTab(
        _ tabs: [SessionTab],
        active: String?,
        direction: Int,
        matches: (SessionTab) -> Bool = { _ in true }
    ) -> SessionTab? {
        guard !tabs.isEmpty else { return nil }
        let dir = direction >= 0 ? 1 : -1
        let index = active.flatMap { id in tabs.firstIndex(where: { $0.sessionID == id }) }
        let start = index ?? (dir == 1 ? -1 : 0)
        for offset in 0..<tabs.count {
            let candidate = tabs[(start + dir * (offset + 1) + tabs.count * 2) % tabs.count]
            if matches(candidate) { return candidate }
        }
        return nil
    }

    private static let sessionTabHistoryLimit = 100

    // parity: tui/src/context/session-tabs-model.ts#recordSessionTabHistory [status=implemented hash=8198d1f26997]
    public static func recordSessionTabHistory(
        _ history: SessionTabHistory,
        sessionID: String
    ) -> SessionTabHistory {
        if history.index >= 0 && history.index < history.entries.count && history.entries[history.index] == sessionID {
            return history
        }
        let end = max(0, min(history.entries.count, history.index + 1))
        let entries = Array((Array(history.entries[0..<end]) + [sessionID]).suffix(sessionTabHistoryLimit))
        return SessionTabHistory(entries: entries, index: entries.count - 1)
    }

    // parity: tui/src/context/session-tabs-model.ts#moveSessionTabHistory [status=implemented hash=e07ad99af8ad]
    public static func moveSessionTabHistory(
        _ history: SessionTabHistory,
        tabs: [SessionTab],
        active: String?,
        direction: Int
    ) -> (history: SessionTabHistory, sessionID: String?) {
        if active == nil {
            guard history.index >= 0 && history.index < history.entries.count else {
                return (history, nil)
            }
            let sid = history.entries[history.index]
            return tabs.contains(where: { $0.sessionID == sid }) ? (history, sid) : (history, nil)
        }
        let indexed = history.entries.enumerated().map { (index: $0.offset, sessionID: $0.element) }
        let candidates: [(index: Int, sessionID: String)]
        if direction < 0 {
            let bound = max(0, min(history.index, indexed.count))
            candidates = Array(indexed[0..<bound]).reversed()
        } else {
            let start = max(0, min(history.index + 1, indexed.count))
            candidates = Array(indexed[start..<indexed.count])
        }
        guard let target = candidates.first(where: { entry in
            entry.sessionID != active && tabs.contains(where: { $0.sessionID == entry.sessionID })
        }) else {
            return (history, nil)
        }
        return (SessionTabHistory(entries: history.entries, index: target.index), target.sessionID)
    }

    // parity: tui/src/context/session-tabs-model.ts#SessionTabMotionValues [status=implemented hash=e21772a9e148]
    public struct SessionTabMotionValues: Equatable, Sendable {
        public var widths: [Double]
        public var selections: [Double]
        public var activities: [Double]

        public init(widths: [Double], selections: [Double], activities: [Double]) {
            self.widths = widths
            self.selections = selections
            self.activities = activities
        }
    }

    // parity: tui/src/context/session-tabs-model.ts#seedSessionTabMotion [status=implemented hash=e178e1bd54df]
    public static func seedSessionTabMotion(
        previous: [String],
        ids: [String],
        current: SessionTabMotionValues,
        next: SessionTabMotionValues
    ) -> SessionTabMotionValues? {
        let positions = ids.map { previous.firstIndex(of: $0) }
        if positions.allSatisfy({ $0 == nil }) { return nil }
        return SessionTabMotionValues(
            widths: positions.enumerated().map { idx, pos in
                guard let pos else { return 0 }
                if pos < current.widths.count { return current.widths[pos] }
                return idx < next.widths.count ? next.widths[idx] : 0
            },
            selections: positions.enumerated().map { idx, pos in
                if let pos, pos < current.selections.count { return current.selections[pos] }
                return idx < next.selections.count ? next.selections[idx] : 0
            },
            activities: positions.enumerated().map { idx, pos in
                if let pos, pos < current.activities.count { return current.activities[pos] }
                return idx < next.activities.count ? next.activities[idx] : 0
            }
        )
    }

    public struct AdaptiveSessionTabLayoutResult: Equatable, Sendable {
        public let tabs: [SessionTab]
        public let widths: [Int]
        public let before: Int
        public let after: Int
        public let start: Int
        public let total: Int
    }

    // parity: tui/src/context/session-tabs-model.ts#adaptiveSessionTabLayout [status=implemented hash=99d2143af904]
    public static func adaptiveSessionTabLayout(
        tabs: [SessionTab],
        active: String?,
        available: Int,
        previousStart: Int = 0
    ) -> AdaptiveSessionTabLayoutResult {
        if tabs.isEmpty {
            return AdaptiveSessionTabLayoutResult(tabs: [], widths: [], before: 0, after: 0, start: 0, total: 0)
        }
        let activeIndex = active.flatMap { id in tabs.firstIndex(where: { $0.sessionID == id }) } ?? -1
        func fit(_ width: Int) -> Int {
            let clamped = max(0, width)
            let count = activeIndex == -1
                ? clamped / SESSION_TAB_MIN_WIDTH
                : 1 + max(0, clamped - SESSION_TAB_WIDTH) / SESSION_TAB_MIN_WIDTH
            return min(tabs.count, max(1, count))
        }
        func solve(_ count: Int, _ start: Int, _ attempts: Int) -> (count: Int, start: Int) {
            let boundedStart = min(max(0, start), tabs.count - count)
            let rawStart: Int
            if activeIndex == -1 {
                rawStart = boundedStart
            } else if activeIndex < boundedStart {
                rawStart = activeIndex
            } else if activeIndex >= boundedStart + count {
                rawStart = activeIndex - count + 1
            } else {
                rawStart = boundedStart
            }
            let nextStart = min(max(0, rawStart), tabs.count - count)
            let markers = (nextStart > 0 ? sessionTabOverflowWidth(nextStart) : 0)
                + (nextStart + count < tabs.count ? sessionTabOverflowWidth(tabs.count - nextStart - count) : 0)
            let nextCount = fit(available - markers)
            if nextCount == count || attempts == 0 { return (count, nextStart) }
            return solve(nextCount, nextStart, attempts - 1)
        }
        let solved = solve(fit(available), previousStart, 3)
        let visible = Array(tabs[solved.start..<(solved.start + solved.count)])
        let before = solved.start
        let after = tabs.count - solved.start - solved.count
        let contentWidth = max(
            1,
            available
                - (before > 0 ? sessionTabOverflowWidth(before) : 0)
                - (after > 0 ? sessionTabOverflowWidth(after) : 0)
        )
        let roomy = contentWidth >= SESSION_TAB_WIDTH * visible.count
        let total = roomy ? min(contentWidth, SESSION_TAB_MAX_WIDTH * visible.count) : contentWidth
        if roomy || activeIndex == -1 {
            let width = total / visible.count
            let remainder = total - width * visible.count
            let widths = visible.indices.map { width + ($0 < remainder ? 1 : 0) }
            return AdaptiveSessionTabLayoutResult(
                tabs: visible, widths: widths, before: before, after: after, start: solved.start, total: total
            )
        }
        let inactiveWidth: Int = visible.count == 1
            ? 0
            : min(
                SESSION_TAB_WIDTH,
                max(SESSION_TAB_MIN_WIDTH, (total - min(SESSION_TAB_WIDTH, total)) / (visible.count - 1))
            )
        let activeWidth = visible.count == 1 ? total : total - inactiveWidth * (visible.count - 1)
        let widths = visible.map { $0.sessionID == active ? activeWidth : inactiveWidth }
        return AdaptiveSessionTabLayoutResult(
            tabs: visible, widths: widths, before: before, after: after, start: solved.start, total: total
        )
    }

    // parity: tui/src/context/session-tabs.tsx#ScrollAnchor [status=implemented hash=695e145e639d]
    public struct ScrollAnchor: Equatable, Hashable, Sendable, Codable {
        public let target: TUIRoutes.AnchorTarget
        public let screenY: Int

        public init(target: TUIRoutes.AnchorTarget, screenY: Int) {
            self.target = target
            self.screenY = screenY
        }
    }

    public final class SessionTabsContextController: @unchecked Sendable {
        private struct Inner: Sendable {
            var tabs: [SessionTab]
            var activeSessionID: String?
            var closed: [ClosedSessionTab]
            var history: SessionTabHistory
            var anchors: [String: ScrollAnchor]
        }

        private let state: Mutex<Inner>

        public init(
            tabs: [SessionTab] = [],
            activeSessionID: String? = nil,
            closed: [ClosedSessionTab] = [],
            history: SessionTabHistory = SessionTabHistory()
        ) {
            self.state = Mutex(Inner(
                tabs: tabs,
                activeSessionID: activeSessionID ?? tabs.first?.sessionID,
                closed: closed,
                history: history,
                anchors: [:]
            ))
        }

        public var tabs: [SessionTab] { state.withLock { $0.tabs } }
        public var activeSessionID: String? { state.withLock { $0.activeSessionID } }
        public var closedTabs: [ClosedSessionTab] { state.withLock { $0.closed } }
        public var history: SessionTabHistory { state.withLock { $0.history } }

        public func open(_ tab: SessionTab, activate: Bool = true) {
            state.withLock { s in
                s.tabs = TUIContext.openSessionTab(s.tabs, tab)
                if activate {
                    s.activeSessionID = tab.sessionID
                    s.history = TUIContext.recordSessionTabHistory(s.history, sessionID: tab.sessionID)
                }
            }
        }

        @discardableResult
        public func close(sessionID: String) -> String? {
            state.withLock { s in
                if let idx = s.tabs.firstIndex(where: { $0.sessionID == sessionID }) {
                    s.closed = TUIContext.recordClosedSessionTab(s.closed, tab: s.tabs[idx], index: idx)
                }
                let result = TUIContext.closeSessionTab(s.tabs, sessionID: sessionID)
                s.tabs = result.tabs
                if s.activeSessionID == sessionID {
                    s.activeSessionID = result.next
                }
                return result.next
            }
        }

        @discardableResult
        public func reopen(sessionID: String? = nil) -> String? {
            state.withLock { s in
                let res = TUIContext.reopenSessionTab(s.closed, tabs: s.tabs, sessionID: sessionID)
                s.closed = res.stack
                if let nextTabs = res.tabs, let reopenedID = res.sessionID {
                    s.tabs = nextTabs
                    s.activeSessionID = reopenedID
                    s.history = TUIContext.recordSessionTabHistory(s.history, sessionID: reopenedID)
                    return reopenedID
                }
                return nil
            }
        }

        public func move(sessionID: String, to index: Int) {
            state.withLock { s in
                s.tabs = TUIContext.moveSessionTab(s.tabs, sessionID: sessionID, index: index)
            }
        }

        @discardableResult
        public func cycle(direction: Int) -> SessionTab? {
            state.withLock { s in
                guard let target = TUIContext.cycleSessionTab(s.tabs, active: s.activeSessionID, direction: direction) else {
                    return nil
                }
                s.activeSessionID = target.sessionID
                s.history = TUIContext.recordSessionTabHistory(s.history, sessionID: target.sessionID)
                return target
            }
        }

        @discardableResult
        public func navigateHistory(direction: Int) -> String? {
            state.withLock { s in
                let res = TUIContext.moveSessionTabHistory(s.history, tabs: s.tabs, active: s.activeSessionID, direction: direction)
                s.history = res.history
                if let nextID = res.sessionID {
                    s.activeSessionID = nextID
                }
                return res.sessionID
            }
        }

        public func layout(available: Int, previousStart: Int = 0) -> AdaptiveSessionTabLayoutResult {
            state.withLock { s in
                TUIContext.adaptiveSessionTabLayout(
                    tabs: s.tabs,
                    active: s.activeSessionID,
                    available: available,
                    previousStart: previousStart
                )
            }
        }

        public func setScrollAnchor(_ anchor: ScrollAnchor?, for sessionID: String) {
            state.withLock { s in
                if let anchor {
                    s.anchors[sessionID] = anchor
                } else {
                    s.anchors.removeValue(forKey: sessionID)
                }
            }
        }

        public func scrollAnchor(for sessionID: String) -> ScrollAnchor? {
            state.withLock { $0.anchors[sessionID] }
        }
    }

    @TaskLocal private static var currentSessionTabs: SessionTabsContextController?

    // parity: tui/src/context/session-tabs.tsx#SessionTabsProvider [status=adapted hash=643e450307a7]
    public static func SessionTabsProvider<R>(
        controller: SessionTabsContextController = SessionTabsContextController(),
        body: () throws -> R
    ) rethrows -> R {
        try $currentSessionTabs.withValue(controller, operation: body)
    }

    // parity: tui/src/context/session-tabs.tsx#useSessionTabs [status=adapted hash=643e450307a7]
    public static func useSessionTabs() throws(TUIConfig.ConfigError) -> SessionTabsContextController {
        guard let value = currentSessionTabs else { throw .missingContext("SessionTabsProvider") }
        return value
    }

    // MARK: - Session Terminals Context (`packages/tui/src/context/session-terminals.tsx`)

    public final class SessionTerminalsController: @unchecked Sendable {
        private struct Inner: Sendable {
            var available: Bool = false
            var focus: String?
            var sessions: [String: String?] = [:]
            var writers: [String: @Sendable ([UInt8]) -> Void] = [:]
            var pendingWrites: [String: [[UInt8]]] = [:]
        }

        private let state = Mutex(Inner())

        public init(available: Bool = false) {
            state.withLock { $0.available = available }
        }

        public var available: Bool { state.withLock { $0.available } }
        public var focus: String? { state.withLock { $0.focus } }

        public func setAvailable(_ value: Bool) {
            state.withLock { $0.available = value }
        }

        public func setFocus(_ terminalID: String?) {
            state.withLock { $0.focus = terminalID }
        }

        public func setTerminal(_ terminalID: String?, for sessionID: String) {
            state.withLock { $0.sessions[sessionID] = terminalID }
        }

        public func terminalID(for sessionID: String) -> String? {
            state.withLock { $0.sessions[sessionID] ?? nil }
        }

        public func attachWriter(
            terminalID: String,
            writer: @escaping @Sendable ([UInt8]) -> Void
        ) -> @Sendable () -> Void {
            let queued = state.withLock { s -> [[UInt8]] in
                s.writers[terminalID] = writer
                return s.pendingWrites.removeValue(forKey: terminalID) ?? []
            }
            for chunk in queued { writer(chunk) }
            return { [weak self] in
                _ = self?.state.withLock { $0.writers.removeValue(forKey: terminalID) }
            }
        }

        public func write(terminalID: String, data: [UInt8]) {
            let writer = state.withLock { s -> (@Sendable ([UInt8]) -> Void)? in
                if let w = s.writers[terminalID] { return w }
                s.pendingWrites[terminalID, default: []].append(data)
                return nil
            }
            writer?(data)
        }
    }

    @TaskLocal private static var currentSessionTerminals: SessionTerminalsController?

    // parity: tui/src/context/session-terminals.tsx#SessionTerminalsProvider [status=adapted hash=f8e3e5407319]
    public static func SessionTerminalsProvider<R>(
        controller: SessionTerminalsController = SessionTerminalsController(),
        body: () throws -> R
    ) rethrows -> R {
        try $currentSessionTerminals.withValue(controller, operation: body)
    }

    // parity: tui/src/context/session-terminals.tsx#useSessionTerminals [status=adapted hash=f8e3e5407319]
    public static func useSessionTerminals() throws(TUIConfig.ConfigError) -> SessionTerminalsController {
        guard let value = currentSessionTerminals else { throw .missingContext("SessionTerminalsProvider") }
        return value
    }

    // MARK: - Storage Context (`packages/tui/src/context/storage.tsx`)

    // parity: tui/src/context/storage.tsx#Storage [status=adapted hash=249412b706fa]
    public protocol Storage: Sendable {
        func readJSON(_ key: String) async -> JSONValue?
        func writeJSON(_ key: String, mutate: @escaping @Sendable (JSONValue?) -> JSONValue) async throws
        func readMemory(_ key: String) -> AnySendableValue?
        func writeMemory(_ key: String, value: AnySendableValue)
        func flush() async throws
    }

    public final class FileBackedStorage: Storage, @unchecked Sendable {
        public let directory: String
        public let locks: String
        private let fs: any OpenCodeFileSystem
        private let memoryMap = Mutex<[String: AnySendableValue]>([:])

        public init(root: String, channel: String, fs: any OpenCodeFileSystem = LocalFileSystem.shared) throws(TUIConfig.ConfigError) {
            let safeChannel = try Self.validateSegment(channel)
            self.directory = "\(root)/\(safeChannel)/tui"
            self.locks = "\(root)/\(safeChannel)/locks"
            self.fs = fs
        }

        private static func validateSegment(_ value: String) throws(TUIConfig.ConfigError) -> String {
            guard !value.isEmpty, value != ".", value != ".." else {
                throw .invalidStorageSegment(value)
            }
            let bytes = Array(value.utf8)
            let first = bytes[0]
            let firstOK = (first >= 0x30 && first <= 0x39) || (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A)
            let restOK = bytes.allSatisfy { b in
                (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
                    || b == 0x2E || b == 0x5F || b == 0x2D
            }
            guard firstOK && restOK else { throw .invalidStorageSegment(value) }
            return value
        }

        public func readJSON(_ key: String) async -> JSONValue? {
            guard let safeKey = try? Self.validateSegment(key) else { return nil }
            let file = "\(directory)/\(safeKey).json"
            guard let bytes = try? await fs.readFile(at: file),
                  let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(bytes))
            else { return nil }
            return decoded
        }

        public func writeJSON(_ key: String, mutate: @escaping @Sendable (JSONValue?) -> JSONValue) async throws {
            let safeKey = try Self.validateSegment(key)
            let file = "\(directory)/\(safeKey).json"
            let fsRef = fs
            try await Flock.withLock(file, options: Flock.Options(dir: locks)) {
                let current = await self.readJSON(safeKey)
                let next = mutate(current)
                let encoded = try JSONEncoder().encode(next)
                try await fsRef.writeFile(Array(encoded), to: file, createDirectories: true)
            }
        }

        public func readMemory(_ key: String) -> AnySendableValue? {
            memoryMap.withLock { $0[key] }
        }

        public func writeMemory(_ key: String, value: AnySendableValue) {
            memoryMap.withLock { $0[key] = value }
        }

        public func flush() async throws {}
    }

    public struct StorageHandle: Sendable {
        public let storage: any Storage
        public let close: @Sendable () -> Void

        public init(storage: any Storage, close: @escaping @Sendable () -> Void = {}) {
            self.storage = storage
            self.close = close
        }
    }

    // parity: tui/src/context/storage.tsx#createStorage [status=adapted hash=428af3c9475f]
    public static func createStorage(
        root: String,
        channel: String,
        fs: any OpenCodeFileSystem = LocalFileSystem.shared
    ) throws(TUIConfig.ConfigError) -> StorageHandle {
        let storage = try FileBackedStorage(root: root, channel: channel, fs: fs)
        return StorageHandle(storage: storage)
    }

    @TaskLocal private static var currentStorage: (any Storage)?

    // parity: tui/src/context/storage.tsx#StorageProvider [status=adapted hash=69b47b426596]
    public static func StorageProvider<R>(storage: any Storage, body: () throws -> R) rethrows -> R {
        try $currentStorage.withValue(storage, operation: body)
    }

    // parity: tui/src/context/storage.tsx#useStorage [status=adapted hash=c22166dd81c1]
    public static func useStorage() throws(TUIConfig.ConfigError) -> any Storage {
        guard let value = currentStorage else { throw .missingContext("StorageProvider") }
        return value
    }

    // parity: tui/src/context/storage.tsx#useStorageOptional [status=adapted hash=e6299d6f79cf]
    public static func useStorageOptional() -> (any Storage)? {
        currentStorage
    }

    // MARK: - Theme Context (`packages/tui/src/context/theme.tsx`)

    // parity: tui/src/context/theme.tsx#ThemeError [status=implemented hash=08e41247ddaf]
    public struct ThemeError: Equatable, Hashable, Sendable {
        public let name: String
        public let message: String

        public init(name: String, message: String) {
            self.name = name
            self.message = message
        }
    }

    // parity: tui/src/context/theme.tsx#ThemeSource [status=adapted hash=798fd1454c45]
    public struct ThemeSource: Sendable {
        public let discover: @Sendable () async -> [String: ThemeDocument]
        public let subscribeRefresh: (@Sendable (@escaping @Sendable () -> Void) -> @Sendable () -> Void)?

        public init(
            discover: @escaping @Sendable () async -> [String: ThemeDocument] = { [:] },
            subscribeRefresh: (@Sendable (@escaping @Sendable () -> Void) -> @Sendable () -> Void)? = nil
        ) {
            self.discover = discover
            self.subscribeRefresh = subscribeRefresh
        }
    }

    // parity: tui/src/context/theme.tsx#createThemeSource [status=adapted hash=72bbde6f9c2c]
    public static func createThemeSource(config: String) -> ThemeSource {
        ThemeSource(discover: {
            let themesDir = "\(config)/themes"
            guard let files = try? await LocalFileSystem.shared.readDirectory(at: themesDir) else { return [:] }
            var found: [String: ThemeDocument] = [:]
            for file in files where file.hasSuffix(".json") {
                let name = String(file.dropLast(5))
                if let bytes = try? await LocalFileSystem.shared.readFile(at: "\(themesDir)/\(file)"),
                   let doc = try? parseThemeDocument(data: Data(bytes), name: name)
                {
                    found[name] = doc
                }
            }
            return found
        })
    }

    public final class ThemeService: @unchecked Sendable {
        private struct Inner: Sendable {
            var activeName: String
            var mode: Mode
            var lockedMode: Mode?
            var themes: [String: ThemeDocument]
            var surface: SurfaceName?
        }

        private let state: Mutex<Inner>

        public init(mode: Mode = .dark, activeName: String = "opencode", customThemes: [String: ThemeDocument] = [:]) {
            var all: [String: ThemeDocument] = [
                "opencode": ThemeDefaults.opencode,
                "opencode-classic": ThemeDefaults.opencodeClassic,
            ]
            for (k, v) in customThemes { all[k] = v }
            self.state = Mutex(Inner(activeName: activeName, mode: mode, lockedMode: nil, themes: all, surface: nil))
        }

        /// "opencode2" was the new theme's name before it became "opencode".
        private static func alias(_ name: String, _ themes: [String: ThemeDocument]) -> String {
            name == "opencode2" && themes["opencode2"] == nil ? "opencode" : name
        }

        /// The theme actually shown, with aliases resolved.
        public var selected: String { state.withLock { Self.alias($0.activeName, $0.themes) } }
        public var mode: Mode { state.withLock { $0.lockedMode ?? $0.mode } }
        public var locked: Bool { state.withLock { $0.lockedMode != nil } }

        public func has(_ name: String) -> Bool {
            state.withLock { !name.isEmpty && $0.themes[Self.alias(name, $0.themes)] != nil }
        }

        public func modes() -> [Mode] {
            let doc = activeDocument()
            return themeModes(doc)
        }

        public func supports(_ requested: Mode) -> Bool {
            modes().contains(requested)
        }

        @discardableResult
        public func set(_ theme: String) -> Bool {
            state.withLock { s in
                let name = Self.alias(theme, s.themes)
                guard !theme.isEmpty, s.themes[name] != nil else { return false }
                s.activeName = name
                return true
            }
        }

        @discardableResult
        public func setMode(_ requested: Mode) -> Bool {
            guard supports(requested) else { return false }
            state.withLock {
                $0.lockedMode = requested
                $0.mode = requested
            }
            return true
        }

        public func unlock() {
            state.withLock { $0.lockedMode = nil }
        }

        private func activeDocument() -> ThemeDocument {
            state.withLock { $0.themes[Self.alias($0.activeName, $0.themes)] ?? ThemeDefaults.opencode }
        }

        public func currentTokens() -> ResolvedTheme {
            let doc = activeDocument()
            let m = mode
            let resolved = (try? resolveThemeDocument(doc, mode: m))
                ?? (try! resolveThemeDocument(ThemeDefaults.opencode, mode: m))
            if let surface = state.withLock({ $0.surface }) {
                return resolved.surface(surface)
            }
            return resolved
        }

        public func currentSyntax() -> SyntaxStyle {
            generateSyntax(currentTokens())
        }

        func withSurface(_ surface: SurfaceName?) -> ThemeService {
            let snap = state.withLock { $0 }
            let derived = ThemeService(mode: snap.mode, activeName: snap.activeName, customThemes: snap.themes)
            derived.state.withLock {
                $0.lockedMode = snap.lockedMode
                $0.surface = surface
            }
            return derived
        }
    }

    @TaskLocal private static var currentThemeService: ThemeService?

    // parity: tui/src/context/theme.tsx#ThemeProvider [status=adapted hash=882e9b63e5d2]
    public static func ThemeProvider<R>(
        mode: Mode = .dark,
        service: ThemeService? = nil,
        body: () throws -> R
    ) rethrows -> R {
        let resolved = service ?? ThemeService(mode: mode)
        return try $currentThemeService.withValue(resolved, operation: body)
    }

    // parity: tui/src/context/theme.tsx#useThemes [status=adapted hash=1ef95a55351a]
    public static func useThemes() throws(TUIConfig.ConfigError) -> ThemeService {
        guard let service = currentThemeService else { throw .missingContext("ThemeProvider") }
        return service
    }

    // parity: tui/src/context/theme.tsx#useTheme [status=adapted hash=efd04dc5200c]
    public static func useTheme() throws(TUIConfig.ConfigError) -> ResolvedTheme {
        try useThemes().currentTokens()
    }

    // parity: tui/src/context/theme.tsx#ThemeContextProvider [status=adapted hash=f4f5cbccdabb]
    public static func ThemeContextProvider<R>(context surface: SurfaceName?, body: () throws -> R) throws -> R {
        let service = try useThemes()
        return try $currentThemeService.withValue(service.withSurface(surface), operation: body)
    }

    // parity: tui/src/context/theme.tsx#createSyntaxStyleMemo [status=adapted hash=5210e4bc0294]
    public static func createSyntaxStyleMemo(_ factory: @escaping @Sendable () -> SyntaxStyle) -> SyntaxStyle {
        factory()
    }

    // MARK: - Thinking Mode (`packages/tui/src/context/thinking.ts`)

    // parity: tui/src/context/thinking.ts#ThinkingMode [status=implemented hash=24ceecd7cd41]
    public enum ThinkingMode: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case show
        case hide
    }

    public struct ReasoningSummaryResult: Equatable, Hashable, Sendable {
        public let title: String?
        public let body: String

        public init(title: String?, body: String) {
            self.title = title
            self.body = body
        }
    }

    /// Extracts leading bolded title block (`"**Title**\n\nbody"`) from a reasoning stream.
    // parity: tui/src/context/thinking.ts#reasoningSummary [status=implemented hash=41f09e64ff10]
    public static func reasoningSummary(_ text: String) -> ReasoningSummaryResult {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.hasPrefix("**") else {
            return ReasoningSummaryResult(title: nil, body: content)
        }
        let afterOpen = content.dropFirst(2)
        guard let closeRange = afterOpen.range(of: "**") else {
            return ReasoningSummaryResult(title: nil, body: content)
        }
        let rawTitle = String(afterOpen[..<closeRange.lowerBound])
        guard !rawTitle.isEmpty, !rawTitle.contains("*"), !rawTitle.contains("\n") else {
            return ReasoningSummaryResult(title: nil, body: content)
        }
        let rest = afterOpen[closeRange.upperBound...]
        if rest.isEmpty {
            return ReasoningSummaryResult(
                title: rawTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                body: ""
            )
        }
        let bodySlice: Substring
        if rest.hasPrefix("\r\n\r\n") {
            bodySlice = rest.dropFirst(4)
        } else if rest.hasPrefix("\n\n") {
            bodySlice = rest.dropFirst(2)
        } else if rest.hasPrefix("\r\n\n") || rest.hasPrefix("\n\r\n") {
            bodySlice = rest.dropFirst(3)
        } else {
            return ReasoningSummaryResult(title: nil, body: content)
        }
        var trimmedEnd = String(bodySlice)
        while let last = trimmedEnd.last, last.isWhitespace {
            trimmedEnd.removeLast()
        }
        return ReasoningSummaryResult(
            title: rawTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            body: trimmedEnd
        )
    }

    // parity: tui/src/context/thinking.ts#nextThinkingMode [status=implemented hash=c1c14278c179]
    public static func nextThinkingMode(_ current: ThinkingMode) -> ThinkingMode {
        current == .show ? .hide : .show
    }

    // MARK: - Update Notification (`packages/tui/src/context/update-notification.tsx`)

    public struct ClientUpdateNotice: Equatable, Hashable, Sendable, Codable {
        public enum Kind: String, Equatable, Hashable, Sendable, Codable {
            case available
            case installed
        }

        public let type: Kind
        public let version: String

        public init(type: Kind, version: String) {
            self.type = type
            self.version = version
        }
    }

    // parity: tui/src/context/update-notification.tsx#UpdateState [status=implemented hash=0abedda2baaa]
    public enum UpdateState: Equatable, Hashable, Sendable, Codable {
        case available(version: String)
        case installed(version: String)
        case installing(version: String)
        case failed(message: String)
    }

    public enum UpdateCheckResult: Equatable, Hashable, Sendable {
        case notice(ClientUpdateNotice)
        case unavailable(message: String)
    }

    // parity: tui/src/context/update-notification.tsx#UpdateSource [status=implemented hash=b435be227c6e]
    public struct UpdateSource: Sendable {
        public let remote: Bool
        public let subscribe: @Sendable (@escaping @Sendable (ClientUpdateNotice) -> Void) -> @Sendable () -> Void
        public let check: @Sendable (AbortSignal, @escaping @Sendable (String) -> Void) async throws -> UpdateCheckResult?
        public let apply: @Sendable (String) async throws -> Void

        public init(
            remote: Bool = false,
            subscribe: @escaping @Sendable (@escaping @Sendable (ClientUpdateNotice) -> Void) -> @Sendable () -> Void = { _ in {} },
            check: @escaping @Sendable (AbortSignal, @escaping @Sendable (String) -> Void) async throws -> UpdateCheckResult? = { _, _ in nil },
            apply: @escaping @Sendable (String) async throws -> Void = { _ in }
        ) {
            self.remote = remote
            self.subscribe = subscribe
            self.check = check
            self.apply = apply
        }
    }

    public final class UpdateNotificationController: @unchecked Sendable {
        private struct Inner: Sendable {
            var state: UpdateState?
            var dismissedVersion: String?
        }

        private let source: UpdateSource
        private let inner = Mutex(Inner())

        public init(source: UpdateSource = UpdateSource()) {
            self.source = source
        }

        public var remote: Bool { source.remote }
        public var state: UpdateState? { inner.withLock { $0.state } }
        public var dismissedVersion: String? { inner.withLock { $0.dismissedVersion } }

        public var visibleState: UpdateState? {
            inner.withLock { s in
                guard let current = s.state else { return nil }
                switch current {
                case .available(let v), .installed(let v):
                    return s.dismissedVersion == v ? nil : current
                case .installing, .failed:
                    return current
                }
            }
        }

        public func notify(_ notice: ClientUpdateNotice) {
            inner.withLock { s in
                switch notice.type {
                case .available: s.state = .available(version: notice.version)
                case .installed: s.state = .installed(version: notice.version)
                }
            }
        }

        public func dismiss() {
            inner.withLock { s in
                switch s.state {
                case .available(let v), .installed(let v):
                    s.dismissedVersion = v
                case .failed:
                    s.state = nil
                case .installing, .none:
                    break
                }
            }
        }

        public func check(signal: AbortSignal = AbortController().signal, onStatus: @escaping @Sendable (String) -> Void = { _ in }) async {
            do {
                guard let result = try await source.check(signal, onStatus) else { return }
                switch result {
                case .notice(let notice):
                    notify(notice)
                case .unavailable(let message):
                    inner.withLock { $0.state = .failed(message: message) }
                }
            } catch {
                inner.withLock { $0.state = .failed(message: TUIUtil.errorMessage(error)) }
            }
        }

        public func apply(version: String) async {
            inner.withLock { $0.state = .installing(version: version) }
            do {
                try await source.apply(version)
                inner.withLock { $0.state = .installed(version: version) }
            } catch {
                inner.withLock { $0.state = .failed(message: TUIUtil.errorMessage(error)) }
            }
        }
    }

    @TaskLocal private static var currentUpdateNotification: UpdateNotificationController?

    // parity: tui/src/context/update-notification.tsx#UpdateNotificationProvider [status=adapted hash=cc5dbd57c0e7]
    public static func UpdateNotificationProvider<R>(
        controller: UpdateNotificationController = UpdateNotificationController(),
        body: () throws -> R
    ) rethrows -> R {
        try $currentUpdateNotification.withValue(controller, operation: body)
    }

    // parity: tui/src/context/update-notification.tsx#useUpdateNotification [status=adapted hash=cc5dbd57c0e7]
    public static func useUpdateNotification() throws(TUIConfig.ConfigError) -> UpdateNotificationController {
        guard let value = currentUpdateNotification else { throw .missingContext("UpdateNotificationProvider") }
        return value
    }
}

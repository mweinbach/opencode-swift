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

// MARK: - Mini TUI Runtime (`packages/tui/src/mini/*`)

/// Direct split-footer interactive Mini TUI runtime (`opencode mini`): types, verbosity, theme,
/// monochrome ASCII transforms, tool renderers, scrollback writers/surfaces, footer panels/menus,
/// permission & form state machines, fragment reconciler, subagent tracker, transport, and prompt queue.
public enum TUIMini {
    // MARK: - Shared Types (`packages/tui/src/mini/types.ts`)

    // parity: tui/src/mini/types.ts#RunFilePart [status=implemented hash=10d0950135fe]
    public struct RunFilePart: Equatable, Hashable, Sendable, Codable {
        public let type: String
        public let url: String
        public let filename: String
        public let mime: String

        public init(url: String, filename: String, mime: String) {
            self.type = "file"
            self.url = url
            self.filename = filename
            self.mime = mime
        }
    }

    public struct PromptModelSelection: Equatable, Hashable, Sendable, Codable {
        public let providerID: String
        public let modelID: String

        public init(providerID: String, modelID: String) {
            self.providerID = providerID
            self.modelID = modelID
        }
    }

    public struct SourceSpan: Equatable, Hashable, Sendable, Codable {
        public var start: Int
        public var end: Int
        public var value: String

        public init(start: Int, end: Int, value: String) {
            self.start = start
            self.end = end
            self.value = value
        }
    }

    public struct FilePartSource: Equatable, Hashable, Sendable, Codable {
        public var type: String
        public var path: String?
        public var text: SourceSpan

        public init(type: String = "file", path: String? = nil, text: SourceSpan) {
            self.type = type
            self.path = path
            self.text = text
        }
    }

    // parity: tui/src/mini/types.ts#RunPromptPart [status=implemented hash=2db6945b58c4]
    public enum RunPromptPart: Equatable, Hashable, Sendable, Codable {
        case file(url: String, filename: String?, mime: String?, description: String?, source: FilePartSource?)
        case agent(name: String, source: SourceSpan?)
        case skill(id: String, source: SourceSpan?)

        public var isFile: Bool {
            if case .file = self { return true }
            return false
        }
    }

    // parity: tui/src/mini/types.ts#RunCommand [status=implemented hash=15e40556ad25]
    public struct RunCommand: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let description: String?
        public let source: String?

        public init(name: String, description: String? = nil, source: String? = nil) {
            self.name = name
            self.description = description
            self.source = source
        }
    }

    public struct RunProviderModel: Equatable, Hashable, Sendable, Codable {
        public let name: String?
        public let inputCost: Double?
        public let contextLimit: Int?
        public let status: String?
        public let variants: [String]

        public init(
            name: String? = nil,
            inputCost: Double? = nil,
            contextLimit: Int? = nil,
            status: String? = nil,
            variants: [String] = []
        ) {
            self.name = name
            self.inputCost = inputCost
            self.contextLimit = contextLimit
            self.status = status
            self.variants = variants
        }
    }

    // parity: tui/src/mini/types.ts#RunProvider [status=implemented hash=d522112e78cf]
    public struct RunProvider: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let name: String
        public var models: [String: RunProviderModel]

        public init(id: String, name: String, models: [String: RunProviderModel] = [:]) {
            self.id = id
            self.name = name
            self.models = models
        }
    }

    // parity: tui/src/mini/types.ts#RunDelivery [status=implemented hash=601a95202b37]
    public typealias RunDelivery = SessionInboxSchema.Delivery

    public struct PromptCommandSelection: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let arguments: String
        public let source: String?

        public init(name: String, arguments: String, source: String? = nil) {
            self.name = name
            self.arguments = arguments
            self.source = source
        }
    }

    // parity: tui/src/mini/types.ts#RunPrompt [status=implemented hash=9ab3ec2c8dff]
    public struct RunPrompt: Equatable, Hashable, Sendable, Codable {
        public var messageID: String?
        public var text: String
        public var parts: [RunPromptPart]
        public var delivery: RunDelivery?
        public var mode: String?
        public var command: PromptCommandSelection?

        public init(
            messageID: String? = nil,
            text: String,
            parts: [RunPromptPart] = [],
            delivery: RunDelivery? = nil,
            mode: String? = nil,
            command: PromptCommandSelection? = nil
        ) {
            self.messageID = messageID
            self.text = text
            self.parts = parts
            self.delivery = delivery
            self.mode = mode
            self.command = command
        }
    }

    // parity: tui/src/mini/types.ts#FooterQueuedPrompt [status=implemented hash=f8c5dfb33c9b]
    public struct FooterQueuedPrompt: Equatable, Hashable, Sendable, Codable {
        public let messageID: String
        public let prompt: RunPrompt
        public let delivery: RunDelivery
        public let skills: [(id: String, name: String)]

        public init(
            messageID: String,
            prompt: RunPrompt,
            delivery: RunDelivery,
            skills: [(id: String, name: String)] = []
        ) {
            self.messageID = messageID
            self.prompt = prompt
            self.delivery = delivery
            self.skills = skills
        }

        public static func == (lhs: FooterQueuedPrompt, rhs: FooterQueuedPrompt) -> Bool {
            lhs.messageID == rhs.messageID && lhs.prompt == rhs.prompt && lhs.delivery == rhs.delivery
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(messageID)
            hasher.combine(prompt)
            hasher.combine(delivery)
        }

        enum CodingKeys: String, CodingKey { case messageID, prompt, delivery }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.messageID = try c.decode(String.self, forKey: .messageID)
            self.prompt = try c.decode(RunPrompt.self, forKey: .prompt)
            self.delivery = try c.decode(RunDelivery.self, forKey: .delivery)
            self.skills = []
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(messageID, forKey: .messageID)
            try c.encode(prompt, forKey: .prompt)
            try c.encode(delivery, forKey: .delivery)
        }
    }

    // parity: tui/src/mini/types.ts#QueuedPromptAction [status=implemented hash=c9b437232958]
    public enum QueuedPromptAction: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case steer
        case queue
        case cancel
    }

    // parity: tui/src/mini/types.ts#RunAgent [status=implemented hash=c99d38854e45]
    public struct RunAgent: Equatable, Hashable, Sendable, Codable {
        public enum Mode: String, Equatable, Hashable, Sendable, Codable {
            case subagent, primary, all
        }

        public let id: String
        public let name: String
        public let description: String?
        public let color: String?
        public let mode: Mode
        public let hidden: Bool

        public init(
            id: String,
            name: String,
            description: String? = nil,
            color: String? = nil,
            mode: Mode = .primary,
            hidden: Bool = false
        ) {
            self.id = id
            self.name = name
            self.description = description
            self.color = color
            self.mode = mode
            self.hidden = hidden
        }
    }

    // parity: tui/src/mini/types.ts#RunReference [status=implemented hash=2b970e40e179]
    public struct RunReference: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let name: String
        public let description: String?
        public let hidden: Bool

        public init(id: String, name: String, description: String? = nil, hidden: Bool = false) {
            self.id = id
            self.name = name
            self.description = description
            self.hidden = hidden
        }
    }

    // parity: tui/src/mini/types.ts#RunInput [status=adapted hash=27e9e954a9d2]
    public struct RunInput: Sendable {
        public let location: LocationSchema.Ref
        public let agent: String?
        public let model: PromptModelSelection?
        public let variant: String?
        public let files: [RunFilePart]
        public let demo: Bool

        public init(
            location: LocationSchema.Ref,
            agent: String? = nil,
            model: PromptModelSelection? = nil,
            variant: String? = nil,
            files: [RunFilePart] = [],
            demo: Bool = false
        ) {
            self.location = location
            self.agent = agent
            self.model = model
            self.variant = variant
            self.files = files
            self.demo = demo
        }
    }

    // parity: tui/src/mini/types.ts#MiniHost [status=adapted hash=6763e4e46b75]
    public struct MiniHost: Sendable {
        public let version: String
        public let platform: String
        public let home: String
        public let showTiming: Bool
        public let writeStdout: @Sendable (String) -> Void
        public let readText: @Sendable (String) async throws -> String
        public let trace: (@Sendable (String, JSONValue?) -> Void)?
        public let resolveVariant: @Sendable (PromptModelSelection?) async -> String?
        public let saveVariant: @Sendable (PromptModelSelection?, String?) async -> Void

        public init(
            version: String = "0.0.0",
            platform: String = Platform.current.rawValue,
            home: String = SystemEnvironment.shared.homeDirectory ?? "",
            showTiming: Bool = false,
            writeStdout: @escaping @Sendable (String) -> Void = { _ in },
            readText: @escaping @Sendable (String) async throws -> String = {
                String(decoding: try await LocalFileSystem.shared.readFile(at: $0), as: UTF8.self)
            },
            trace: (@Sendable (String, JSONValue?) -> Void)? = nil,
            resolveVariant: @escaping @Sendable (PromptModelSelection?) async -> String? = { _ in nil },
            saveVariant: @escaping @Sendable (PromptModelSelection?, String?) async -> Void = { _, _ in }
        ) {
            self.version = version
            self.platform = platform
            self.home = home
            self.showTiming = showTiming
            self.writeStdout = writeStdout
            self.readText = readText
            self.trace = trace
            self.resolveVariant = resolveVariant
            self.saveVariant = saveVariant
        }
    }

    // parity: tui/src/mini/types.ts#EntryKind [status=implemented hash=e2304419de3e]
    public enum EntryKind: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case system, user, assistant, reasoning, tool, error
    }

    public enum FooterPhase: String, Equatable, Hashable, Sendable, Codable {
        case idle, running
    }

    public struct FooterUsage: Equatable, Hashable, Sendable, Codable {
        public var tokens: Int
        public var percent: Double?
        public var cost: Double?

        public init(tokens: Int, percent: Double? = nil, cost: Double? = nil) {
            self.tokens = tokens
            self.percent = percent
            self.cost = cost
        }
    }

    // parity: tui/src/mini/types.ts#FooterState [status=implemented hash=852204b011b8]
    public struct FooterState: Equatable, Hashable, Sendable, Codable {
        public var phase: FooterPhase
        public var status: String
        public var notice: String
        public var model: String
        public var usage: FooterUsage?
        public var first: Bool
        public var interrupt: Int
        public var exit: Int

        public init(
            phase: FooterPhase = .idle,
            status: String = "",
            notice: String = "",
            model: String = "",
            usage: FooterUsage? = nil,
            first: Bool = true,
            interrupt: Int = 0,
            exit: Int = 0
        ) {
            self.phase = phase
            self.status = status
            self.notice = notice
            self.model = model
            self.usage = usage
            self.first = first
            self.interrupt = interrupt
            self.exit = exit
        }
    }

    // parity: tui/src/mini/types.ts#FooterPatch [status=implemented hash=6eb9e3c70fd7]
    public struct FooterPatch: Equatable, Hashable, Sendable, Codable {
        public var phase: FooterPhase?
        public var status: String?
        public var notice: String?
        public var model: String?
        public var usage: FooterUsage?
        public var first: Bool?
        public var interrupt: Int?
        public var exit: Int?

        public init(
            phase: FooterPhase? = nil,
            status: String? = nil,
            notice: String? = nil,
            model: String? = nil,
            usage: FooterUsage? = nil,
            first: Bool? = nil,
            interrupt: Int? = nil,
            exit: Int? = nil
        ) {
            self.phase = phase
            self.status = status
            self.notice = notice
            self.model = model
            self.usage = usage
            self.first = first
            self.interrupt = interrupt
            self.exit = exit
        }

        public func applying(to state: FooterState) -> FooterState {
            var next = state
            if let phase { next.phase = phase }
            if let status { next.status = status }
            if let notice { next.notice = notice }
            if let model { next.model = model }
            if let usage { next.usage = usage }
            if let first { next.first = first }
            if let interrupt { next.interrupt = interrupt }
            if let exit { next.exit = exit }
            return next
        }
    }

    // parity: tui/src/mini/types.ts#TurnSummary [status=implemented hash=96ae893d2d02]
    public struct TurnSummary: Equatable, Hashable, Sendable, Codable {
        public let agent: String
        public let model: String
        public let duration: String

        public init(agent: String, model: String, duration: String) {
            self.agent = agent
            self.model = model
            self.duration = duration
        }
    }

    // parity: tui/src/mini/types.ts#ScrollbackOptions [status=implemented hash=69fee409d57c]
    public struct ScrollbackOptions: Equatable, Hashable, Sendable, Codable {
        public var suppressBackgrounds: Bool
        public var shellOutput: Bool
        public var mono: Bool

        public init(suppressBackgrounds: Bool = false, shellOutput: Bool = true, mono: Bool = false) {
            self.suppressBackgrounds = suppressBackgrounds
            self.shellOutput = shellOutput
            self.mono = mono
        }
    }

    public struct MiniTodoItem: Equatable, Hashable, Sendable, Codable {
        public let content: String
        public let status: String

        public init(content: String, status: String) {
            self.content = content
            self.status = status
        }
    }

    public struct ToolDiffItem: Equatable, Hashable, Sendable, Codable {
        public let title: String
        public let diff: String
        public let file: String?
        public let deletions: Int?

        public init(title: String, diff: String, file: String? = nil, deletions: Int? = nil) {
            self.title = title
            self.diff = diff
            self.file = file
            self.deletions = deletions
        }
    }

    public struct ToolQuestionItem: Equatable, Hashable, Sendable, Codable {
        public let question: String
        public let answer: String

        public init(question: String, answer: String) {
            self.question = question
            self.answer = answer
        }
    }

    // parity: tui/src/mini/types.ts#ToolSnapshot [status=implemented hash=561c4d08cc69]
    public enum ToolSnapshot: Equatable, Hashable, Sendable, Codable {
        case code(title: String, content: String, file: String?)
        case diff(items: [ToolDiffItem])
        case task(title: String, rows: [String], tail: String)
        case todo(items: [MiniTodoItem])
        case question(items: [ToolQuestionItem], tail: String)
    }

    // parity: tui/src/mini/types.ts#MiniToolPart [status=implemented hash=2195e856ca26]
    public struct MiniToolPart: Equatable, Sendable {
        public let partID: String
        public let sessionID: String
        public let messageID: String
        public let id: String
        public let tool: String
        public let status: String
        public let output: String?
        public let error: String?

        public init(
            partID: String,
            sessionID: String,
            messageID: String,
            id: String,
            tool: String,
            status: String,
            output: String? = nil,
            error: String? = nil
        ) {
            self.partID = partID
            self.sessionID = sessionID
            self.messageID = messageID
            self.id = id
            self.tool = tool
            self.status = status
            self.output = output
            self.error = error
        }
    }

    // parity: tui/src/mini/types.ts#MiniPermissionRequest [status=implemented hash=28c41d054ca7]
    public struct MiniPermissionRequest: Equatable, Hashable, Sendable, Codable {
        public let request: PermissionSchema.Request
        public let tool: SessionMessageSchema.AssistantTool?

        public var id: String { request.id.rawValue }
        public var sessionID: String { request.sessionID.rawValue }
        public var action: String { request.action }
        public var resources: [String] { request.resources }
        public var save: [String]? { request.save }
        public var metadata: [String: JSONValue]? { request.metadata }

        public init(request: PermissionSchema.Request, tool: SessionMessageSchema.AssistantTool? = nil) {
            self.request = request
            self.tool = tool
        }
    }

    // parity: tui/src/mini/types.ts#MiniFormRequest [status=implemented hash=9bc45ea2a0a5]
    public struct MiniFormRequest: Equatable, Hashable, Sendable, Codable {
        public let form: FormSchema.Info
        public let location: LocationSchema.Ref?

        public var id: String { form.id.rawValue }
        public var sessionID: String { form.sessionID }
        public var title: String { form.title }
        public var fields: [FormSchema.Field] { form.fields.elements }

        public init(form: FormSchema.Info, location: LocationSchema.Ref? = nil) {
            self.form = form
            self.location = location
        }
    }

    // parity: tui/src/mini/types.ts#EntryLayout [status=implemented hash=70fc682faa62]
    public enum EntryLayout: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case inline
        case block
    }

    // parity: tui/src/mini/types.ts#RunEntryBody [status=implemented hash=ff6f6dbfed7e]
    public enum RunEntryBody: Equatable, Hashable, Sendable, Codable {
        case none
        case text(content: String)
        case code(content: String, filetype: String?)
        case markdown(content: String)
        case structured(snapshot: ToolSnapshot)
    }

    // parity: tui/src/mini/types.ts#FooterView [status=implemented hash=5badcebbd7a0]
    public enum FooterView: Equatable, Hashable, Sendable, Codable {
        case prompt
        case permission(request: MiniPermissionRequest)
        case form(request: MiniFormRequest)
    }

    // parity: tui/src/mini/types.ts#FooterPromptRoute [status=implemented hash=1b8157c1ea6b]
    public enum FooterPromptRoute: Equatable, Hashable, Sendable, Codable {
        case composer
        case queuedMenu
        case subagentMenu
        case subagent(sessionID: String)
        case command
        case agent
        case model
        case variant
        case settings
    }

    // parity: tui/src/mini/types.ts#FooterSubagentTab [status=implemented hash=a108300700a4]
    public struct FooterSubagentTab: Equatable, Hashable, Sendable, Codable {
        public enum Status: String, Equatable, Hashable, Sendable, Codable {
            case running, completed, cancelled, error
        }

        public let sessionID: String
        public var label: String
        public var description: String
        public var status: Status
        public var title: String?

        public init(
            sessionID: String,
            label: String,
            description: String = "",
            status: Status = .running,
            title: String? = nil
        ) {
            self.sessionID = sessionID
            self.label = label
            self.description = description
            self.status = status
            self.title = title
        }
    }

    // parity: tui/src/mini/types.ts#FooterSubagentDetail [status=implemented hash=ae6e6549f5a1]
    public struct FooterSubagentDetail: Equatable, Sendable {
        public var commits: [StreamCommit]

        public init(commits: [StreamCommit] = []) {
            self.commits = commits
        }
    }

    // parity: tui/src/mini/types.ts#FooterSubagentState [status=implemented hash=53dd1c061ee4]
    public struct FooterSubagentState: Equatable, Sendable {
        public var tabs: [FooterSubagentTab]
        public var details: [String: FooterSubagentDetail]
        public var permissions: [MiniPermissionRequest]
        public var forms: [MiniFormRequest]

        public init(
            tabs: [FooterSubagentTab] = [],
            details: [String: FooterSubagentDetail] = [:],
            permissions: [MiniPermissionRequest] = [],
            forms: [MiniFormRequest] = []
        ) {
            self.tabs = tabs
            self.details = details
            self.permissions = permissions
            self.forms = forms
        }
    }

    // parity: tui/src/mini/types.ts#FooterEvent [status=implemented hash=dae029589d3d]
    public enum FooterEvent: Equatable, Sendable {
        case history([RunPrompt])
        case agent(String?)
        case catalog(agents: [RunAgent], references: [RunReference], commands: [RunCommand]?)
        case models(providers: [RunProvider])
        case variants(variants: [String], current: String?)
        case queuedPrompts([FooterQueuedPrompt])
        case first(Bool)
        case model(label: String, selection: PromptModelSelection)
        case turnSend
        case turnIdle
        case turnDuration(String)
        case streamPatch(FooterPatch)
        case streamView(FooterView)
        case streamSubagent(FooterSubagentState)
    }

    // parity: tui/src/mini/types.ts#PermissionReply [status=implemented hash=7720b3f4a555]
    public struct PermissionReply: Equatable, Hashable, Sendable, Codable {
        public let sessionID: String
        public let requestID: String
        public let decision: PermissionSchema.Reply
        public let message: String?

        public init(sessionID: String, requestID: String, decision: PermissionSchema.Reply, message: String? = nil) {
            self.sessionID = sessionID
            self.requestID = requestID
            self.decision = decision
            self.message = message
        }
    }

    // parity: tui/src/mini/types.ts#FormReply [status=implemented hash=0858bfa9218f]
    public struct FormReply: Equatable, Hashable, Sendable, Codable {
        public let sessionID: String
        public let formID: String
        public let answer: [String: FormSchema.Value]
        public let location: LocationSchema.Ref?

        public init(
            sessionID: String,
            formID: String,
            answer: [String: FormSchema.Value],
            location: LocationSchema.Ref? = nil
        ) {
            self.sessionID = sessionID
            self.formID = formID
            self.answer = answer
            self.location = location
        }
    }

    // parity: tui/src/mini/types.ts#FormCancel [status=implemented hash=64136a430a01]
    public struct FormCancel: Equatable, Hashable, Sendable, Codable {
        public let sessionID: String
        public let formID: String
        public let location: LocationSchema.Ref?

        public init(sessionID: String, formID: String, location: LocationSchema.Ref? = nil) {
            self.sessionID = sessionID
            self.formID = formID
            self.location = location
        }
    }

    // parity: tui/src/mini/types.ts#RunTuiConfig [status=implemented hash=f500a993f570]
    public typealias RunTuiConfig = TUIConfig.Resolved

    // parity: tui/src/mini/types.ts#MiniSettings [status=implemented hash=414a39b4314d]
    public struct MiniSettings: Equatable, Hashable, Sendable, Codable {
        public var thinking: TUIContext.ThinkingMode
        public var tools: TUIContext.ThinkingMode
        public var shellOutput: TUIContext.ThinkingMode
        public var turnSummary: TUIContext.ThinkingMode
        public var footer: TUIContext.ThinkingMode
        public var splash: TUIContext.ThinkingMode
        public var workSpinner: TUIConfig.MiniWorkSpinner
        public var mono: Bool

        public init(
            thinking: TUIContext.ThinkingMode = .show,
            tools: TUIContext.ThinkingMode = .hide,
            shellOutput: TUIContext.ThinkingMode = .hide,
            turnSummary: TUIContext.ThinkingMode = .show,
            footer: TUIContext.ThinkingMode = .show,
            splash: TUIContext.ThinkingMode = .show,
            workSpinner: TUIConfig.MiniWorkSpinner = .blockSoftSlide,
            mono: Bool = false
        ) {
            self.thinking = thinking
            self.tools = tools
            self.shellOutput = shellOutput
            self.turnSummary = turnSummary
            self.footer = footer
            self.splash = splash
            self.workSpinner = workSpinner
            self.mono = mono
        }
    }

    // parity: tui/src/mini/types.ts#MiniVerbosity [status=implemented hash=c45481f0e7ea]
    public enum MiniVerbosity: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case quiet
        case `default`
        case everything
    }

    // parity: tui/src/mini/types.ts#MiniSettingChange [status=implemented hash=5ebcb1b4bf8d]
    public enum MiniSettingChange: Equatable, Hashable, Sendable {
        case thinking(TUIContext.ThinkingMode)
        case tools(TUIContext.ThinkingMode)
        case shellOutput(TUIContext.ThinkingMode)
        case turnSummary(TUIContext.ThinkingMode)
        case footer(TUIContext.ThinkingMode)
        case splash(TUIContext.ThinkingMode)
        case workSpinner(TUIConfig.MiniWorkSpinner)
        case mono(Bool)
        case verbosity(MiniVerbosity)
    }

    public enum StreamPhase: String, Equatable, Hashable, Sendable, Codable {
        case start, progress, final
    }

    public enum StreamSource: String, Equatable, Hashable, Sendable, Codable {
        case assistant, reasoning, tool, system
    }

    public enum StreamToolState: String, Equatable, Hashable, Sendable, Codable {
        case running, completed, error
    }

    // parity: tui/src/mini/types.ts#StreamCommit [status=implemented hash=df760773bc8c]
    public struct StreamCommit: Equatable, Sendable {
        public var kind: EntryKind
        public var text: String
        public var image: String?
        public var phase: StreamPhase
        public var source: StreamSource
        public var compaction: Bool
        public var summary: TurnSummary?
        public var messageID: String?
        public var partID: String?
        public var tool: String?
        public var directory: String?
        public var part: SessionMessageSchema.AssistantTool?
        public var interrupted: Bool
        public var toolState: StreamToolState?
        public var toolError: String?
        public var shellCommand: String?

        public init(
            kind: EntryKind,
            text: String,
            image: String? = nil,
            phase: StreamPhase,
            source: StreamSource,
            compaction: Bool = false,
            summary: TurnSummary? = nil,
            messageID: String? = nil,
            partID: String? = nil,
            tool: String? = nil,
            directory: String? = nil,
            part: SessionMessageSchema.AssistantTool? = nil,
            interrupted: Bool = false,
            toolState: StreamToolState? = nil,
            toolError: String? = nil,
            shellCommand: String? = nil
        ) {
            self.kind = kind
            self.text = text
            self.image = image
            self.phase = phase
            self.source = source
            self.compaction = compaction
            self.summary = summary
            self.messageID = messageID
            self.partID = partID
            self.tool = tool
            self.directory = directory
            self.part = part
            self.interrupted = interrupted
            self.toolState = toolState
            self.toolError = toolError
            self.shellCommand = shellCommand
        }
    }

    // parity: tui/src/mini/types.ts#LocalReplayRow [status=implemented hash=3da5e1a42ca1]
    public struct LocalReplayRow: Equatable, Sendable {
        public let commit: StreamCommit

        public init(commit: StreamCommit) {
            self.commit = commit
        }
    }

    // parity: tui/src/mini/types.ts#FooterApi [status=implemented hash=6c52775c1d6e]
    public protocol FooterApi: AnyObject, Sendable {
        var isClosed: Bool { get }
        func onPrompt(_ fn: @escaping @Sendable (RunPrompt) -> Void) -> @Sendable () -> Void
        func onClose(_ fn: @escaping @Sendable () -> Void) -> @Sendable () -> Void
        func event(_ next: FooterEvent)
        func append(_ commit: StreamCommit)
        func idle() async
        func close()
        func destroy()
    }

    // MARK: - Verbosity (`packages/tui/src/mini/verbosity.ts`)

    public struct VerbosityKnobs: Equatable, Hashable, Sendable {
        public let thinking: TUIContext.ThinkingMode
        public let tools: TUIContext.ThinkingMode
        public let shellOutput: TUIContext.ThinkingMode
        public let turnSummary: TUIContext.ThinkingMode
        public let footer: TUIContext.ThinkingMode
    }

    // parity: tui/src/mini/verbosity.ts#verbosityPreset [status=implemented hash=6647fe2fabe6]
    public static func verbosityPreset(_ level: MiniVerbosity) -> VerbosityKnobs {
        switch level {
        case .quiet:
            return VerbosityKnobs(thinking: .hide, tools: .hide, shellOutput: .hide, turnSummary: .hide, footer: .hide)
        case .default:
            return VerbosityKnobs(thinking: .show, tools: .hide, shellOutput: .hide, turnSummary: .show, footer: .show)
        case .everything:
            return VerbosityKnobs(thinking: .show, tools: .show, shellOutput: .show, turnSummary: .show, footer: .show)
        }
    }

    // parity: tui/src/mini/verbosity.ts#verbosityLabel [status=implemented hash=20c27015cae3]
    public static func verbosityLabel(_ level: MiniVerbosity?) -> String {
        switch level {
        case .quiet: return "Quiet"
        case .default: return "Default"
        case .everything: return "Everything"
        case nil: return "Custom"
        }
    }

    // parity: tui/src/mini/verbosity.ts#matchMiniVerbosity [status=implemented hash=bf465f698552]
    public static func matchMiniVerbosity(_ settings: MiniSettings) -> MiniVerbosity? {
        for level in MiniVerbosity.allCases {
            let p = verbosityPreset(level)
            if settings.thinking == p.thinking
                && settings.tools == p.tools
                && settings.shellOutput == p.shellOutput
                && settings.turnSummary == p.turnSummary
                && settings.footer == p.footer
            {
                return level
            }
        }
        return nil
    }

    private static func verbosityDistance(_ settings: MiniSettings, _ level: MiniVerbosity) -> Int {
        let p = verbosityPreset(level)
        var d = 0
        if settings.thinking != p.thinking { d += 1 }
        if settings.tools != p.tools { d += 1 }
        if settings.shellOutput != p.shellOutput { d += 1 }
        if settings.turnSummary != p.turnSummary { d += 1 }
        if settings.footer != p.footer { d += 1 }
        return d
    }

    // parity: tui/src/mini/verbosity.ts#cycleMiniVerbosity [status=implemented hash=b7646b5da800]
    public static func cycleMiniVerbosity(_ settings: MiniSettings, direction: Int) -> MiniVerbosity {
        let levels: [MiniVerbosity] = [.quiet, .default, .everything]
        let currentIndex: Int
        if let matched = matchMiniVerbosity(settings), let idx = levels.firstIndex(of: matched) {
            currentIndex = idx
        } else {
            currentIndex = levels.indices.min { verbosityDistance(settings, levels[$0]) < verbosityDistance(settings, levels[$1]) } ?? 0
        }
        let step = direction >= 0 ? 1 : -1
        let next = max(0, min(levels.count - 1, currentIndex + step))
        return levels[next]
    }

    // parity: tui/src/mini/verbosity.ts#verbosityChange [status=implemented hash=dd111b988112]
    public static func verbosityChange(_ settings: MiniSettings, direction: Int) -> MiniSettingChange? {
        let value = cycleMiniVerbosity(settings, direction: direction)
        if matchMiniVerbosity(settings) == value { return nil }
        return .verbosity(value)
    }

    // parity: tui/src/mini/verbosity.ts#applyMiniSettingChange [status=implemented hash=c1f733bbde09]
    public static func applyMiniSettingChange(_ settings: MiniSettings, _ change: MiniSettingChange) -> MiniSettings {
        var next = settings
        switch change {
        case .thinking(let v): next.thinking = v
        case .tools(let v): next.tools = v
        case .shellOutput(let v): next.shellOutput = v
        case .turnSummary(let v): next.turnSummary = v
        case .footer(let v): next.footer = v
        case .splash(let v): next.splash = v
        case .workSpinner(let v): next.workSpinner = v
        case .mono(let v): next.mono = v
        case .verbosity(let level):
            let p = verbosityPreset(level)
            next.thinking = p.thinking
            next.tools = p.tools
            next.shellOutput = p.shellOutput
            next.turnSummary = p.turnSummary
            next.footer = p.footer
        }
        return next
    }

    // MARK: - Monochrome ASCII Utilities (`packages/tui/src/mini/mono.ts`)

    private static let monoPrefixMap: [UInt32: String] = [
        0x2192: "->", 0x2190: "<-", 0x2731: "*", 0x2699: "*",
        0x2716: "!", 0x2717: "!", 0x25C8: "*", 0x25C9: "*", 0x27F3: "*",
    ]

    private static let monoMarkdownMap: [UInt32: String] = [
        0x2192: "->", 0x2190: "<-", 0x2731: "*", 0x2699: "*",
        0x2716: "!", 0x2717: "!", 0x25C8: "*", 0x25C9: "*", 0x27F3: "*",
        0x00A0: " ", 0x00B7: "-", 0x2010: "-", 0x2011: "-", 0x2012: "-",
        0x2013: "-", 0x2014: "--", 0x2018: "'", 0x2019: "'", 0x201C: "\"",
        0x201D: "\"", 0x2022: "*", 0x2026: "...", 0x2191: "up", 0x2193: "down",
    ]

    public struct MonoMarkdownTableOptions: Equatable, Hashable, Sendable {
        public let style: String = "columns"
        public let widthMode: String = "content"
        public let borders: Bool = false
    }

    // parity: tui/src/mini/mono.ts#monoMarkdownTableOptions [status=implemented hash=23bdae2212c6]
    public static let monoMarkdownTableOptions = MonoMarkdownTableOptions()

    private static func monoText(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            let v = scalar.value
            if v == 0x09 || v == 0x0A || (v >= 0x20 && v <= 0x7E) {
                out.unicodeScalars.append(scalar)
            } else {
                out += monoMarkdownMap[v] ?? "?"
            }
        }
        return out
    }

    // parity: tui/src/mini/mono.ts#monoMarkdownRenderable [status=adapted hash=524a76772ec6]
    public static func monoMarkdownRenderable(_ renderable: MarkdownRenderable) {
        let asciiBorder = BorderCharacters(
            topLeft: "+", topRight: "+", bottomLeft: "+", bottomRight: "+",
            horizontal: "-", vertical: "|", topT: "+", bottomT: "+", leftT: "+", rightT: "+", cross: "+"
        )
        func visit(_ node: Renderable) {
            if let box = node as? BoxRenderable {
                box.customBorderChars = asciiBorder
            } else if let text = node as? TextRenderable {
                let transformed = text.content.chunks.map { chunk in
                    TextChunk(text: monoText(chunk.text), fg: chunk.fg, bg: chunk.bg, attributes: chunk.attributes, link: chunk.link)
                }
                text.setContent(StyledText(chunks: transformed))
            }
            for child in node.getChildren() { visit(child) }
        }
        visit(renderable)
    }

    // parity: tui/src/mini/mono.ts#monoSnapshot [status=implemented hash=51f36821f8b9]
    public static func monoSnapshot(_ event: CliRendererExternalOutputEvent) {
        let buf = event.snapshot
        let w = buf.width
        let h = buf.height
        for y in 0..<h {
            for x in 0..<w {
                let idx = y * w + x
                let point = buf.chars[idx]
                if point <= 0x7F { continue }
                let replacement: String
                let kind = point >> 30
                if kind == 2 { replacement = "?" }
                else if kind == 3 { replacement = " " }
                else if point == 0x2500 { replacement = "-" }
                else if point == 0x2502 { replacement = "|" }
                else { replacement = monoMarkdownMap[point].map { String($0.prefix(1)) } ?? "?" }
                buf.setCell(x: x, y: y, char: replacement, fg: buf.fg[idx], bg: buf.bg[idx], attributes: buf.attributes[idx])
            }
        }
    }

    // parity: tui/src/mini/mono.ts#monoPrefix [status=implemented hash=9cdd17156bfe]
    public static func monoPrefix(_ value: String, mono: Bool) -> String {
        guard mono, let first = value.unicodeScalars.first, let replacement = monoPrefixMap[first.value] else {
            return value
        }
        return replacement + String(value.unicodeScalars.dropFirst())
    }

    // parity: tui/src/mini/mono.ts#monoToolText [status=implemented hash=e26237659bdc]
    public static func monoToolText(_ value: String, mono: Bool) -> String {
        let result = monoPrefix(value, mono: mono)
        guard mono else { return result }
        let sep = " · "
        guard let range = result.range(of: sep, options: .backwards) else { return result }
        let head = String(result[..<range.lowerBound])
        let isQuestions: Bool = {
            guard head.hasSuffix(" questions") else { return false }
            let digits = head.dropLast(" questions".count)
            return !digits.isEmpty && digits.allSatisfy { $0 >= "0" && $0 <= "9" }
        }()
        if !head.contains(" completed") && head != "patch" && !isQuestions {
            return result
        }
        return head + " - " + String(result[range.upperBound...])
    }

    // parity: tui/src/mini/mono.ts#monoShortcut [status=implemented hash=5f48b2301f36]
    public static func monoShortcut(_ value: String, mono: Bool) -> String {
        guard mono else { return value }
        return value
            .replacingOccurrences(of: "→", with: "right")
            .replacingOccurrences(of: "←", with: "left")
            .replacingOccurrences(of: "↑", with: "up")
            .replacingOccurrences(of: "↓", with: "down")
    }

    // parity: tui/src/mini/mono.ts#monoTruncate [status=implemented hash=28f9234809a2]
    public static func monoTruncate(_ value: String, width: Int, mono: Bool) -> String {
        guard mono, value.utf16.count > width else { return value }
        if width <= 3 { return String(repeating: ".", count: max(0, width)) }
        return String(decoding: Array(value.utf16).prefix(width - 3), as: UTF16.self) + "..."
    }

    // MARK: - Mini Theme (`packages/tui/src/mini/theme.ts`)

    public struct EntryTone: Equatable, Hashable, Sendable {
        public let body: RGBA
        public let start: RGBA?

        public init(body: RGBA, start: RGBA? = nil) {
            self.body = body
            self.start = start
        }
    }

    // parity: tui/src/mini/theme.ts#RunEntryTheme [status=implemented hash=33efa35723f4]
    public struct RunEntryTheme: Equatable, Hashable, Sendable {
        public let system: EntryTone
        public let user: EntryTone
        public let assistant: EntryTone
        public let reasoning: EntryTone
        public let tool: EntryTone
        public let error: EntryTone

        public subscript(_ kind: EntryKind) -> EntryTone {
            switch kind {
            case .system: return system
            case .user: return user
            case .assistant: return assistant
            case .reasoning: return reasoning
            case .tool: return tool
            case .error: return error
            }
        }
    }

    // parity: tui/src/mini/theme.ts#RunSplashTheme [status=implemented hash=f133a487cfc2]
    public struct RunSplashTheme: Equatable, Hashable, Sendable {
        public let left: RGBA
        public let right: RGBA
        public let leftShadow: RGBA
    }

    // parity: tui/src/mini/theme.ts#RunFooterTheme [status=implemented hash=41458547b900]
    public struct RunFooterTheme: Equatable, Hashable, Sendable {
        public let actionSecondaryText: RGBA
        public let actionFocusedBg: RGBA
        public let actionFocusedText: RGBA
        public let formfieldText: RGBA
        public let formfieldFocusedBg: RGBA
        public let formfieldFocusedText: RGBA
        public let selection: RGBA
        public let running: RGBA
        public let question: RGBA
        public let permission: RGBA
        public let success: RGBA
        public let link: RGBA
        public let categorical: [RGBA]
        public let warning: RGBA
        public let error: RGBA
        public let muted: RGBA
        public let text: RGBA
        public let shade: RGBA
        public let surface: RGBA
        public let pane: RGBA
        public let border: RGBA
        public let line: RGBA
    }

    // parity: tui/src/mini/theme.ts#RunBlockTheme [status=implemented hash=8ff11adb2f7e]
    public struct RunBlockTheme: @unchecked Sendable {
        public let text: RGBA
        public let muted: RGBA
        public let faint: RGBA
        public let warning: RGBA
        public let syntax: SyntaxStyle?
        public let diffRemoved: RGBA
        public let diffAddedBg: RGBA
        public let diffRemovedBg: RGBA
        public let diffContextBg: RGBA
        public let diffHighlightAdded: RGBA
        public let diffHighlightRemoved: RGBA
        public let diffLineNumber: RGBA
        public let diffAddedLineNumberBg: RGBA
        public let diffRemovedLineNumberBg: RGBA
    }

    // parity: tui/src/mini/theme.ts#RunTheme [status=implemented hash=b825d8dc7fd1]
    public struct RunTheme: @unchecked Sendable {
        public let background: RGBA
        public let footer: RunFooterTheme
        public let entry: RunEntryTheme
        public let splash: RunSplashTheme
        public let block: RunBlockTheme
    }

    // parity: tui/src/mini/theme.ts#transparent [status=implemented hash=c42876cde44c]
    public static let transparent = RGBA.fromValues(0, 0, 0, 0)

    private static func mapResolvedTheme(_ theme: ResolvedTheme, syntax: SyntaxStyle? = nil) -> RunTheme {
        var cat: [RGBA] = []
        for scale in theme.categorical {
            let c = scale[.s200]
            if !cat.contains(c) { cat.append(c) }
        }
        return RunTheme(
            background: RGBA.defaultBackground(snapshot: hex(theme.background.base)),
            footer: RunFooterTheme(
                actionSecondaryText: theme.text.action.secondary.base,
                actionFocusedBg: theme.background.action.primary.focused,
                actionFocusedText: theme.text.action.primary.focused,
                formfieldText: theme.text.formfield.base,
                formfieldFocusedBg: theme.background.formfield.focused,
                formfieldFocusedText: theme.text.formfield.focused,
                selection: theme.text.formfield.selected,
                running: theme.hue.interactive[.s200],
                question: theme.hue.accent[.s200],
                permission: theme.hue.accent[.s200],
                success: theme.text.feedback.success.base,
                link: theme.markdown.link,
                categorical: cat,
                warning: theme.text.feedback.warning.base,
                error: theme.text.feedback.error.base,
                muted: theme.text.muted,
                text: theme.text.base,
                shade: theme.background.raised.base,
                surface: theme.background.raised.base,
                pane: theme.background.raised.high,
                border: theme.border.base,
                line: theme.background.raised.high
            ),
            entry: RunEntryTheme(
                system: EntryTone(body: theme.text.muted),
                user: EntryTone(body: theme.text.base),
                assistant: EntryTone(body: theme.markdown.text),
                reasoning: EntryTone(body: theme.text.muted),
                tool: EntryTone(body: theme.text.muted, start: theme.text.muted),
                error: EntryTone(body: theme.text.feedback.error.base)
            ),
            splash: RunSplashTheme(
                left: theme.text.muted,
                right: theme.text.base,
                leftShadow: theme.background.raised.base
            ),
            block: RunBlockTheme(
                text: theme.text.base,
                muted: theme.text.muted,
                faint: theme.text.faint,
                warning: theme.text.feedback.warning.base,
                syntax: syntax,
                diffRemoved: theme.diff.text.removed,
                diffAddedBg: theme.diff.background.added,
                diffRemovedBg: theme.diff.background.removed,
                diffContextBg: theme.diff.background.context,
                diffHighlightAdded: theme.diff.highlight.added,
                diffHighlightRemoved: theme.diff.highlight.removed,
                diffLineNumber: theme.diff.lineNumber.text,
                diffAddedLineNumberBg: theme.diff.lineNumber.background.added,
                diffRemovedLineNumberBg: theme.diff.lineNumber.background.removed
            )
        )
    }

    private static func makeMonoTheme(mode: Mode) -> RunTheme {
        let fgColor = RGBA.defaultForeground(snapshot: mode == .light ? "#000000" : "#ffffff")
        let bgColor = RGBA.defaultBackground(snapshot: mode == .light ? "#ffffff" : "#000000")
        return RunTheme(
            background: bgColor,
            footer: RunFooterTheme(
                actionSecondaryText: fgColor, actionFocusedBg: bgColor, actionFocusedText: fgColor,
                formfieldText: fgColor, formfieldFocusedBg: bgColor, formfieldFocusedText: fgColor,
                selection: fgColor, running: fgColor, question: fgColor, permission: fgColor,
                success: fgColor, link: fgColor, categorical: [fgColor], warning: fgColor,
                error: fgColor, muted: fgColor, text: fgColor, shade: bgColor, surface: bgColor,
                pane: bgColor, border: fgColor, line: bgColor
            ),
            entry: RunEntryTheme(
                system: EntryTone(body: fgColor), user: EntryTone(body: fgColor),
                assistant: EntryTone(body: fgColor), reasoning: EntryTone(body: fgColor),
                tool: EntryTone(body: fgColor), error: EntryTone(body: fgColor)
            ),
            splash: RunSplashTheme(left: fgColor, right: fgColor, leftShadow: bgColor),
            block: RunBlockTheme(
                text: fgColor, muted: fgColor, faint: fgColor, warning: fgColor, syntax: nil,
                diffRemoved: fgColor, diffAddedBg: bgColor, diffRemovedBg: bgColor, diffContextBg: bgColor,
                diffHighlightAdded: fgColor, diffHighlightRemoved: fgColor, diffLineNumber: fgColor,
                diffAddedLineNumberBg: bgColor, diffRemovedLineNumberBg: bgColor
            )
        )
    }

    // parity: tui/src/mini/theme.ts#RUN_THEME_FALLBACK [status=implemented hash=de79436b0e84]
    public static let RUN_THEME_FALLBACK: RunTheme = mapResolvedTheme(
        try! resolveThemeDocument(ThemeDefaults.opencode, mode: .dark)
    )

    // parity: tui/src/mini/theme.ts#RUN_THEME_FALLBACK_LIGHT [status=implemented hash=f1b90705d1c4]
    public static let RUN_THEME_FALLBACK_LIGHT: RunTheme = mapResolvedTheme(
        try! resolveThemeDocument(ThemeDefaults.opencode, mode: .light)
    )

    // parity: tui/src/mini/theme.ts#RUN_THEME_MONO [status=implemented hash=95108cffb044]
    public static let RUN_THEME_MONO: RunTheme = makeMonoTheme(mode: .dark)

    // parity: tui/src/mini/theme.ts#resolveRunTheme [status=adapted hash=def39c0439be]
    public static func resolveRunTheme(
        renderer: CliRenderer,
        config: TUIConfig.ThemeConfig? = nil,
        mono: Bool = false
    ) async -> RunTheme {
        let mode: Mode = (config?.mode == .light) ? .light : .dark
        if mono {
            return makeMonoTheme(mode: mode)
        }
        let resolved = (try? resolveThemeDocument(ThemeDefaults.opencode, mode: mode))
            ?? (try! resolveThemeDocument(ThemeDefaults.opencode, mode: .dark))
        let syntax = renderer.isDestroyed ? nil : generateSyntax(resolved)
        return mapResolvedTheme(resolved, syntax: syntax)
    }

    // MARK: - Tool Display Rules (`packages/tui/src/mini/tool.ts`)

    public struct ToolView: Equatable, Hashable, Sendable {
        public let output: Bool
        public let final: Bool
        public let snap: String?

        public init(output: Bool, final: Bool, snap: String? = nil) {
            self.output = output
            self.final = final
            self.snap = snap
        }
    }

    public struct ToolInline: Equatable, Hashable, Sendable {
        public let icon: String
        public let title: String
        public let description: String?
        public let mode: EntryLayout?
        public let body: String?

        public init(icon: String, title: String, description: String? = nil, mode: EntryLayout? = nil, body: String? = nil) {
            self.icon = icon
            self.title = title
            self.description = description
            self.mode = mode
            self.body = body
        }
    }

    public struct ToolFrame: Sendable {
        public let directory: String?
        public let raw: String
        public let name: String
        public let input: [String: JSONValue]
        public let meta: [String: JSONValue]
        public let status: String
        public let error: String
        public let output: String

        public init(
            directory: String? = nil,
            raw: String = "",
            name: String,
            input: [String: JSONValue] = [:],
            meta: [String: JSONValue] = [:],
            status: String = "",
            error: String = "",
            output: String = ""
        ) {
            self.directory = directory
            self.raw = raw
            self.name = name
            self.input = input
            self.meta = meta
            self.status = status
            self.error = error
            self.output = output
        }
    }

    private static func canonicalMiniToolName(_ name: String) -> String {
        switch name.lowercased() {
        case "bash": return "shell"
        case "apply_patch": return "patch"
        case "task": return "subagent"
        default: return name.lowercased()
        }
    }

    // parity: tui/src/mini/tool.ts#readDisplayText [status=implemented hash=bd133f84c759]
    public static func readDisplayText(_ text: String) -> String? {
        guard text.hasPrefix("{"),
              let json = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              case .object(let env) = json
        else { return nil }
        if case .string(let content) = env["content"] {
            let isTextPage: Bool = if case .string(let t) = env["type"] { t == "text-page" } else { false }
            let isUTF8: Bool = if case .string(let e) = env["encoding"] { e == "utf8" } else { false }
            if isTextPage || isUTF8 { return content }
        }
        if case .array(let entries) = env["entries"] {
            return entries.compactMap { entry -> String? in
                switch entry {
                case .string(let s): return s
                case .object(let d):
                    if case .string(let p) = d["path"] { return p }
                    return nil
                default: return nil
                }
            }.joined(separator: "\n")
        }
        return nil
    }

    // parity: tui/src/mini/tool.ts#toolOutputText [status=implemented hash=3abcec2140e7]
    public static func toolOutputText(_ name: String, content: [SessionMessageSchema.ToolContent]?) -> String {
        guard let content else { return "" }
        let canon = canonicalMiniToolName(name)
        if canon == "shell" {
            for item in content {
                if case .text(let s) = item { return s }
            }
            return ""
        }
        let joined = content.compactMap { item -> String? in
            if case .text(let s) = item, !s.isEmpty { return s }
            return nil
        }.joined(separator: "\n")
        if canon == "read" { return readDisplayText(joined) ?? joined }
        return joined
    }

    // parity: tui/src/mini/tool.ts#normalizeTool [status=implemented hash=5605f9403914]
    public static func normalizeTool(_ tool: SessionMessageSchema.AssistantTool) -> SessionMessageSchema.AssistantTool {
        let canon = canonicalMiniToolName(tool.name)
        return SessionMessageSchema.AssistantTool(
            id: tool.id,
            name: canon,
            executed: tool.executed,
            native: tool.native,
            state: tool.state,
            time: tool.time
        )
    }

    // parity: tui/src/mini/tool.ts#toolPath [status=implemented hash=a73212adb369]
    public static func toolPath(_ input: String?, home: Bool = false, directory: String? = nil) -> String {
        let base = directory ?? TUIEditor.currentWorkingDirectory()
        let homeDir = home ? (SystemEnvironment.shared.homeDirectory ?? "") : ""
        return TUIContext.PathFormatter(base: base, home: homeDir).format(input)
    }

    // parity: tui/src/mini/tool.ts#toolView [status=implemented hash=3d0df663df2d]
    public static func toolView(_ name: String?) -> ToolView {
        guard let name else { return ToolView(output: true, final: true) }
        switch canonicalMiniToolName(name) {
        case "invalid", "shell", "batch":
            return ToolView(output: true, final: false)
        case "write":
            return ToolView(output: false, final: true, snap: "code")
        case "edit", "patch":
            return ToolView(output: false, final: true, snap: "diff")
        case "subagent", "todowrite", "question":
            return ToolView(output: false, final: true, snap: "structured")
        case "read", "glob", "grep", "list", "lsp", "webfetch", "websearch", "skill":
            return ToolView(output: false, final: false)
        default:
            return ToolView(output: true, final: true)
        }
    }

    // parity: tui/src/mini/tool.ts#toolStructuredFinal [status=implemented hash=863fabbc3909]
    public static func toolStructuredFinal(_ commit: StreamCommit) -> Bool {
        let state = commit.toolState?.rawValue ?? commit.part?.state.statusTag
        return commit.kind == .tool
            && commit.phase == .final
            && state == "completed"
            && toolView(commit.tool ?? commit.part?.name).snap != nil
    }

    private static func makeFrame(from part: SessionMessageSchema.AssistantTool, directory: String?) -> ToolFrame {
        let norm = normalizeTool(part)
        switch norm.state {
        case .streaming(let s):
            return ToolFrame(directory: directory, raw: s.input, name: norm.name, status: "streaming")
        case .running(let s):
            return ToolFrame(directory: directory, raw: "", name: norm.name, input: s.input, meta: s.metadata, status: "running")
        case .completed(let s):
            let out = toolOutputText(norm.name, content: s.content)
            return ToolFrame(directory: directory, raw: out, name: norm.name, input: s.input, meta: s.metadata ?? [:], status: "completed", output: out)
        case .error(let s):
            let out = toolOutputText(norm.name, content: s.content)
            return ToolFrame(directory: directory, raw: out, name: norm.name, input: s.input, meta: s.metadata ?? [:], status: "error", error: s.error.message, output: out)
        }
    }

    private static func stringField(_ dict: [String: JSONValue], _ keys: String...) -> String? {
        for key in keys {
            if case .string(let s) = dict[key], !s.isEmpty { return s }
        }
        return nil
    }

    // parity: tui/src/mini/tool.ts#toolInlineInfo [status=implemented hash=ad932b6c38e8]
    public static func toolInlineInfo(_ part: SessionMessageSchema.AssistantTool, directory: String? = nil) -> ToolInline {
        let ctx = makeFrame(from: part, directory: directory)
        switch ctx.name {
        case "shell":
            return ToolInline(
                icon: "$",
                title: stringField(ctx.input, "command") ?? "",
                mode: .block,
                body: ctx.status == "completed" ? ctx.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            )
        case "read":
            return ToolInline(icon: "→", title: "Read \(toolPath(stringField(ctx.input, "path", "filePath"), directory: directory))")
        case "write":
            return ToolInline(icon: "←", title: "Write \(toolPath(stringField(ctx.input, "path", "filePath"), directory: directory))")
        case "edit":
            return ToolInline(icon: "←", title: "Edit \(toolPath(stringField(ctx.input, "path", "filePath"), directory: directory))")
        case "glob":
            return ToolInline(icon: "✱", title: "Glob \"\(stringField(ctx.input, "pattern") ?? "")\"")
        case "grep":
            return ToolInline(icon: "✱", title: "Grep \"\(stringField(ctx.input, "pattern") ?? "")\"")
        case "webfetch":
            return ToolInline(icon: "%", title: "WebFetch \(stringField(ctx.input, "url") ?? "")")
        case "websearch":
            return ToolInline(icon: "◈", title: "WebSearch \"\(stringField(ctx.input, "query") ?? "")\"")
        default:
            return ToolInline(icon: "⚙", title: TUIRoutes.genericToolSummary(ctx.name, input: ctx.input))
        }
    }

    // parity: tui/src/mini/tool.ts#toolScroll [status=implemented hash=07281ae940c0]
    public static func toolScroll(phase: StreamPhase, ctx: ToolFrame) -> String {
        switch phase {
        case .start:
            switch ctx.name {
            case "shell":
                let cmd = stringField(ctx.input, "command") ?? ""
                return cmd.isEmpty ? "$" : "$ \(cmd)"
            case "read":
                let p = stringField(ctx.input, "path", "filePath") ?? ""
                return p.isEmpty ? "→ Read" : "→ Read \(toolPath(p, directory: ctx.directory))"
            case "write":
                let p = stringField(ctx.input, "path", "filePath") ?? ""
                return p.isEmpty ? "← Write" : "← Write \(toolPath(p, directory: ctx.directory))"
            case "edit":
                let p = stringField(ctx.input, "path", "filePath") ?? ""
                return p.isEmpty ? "← Edit" : "← Edit \(toolPath(p, directory: ctx.directory))"
            case "glob":
                let pat = stringField(ctx.input, "pattern") ?? ""
                return pat.isEmpty ? "✱ Glob" : "✱ Glob \"\(pat)\""
            case "grep":
                let pat = stringField(ctx.input, "pattern") ?? ""
                return pat.isEmpty ? "✱ Grep" : "✱ Grep \"\(pat)\""
            case "webfetch":
                let url = stringField(ctx.input, "url") ?? ""
                return url.isEmpty ? "% WebFetch" : "% WebFetch \(url)"
            case "subagent", "todowrite", "question", "invalid", "batch":
                return ""
            default:
                return "⚙ \(TUIRoutes.genericToolSummary(ctx.name, input: ctx.input))"
            }
        case .progress:
            return ctx.raw
        case .final:
            if ctx.status == "error" {
                let err = ctx.error.isEmpty ? ctx.raw : ctx.error
                return err.isEmpty ? "✖ \(ctx.name) failed" : "✖ \(err)"
            }
            if ctx.name == "patch" { return "patch" }
            return "\(ctx.name) completed"
        }
    }

    // parity: tui/src/mini/tool.ts#toolEntryBody [status=implemented hash=366885a9b1ec]
    public static func toolEntryBody(
        _ commit: StreamCommit,
        raw: String,
        options: ScrollbackOptions? = nil
    ) -> RunEntryBody? {
        if let shellCmd = commit.shellCommand {
            switch commit.phase {
            case .start: return .text(content: "$ \(shellCmd)")
            case .progress:
                let body = stripAnsiSequences(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
                guard !body.isEmpty else { return nil }
                return .text(content: shellCmd.isEmpty ? body : "\n\(body)")
            case .final:
                if commit.toolState == .error {
                    let ctx = commit.part.map { makeFrame(from: $0, directory: commit.directory) }
                        ?? ToolFrame(directory: commit.directory, raw: raw, name: "shell", status: "error", error: commit.toolError ?? raw)
                    let txt = toolScroll(phase: .final, ctx: ctx)
                    return txt.isEmpty ? nil : .text(content: txt)
                }
                return nil
            }
        }

        let ctx: ToolFrame
        if let part = commit.part {
            let base = makeFrame(from: part, directory: commit.directory)
            ctx = ToolFrame(
                directory: commit.directory,
                raw: raw,
                name: canonicalMiniToolName(commit.tool ?? base.name),
                input: base.input,
                meta: base.meta,
                status: commit.toolState?.rawValue ?? base.status,
                error: (commit.toolError ?? base.error).trimmingCharacters(in: .whitespacesAndNewlines),
                output: base.output
            )
        } else {
            ctx = ToolFrame(
                directory: commit.directory,
                raw: raw,
                name: canonicalMiniToolName(commit.tool ?? "tool"),
                status: commit.toolState?.rawValue ?? "",
                error: (commit.toolError ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                output: raw
            )
        }
        let view = toolView(ctx.name)
        if ctx.name == "shell" && commit.phase == .progress && options?.shellOutput == false { return nil }
        if ctx.name == "subagent" && commit.phase == .start { return nil }
        if commit.phase == .progress && !view.output { return nil }
        if commit.phase == .final {
            if ctx.status == "error" {
                let s = toolScroll(phase: .final, ctx: ctx)
                return s.isEmpty ? nil : .text(content: s)
            }
            if !view.final { return nil }
            if toolStructuredFinal(commit) {
                if ctx.name == "write", let content = stringField(ctx.input, "content") {
                    let file = stringField(ctx.input, "path", "filePath")
                    return .structured(snapshot: .code(title: "← Write \(toolPath(file, directory: ctx.directory))", content: content, file: file))
                }
                if ctx.name == "edit", let diff = stringField(ctx.meta, "diff") ?? stringField(ctx.input, "diff") {
                    let file = stringField(ctx.input, "path", "filePath")
                    return .structured(snapshot: .diff(items: [ToolDiffItem(title: "← Edit \(toolPath(file, directory: ctx.directory))", diff: diff, file: file)]))
                }
            }
        }
        let txt = toolScroll(phase: commit.phase, ctx: ctx)
        return txt.isEmpty ? nil : .text(content: txt)
    }

    private static let languageExtensions: [String: String] = [
        ".ts": "typescript", ".tsx": "typescriptreact", ".mts": "typescript", ".cts": "typescript",
        ".js": "javascript", ".jsx": "javascriptreact", ".mjs": "javascript", ".cjs": "javascript",
        ".swift": "swift", ".rs": "rust", ".go": "go", ".py": "python", ".rb": "ruby",
        ".json": "json", ".yaml": "yaml", ".yml": "yaml", ".toml": "toml", ".md": "markdown",
        ".sh": "bash", ".zsh": "bash", ".bash": "bash", ".c": "c", ".h": "c", ".cpp": "cpp",
        ".css": "css", ".html": "html", ".xml": "xml", ".sql": "sql", ".zig": "zig",
    ]

    // parity: tui/src/mini/tool.ts#toolFiletype [status=implemented hash=0fc94a6e2661]
    public static func toolFiletype(_ input: String?) -> String? {
        guard let input, let dot = input.lastIndex(of: ".") else { return nil }
        let ext = String(input[dot...]).lowercased()
        guard let lang = languageExtensions[ext] else { return nil }
        if lang == "typescriptreact" || lang == "javascriptreact" || lang == "javascript" {
            return "typescript"
        }
        return lang
    }

    // MARK: - Entry Body (`packages/tui/src/mini/entry.body.ts`)

    // parity: tui/src/mini/entry.body.ts#EntryFlags [status=implemented hash=69e16e03c27b]
    public struct EntryFlags: Equatable, Hashable, Sendable {
        public let startOnNewLine: Bool
        public let trailingNewline: Bool

        public init(startOnNewLine: Bool, trailingNewline: Bool) {
            self.startOnNewLine = startOnNewLine
            self.trailingNewline = trailingNewline
        }
    }

    // parity: tui/src/mini/entry.body.ts#entryFlags [status=implemented hash=7b2dfd40283e]
    public static func entryFlags(_ commit: StreamCommit) -> EntryFlags {
        if commit.summary != nil || commit.kind == .user || commit.kind == .error {
            return EntryFlags(startOnNewLine: true, trailingNewline: false)
        }
        if commit.kind == .tool || commit.kind == .assistant || commit.kind == .reasoning {
            if commit.phase == .progress {
                return EntryFlags(startOnNewLine: false, trailingNewline: false)
            }
            return EntryFlags(startOnNewLine: true, trailingNewline: true)
        }
        return EntryFlags(startOnNewLine: true, trailingNewline: true)
    }

    // parity: tui/src/mini/entry.body.ts#entryDone [status=implemented hash=49ee87b272dc]
    public static func entryDone(_ commit: StreamCommit) -> Bool {
        if commit.kind == .assistant || commit.kind == .reasoning {
            return commit.phase == .final
        }
        if commit.kind == .tool {
            return commit.phase == .final || (commit.phase == .progress && commit.toolState == .completed)
        }
        return true
    }

    // parity: tui/src/mini/entry.body.ts#entryCanStream [status=implemented hash=4b6925a3733a]
    public static func entryCanStream(_ commit: StreamCommit, body: RunEntryBody) -> Bool {
        guard commit.phase == .progress, body != .none else { return false }
        if commit.kind == .tool { return commit.toolState != .completed }
        return commit.kind == .assistant || commit.kind == .reasoning
    }

    private static func flattenMonoBody(_ body: RunEntryBody) -> RunEntryBody {
        switch body {
        case .none, .text, .markdown: return body
        case .code(let content, _): return content.isEmpty ? .none : .text(content: content)
        case .structured(let snapshot):
            switch snapshot {
            case .todo: return body
            case .code(let title, let content, _): return .text(content: "\(title)\n\(content)")
            case .diff(let items):
                let joined = items.map { item in
                    let trimmed = item.diff.trimmingCharacters(in: .whitespacesAndNewlines)
                    return "\(item.title)\n\(trimmed.isEmpty ? "-\(item.deletions ?? 0) lines" : trimmed)"
                }.joined(separator: "\n\n")
                return joined.isEmpty ? .none : .text(content: joined)
            case .task(let title, let rows, let tail):
                let joined = ([title] + rows + [tail]).filter { !$0.isEmpty }.joined(separator: "\n")
                return joined.isEmpty ? .none : .text(content: joined)
            case .question(let items, let tail):
                let lines = ["# Questions"] + items.flatMap { [$0.question, $0.answer] } + [tail]
                let joined = lines.filter { !$0.isEmpty }.joined(separator: "\n")
                return joined.isEmpty ? .none : .text(content: joined)
            }
        }
    }

    // parity: tui/src/mini/entry.body.ts#entryBody [status=implemented hash=d7c5af2010a1]
    public static func entryBody(_ commit: StreamCommit, options: ScrollbackOptions? = nil) -> RunEntryBody {
        if commit.summary != nil { return .none }
        let raw = commit.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let mono = options?.mono == true

        func userBody(_ text: String) -> RunEntryBody {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
            let leadCount = text.prefix(while: { $0 == "\n" }).count
            let lead = String(repeating: "\n", count: leadCount)
            let body = String(text.dropFirst(leadCount))
            return .text(content: "\(lead)\(mono ? ">" : "›") \(body)")
        }

        if commit.image != nil {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let caption = trimmed.isEmpty ? "Image" : trimmed
            return commit.kind == .user ? userBody(caption) : .text(content: monoToolText(caption, mono: mono))
        }
        switch commit.kind {
        case .user:
            return userBody(raw)
        case .tool:
            let body = toolEntryBody(commit, raw: raw, options: options) ?? .none
            let result = mono ? flattenMonoBody(body) : body
            if mono, case .text(let c) = result, commit.phase != .progress {
                return .text(content: monoToolText(c, mono: true))
            }
            return result
        case .assistant:
            if commit.phase == .start { return .none }
            if commit.phase == .final {
                return commit.interrupted ? .text(content: "assistant interrupted") : .none
            }
            return raw.isEmpty ? .none : .markdown(content: raw)
        case .reasoning:
            if commit.phase == .start { return .none }
            if commit.phase == .final {
                return commit.interrupted ? .text(content: "reasoning interrupted") : .none
            }
            let clean = raw.replacingOccurrences(of: "[REDACTED]", with: "")
            if clean.isEmpty { return .none }
            let leadCount = clean.prefix(while: { $0 == "\n" }).count
            let lead = String(repeating: "\n", count: leadCount)
            let body = String(clean.dropFirst(leadCount))
            if body.hasPrefix("Thinking:") {
                let rest = String(body.dropFirst("Thinking:".count)).drop(while: { $0 == " " || $0 == "\t" })
                if mono { return .text(content: "\(lead)Thinking: \(rest)") }
                return .code(content: "\(lead)_Thinking:_ \(rest)", filetype: "markdown")
            }
            return mono ? .text(content: clean) : .code(content: clean, filetype: "markdown")
        case .system, .error:
            let content = commit.phase == .progress ? raw : raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty { return .none }
            return .text(content: mono ? monoPrefix(content, mono: true) : content)
        }
    }

    // MARK: - Scrollback Shared, Writer & Surface (`scrollback.shared.ts`, `scrollback.writer.tsx`, `scrollback.surface.ts`)

    // parity: tui/src/mini/scrollback.shared.ts#entrySyntax [status=adapted hash=91f51b845af9]
    public static func entrySyntax(_ theme: RunTheme) -> SyntaxStyle {
        var styles: [String: StyleDefinitionInput] = [:]
        if let existing = theme.block.syntax {
            for name in existing.getRegisteredNames() {
                if let def = existing.getStyle(name) {
                    styles[name] = StyleDefinitionInput(
                        fg: def.fg.map { .rgba($0) },
                        bg: def.bg.map { .rgba($0) },
                        bold: def.bold, italic: def.italic, underline: def.underline,
                        dim: def.dim, strikethrough: def.strikethrough
                    )
                }
            }
        }
        return SyntaxStyle.fromStyles(styles)
    }

    private static func entryFailed(_ commit: StreamCommit) -> Bool {
        commit.kind == .tool && (commit.toolState == .error || commit.part?.state.statusTag == "error")
    }

    // parity: tui/src/mini/scrollback.shared.ts#entryLook [status=implemented hash=755777de97fa]
    public static func entryLook(_ commit: StreamCommit, theme: RunEntryTheme) -> (fg: RGBA, attrs: UInt32?) {
        if commit.kind == .user { return (theme.user.body, nil) }
        if entryFailed(commit) { return (theme.error.body, createTextAttributes(bold: true)) }
        if commit.phase == .final { return (theme.system.body, nil) }
        if commit.kind == .tool && commit.phase == .start { return (theme.tool.start ?? theme.tool.body, nil) }
        if commit.kind == .assistant { return (theme.assistant.body, nil) }
        if commit.kind == .reasoning { return (theme.reasoning.body, nil) }
        if commit.kind == .error { return (theme.error.body, createTextAttributes(bold: true)) }
        if commit.kind == .tool { return (theme.tool.body, nil) }
        return (theme.system.body, nil)
    }

    // parity: tui/src/mini/scrollback.shared.ts#entryColor [status=implemented hash=3f2c2c9da33f]
    public static func entryColor(_ commit: StreamCommit, theme: RunTheme) -> RGBA {
        if commit.kind == .assistant { return theme.entry.assistant.body }
        if commit.kind == .reasoning { return theme.entry.reasoning.body }
        if entryFailed(commit) { return theme.entry.error.body }
        if commit.kind == .tool { return theme.block.text }
        return entryLook(commit, theme: theme.entry).fg
    }

    // parity: tui/src/mini/scrollback.writer.tsx#entryGroupKey [status=implemented hash=263006c9879d]
    public static func entryGroupKey(_ commit: StreamCommit) -> String? {
        guard let partID = commit.partID, !partID.isEmpty else { return nil }
        let part = "\(commit.messageID ?? "")\u{0}\(partID)"
        if toolStructuredFinal(commit) { return "tool:\(part):final" }
        return "\(commit.kind.rawValue):\(part)"
    }

    // parity: tui/src/mini/scrollback.writer.tsx#sameEntryGroup [status=implemented hash=18219d4ce8c3]
    public static func sameEntryGroup(_ left: StreamCommit?, _ right: StreamCommit) -> Bool {
        guard let left, let lk = entryGroupKey(left), let rk = entryGroupKey(right) else { return false }
        return lk == rk
    }

    private static func entryLayout(_ commit: StreamCommit, body: RunEntryBody? = nil) -> EntryLayout {
        if commit.image != nil { return .block }
        if commit.kind == .tool {
            let b = body ?? entryBody(commit)
            switch b {
            case .structured, .markdown: return .block
            case .text(let content) where commit.phase == .progress && commit.toolState == .completed && content.contains("\n"):
                return .block
            default: return .inline
            }
        }
        return .block
    }

    // parity: tui/src/mini/scrollback.writer.tsx#separatorRows [status=implemented hash=01665a1d8419]
    public static func separatorRows(
        prev: StreamCommit?,
        next: StreamCommit,
        body: RunEntryBody? = nil
    ) -> Int {
        guard let prev, !sameEntryGroup(prev, next) else { return 0 }
        if entryLayout(prev) == .inline && entryLayout(next, body: body) == .inline { return 0 }
        return 1
    }

    // parity: tui/src/mini/scrollback.writer.tsx#RunEntryContent [status=adapted hash=8af11244b796]
    public static func RunEntryContent(
        ctx: any RenderContext,
        commit: StreamCommit,
        body: RunEntryBody? = nil,
        theme: RunTheme = RUN_THEME_FALLBACK,
        opts: ScrollbackOptions? = nil
    ) -> Renderable {
        let resolvedBody = body ?? entryBody(commit, options: opts)
        let look = entryLook(commit, theme: theme.entry)
        if commit.compaction {
            let box = BoxRenderable(ctx: ctx, options: BoxOptions(width: .percent(100), flexDirection: .row))
            box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("── \(commit.text) ──"), fg: .rgba(theme.block.muted))))
            return box
        }
        switch resolvedBody {
        case .none:
            return BoxRenderable(ctx: ctx, options: BoxOptions(height: .point(0)))
        case .text(let content):
            return TextRenderable(ctx: ctx, options: TextOptions(
                content: .string(content), width: .percent(100), fg: .rgba(look.fg), attributes: look.attrs, wrapMode: .word
            ))
        case .code(let content, _):
            return TextRenderable(ctx: ctx, options: TextOptions(
                content: .string(content), width: .percent(100), fg: .rgba(entryColor(commit, theme: theme)), wrapMode: .word
            ))
        case .markdown(let content):
            return TextRenderable(ctx: ctx, options: TextOptions(
                content: .string(content), width: .percent(100), fg: .rgba(theme.entry.assistant.body), wrapMode: .word
            ))
        case .structured(let snapshot):
            let flat = flattenMonoBody(.structured(snapshot: snapshot))
            let txt: String
            if case .text(let c) = flat { txt = c } else { txt = commit.text }
            return TextRenderable(ctx: ctx, options: TextOptions(
                content: .string(txt), width: .percent(100), fg: .rgba(theme.block.text), wrapMode: .word
            ))
        }
    }

    // parity: tui/src/mini/scrollback.writer.tsx#entryWriter [status=adapted hash=216ed3e58ba6]
    public static func entryWriter(
        commit: StreamCommit,
        body: RunEntryBody? = nil,
        theme: RunTheme = RUN_THEME_FALLBACK,
        opts: ScrollbackOptions? = nil
    ) -> ScrollbackWriter {
        { ctx in
            let flags = entryFlags(commit)
            let node = RunEntryContent(ctx: ctx.renderContext, commit: commit, body: body, theme: theme, opts: opts)
            return ScrollbackSnapshot(
                root: node,
                width: max(1, ctx.width),
                rowColumns: max(1, ctx.width),
                startOnNewLine: flags.startOnNewLine,
                trailingNewline: flags.trailingNewline
            )
        }
    }

    // parity: tui/src/mini/scrollback.writer.tsx#spacerWriter [status=adapted hash=c7ce271118f6]
    public static func spacerWriter() -> ScrollbackWriter {
        { ctx in
            let box = BoxRenderable(ctx: ctx.renderContext, options: BoxOptions(width: .point(Float(max(1, ctx.width))), height: .point(1)))
            return ScrollbackSnapshot(root: box, width: max(1, ctx.width), height: 1, rowColumns: max(1, ctx.width), startOnNewLine: true, trailingNewline: false)
        }
    }

    // parity: tui/src/mini/scrollback.writer.tsx#turnSummaryWriter [status=adapted hash=a20e94a6da3b]
    public static func turnSummaryWriter(
        summary: TurnSummary,
        theme: RunTheme = RUN_THEME_FALLBACK,
        mono: Bool = false
    ) -> ScrollbackWriter {
        { ctx in
            let sep = mono ? " - " : " · "
            let line = "\(summary.agent)\(sep)\(summary.model)\(sep)\(summary.duration)"
            let node = TextRenderable(ctx: ctx.renderContext, options: TextOptions(
                content: .string(line),
                width: .point(Float(max(1, ctx.width))),
                fg: .rgba(theme.entry.system.body)
            ))
            return ScrollbackSnapshot(root: node, width: max(1, ctx.width), height: 1, rowColumns: max(1, ctx.width), startOnNewLine: true, trailingNewline: false)
        }
    }

    // parity: tui/src/mini/scrollback.surface.ts#RunScrollbackStream [status=adapted hash=04a4f2df166c]
    public final class RunScrollbackStream: @unchecked Sendable {
        private let renderer: CliRenderer
        private var theme: RunTheme
        private var mono: Bool
        private var shellOutput: Bool
        private var wrote: Bool
        private var tail: StreamCommit?
        private var destroyed = false
        public private(set) var committed: [StreamCommit] = []

        public init(
            renderer: CliRenderer,
            theme: RunTheme = RUN_THEME_FALLBACK,
            mono: Bool = false,
            shellOutput: Bool = true,
            wrote: Bool = false
        ) {
            self.renderer = renderer
            self.theme = theme
            self.mono = mono
            self.shellOutput = shellOutput
            self.wrote = wrote
        }

        // parity: tui/src/mini/scrollback.surface.ts#RunScrollbackStream.setTheme [status=implemented hash=f81976a2e0ea]
        public func setTheme(_ theme: RunTheme) {
            self.theme = theme
        }

        // parity: tui/src/mini/scrollback.surface.ts#RunScrollbackStream.setMono [status=implemented hash=205122a1d6e2]
        public func setMono(_ mono: Bool) {
            self.mono = mono
        }

        // parity: tui/src/mini/scrollback.surface.ts#RunScrollbackStream.append [status=implemented hash=e41f26a7ddf9]
        public func append(_ commit: StreamCommit) {
            guard !destroyed else { return }
            let opts = ScrollbackOptions(shellOutput: shellOutput, mono: mono)
            if let summary = commit.summary {
                if separatorRows(prev: tail, next: commit) > 0 || (tail == nil && wrote) {
                    try? renderer.writeToScrollback(spacerWriter())
                }
                try? renderer.writeToScrollback(turnSummaryWriter(summary: summary, theme: theme, mono: mono))
                tail = commit
                wrote = true
                committed.append(commit)
                return
            }
            let body = entryBody(commit, options: opts)
            guard body != .none else { return }
            if separatorRows(prev: tail, next: commit, body: body) > 0 || (tail == nil && wrote) {
                try? renderer.writeToScrollback(spacerWriter())
            }
            try? renderer.writeToScrollback(entryWriter(commit: commit, body: body, theme: theme, opts: opts))
            tail = commit
            wrote = true
            committed.append(commit)
        }

        // parity: tui/src/mini/scrollback.surface.ts#RunScrollbackStream.complete [status=implemented hash=f15383b96887]
        public func complete(trailingNewline: Bool = false) async {
            guard !destroyed else { return }
            if trailingNewline && tail != nil {
                try? renderer.writeToScrollback(spacerWriter())
            }
            tail = nil
        }

        // parity: tui/src/mini/scrollback.surface.ts#RunScrollbackStream.writeTurnSummary [status=implemented hash=0ede79e98cc6]
        public func writeTurnSummary(agent: String, model: String, duration: String) async {
            append(TUIMini.turnSummaryCommit(agent: agent, model: model, duration: duration))
        }

        // parity: tui/src/mini/scrollback.surface.ts#RunScrollbackStream.destroy [status=implemented hash=1aa5a9343c60]
        public func destroy() {
            destroyed = true
            tail = nil
        }
    }

    // MARK: - Splash Banners (`packages/tui/src/mini/splash.ts`)

    // parity: tui/src/mini/splash.ts#SplashMeta [status=implemented hash=348ba7510e8c]
    public struct SplashMeta: Equatable, Hashable, Sendable, Codable {
        public let title: String
        public let sessionID: String

        public init(title: String, sessionID: String) {
            self.title = title
            self.sessionID = sessionID
        }
    }

    private static let splashTitleLimit = 50
    private static let splashTitleFallback = "Untitled session"

    private static func truncateUTF16(_ value: String, maxLength: Int) -> String {
        let u = Array(value.utf16)
        if u.count <= maxLength { return value }
        if maxLength <= 1 { return "…" }
        return String(decoding: u.prefix(maxLength - 1), as: UTF16.self) + "…"
    }

    private static func takeDisplayWidth(_ text: String, width: Int) -> String {
        guard width > 0 else { return "" }
        var out = ""
        var used = 0
        for ch in text {
            let s = String(ch)
            let w = stringWidth(s)
            if used + w > width { break }
            out.append(ch)
            used += w
        }
        return out
    }

    // parity: tui/src/mini/splash.ts#splashMeta [status=implemented hash=2f046b564d1c]
    public static func splashMeta(title rawTitle: String?, sessionID: String, mono: Bool = false) -> SplashMeta {
        guard let rawTitle else {
            return SplashMeta(title: splashTitleFallback, sessionID: sessionID)
        }
        let collapsed = rawTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
            .joined(separator: " ")
        let finalTitle: String
        if collapsed.isEmpty {
            finalTitle = splashTitleFallback
        } else if mono {
            finalTitle = monoTruncate(collapsed, width: splashTitleLimit, mono: true)
        } else {
            finalTitle = truncateUTF16(collapsed, maxLength: splashTitleLimit)
        }
        return SplashMeta(title: finalTitle, sessionID: sessionID)
    }

    public struct EntrySplashLayout: Equatable, Hashable, Sendable {
        public let label: String
        public let version: String
        public let path: String
        public let metadata: String
    }

    // parity: tui/src/mini/splash.ts#entrySplashLayout [status=implemented hash=3ece6aa56ecf]
    public static func entrySplashLayout(
        width: Int,
        version: String,
        detail: String? = nil,
        mono: Bool = false
    ) -> EntrySplashLayout {
        let detailStr = detail ?? ""
        let segments = detailStr.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        let leaf = segments.last ?? detailStr
        let separator = mono ? " - " : " · "
        let ellipsis = mono ? "..." : "…"
        let slash = detailStr.contains("\\") ? "\\" : "/"
        var paths: [String] = []
        if segments.count > 1 {
            for idx in stride(from: segments.count - 1, through: 1, by: -1) {
                let candidate = ellipsis + slash + segments[idx...].joined(separator: slash)
                if stringWidth(candidate) < stringWidth(detailStr) {
                    paths.append(candidate)
                }
            }
        }
        if !detailStr.isEmpty { paths.append(detailStr) }

        var label = takeDisplayWidth("oc mini", width: width)
        var ver = ""
        var pathVal = ""
        var metadata = ""

        struct Stage { let label: String?; let version: String?; let path: String? }
        var stages: [Stage] = [Stage(label: "\(mono ? "[O]" : "▪") oc mini", version: nil, path: nil)]
        if !leaf.isEmpty { stages.append(Stage(label: nil, version: nil, path: leaf)) }
        if !version.isEmpty { stages.append(Stage(label: nil, version: version, path: nil)) }
        for p in paths { stages.append(Stage(label: nil, version: nil, path: p)) }

        for stage in stages {
            let nextLabel = stage.label ?? label
            let nextVer = stage.version ?? ver
            let nextPath = stage.path ?? pathVal
            let nextMeta = (nextVer.isEmpty ? "" : " v\(nextVer)") + (nextPath.isEmpty ? "" : separator + nextPath)
            if stringWidth(nextLabel + nextMeta) > width { break }
            label = nextLabel
            ver = nextVer
            pathVal = nextPath
            metadata = nextMeta
        }
        return EntrySplashLayout(label: label, version: ver, path: pathVal, metadata: metadata)
    }

    // parity: tui/src/mini/splash.ts#entrySplash [status=implemented hash=0b30d0c8928a]
    public static func entrySplash(
        version: String,
        detail: String? = nil,
        mono: Bool = false,
        theme: RunSplashTheme = RUN_THEME_FALLBACK.splash
    ) -> ScrollbackWriter {
        { ctx in
            let width = max(1, ctx.width)
            let layout = entrySplashLayout(width: width, version: version, detail: detail, mono: mono)
            let root = BoxRenderable(ctx: ctx.renderContext, options: BoxOptions(
                width: .point(Float(width)),
                height: .point(2),
                flexDirection: .row,
                paddingTop: .point(1),
                overflow: .hidden
            ))
            let styled = StyledText(chunks: [
                TextChunk(text: layout.label, fg: theme.right),
                TextChunk(text: layout.metadata, fg: theme.left),
            ])
            root.add(TextRenderable(ctx: ctx.renderContext, options: TextOptions(
                content: .styled(styled),
                width: .point(Float(width)),
                height: .point(1),
                wrapMode: TextWrapMode.none
            )))
            return ScrollbackSnapshot(root: root, width: width, height: 2, rowColumns: width, startOnNewLine: true, trailingNewline: false)
        }
    }

    // parity: tui/src/mini/splash.ts#exitSplash [status=implemented hash=a8e70f11e481]
    public static func exitSplash(
        title: String?,
        sessionID: String,
        mono: Bool = false,
        showSession: Bool = true,
        theme: RunSplashTheme = RUN_THEME_FALLBACK.splash
    ) -> ScrollbackWriter {
        { ctx in
            let width = max(1, ctx.width)
            let meta = splashMeta(title: title, sessionID: sessionID, mono: mono)
            let mark = mono ? ["[O]"] : Array(TUILogo.go.right.dropFirst())
            let bodyLeft = (mark.first?.count ?? 0) + 2
            let command = "opencode mini -s \(meta.sessionID)"
            let label = "Continue "
            let wide = bodyLeft + stringWidth(label + command) <= width
            let height = 1 + (wide ? max(mark.count, 2) : max(1, (stringWidth(command) + width - 1) / width))
            let root = BoxRenderable(ctx: ctx.renderContext, options: BoxOptions(
                width: .point(Float(width)),
                height: .point(Float(height)),
                flexDirection: .column,
                paddingTop: .point(1)
            ))
            if wide && showSession {
                root.add(TextRenderable(ctx: ctx.renderContext, options: TextOptions(
                    content: .string("Session  \(meta.title)"),
                    fg: .rgba(theme.right),
                    attributes: createTextAttributes(bold: true)
                )))
            }
            root.add(TextRenderable(ctx: ctx.renderContext, options: TextOptions(
                content: .string(wide ? "\(label)\(command)" : command),
                fg: .rgba(theme.right),
                attributes: createTextAttributes(bold: true)
            )))
            return ScrollbackSnapshot(root: root, width: width, height: height, rowColumns: width, startOnNewLine: true, trailingNewline: false)
        }
    }

    // MARK: - Turn Summary & Session Data (`turn-summary.ts`, `session-data.ts`, `stream.ts`)

    // parity: tui/src/mini/turn-summary.ts#turnSummaryCommit [status=implemented hash=a39c58462de3]
    public static func turnSummaryCommit(
        agent: String,
        model: String,
        duration: String,
        messageID: String? = nil
    ) -> StreamCommit {
        StreamCommit(
            kind: .system,
            text: "\(agent) · \(model) · \(duration)",
            phase: .final,
            source: .system,
            summary: TurnSummary(agent: agent, model: model, duration: duration),
            messageID: messageID
        )
    }

    // parity: tui/src/mini/session-data.ts#pickBlockerView [status=implemented hash=6267e1889694]
    public static func pickBlockerView(
        permission: MiniPermissionRequest? = nil,
        form: MiniFormRequest? = nil
    ) -> FooterView {
        if let permission { return .permission(request: permission) }
        if let form { return .form(request: form) }
        return .prompt
    }

    // parity: tui/src/mini/session-data.ts#blockerStatus [status=implemented hash=9f9219ba4ee2]
    public static func blockerStatus(_ view: FooterView) -> String {
        switch view {
        case .permission: return "awaiting permission"
        case .form: return "awaiting form"
        case .prompt: return ""
        }
    }

    public struct StreamOutput: Equatable, Sendable {
        public let commits: [StreamCommit]
        public let updates: [FooterEvent]

        public init(commits: [StreamCommit] = [], updates: [FooterEvent] = []) {
            self.commits = commits
            self.updates = updates
        }
    }

    // parity: tui/src/mini/stream.ts#writeSessionOutput [status=implemented hash=71625229e689]
    public static func writeSessionOutput(
        footer: any FooterApi,
        output: StreamOutput,
        trace: (@Sendable (String, JSONValue?) -> Void)? = nil
    ) {
        for commit in output.commits {
            trace?("ui.commit", .string(commit.text))
            footer.append(commit)
        }
        for update in output.updates {
            if case .streamPatch(var p) = update {
                if p.status != nil && p.phase == nil {
                    p.phase = .running
                }
                trace?("ui.patch", nil)
                footer.event(.streamPatch(p))
            } else {
                trace?("ui.patch", nil)
                footer.event(update)
            }
        }
    }

    // MARK: - Prompt Shared & Editor (`prompt.shared.ts`, `prompt.editor.ts`)

    private static let historyLimit = 200

    // parity: tui/src/mini/prompt.shared.ts#PromptHistoryState [status=implemented hash=815660c1e1a9]
    public struct PromptHistoryState: Equatable, Hashable, Sendable, Codable {
        public var items: [RunPrompt]
        public var index: Int?
        public var draft: String

        public init(items: [RunPrompt] = [], index: Int? = nil, draft: String = "") {
            self.items = items
            self.index = index
            self.draft = draft
        }
    }

    // parity: tui/src/mini/prompt.shared.ts#PromptMove [status=implemented hash=9e3258b5ca8e]
    public struct PromptMove: Equatable, Hashable, Sendable {
        public let state: PromptHistoryState
        public let text: String?
        public let cursor: Int?
        public let apply: Bool

        public init(state: PromptHistoryState, text: String? = nil, cursor: Int? = nil, apply: Bool) {
            self.state = state
            self.text = text
            self.cursor = cursor
            self.apply = apply
        }
    }

    // parity: tui/src/mini/prompt.shared.ts#promptCopy [status=implemented hash=3cde82cd13f4]
    public static func promptCopy(_ prompt: RunPrompt) -> RunPrompt {
        RunPrompt(text: prompt.text, parts: prompt.parts, mode: prompt.mode, command: prompt.command)
    }

    // parity: tui/src/mini/prompt.shared.ts#promptAppend [status=implemented hash=4f7db28dafe3]
    public static func promptAppend(
        _ prompt: RunPrompt,
        following: RunPrompt,
        widthMethod: WidthMethod = .unicode
    ) -> RunPrompt {
        let prefix = prompt.text.isEmpty ? "" : "\(prompt.text)\n\n"
            let method: TextWidthMethod = widthMethod == .wcwidth ? .wcwidth : .unicode
            let offset = measureEditText(prefix, widthMethod: method)
        let shiftedParts: [RunPromptPart] = following.parts.map { part in
            switch part {
            case .file(let url, let filename, let mime, let desc, let source):
                let nextSource = source.map {
                    FilePartSource(type: $0.type, path: $0.path, text: SourceSpan(start: $0.text.start + offset, end: $0.text.end + offset, value: $0.text.value))
                }
                return .file(url: url, filename: filename, mime: mime, description: desc, source: nextSource)
            case .agent(let name, let source):
                return .agent(name: name, source: source.map { SourceSpan(start: $0.start + offset, end: $0.end + offset, value: $0.value) })
            case .skill(let id, let source):
                return .skill(id: id, source: source.map { SourceSpan(start: $0.start + offset, end: $0.end + offset, value: $0.value) })
            }
        }
        return RunPrompt(
            text: prefix + following.text,
            parts: prompt.parts + shiftedParts,
            command: prompt.text.isEmpty ? following.command : prompt.command
        )
    }

    // parity: tui/src/mini/prompt.shared.ts#promptSame [status=implemented hash=e9b3cc3be7b8]
    public static func promptSame(_ a: RunPrompt, _ b: RunPrompt) -> Bool {
        a.mode == b.mode && a.text == b.text && a.parts == b.parts && a.command == b.command
    }

    // parity: tui/src/mini/prompt.shared.ts#EXIT_COMMANDS [status=implemented hash=c852b671bb20]
    public static let EXIT_COMMANDS = ["exit", "quit", "q"]

    // parity: tui/src/mini/prompt.shared.ts#isExitCommand [status=implemented hash=d375c2635633]
    public static func isExitCommand(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text == ":q" || EXIT_COMMANDS.contains { text == "/\($0)" }
    }

    // parity: tui/src/mini/prompt.shared.ts#isNewCommand [status=implemented hash=a09b4e1c41ad]
    public static func isNewCommand(_ input: String) -> Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/new"
    }

    // parity: tui/src/mini/prompt.shared.ts#isCompactCommand [status=implemented hash=f3b2f46c5a1f]
    public static func isCompactCommand(_ input: String) -> Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/compact"
    }

    // parity: tui/src/mini/prompt.shared.ts#createPromptHistory [status=implemented hash=6620ebd6d854]
    public static func createPromptHistory(_ items: [RunPrompt] = []) -> PromptHistoryState {
        let filtered = items
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.parts.contains(where: \.isFile) }
            .map(promptCopy)
        var deduped: [RunPrompt] = []
        for item in filtered {
            if let last = deduped.last, promptSame(last, item) { continue }
            deduped.append(item)
        }
        return PromptHistoryState(items: Array(deduped.suffix(historyLimit)), index: nil, draft: "")
    }

    // parity: tui/src/mini/prompt.shared.ts#pushPromptHistory [status=implemented hash=6cd8156affbe]
    public static func pushPromptHistory(_ state: PromptHistoryState, _ prompt: RunPrompt) -> PromptHistoryState {
        guard !prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.parts.contains(where: \.isFile) else {
            return state
        }
        let next = promptCopy(prompt)
        if let last = state.items.last, promptSame(last, next) {
            return PromptHistoryState(items: state.items, index: nil, draft: "")
        }
        return PromptHistoryState(items: Array((state.items + [next]).suffix(historyLimit)), index: nil, draft: "")
    }

    // parity: tui/src/mini/prompt.shared.ts#movePromptHistory [status=implemented hash=38ce04e397fe]
    public static func movePromptHistory(
        _ state: PromptHistoryState,
        dir: Int,
        text: String,
        cursor: Int,
        widthMethod: WidthMethod = .unicode
    ) -> PromptMove {
        guard !state.items.isEmpty else { return PromptMove(state: state, apply: false) }
        let method: TextWidthMethod = widthMethod == .wcwidth ? .wcwidth : .unicode
        let d = dir >= 0 ? 1 : -1
        if d == -1 && cursor != 0 { return PromptMove(state: state, apply: false) }
        if d == 1 && cursor != measureEditText(text, widthMethod: method) { return PromptMove(state: state, apply: false) }

        guard let currentIndex = state.index else {
            if d == 1 { return PromptMove(state: state, apply: false) }
            let idx = state.items.count - 1
            let nextState = PromptHistoryState(items: state.items, index: idx, draft: text)
            return PromptMove(state: nextState, text: state.items[idx].text, cursor: 0, apply: true)
        }

        let idx = currentIndex + d
        if idx < 0 { return PromptMove(state: state, apply: false) }
        if idx >= state.items.count {
            let nextState = PromptHistoryState(items: state.items, index: nil, draft: state.draft)
            return PromptMove(
                state: nextState,
                text: state.draft,
                cursor: measureEditText(state.draft, widthMethod: method),
                apply: true
            )
        }
        let nextState = PromptHistoryState(items: state.items, index: idx, draft: state.draft)
        let nextText = state.items[idx].text
        return PromptMove(
            state: nextState,
            text: nextText,
            cursor: d == -1 ? 0 : measureEditText(nextText, widthMethod: method),
            apply: true
        )
    }

    // parity: tui/src/mini/prompt.editor.ts#resolveEditorSlashValue [status=implemented hash=c52d0cc65adc]
    public static func resolveEditorSlashValue(_ text: String) -> String {
        guard let head = TUIPrompt.parseSlashHead(text), head.name.lowercased() == "editor" else {
            return text
        }
        return head.arguments
    }

    // parity: tui/src/mini/prompt.editor.ts#realignEditorPromptParts [status=implemented hash=3768d53717b3]
    public static func realignEditorPromptParts(
        _ content: String,
        parts: [RunPromptPart],
        widthMethod: WidthMethod = .unicode
    ) -> [RunPromptPart] {
        let mentions: [PromptSchema.PromptMention?] = parts.map { part in
            switch part {
            case .file(_, _, _, _, let source):
                return source.map { PromptSchema.PromptMention(start: $0.text.start, end: $0.text.end, text: $0.text.value) }
            case .agent(_, let source), .skill(_, let source):
                return source.map { PromptSchema.PromptMention(start: $0.start, end: $0.end, text: $0.value) }
            }
        }
        let matches = TUIPrompt.realignPromptMentions(content, mentions: mentions, widthMethod: widthMethod)
        return parts.enumerated().compactMap { index, part in
            guard let m = mentions[index], !m.text.isEmpty else { return part }
            guard let match = matches[index] else { return nil }
            switch part {
            case .file(let url, let filename, let mime, let desc, let source):
                let nextSource = source.map {
                    FilePartSource(type: $0.type, path: $0.path, text: SourceSpan(start: match.start, end: match.end, value: match.text))
                }
                return .file(url: url, filename: filename, mime: mime, description: desc, source: nextSource)
            case .agent(let name, _):
                return .agent(name: name, source: SourceSpan(start: match.start, end: match.end, value: match.text))
            case .skill(let id, _):
                return .skill(id: id, source: SourceSpan(start: match.start, end: match.end, value: match.text))
            }
        }
    }

    // MARK: - Permission State Machine (`packages/tui/src/mini/permission.shared.ts`)

    // parity: tui/src/mini/permission.shared.ts#PermissionStage [status=implemented hash=842af4180801]
    public enum PermissionStage: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case permission, always, reject
    }

    // parity: tui/src/mini/permission.shared.ts#PermissionOption [status=implemented hash=a8e8dc1d84ff]
    public enum PermissionOption: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case once, always, reject, confirm, cancel
    }

    // parity: tui/src/mini/permission.shared.ts#PermissionBodyState [status=implemented hash=d590fd0d6642]
    public struct PermissionBodyState: Equatable, Hashable, Sendable, Codable {
        public var requestID: String
        public var sessionID: String
        public var stage: PermissionStage
        public var selected: PermissionOption
        public var message: String
        public var submitting: Bool

        public init(
            requestID: String,
            sessionID: String,
            stage: PermissionStage = .permission,
            selected: PermissionOption = .once,
            message: String = "",
            submitting: Bool = false
        ) {
            self.requestID = requestID
            self.sessionID = sessionID
            self.stage = stage
            self.selected = selected
            self.message = message
            self.submitting = submitting
        }
    }

    // parity: tui/src/mini/permission.shared.ts#PermissionStep [status=implemented hash=072783cb09a2]
    public struct PermissionStep: Equatable, Hashable, Sendable {
        public let state: PermissionBodyState
        public let reply: PermissionReply?

        public init(state: PermissionBodyState, reply: PermissionReply? = nil) {
            self.state = state
            self.reply = reply
        }
    }

    // parity: tui/src/mini/permission.shared.ts#createPermissionBodyState [status=implemented hash=25d4cc356c93]
    public static func createPermissionBodyState(_ request: MiniPermissionRequest) -> PermissionBodyState {
        PermissionBodyState(requestID: request.id, sessionID: request.sessionID)
    }

    // parity: tui/src/mini/permission.shared.ts#permissionOptions [status=implemented hash=2bf804df0129]
    public static func permissionOptions(_ stage: PermissionStage) -> [PermissionOption] {
        switch stage {
        case .permission: return [.once, .always, .reject]
        case .always: return [.confirm, .cancel]
        case .reject: return []
        }
    }

    public struct PermissionDisplayInfo: Equatable, Hashable, Sendable {
        public let icon: String
        public let title: String
        public let lines: [String]
        public let diff: String?
        public let patch: String?
    }

    // parity: tui/src/mini/permission.shared.ts#permissionInfo [status=implemented hash=465eff6c095a]
    public static func permissionInfo(
        _ request: MiniPermissionRequest,
        directory: String? = nil,
        mono: Bool = false
    ) -> PermissionDisplayInfo {
        let icon = request.action == "shell" ? "$" : request.action == "edit" ? "←" : "⚙"
        let formattedResources = request.resources.map { toolPath($0, home: true, directory: directory) }
        let title = formattedResources.first ?? request.action
        let lines = mono ? formattedResources.map { monoPrefix($0, mono: true) } : formattedResources
        return PermissionDisplayInfo(
            icon: mono ? monoPrefix(icon, mono: true) : icon,
            title: title,
            lines: lines,
            diff: nil,
            patch: nil
        )
    }

    // parity: tui/src/mini/permission.shared.ts#permissionLabel [status=implemented hash=b059bb82d729]
    public static func permissionLabel(_ option: PermissionOption) -> String {
        switch option {
        case .once: return "Allow once"
        case .always: return "Allow always"
        case .reject: return "Reject"
        case .confirm: return "Confirm"
        case .cancel: return "Cancel"
        }
    }

    // parity: tui/src/mini/permission.shared.ts#permissionAlwaysLines [status=implemented hash=1c1edbe424e6]
    public static func permissionAlwaysLines(action: String, save: [String] = []) -> [String] {
        TUIUtil.permissionAlwaysLines(action: action, save: save)
    }

    // parity: tui/src/mini/permission.shared.ts#permissionShift [status=implemented hash=689223891586]
    public static func permissionShift(
        _ state: PermissionBodyState,
        dir: Int,
        list: [PermissionOption]? = nil
    ) -> PermissionBodyState {
        let opts = list ?? permissionOptions(state.stage)
        guard !opts.isEmpty else { return state }
        let idx = opts.firstIndex(of: state.selected) ?? 0
        let d = dir >= 0 ? 1 : -1
        var next = state
        next.selected = opts[(idx + d + opts.count) % opts.count]
        return next
    }

    // parity: tui/src/mini/permission.shared.ts#permissionHover [status=implemented hash=dc01dd2870e0]
    public static func permissionHover(_ state: PermissionBodyState, option: PermissionOption) -> PermissionBodyState {
        var next = state
        next.selected = option
        return next
    }

    // parity: tui/src/mini/permission.shared.ts#permissionRun [status=implemented hash=27b208f74e04]
    public static func permissionRun(
        _ state: PermissionBodyState,
        requestID: String,
        option: PermissionOption
    ) -> PermissionStep {
        if state.submitting { return PermissionStep(state: state) }
        if state.stage == .permission {
            if option == .always {
                var next = state; next.stage = .always; next.selected = .confirm
                return PermissionStep(state: next)
            }
            if option == .reject {
                var next = state; next.stage = .reject; next.selected = .reject
                return PermissionStep(state: next)
            }
            return PermissionStep(
                state: state,
                reply: PermissionReply(sessionID: state.sessionID, requestID: requestID, decision: .once)
            )
        }
        guard state.stage == .always else { return PermissionStep(state: state) }
        if option == .cancel {
            var next = state; next.stage = .permission; next.selected = .always
            return PermissionStep(state: next)
        }
        return PermissionStep(
            state: state,
            reply: PermissionReply(sessionID: state.sessionID, requestID: requestID, decision: .always)
        )
    }

    // parity: tui/src/mini/permission.shared.ts#permissionReject [status=implemented hash=5c707576d5d4]
    public static func permissionReject(_ state: PermissionBodyState, requestID: String) -> PermissionReply? {
        guard !state.submitting else { return nil }
        let msg = state.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return PermissionReply(sessionID: state.sessionID, requestID: requestID, decision: .reject, message: msg.isEmpty ? nil : msg)
    }

    // parity: tui/src/mini/permission.shared.ts#permissionCancel [status=implemented hash=590352fbb3f7]
    public static func permissionCancel(_ state: PermissionBodyState) -> PermissionBodyState {
        var next = state; next.stage = .permission; next.selected = .reject; return next
    }

    // parity: tui/src/mini/permission.shared.ts#permissionEscape [status=implemented hash=1216d681f346]
    public static func permissionEscape(_ state: PermissionBodyState) -> PermissionBodyState {
        var next = state
        if state.stage == .always {
            next.stage = .permission
            next.selected = .always
        } else {
            next.stage = .reject
            next.selected = .reject
        }
        return next
    }

    // MARK: - Form State Machine (`packages/tui/src/mini/form.shared.ts`)

    // parity: tui/src/mini/form.shared.ts#formCustom [status=implemented hash=0560719d06b5]
    public static func formCustom(_ field: TUIUtil.FormField?) -> Bool {
        TUIUtil.formCustom(field)
    }

    // parity: tui/src/mini/form.shared.ts#formLabel [status=implemented hash=0560719d06b5]
    public static func formLabel(_ field: TUIUtil.FormField) -> String {
        TUIUtil.formLabel(field)
    }

    // parity: tui/src/mini/form.shared.ts#formRows [status=implemented hash=0560719d06b5]
    public static func formRows(_ field: TUIUtil.FormField?) -> [TUIUtil.FormRow] {
        TUIUtil.formRows(field)
    }

    // parity: tui/src/mini/form.shared.ts#formTextual [status=implemented hash=0560719d06b5]
    public static func formTextual(_ field: TUIUtil.FormField?) -> Bool {
        TUIUtil.formTextual(field)
    }

    // parity: tui/src/mini/form.shared.ts#formValidateValue [status=implemented hash=0560719d06b5]
    public static func formValidateValue(_ field: TUIUtil.FormAnswerField, value: TUIUtil.FormValue?) -> String? {
        TUIUtil.formValidateValue(field, value: value)
    }

    // parity: tui/src/mini/form.shared.ts#FormBodyState [status=implemented hash=18c3a52a6bb6]
    public struct FormBodyState: Equatable, Hashable, Sendable, Codable {
        public var formID: String
        public var field: Int
        public var answers: [String: FormSchema.Value]
        public var custom: [String: String]
        public var selected: Int
        public var editing: Bool
        public var externalReady: [String: Bool]
        public var submitting: Bool
        public var error: String

        public init(
            formID: String,
            field: Int = 0,
            answers: [String: FormSchema.Value] = [:],
            custom: [String: String] = [:],
            selected: Int = 0,
            editing: Bool = false,
            externalReady: [String: Bool] = [:],
            submitting: Bool = false,
            error: String = ""
        ) {
            self.formID = formID
            self.field = field
            self.answers = answers
            self.custom = custom
            self.selected = selected
            self.editing = editing
            self.externalReady = externalReady
            self.submitting = submitting
            self.error = error
        }
    }

    private static func fieldKey(_ field: FormSchema.Field) -> String {
        switch field {
        case .string(let f): return f.key
        case .number(let f): return f.key
        case .integer(let f): return f.key
        case .boolean(let f): return f.key
        case .multiselect(let f): return f.key
        case .external(let f): return f.key
        }
    }

    private static func fieldLabel(_ field: FormSchema.Field) -> String {
        switch field {
        case .string(let f): return f.title ?? f.key
        case .number(let f): return f.title ?? f.key
        case .integer(let f): return f.title ?? f.key
        case .boolean(let f): return f.title ?? f.key
        case .multiselect(let f): return f.title ?? f.key
        case .external(let f): return f.title ?? f.key
        }
    }

    private static func isFieldTextual(_ field: FormSchema.Field?) -> Bool {
        guard let field else { return false }
        switch field {
        case .string(let f): return f.options == nil
        case .number, .integer: return true
        default: return false
        }
    }

    private static func fieldAllowsCustom(_ field: FormSchema.Field?) -> Bool {
        guard let field else { return false }
        switch field {
        case .string(let f): return f.options != nil && f.custom == true
        case .multiselect(let f): return f.custom == true
        default: return false
        }
    }

    private static func fieldChoiceValues(_ field: FormSchema.Field?) -> [FormSchema.Value] {
        guard let field else { return [] }
        switch field {
        case .boolean: return [.bool(true), .bool(false)]
        case .string(let f): return (f.options ?? []).map { .string($0.value) }
        case .multiselect(let f): return f.options.map { .string($0.value) }
        default: return []
        }
    }

    private static func initialSelectedIndex(_ field: FormSchema.Field?, answer: FormSchema.Value?) -> Int {
        guard let answer else { return 0 }
        let choices = fieldChoiceValues(field)
        return choices.firstIndex(of: answer) ?? 0
    }

    // parity: tui/src/mini/form.shared.ts#createFormBodyState [status=implemented hash=d827356baeb1]
    public static func createFormBodyState(_ form: FormSchema.Info) -> FormBodyState {
        var answers: [String: FormSchema.Value] = [:]
        for field in form.fields.elements {
            switch field {
            case .string(let f): if let d = f.defaultValue { answers[f.key] = .string(d) }
            case .number(let f): if let d = f.defaultValue { answers[f.key] = .number(d) }
            case .integer(let f): if let d = f.defaultValue { answers[f.key] = .number(Double(d)) }
            case .boolean(let f): if let d = f.defaultValue { answers[f.key] = .bool(d) }
            case .multiselect(let f): if let d = f.defaultValue { answers[f.key] = .strings(d) }
            case .external: break
            }
        }
        let first = form.fields.elements.first
        let sel = initialSelectedIndex(first, answer: first.flatMap { answers[fieldKey($0)] })
        return FormBodyState(
            formID: form.id.rawValue,
            field: 0,
            answers: answers,
            selected: sel,
            editing: isFieldTextual(first)
        )
    }

    // parity: tui/src/mini/form.shared.ts#formSync [status=implemented hash=18c70dc13562]
    public static func formSync(_ state: FormBodyState, form: FormSchema.Info) -> FormBodyState {
        state.formID == form.id.rawValue ? state : createFormBodyState(form)
    }

    // parity: tui/src/mini/form.shared.ts#formUnsupported [status=implemented hash=38279ec6d9ad]
    public static func formUnsupported(_ form: FormSchema.Info) -> String? {
        if form.fields.elements.isEmpty { return "This form has no supported fields." }
        for field in form.fields.elements {
            switch field {
            case .string(let f):
                if let when = f.when, !when.isEmpty { return "Conditional forms are not supported in Mini yet." }
                if f.pattern != nil { return "Pattern-constrained forms are not supported in Mini yet." }
            case .number(let f):
                if let when = f.when, !when.isEmpty { return "Conditional forms are not supported in Mini yet." }
            case .integer(let f):
                if let when = f.when, !when.isEmpty { return "Conditional forms are not supported in Mini yet." }
            case .boolean(let f):
                if let when = f.when, !when.isEmpty { return "Conditional forms are not supported in Mini yet." }
            case .multiselect(let f):
                if let when = f.when, !when.isEmpty { return "Conditional forms are not supported in Mini yet." }
            case .external:
                break
            }
        }
        return nil
    }

    // parity: tui/src/mini/form.shared.ts#formCurrent [status=implemented hash=61d6e1266108]
    public static func formCurrent(_ form: FormSchema.Info, state: FormBodyState) -> FormSchema.Field? {
        guard state.field >= 0 && state.field < form.fields.elements.count else { return nil }
        return form.fields.elements[state.field]
    }

    // parity: tui/src/mini/form.shared.ts#formConfirm [status=implemented hash=c3fd51e91181]
    public static func formConfirm(_ form: FormSchema.Info, state: FormBodyState) -> Bool {
        state.field >= form.fields.elements.count
    }

    // parity: tui/src/mini/form.shared.ts#formSingle [status=implemented hash=92dcb57faddf]
    public static func formSingle(_ form: FormSchema.Info) -> Bool {
        guard form.fields.elements.count == 1, let first = form.fields.elements.first else { return false }
        switch first {
        case .boolean, .number, .integer, .external, .string: return true
        case .multiselect: return false
        }
    }

    // parity: tui/src/mini/form.shared.ts#formPlaceholder [status=implemented hash=b7b10398ffd2]
    public static func formPlaceholder(_ field: FormSchema.Field?) -> String {
        if case .string(let f) = field { return f.placeholder ?? "Type your answer" }
        return "Enter a number"
    }

    // parity: tui/src/mini/form.shared.ts#formMove [status=implemented hash=1539d78d2b28]
    public static func formMove(_ state: FormBodyState, form: FormSchema.Info, direction: Int) -> FormBodyState {
        let field = formCurrent(form, state: state)
        let total = fieldChoiceValues(field).count + (fieldAllowsCustom(field) ? 1 : 0)
        guard total > 0 else { return state }
        let d = direction >= 0 ? 1 : -1
        var next = state
        next.selected = (state.selected + d + total) % total
        next.error = ""
        return next
    }

    // parity: tui/src/mini/form.shared.ts#formSetSelected [status=implemented hash=3962049d13d8]
    public static func formSetSelected(_ state: FormBodyState, selected: Int) -> FormBodyState {
        var next = state; next.selected = selected; next.error = ""; return next
    }

    // parity: tui/src/mini/form.shared.ts#formSetSubmitting [status=implemented hash=e26869fe9ffe]
    public static func formSetSubmitting(_ state: FormBodyState, submitting: Bool, error: String = "") -> FormBodyState {
        var next = state; next.submitting = submitting; next.error = error; return next
    }

    // parity: tui/src/mini/form.shared.ts#formSetError [status=implemented hash=48d9bb2d04ea]
    public static func formSetError(_ state: FormBodyState, error: String) -> FormBodyState {
        var next = state; next.error = error; next.submitting = false; return next
    }

    // parity: tui/src/mini/form.shared.ts#formSetExternalReady [status=implemented hash=2bc41789defe]
    public static func formSetExternalReady(_ state: FormBodyState, key: String) -> FormBodyState {
        var next = state; next.externalReady[key] = true; next.error = ""; return next
    }

    // parity: tui/src/mini/form.shared.ts#formDisplay [status=implemented hash=f2418cb2aac1]
    public static func formDisplay(_ field: FormSchema.Field, value: FormSchema.Value?) -> String {
        guard let value else { return "" }
        switch value {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "Yes" : "No"
        case .strings(let arr): return arr.joined(separator: ", ")
        }
    }

    // parity: tui/src/mini/form.shared.ts#formInput [status=implemented hash=907638b660aa]
    public static func formInput(_ state: FormBodyState, field: FormSchema.Field?) -> String {
        guard let field else { return "" }
        if case .external = field { return "" }
        let key = fieldKey(field)
        return state.custom[key] ?? formDisplay(field, value: state.answers[key])
    }

    // parity: tui/src/mini/form.shared.ts#formSetDraft [status=implemented hash=2642c5a44416]
    public static func formSetDraft(_ state: FormBodyState, field: FormSchema.Field?, value: String) -> FormBodyState {
        guard let field else { return state }
        if case .external = field { return state }
        var next = state
        next.custom[fieldKey(field)] = value
        return next
    }

    private static func validateFieldValue(_ field: FormSchema.Field, _ value: FormSchema.Value?) -> String? {
        switch field {
        case .string(let f):
            guard case .string(let s) = value else {
                return f.required == false ? nil : "Required"
            }
            if let minLen = f.minLength, s.count < minLen.rawValue { return "Must be at least \(minLen.rawValue) characters" }
            if let maxLen = f.maxLength, s.count > maxLen.rawValue { return "Must be at most \(maxLen.rawValue) characters" }
            return nil
        case .number(let f):
            guard case .number(let n) = value, n.isFinite else {
                return f.required == false ? nil : "Enter a valid number"
            }
            if let minV = f.minimum, n < minV { return "Must be at least \(minV)" }
            if let maxV = f.maximum, n > maxV { return "Must be at most \(maxV)" }
            return nil
        case .integer(let f):
            guard case .number(let n) = value, n.isFinite, n.rounded() == n else {
                return f.required == false ? nil : "Enter a valid integer"
            }
            if let minV = f.minimum, n < minV { return "Must be at least \(minV)" }
            if let maxV = f.maximum, n > maxV { return "Must be at most \(maxV)" }
            return nil
        case .boolean(let f):
            if case .bool = value { return nil }
            return f.required == false ? nil : "Required"
        case .multiselect(let f):
            guard case .strings(let arr) = value else {
                return f.required == false ? nil : "Select at least one option"
            }
            if let minItems = f.minItems, arr.count < minItems.rawValue { return "Select at least \(minItems.rawValue)" }
            if let maxItems = f.maxItems, arr.count > maxItems.rawValue { return "Select at most \(maxItems.rawValue)" }
            return nil
        case .external:
            return value == .bool(true) ? nil : "Required"
        }
    }

    // parity: tui/src/mini/form.shared.ts#formValidate [status=implemented hash=4d73f293e5a7]
    public static func formValidate(_ form: FormSchema.Info, state: FormBodyState) -> String? {
        if let unsupported = formUnsupported(form) { return unsupported }
        for field in form.fields.elements {
            let key = fieldKey(field)
            if case .external = field {
                if state.answers[key] != .bool(true) { return "Acknowledge \(fieldLabel(field))" }
                continue
            }
            if let invalid = validateFieldValue(field, state.answers[key]) {
                return "\(fieldLabel(field)): \(invalid)"
            }
        }
        return nil
    }

    // parity: tui/src/mini/form.shared.ts#formAnswer [status=implemented hash=5f35af22ce83]
    public static func formAnswer(_ form: FormSchema.Info, state: FormBodyState) -> [String: FormSchema.Value]? {
        if formValidate(form, state: state) != nil { return nil }
        var out: [String: FormSchema.Value] = [:]
        for field in form.fields.elements {
            let key = fieldKey(field)
            if let val = state.answers[key] { out[key] = val }
        }
        return out
    }

    // parity: tui/src/mini/form.shared.ts#formReply [status=implemented hash=5e9207214f8d]
    public static func formReply(_ form: MiniFormRequest, state: FormBodyState) -> FormReply? {
        guard let answer = formAnswer(form.form, state: state) else { return nil }
        return FormReply(sessionID: form.sessionID, formID: form.id, answer: answer, location: form.location)
    }

    // parity: tui/src/mini/form.shared.ts#formSetField [status=implemented hash=08cefc18990e]
    public static func formSetField(_ state: FormBodyState, form: FormSchema.Info, index: Int) -> FormBodyState {
        let bounded = max(0, min(form.fields.elements.count, index))
        let field: FormSchema.Field? = bounded < form.fields.elements.count ? form.fields.elements[bounded] : nil
        var next = state
        next.field = bounded
        next.selected = initialSelectedIndex(field, answer: field.flatMap { state.answers[fieldKey($0)] })
        next.editing = isFieldTextual(field)
        next.error = ""
        return next
    }

    // parity: tui/src/mini/form.shared.ts#formPick [status=implemented hash=388b780e6760]
    public static func formPick(_ state: FormBodyState, form: FormSchema.Info) -> FormBodyState {
        guard let field = formCurrent(form, state: state) else { return state }
        if case .external = field { return state }
        if isFieldTextual(field) { return state }
        let choices = fieldChoiceValues(field)
        if state.selected == choices.count && fieldAllowsCustom(field) {
            var next = state; next.editing = true; next.error = ""; return next
        }
        guard state.selected >= 0 && state.selected < choices.count else { return state }
        let picked = choices[state.selected]
        let key = fieldKey(field)
        if case .multiselect = field, case .string(let s) = picked {
            var list: [String]
            if case .strings(let existing) = state.answers[key] { list = existing } else { list = [] }
            if let idx = list.firstIndex(of: s) { list.remove(at: idx) } else { list.append(s) }
            var next = state
            next.answers[key] = .strings(list)
            next.error = ""
            return next
        }
        var next = state
        next.answers[key] = picked
        next.error = ""
        return formSetField(next, form: form, index: formSingle(form) ? state.field : state.field + 1)
    }

    // parity: tui/src/mini/form.shared.ts#formCommitInput [status=implemented hash=fe3053338d22]
    public static func formCommitInput(_ state: FormBodyState, form: FormSchema.Info, text: String) -> FormBodyState {
        guard let field = formCurrent(form, state: state) else { return state }
        switch field {
        case .external, .boolean: return state
        default: break
        }
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = fieldKey(field)
        if case .multiselect = field {
            var existing: [String]
            if case .strings(let arr) = state.answers[key] { existing = arr } else { existing = [] }
            if let prevCustom = state.custom[key], !prevCustom.isEmpty {
                existing.removeAll { $0 == prevCustom }
            }
            if !input.isEmpty && !existing.contains(input) { existing.append(input) }
            let val = FormSchema.Value.strings(existing)
            if let invalid = validateFieldValue(field, val) { return formSetError(state, error: invalid) }
            var next = state
            next.answers[key] = val
            next.custom[key] = input
            next.editing = false
            next.error = ""
            return next
        }
        let value: FormSchema.Value?
        if input.isEmpty {
            value = nil
        } else if case .number = field {
            value = Double(input).map { .number($0) }
        } else if case .integer = field {
            value = Double(input).map { .number($0) }
        } else {
            value = .string(input)
        }
        if let invalid = validateFieldValue(field, value) { return formSetError(state, error: invalid) }
        var next = state
        if let value { next.answers[key] = value } else { next.answers.removeValue(forKey: key) }
        next.custom[key] = input
        next.editing = false
        next.error = ""
        return next
    }

    // parity: tui/src/mini/form.shared.ts#formAcknowledge [status=implemented hash=03301021b32e]
    public static func formAcknowledge(_ state: FormBodyState, form: FormSchema.Info) -> FormBodyState {
        guard let field = formCurrent(form, state: state), case .external(let ext) = field,
              state.externalReady[ext.key] == true
        else { return state }
        var next = state
        next.answers[ext.key] = .bool(true)
        next.error = ""
        return formSetField(next, form: form, index: formSingle(form) ? state.field : state.field + 1)
    }

    // parity: tui/src/mini/form.shared.ts#formErrorMessage [status=implemented hash=a8abb5ac2e86]
    public static func formErrorMessage(_ error: (any Error)?) -> String {
        guard let error else { return "Form request failed" }
        let msg = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.isEmpty ? "Form request failed" : msg
    }

    // MARK: - Catalog, Session, Variant & Boot (`catalog.shared.ts`, `session.shared.ts`, `variant.shared.ts`, `runtime.boot.ts`)

    // parity: tui/src/mini/catalog.shared.ts#runProviders [status=implemented hash=47cad2ee3726]
    public static func runProviders(
        providers: [(id: String, name: String)],
        models: [(providerID: String, id: String, name: String, inputCost: Double?, contextLimit: Int, status: String?, variants: [String])]
    ) -> [RunProvider] {
        var grouped: [String: RunProvider] = [:]
        var order: [String] = []
        for p in providers {
            if grouped[p.id] == nil { order.append(p.id) }
            grouped[p.id] = RunProvider(id: p.id, name: p.name, models: [:])
        }
        for m in models {
            if grouped[m.providerID] == nil {
                order.append(m.providerID)
                grouped[m.providerID] = RunProvider(id: m.providerID, name: m.providerID, models: [:])
            }
            grouped[m.providerID]?.models[m.id] = RunProviderModel(
                name: m.name, inputCost: m.inputCost, contextLimit: m.contextLimit, status: m.status, variants: m.variants
            )
        }
        return order.compactMap { grouped[$0] }
    }

    // parity: tui/src/mini/catalog.shared.ts#requestOptions [status=implemented hash=1d57ca5afed9]
    public static func requestOptions(signal: AbortSignal? = nil) -> RequestOptions {
        RequestOptions(signal: signal)
    }

    // parity: tui/src/mini/catalog.shared.ts#loadRunAgents [status=adapted hash=633c2eff9f2c]
    public static func loadRunAgents(
        fetch: @Sendable (LocationSchema.Ref, RequestOptions) async throws -> [RunAgent],
        ref: LocationSchema.Ref,
        signal: AbortSignal? = nil
    ) async throws -> [RunAgent] {
        try await fetch(ref, requestOptions(signal: signal))
    }

    // parity: tui/src/mini/catalog.shared.ts#loadRunCommands [status=adapted hash=1f6204151db0]
    public static func loadRunCommands(
        fetch: @Sendable (LocationSchema.Ref, RequestOptions) async throws -> [RunCommand],
        ref: LocationSchema.Ref,
        signal: AbortSignal? = nil
    ) async throws -> [RunCommand] {
        try await fetch(ref, requestOptions(signal: signal))
    }

    // parity: tui/src/mini/catalog.shared.ts#loadRunReferences [status=adapted hash=ad846d2fbad9]
    public static func loadRunReferences(
        fetch: @Sendable (LocationSchema.Ref, RequestOptions) async throws -> [RunReference],
        ref: LocationSchema.Ref,
        signal: AbortSignal? = nil
    ) async throws -> [RunReference] {
        try await fetch(ref, requestOptions(signal: signal)).filter { !$0.hidden }
    }

    // parity: tui/src/mini/catalog.shared.ts#loadRunProviders [status=adapted hash=0a7a5286c9c5]
    public static func loadRunProviders(
        fetch: @Sendable (LocationSchema.Ref, RequestOptions) async throws -> [RunProvider],
        ref: LocationSchema.Ref,
        signal: AbortSignal? = nil
    ) async throws -> [RunProvider] {
        try await fetch(ref, requestOptions(signal: signal))
    }

    // parity: tui/src/mini/session.shared.ts#SessionMessages [status=implemented hash=64bd2094fc63]
    public typealias SessionMessages = [SessionMessageSchema.Info]

    public struct SessionTurn: Equatable, Hashable, Sendable {
        public var prompt: RunPrompt
        public var provider: String?
        public var model: String?
        public var variant: String?

        public init(prompt: RunPrompt, provider: String? = nil, model: String? = nil, variant: String? = nil) {
            self.prompt = prompt
            self.provider = provider
            self.model = model
            self.variant = variant
        }
    }

    // parity: tui/src/mini/session.shared.ts#RunSession [status=implemented hash=554076514447]
    public struct RunSession: Equatable, Hashable, Sendable {
        public var first: Bool
        public var turns: [SessionTurn]
        public var model: PromptModelSelection?
        public var variant: String?

        public init(first: Bool = true, turns: [SessionTurn] = [], model: PromptModelSelection? = nil, variant: String? = nil) {
            self.first = first
            self.turns = turns
            self.model = model
            self.variant = variant
        }
    }

    // parity: tui/src/mini/session.shared.ts#messagePrompt [status=implemented hash=2326c782be35]
    public static func messagePrompt(_ message: SessionMessageSchema.User) -> RunPrompt {
        var parts: [RunPromptPart] = []
        for file in message.files ?? [] {
            let uri: String
            switch file.source {
            case .uri(let u): uri = u
            case .inline: uri = "data:\(file.mime);base64,\(file.data.rawValue)"
            }
            let source = file.mention.map {
                FilePartSource(
                    type: "file",
                    path: file.name ?? (uri.hasPrefix("data:") ? "inline attachment" : uri),
                    text: SourceSpan(start: $0.start, end: $0.end, value: $0.text)
                )
            }
            parts.append(.file(url: uri, filename: file.name, mime: file.mime, description: file.description, source: source))
        }
        for agent in message.agents ?? [] {
            parts.append(.agent(name: agent.name, source: agent.mention.map { SourceSpan(start: $0.start, end: $0.end, value: $0.text) }))
        }
        for skill in message.skills ?? [] {
            parts.append(.skill(id: skill.id, source: skill.mention.map { SourceSpan(start: $0.start, end: $0.end, value: $0.text) }))
        }
        return RunPrompt(text: message.text, parts: parts)
    }

    // parity: tui/src/mini/session.shared.ts#createSession [status=implemented hash=60c1f34bb697]
    public static func createSession(_ messages: SessionMessages) -> RunSession {
        let turns: [SessionTurn] = messages.compactMap { msg in
            guard case .user(let u) = msg else { return nil }
            return SessionTurn(prompt: messagePrompt(u))
        }
        return RunSession(first: messages.isEmpty, turns: turns)
    }

    // parity: tui/src/mini/session.shared.ts#resolveCurrentSession [status=adapted hash=231e8f45c48e]
    public static func resolveCurrentSession(
        loadMessages: @Sendable () async throws -> SessionMessages,
        loadSessionModel: @Sendable () async throws -> SessionSchema.ModelRef?
    ) async throws -> RunSession {
        async let messages = loadMessages()
        async let model = loadSessionModel()
        let current = createSession(try await messages)
        let ref = try await model
        guard let ref else { return current }
        return RunSession(
            first: current.first,
            turns: current.turns.map { SessionTurn(prompt: $0.prompt, provider: ref.providerID, model: ref.id, variant: ref.variant) },
            model: PromptModelSelection(providerID: ref.providerID, modelID: ref.id),
            variant: ref.variant
        )
    }

    // parity: tui/src/mini/session.shared.ts#sessionHistory [status=implemented hash=bdb1a86eabd5]
    public static func sessionHistory(_ session: RunSession, limit: Int = 200) -> [RunPrompt] {
        var out: [RunPrompt] = []
        for turn in session.turns {
            let p = turn.prompt
            guard !p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || p.parts.contains(where: \.isFile) else {
                continue
            }
            if let last = out.last, promptSame(last, p) { continue }
            out.append(promptCopy(p))
        }
        return Array(out.suffix(limit))
    }

    // parity: tui/src/mini/session.shared.ts#sessionVariant [status=implemented hash=efba80289ff5]
    public static func sessionVariant(_ session: RunSession, model: PromptModelSelection?) -> String? {
        guard let model else { return nil }
        if session.model == model { return session.variant }
        return session.turns.last(where: { $0.provider == model.providerID && $0.model == model.modelID })?.variant
    }

    // parity: tui/src/mini/variant.shared.ts#modelInfo [status=implemented hash=1823b0299cae]
    public static func modelInfo(
        providers: [RunProvider]?,
        model: PromptModelSelection
    ) -> (provider: String, model: String) {
        let provider = providers?.first(where: { $0.id == model.providerID })
        return (
            provider: provider?.name ?? model.providerID,
            model: provider?.models[model.modelID]?.name ?? model.modelID
        )
    }

    // parity: tui/src/mini/variant.shared.ts#formatModelLabel [status=implemented hash=9f2d0c0d7dd1]
    public static func formatModelLabel(
        _ model: PromptModelSelection,
        variant: String? = nil,
        providers: [RunProvider]? = nil
    ) -> String {
        let names = modelInfo(providers: providers, model: model)
        let suffix = (variant != nil && !variant!.isEmpty) ? " · \(variant!)" : ""
        return "\(names.model) · \(names.provider)\(suffix)"
    }

    // parity: tui/src/mini/variant.shared.ts#cycleVariant [status=implemented hash=66e46576a082]
    public static func cycleVariant(_ current: String?, variants: [String]) -> String? {
        TUIModelPreference.cycleModelVariant(current, variants: variants)
    }

    // parity: tui/src/mini/variant.shared.ts#pickVariant [status=implemented hash=51c2a3327c86]
    public static func pickVariant(_ model: PromptModelSelection?, session: RunSession) -> String? {
        sessionVariant(session, model: model)
    }

    // parity: tui/src/mini/variant.shared.ts#resolveVariant [status=implemented hash=21ad27372741]
    public static func resolveVariant(
        input: String?,
        session: String?,
        saved: String?,
        variants: [String]
    ) -> String? {
        if let input { return TUIModelPreference.normalizeModelVariant(input) }
        func fit(_ value: String?) -> String? {
            guard let normalized = TUIModelPreference.normalizeModelVariant(value), !normalized.isEmpty else { return nil }
            return (variants.isEmpty || variants.contains(normalized)) ? normalized : nil
        }
        return fit(session) ?? fit(saved)
    }

    // parity: tui/src/mini/runtime.boot.ts#ModelInfo [status=implemented hash=cbbabfd8b239]
    public struct ModelInfo: Equatable, Hashable, Sendable {
        public let providers: [RunProvider]

        public init(providers: [RunProvider] = []) {
            self.providers = providers
        }
    }

    // parity: tui/src/mini/runtime.boot.ts#SessionInfo [status=implemented hash=dfb723c3281a]
    public struct SessionInfo: Equatable, Hashable, Sendable {
        public let first: Bool
        public let history: [RunPrompt]
        public let model: PromptModelSelection?
        public let variant: String?

        public init(first: Bool = true, history: [RunPrompt] = [], model: PromptModelSelection? = nil, variant: String? = nil) {
            self.first = first
            self.history = history
            self.model = model
            self.variant = variant
        }
    }

    // parity: tui/src/mini/runtime.boot.ts#resolveModelInfoStrict [status=adapted hash=c80256cc3ecc]
    public static func resolveModelInfoStrict(
        fetch: @Sendable () async throws -> [RunProvider]
    ) async throws -> ModelInfo {
        ModelInfo(providers: try await fetch())
    }

    // parity: tui/src/mini/runtime.boot.ts#resolveModelInfo [status=adapted hash=652ab5f2e036]
    public static func resolveModelInfo(
        fetch: @Sendable () async throws -> [RunProvider]
    ) async -> ModelInfo {
        (try? await resolveModelInfoStrict(fetch: fetch)) ?? ModelInfo()
    }

    // parity: tui/src/mini/runtime.boot.ts#resolveSessionInfo [status=adapted hash=72a289663613]
    public static func resolveSessionInfo(
        load: @Sendable () async throws -> RunSession,
        model: PromptModelSelection? = nil
    ) async -> SessionInfo {
        guard let session = try? await load() else { return SessionInfo() }
        return SessionInfo(
            first: session.first,
            history: sessionHistory(session),
            model: session.model,
            variant: pickVariant(model ?? session.model, session: session)
        )
    }

    // parity: tui/src/mini/runtime.boot.ts#resolveRunTuiConfig [status=implemented hash=e1cff0fbaf68]
    public static func resolveRunTuiConfig(
        _ config: RunTuiConfig? = nil,
        platform: String = Platform.current.rawValue
    ) async -> RunTuiConfig {
        config ?? TUIConfig.resolve(TUIConfig.Info(), options: TUIConfig.ResolveOptions(terminalSuspend: platform != "windows"))
    }

    // parity: tui/src/mini/runtime.boot.ts#resolveMiniSettings [status=implemented hash=9679701f05e8]
    public static func resolveMiniSettings(_ config: TUIConfig.MiniConfig? = nil) -> MiniSettings {
        MiniSettings(
            thinking: config?.thinking ?? .show,
            tools: config?.tools ?? .hide,
            shellOutput: config?.shellOutput ?? .hide,
            turnSummary: config?.turnSummary ?? .show,
            footer: config?.footer ?? .show,
            splash: config?.splash ?? .show,
            workSpinner: config?.workSpinner ?? .blockSoftSlide,
            mono: config?.mono ?? false
        )
    }

    // MARK: - Stream V2 Fragment, Image, Subagent & Transport (`stream-v2.*.ts`)

    // parity: tui/src/mini/stream-v2.fragment.ts#FragmentRef [status=implemented hash=014b77c145ca]
    public struct FragmentRef: Equatable, Hashable, Sendable, Codable {
        public let messageID: String
        public let partID: String

        public init(messageID: String, partID: String) {
            self.messageID = messageID
            self.partID = partID
        }
    }

    // parity: tui/src/mini/stream-v2.fragment.ts#FragmentUpdate [status=implemented hash=938f3e1ce8a0]
    public struct FragmentUpdate: Equatable, Hashable, Sendable {
        public let messageID: String
        public let partID: String
        public let key: String
        public let previous: String
        public let text: String
    }

    // parity: tui/src/mini/stream-v2.fragment.ts#FragmentRestore [status=implemented hash=4457deb1a9c9]
    public enum FragmentRestore: Equatable, Hashable, Sendable {
        case append(suffix: String)
        case covered
        case conflict
    }

    // parity: tui/src/mini/stream-v2.fragment.ts#fragmentRef [status=implemented hash=c3efedacbd6c]
    public static func fragmentRef(messageID: String, kind: String, ordinal: Int) -> FragmentRef {
        FragmentRef(messageID: messageID, partID: "\(kind):\(ordinal)")
    }

    // parity: tui/src/mini/stream-v2.fragment.ts#FragmentReconciler [status=implemented hash=4613d134212c]
    public final class FragmentReconciler: @unchecked Sendable {
        private struct Entry {
            var text: String
            var projected: String?
        }

        private let map = Mutex<[String: Entry]>([:])

        public init() {}

        public func key(_ ref: FragmentRef) -> String {
            "\(ref.messageID)\u{0}\(ref.partID)"
        }

        public func clear() { map.withLock { $0.removeAll() } }

        public func value(_ ref: FragmentRef) -> String? {
            map.withLock { $0[key(ref)]?.text }
        }

        public func project(_ ref: FragmentRef, text: String, visible: Bool) -> FragmentUpdate {
            let id = key(ref)
            let prev = map.withLock { m -> String in
                let old = m[id]
                m[id] = Entry(text: text, projected: visible ? text : old?.projected)
                return old?.text ?? ""
            }
            return FragmentUpdate(messageID: ref.messageID, partID: ref.partID, key: id, previous: prev, text: text)
        }

        public func delta(_ ref: FragmentRef, _ delta: String) -> FragmentUpdate? {
            let id = key(ref)
            return map.withLock { m -> FragmentUpdate? in
                if var cur = m[id], let proj = cur.projected, let range = proj.range(of: delta) {
                    cur.projected = String(proj[range.upperBound...])
                    m[id] = cur
                    return nil
                }
                let prev = m[id]?.text ?? ""
                let next = prev + delta
                m[id] = Entry(text: next, projected: m[id]?.projected)
                return FragmentUpdate(messageID: ref.messageID, partID: ref.partID, key: id, previous: prev, text: next)
            }
        }

        public func end(_ ref: FragmentRef, text: String) -> FragmentUpdate {
            let id = key(ref)
            let prev = map.withLock { m -> String in
                let old = m[id]?.text ?? ""
                m[id] = Entry(text: text, projected: nil)
                return old
            }
            return FragmentUpdate(messageID: ref.messageID, partID: ref.partID, key: id, previous: prev, text: text)
        }

        public func restore(_ ref: FragmentRef, text: String) -> FragmentRestore {
            let id = key(ref)
            return map.withLock { m in
                guard let cur = m[id] else {
                    m[id] = Entry(text: text, projected: text)
                    return .append(suffix: text)
                }
                if text.hasPrefix(cur.text) {
                    let suffix = String(text.dropFirst(cur.text.count))
                    m[id] = Entry(text: text, projected: text)
                    return .append(suffix: suffix)
                }
                if cur.text.hasPrefix(text) { return .covered }
                return .conflict
            }
        }
    }

    // parity: tui/src/mini/stream-v2.fragment.ts#createFragmentReconciler [status=implemented hash=15e0aa4da64d]
    public static func createFragmentReconciler() -> FragmentReconciler {
        FragmentReconciler()
    }

    // parity: tui/src/mini/stream-v2.image.ts#ImageCommit [status=implemented hash=44dcb7714a24]
    public typealias ImageCommit = StreamCommit

    // parity: tui/src/mini/stream-v2.image.ts#userImageCommits [status=implemented hash=852d511e92d0]
    public static func userImageCommits(
        messageID: String,
        files: [PromptSchema.FileAttachment]?
    ) -> [ImageCommit] {
        let projected = (files ?? []).map {
            TUIPrompt.ProjectedFile(mime: $0.mime, source: $0.source, name: $0.name, description: $0.description, mention: $0.mention, payload: $0.data.rawValue)
        }
        return TUIPrompt.deduplicateVisibleImages(projected)
            .filter { $0.mime.hasPrefix("image/") }
            .enumerated()
            .map { index, file in
                StreamCommit(
                    kind: .user,
                    text: file.name ?? file.mention?.text ?? "[Image \(index + 1)]",
                    image: "data:\(file.mime);base64,\(file.payload)",
                    phase: .final,
                    source: .system,
                    messageID: messageID,
                    partID: "image:\(index)"
                )
            }
    }

    // parity: tui/src/mini/stream-v2.image.ts#toolImageCommits [status=implemented hash=3c218f28c73a]
    public static func toolImageCommits(
        part: SessionMessageSchema.AssistantTool,
        messageID: String
    ) -> [ImageCommit] {
        let contents: [SessionMessageSchema.ToolContent]
        switch part.state {
        case .completed(let s): contents = s.content
        case .error(let s): contents = s.content ?? []
        case .streaming, .running: contents = []
        }
        return contents.compactMap { item -> (uri: String, name: String?)? in
            if case .file(let uri, let mime, let name) = item, mime.hasPrefix("image/"), uri.hasPrefix("data:image/") {
                return (uri, name)
            }
            return nil
        }.enumerated().map { index, file in
            StreamCommit(
                kind: .tool,
                text: file.name ?? "[Image \(index + 1)]",
                image: file.uri,
                phase: .final,
                source: .tool,
                messageID: messageID,
                partID: "prt_\(part.id):image:\(index)"
            )
        }
    }

    // parity: tui/src/mini/stream-v2.subagent.ts#toolCommit [status=implemented hash=600ac5a6921e]
    public static func toolCommit(
        _ input: SessionMessageSchema.AssistantTool,
        messageID: String,
        phase: StreamPhase,
        value: String? = nil,
        directory: String? = nil,
        version: Int = 0
    ) -> StreamCommit {
        let part = normalizeTool(input)
        let text: String
        let toolState: StreamToolState
        var toolError: String? = nil
        switch part.state {
        case .streaming:
            text = ""
            toolState = .running
        case .running:
            text = value ?? (part.name == "subagent" ? "running subagent" : "running \(part.name)")
            toolState = .running
        case .completed(let s):
            text = value ?? toolOutputText(part.name, content: s.content)
            toolState = .completed
        case .error(let s):
            let partial = phase == .progress && value != nil
            text = partial ? (value ?? "") : s.error.message
            toolState = partial ? .running : .error
            toolError = partial ? nil : s.error.message
        }
        return StreamCommit(
            kind: .tool,
            text: text,
            phase: phase,
            source: .tool,
            messageID: messageID,
            partID: "prt_\(part.id)\(version > 0 ? ":snapshot:\(version)" : "")",
            tool: part.name,
            directory: directory,
            part: part,
            toolState: toolState,
            toolError: toolError
        )
    }

    // parity: tui/src/mini/stream-v2.subagent.ts#toolFinalPhase [status=implemented hash=6e9dfb449009]
    public static func toolFinalPhase(_ part: SessionMessageSchema.AssistantTool) -> StreamPhase {
        let tool = normalizeTool(part)
        guard case .completed(let s) = tool.state else { return .final }
        return toolView(tool.name).output && !toolOutputText(tool.name, content: s.content).isEmpty ? .progress : .final
    }

    // parity: tui/src/mini/stream-v2.subagent.ts#SubagentTrackerInput [status=implemented hash=4f0e4a961938]
    public struct SubagentTrackerInput: Sendable {
        public let sessionID: String
        public let thinking: Bool
        public let directory: String?
        public let signal: AbortSignal?
        public let emit: @Sendable () -> Void

        public init(
            sessionID: String,
            thinking: Bool = true,
            directory: String? = nil,
            signal: AbortSignal? = nil,
            emit: @escaping @Sendable () -> Void = {}
        ) {
            self.sessionID = sessionID
            self.thinking = thinking
            self.directory = directory
            self.signal = signal
            self.emit = emit
        }
    }

    // parity: tui/src/mini/stream-v2.subagent.ts#SubagentTracker [status=adapted hash=d07884a80a89]
    public final class SubagentTracker: @unchecked Sendable {
        private let input: SubagentTrackerInput
        private let state = Mutex<FooterSubagentState>(FooterSubagentState())
        private let selectedID = Mutex<String?>(nil)

        public init(input: SubagentTrackerInput) {
            self.input = input
        }

        public func upsertTab(_ tab: FooterSubagentTab) {
            state.withLock { s in
                if let idx = s.tabs.firstIndex(where: { $0.sessionID == tab.sessionID }) {
                    s.tabs[idx] = tab
                } else {
                    s.tabs.append(tab)
                }
            }
            input.emit()
        }

        public func appendCommit(sessionID: String, commit: StreamCommit) {
            state.withLock { s in
                var detail = s.details[sessionID] ?? FooterSubagentDetail()
                detail.commits.append(commit)
                s.details[sessionID] = detail
            }
            if selectedID.withLock({ $0 }) == sessionID { input.emit() }
        }

        public func select(_ sessionID: String?) {
            selectedID.withLock { $0 = sessionID }
            input.emit()
        }

        public func settleForm(sessionID: String, formID: String) {
            state.withLock { $0.forms.removeAll { $0.sessionID == sessionID && $0.id == formID } }
            input.emit()
        }

        public func snapshot() -> FooterSubagentState {
            let sel = selectedID.withLock { $0 }
            return state.withLock { s in
                let details: [String: FooterSubagentDetail] = sel.flatMap { id in s.details[id].map { [id: $0] } } ?? [:]
                return FooterSubagentState(tabs: s.tabs, details: details, permissions: s.permissions, forms: s.forms)
            }
        }

        public func close() {}
    }

    // parity: tui/src/mini/stream-v2.subagent.ts#createSubagentTracker [status=adapted hash=1ebf36f3724c]
    public static func createSubagentTracker(_ input: SubagentTrackerInput) -> SubagentTracker {
        SubagentTracker(input: input)
    }

    // parity: tui/src/mini/stream-v2.transport.ts#SessionTurnInput [status=implemented hash=f4190951007c]
    public struct SessionTurnInput: Sendable {
        public let agent: String?
        public let model: PromptModelSelection?
        public let variant: String?
        public let prompt: RunPrompt
        public let files: [RunFilePart]
        public let includeFiles: Bool
        public let signal: AbortSignal?

        public init(
            agent: String? = nil,
            model: PromptModelSelection? = nil,
            variant: String? = nil,
            prompt: RunPrompt,
            files: [RunFilePart] = [],
            includeFiles: Bool = false,
            signal: AbortSignal? = nil
        ) {
            self.agent = agent
            self.model = model
            self.variant = variant
            self.prompt = prompt
            self.files = files
            self.includeFiles = includeFiles
            self.signal = signal
        }
    }

    // parity: tui/src/mini/stream-v2.transport.ts#SessionResizeReplayInput [status=implemented hash=2a8f771db934]
    public struct SessionResizeReplayInput: Sendable {
        public let localRows: @Sendable () -> [LocalReplayRow]
        public let reset: @Sendable () async -> Void

        public init(
            localRows: @escaping @Sendable () -> [LocalReplayRow] = { [] },
            reset: @escaping @Sendable () async -> Void = {}
        ) {
            self.localRows = localRows
            self.reset = reset
        }
    }

    // parity: tui/src/mini/stream-v2.transport.ts#SessionTransport [status=implemented hash=fd1ba67fa177]
    public struct SessionTransport: Sendable {
        public let runPromptTurn: @Sendable (SessionTurnInput, (@Sendable () -> Void)?) async throws -> Void
        public let admitPromptTurn: @Sendable (SessionTurnInput, RunDelivery) async throws -> Void
        public let waitForIdle: @Sendable () async -> Void
        public let interruptActiveTurn: @Sendable () async -> Void
        public let selectSubagent: @Sendable (String?) -> Void
        public let replayOnResize: @Sendable (SessionResizeReplayInput) async -> Bool
        public let close: @Sendable () async -> Void

        public init(
            runPromptTurn: @escaping @Sendable (SessionTurnInput, (@Sendable () -> Void)?) async throws -> Void = { _, cb in cb?() },
            admitPromptTurn: @escaping @Sendable (SessionTurnInput, RunDelivery) async throws -> Void = { _, _ in },
            waitForIdle: @escaping @Sendable () async -> Void = {},
            interruptActiveTurn: @escaping @Sendable () async -> Void = {},
            selectSubagent: @escaping @Sendable (String?) -> Void = { _ in },
            replayOnResize: @escaping @Sendable (SessionResizeReplayInput) async -> Bool = { _ in false },
            close: @escaping @Sendable () async -> Void = {}
        ) {
            self.runPromptTurn = runPromptTurn
            self.admitPromptTurn = admitPromptTurn
            self.waitForIdle = waitForIdle
            self.interruptActiveTurn = interruptActiveTurn
            self.selectSubagent = selectSubagent
            self.replayOnResize = replayOnResize
            self.close = close
        }
    }

    // parity: tui/src/mini/stream-v2.transport.ts#formatUnknownError [status=implemented hash=eff5670fa2cc]
    public static func formatUnknownError(_ error: (any Error)?) -> String {
        guard let error else { return "unknown error" }
        let desc = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        return desc.isEmpty ? "unknown error" : desc
    }

    private final class MiniLiveSessionTransport: @unchecked Sendable {
        private struct TrackedTool: Sendable {
            var part: SessionMessageSchema.AssistantTool
            var output: String
            var version: Int
            var started: Bool
        }

        private struct State: Sendable {
            var sessionID: String?
            var closed: Bool = false
            var connected: Bool = false
            var connectedWaiters: [CheckedContinuation<Void, Never>] = []
            var streamStarted: Bool = false
            var streamTask: Task<Void, Never>?
            var offFooterClose: (@Sendable () -> Void)?
            var rootActive: Bool = false
            var turnActive: Bool = false
            var turnSettled: Bool = false
            var turnWaiters: [CheckedContinuation<Void, Never>] = []
            var turnEmittedAssistant: Bool = false
            var pendingUserText: [String: String] = [:]
            var renderedUserIDs: Set<String> = []
            var renderedErrorIDs: Set<String> = []
            var tools: [String: TrackedTool] = [:]
            var finishedTools: Set<String> = []
        }

        private let client: OpenCodeClient
        private let footer: any FooterApi
        private let directory: String?
        private let thinking: Bool
        private let tools: Bool
        private let replay: Bool
        private let replayLimit: Int?
        private let onCommit: (@Sendable (StreamCommit) -> Void)?
        private let onSessionTitle: (@Sendable (String) -> Void)?
        private let tracker: SubagentTracker
        private let fragments = createFragmentReconciler()
        private let streamController = AbortController()
        private let state: Mutex<State>

        init(
            sessionID: String?,
            footer: any FooterApi,
            client: OpenCodeClient,
            directory: String?,
            thinking: Bool,
            tools: Bool,
            replay: Bool,
            replayLimit: Int?,
            onCommit: (@Sendable (StreamCommit) -> Void)?,
            onSessionTitle: (@Sendable (String) -> Void)?
        ) {
            let normalizedID = (sessionID?.isEmpty == false) ? sessionID : nil
            self.client = client
            self.footer = footer
            self.directory = directory
            self.thinking = thinking
            self.tools = tools
            self.replay = replay
            self.replayLimit = replayLimit
            self.onCommit = onCommit
            self.onSessionTitle = onSessionTitle
            self.tracker = createSubagentTracker(SubagentTrackerInput(
                sessionID: normalizedID ?? "",
                thinking: thinking,
                directory: directory,
                signal: streamController.signal
            ) {
                footer.event(.streamSubagent(FooterSubagentState()))
            })
            self.state = Mutex(State(sessionID: normalizedID))

            let off = footer.onClose { [weak self] in
                self?.abortStream()
            }
            self.state.withLock { $0.offFooterClose = off }
            if normalizedID != nil {
                ensureEventStreamStarted()
            }
        }

        var currentSessionID: String? {
            state.withLock { $0.sessionID }
        }

        private var isClosed: Bool {
            state.withLock { $0.closed }
        }

        private var isTurnSettled: Bool {
            state.withLock { $0.turnSettled || !$0.turnActive }
        }

        private func abortStream() {
            streamController.abort()
            let (connWaiters, turnWaiters) = state.withLock { s -> ([CheckedContinuation<Void, Never>], [CheckedContinuation<Void, Never>]) in
                s.turnSettled = true
                s.turnActive = false
                let cw = s.connectedWaiters
                let tw = s.turnWaiters
                s.connectedWaiters.removeAll()
                s.turnWaiters.removeAll()
                return (cw, tw)
            }
            for w in connWaiters { w.resume() }
            for w in turnWaiters { w.resume() }
        }

        private func markConnected() {
            let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
                s.connected = true
                let w = s.connectedWaiters
                s.connectedWaiters.removeAll()
                return w
            }
            for w in waiters { w.resume() }
        }

        private func ensureEventStreamStarted() {
            let shouldStart = state.withLock { s -> Bool in
                if s.streamStarted || s.closed { return false }
                s.streamStarted = true
                return true
            }
            guard shouldStart else { return }
            let task = Task<Void, Never> { [weak self] in
                await self?.runEventLoop()
            }
            state.withLock { $0.streamTask = task }
        }

        private func waitUntilStreamReady(timeoutMs: Int = 250) async {
            if state.withLock({ $0.connected || $0.closed }) || footer.isClosed {
                return
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    guard let self else { return }
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let alreadyReady = self.state.withLock { s -> Bool in
                            if s.connected || s.closed { return true }
                            s.connectedWaiters.append(continuation)
                            return false
                        }
                        if alreadyReady {
                            continuation.resume()
                        }
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(timeoutMs))
                }
                _ = await group.next()
                group.cancelAll()
            }
        }

        private func armActiveTurn() {
            state.withLock { s in
                s.turnActive = true
                s.turnSettled = false
                s.turnEmittedAssistant = false
            }
        }

        private func finishActiveTurn(emitIdle: Bool) {
            let (waiters, closed) = state.withLock { s -> ([CheckedContinuation<Void, Never>], Bool) in
                s.rootActive = false
                s.turnSettled = true
                s.turnActive = false
                let w = s.turnWaiters
                s.turnWaiters.removeAll()
                return (w, s.closed)
            }
            if emitIdle && !closed && !footer.isClosed {
                writeSessionOutput(
                    footer: footer,
                    output: StreamOutput(updates: [
                        .streamPatch(FooterPatch(phase: .idle, status: "")),
                        .turnIdle,
                    ])
                )
            }
            for w in waiters { w.resume() }
        }

        private func waitForActiveTurn(signal: AbortSignal?) async {
            if isTurnSettled || isClosed || footer.isClosed || signal?.isAborted == true {
                return
            }
            let cleanup = signal?.onAbort { [weak self] in
                guard let self else { return }
                if let sid = self.currentSessionID {
                    Task {
                        _ = try? await self.client.session.interrupt(SessionInterruptInput(sessionID: sid, resume: true))
                    }
                }
                self.finishActiveTurn(emitIdle: true)
            }
            defer { cleanup?() }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let done = state.withLock { s -> Bool in
                    if s.turnSettled || !s.turnActive || s.closed { return true }
                    s.turnWaiters.append(continuation)
                    return false
                }
                if done {
                    continuation.resume()
                }
            }
        }

        private func ensureSession(for turn: SessionTurnInput) async throws -> (sessionID: String, createdFresh: Bool) {
            if let existing = state.withLock({ $0.sessionID }), !existing.isEmpty {
                return (existing, false)
            }
            let modelRef: ModelSchema.Ref? = turn.model.map {
                ModelSchema.Ref(
                    id: ModelSchema.ID(rawValue: $0.modelID),
                    providerID: ProviderSchema.ID(rawValue: $0.providerID),
                    variant: turn.variant.map(ModelSchema.VariantID.init(rawValue:))
                )
            }
            let location: LocationSchema.PublicRef? = directory
                .flatMap { SchemaPrimitive.AbsolutePath(rawValue: $0) }
                .map { LocationSchema.PublicRef(directory: $0) }
            let created = try await client.session.create(
                SessionCreateInput(
                    agent: turn.agent,
                    model: modelRef,
                    location: location
                ),
                options: turn.signal.map { RequestOptions(signal: $0) }
            )
            let createdID = created.id.rawValue
            let resolved = state.withLock { s -> String in
                if let existing = s.sessionID, !existing.isEmpty { return existing }
                s.sessionID = createdID
                return createdID
            }
            return (resolved, true)
        }

        private func buildFileAttachments(_ turn: SessionTurnInput) -> [PromptInputSchema.FileAttachment] {
            var out: [PromptInputSchema.FileAttachment] = []
            if turn.includeFiles {
                for file in turn.files {
                    out.append(PromptInputSchema.FileAttachment(uri: file.url, name: file.filename))
                }
            }
            for part in turn.prompt.parts {
                if case .file(let url, let filename, _, let description, let source) = part {
                    let mention = source.map {
                        PromptSchema.PromptMention(start: $0.text.start, end: $0.text.end, text: $0.text.value)
                    }
                    out.append(PromptInputSchema.FileAttachment(
                        uri: url,
                        name: filename,
                        description: description,
                        mention: mention
                    ))
                }
            }
            return out
        }

        private func buildAgentAttachments(_ turn: SessionTurnInput) -> [PromptSchema.AgentAttachment] {
            turn.prompt.parts.compactMap { part in
                guard case .agent(let name, let source) = part else { return nil }
                let mention = source.map {
                    PromptSchema.PromptMention(start: $0.start, end: $0.end, text: $0.value)
                }
                return PromptSchema.AgentAttachment(name: name, mention: mention)
            }
        }

        private func buildSkillAttachments(_ turn: SessionTurnInput) -> [PromptInputSchema.SkillAttachment] {
            turn.prompt.parts.compactMap { part in
                guard case .skill(let id, let source) = part else { return nil }
                let mention = source.map {
                    PromptSchema.PromptMention(start: $0.start, end: $0.end, text: $0.value)
                }
                return PromptInputSchema.SkillAttachment(id: id, mention: mention)
            }
        }

        private func sendPromptPayload(
            sessionID: String,
            messageID: String,
            turn: SessionTurnInput,
            delivery: RunDelivery
        ) async throws {
            let files = buildFileAttachments(turn)
            let agents = buildAgentAttachments(turn)
            let skills = buildSkillAttachments(turn)
            let reqOptions = turn.signal.map { RequestOptions(signal: $0) }
            let optFiles: [PromptInputSchema.FileAttachment]? = files.isEmpty ? nil : files
            let optAgents: [PromptSchema.AgentAttachment]? = agents.isEmpty ? nil : agents
            let optSkills: [PromptInputSchema.SkillAttachment]? = skills.isEmpty ? nil : skills
            if let command = turn.prompt.command {
                let cmdInput = SessionCommandInput(
                    sessionID: sessionID,
                    name: command.name,
                    text: command.arguments,
                    files: optFiles,
                    agents: optAgents,
                    skills: optSkills,
                    delivery: delivery
                )
                try await client.session.command(cmdInput, options: reqOptions)
            } else {
                let promptInput = SessionPromptInput(
                    sessionID: sessionID,
                    id: messageID,
                    text: turn.prompt.text,
                    files: optFiles,
                    agents: optAgents,
                    skills: optSkills,
                    delivery: delivery
                )
                _ = try await client.session.prompt(promptInput, options: reqOptions)
            }
        }

        func admitPromptTurn(_ turn: SessionTurnInput, delivery: RunDelivery) async throws {
            let (sid, createdFresh) = try await ensureSession(for: turn)
            ensureEventStreamStarted()
            await waitUntilStreamReady()
            let reqOptions = turn.signal.map { RequestOptions(signal: $0) }
            if !createdFresh && turn.prompt.command == nil {
                if let agent = turn.agent {
                    try await client.session.switchAgent(SessionSwitchAgentInput(sessionID: sid, agent: agent), options: reqOptions)
                }
                if let model = turn.model {
                    let ref = ModelSchema.Ref(
                        id: ModelSchema.ID(rawValue: model.modelID),
                        providerID: ProviderSchema.ID(rawValue: model.providerID),
                        variant: turn.variant.map(ModelSchema.VariantID.init(rawValue:))
                    )
                    try await client.session.switchModel(SessionSwitchModelInput(sessionID: sid, model: ref), options: reqOptions)
                }
            }
            let messageID = turn.prompt.messageID ?? SessionMessageSchema.ID.create().rawValue
            try await sendPromptPayload(sessionID: sid, messageID: messageID, turn: turn, delivery: delivery)
        }

        func runPromptTurn(_ turn: SessionTurnInput, admitted: (@Sendable () -> Void)?) async throws {
            let (sid, createdFresh) = try await ensureSession(for: turn)
            let reqOptions = turn.signal.map { RequestOptions(signal: $0) }
            if !createdFresh && turn.prompt.command == nil {
                if let agent = turn.agent {
                    try await client.session.switchAgent(SessionSwitchAgentInput(sessionID: sid, agent: agent), options: reqOptions)
                }
                if let model = turn.model {
                    let ref = ModelSchema.Ref(
                        id: ModelSchema.ID(rawValue: model.modelID),
                        providerID: ProviderSchema.ID(rawValue: model.providerID),
                        variant: turn.variant.map(ModelSchema.VariantID.init(rawValue:))
                    )
                    try await client.session.switchModel(SessionSwitchModelInput(sessionID: sid, model: ref), options: reqOptions)
                }
            }

            armActiveTurn()
            ensureEventStreamStarted()
            await waitUntilStreamReady()

            let messageID = turn.prompt.messageID ?? SessionMessageSchema.ID.create().rawValue
            let delivery = turn.prompt.delivery ?? .steer
            do {
                try await sendPromptPayload(sessionID: sid, messageID: messageID, turn: turn, delivery: delivery)
                admitted?()
            } catch {
                finishActiveTurn(emitIdle: true)
                throw error
            }

            if turn.prompt.command != nil {
                finishActiveTurn(emitIdle: true)
                await footer.idle()
                return
            }

            let waitTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.client.experimental.session.wait(
                        ExperimentalSessionWaitInput(sessionID: sid),
                        options: reqOptions
                    )
                    if !self.isTurnSettled {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    if !self.isTurnSettled && !self.isClosed {
                        await self.reconcileProjectedMessages(sessionID: sid, after: messageID)
                        self.finishActiveTurn(emitIdle: true)
                    }
                } catch {
                    // Minimal servers/mocks without experimental wait settle via SSE terminal events.
                }
            }
            defer { waitTask.cancel() }

            await waitForActiveTurn(signal: turn.signal)
            await footer.idle()
        }

        func waitForIdle() async {
            await waitForActiveTurn(signal: nil)
            await footer.idle()
        }

        func interruptActiveTurn() async {
            if let sid = currentSessionID {
                _ = try? await client.session.interrupt(SessionInterruptInput(sessionID: sid, resume: true))
            }
            finishActiveTurn(emitIdle: true)
        }

        func selectSubagent(_ sessionID: String?) {
            tracker.select(sessionID)
        }

        func replayOnResize(_ input: SessionResizeReplayInput) async -> Bool {
            await input.reset()
            for row in input.localRows() {
                footer.append(row.commit)
            }
            if replay, let sid = currentSessionID {
                await reconcileProjectedMessages(sessionID: sid, after: nil)
            }
            return true
        }

        func close() async {
            let (task, off) = state.withLock { s -> (Task<Void, Never>?, (@Sendable () -> Void)?) in
                s.closed = true
                let t = s.streamTask
                s.streamTask = nil
                let o = s.offFooterClose
                s.offFooterClose = nil
                return (t, o)
            }
            off?()
            abortStream()
            task?.cancel()
            await task?.value
            tracker.close()
        }

        private func emitOutput(commits: [StreamCommit] = [], updates: [FooterEvent] = []) {
            if isClosed || footer.isClosed { return }
            if let onCommit {
                for commit in commits {
                    onCommit(commit)
                }
            }
            writeSessionOutput(footer: footer, output: StreamOutput(commits: commits, updates: updates))
        }

        private func runEventLoop() async {
            var backoffMs: UInt64 = 100
            while !Task.isCancelled && !isClosed && !streamController.signal.isAborted && !footer.isClosed {
                let stream = client.event.subscribe(SubscribeOptions(signal: streamController.signal))
                var sawEvent = false
                do {
                    for try await event in stream {
                        if Task.isCancelled || isClosed || streamController.signal.isAborted || footer.isClosed {
                            break
                        }
                        sawEvent = true
                        backoffMs = 100
                        if !state.withLock({ $0.connected }) {
                            markConnected()
                        }
                        handleEvent(event)
                    }
                    markConnected()
                    let shouldSettle = state.withLock { $0.turnActive && !$0.turnSettled }
                    if shouldSettle && sawEvent {
                        finishActiveTurn(emitIdle: true)
                    }
                    if isClosed || footer.isClosed || streamController.signal.isAborted {
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(backoffMs))
                    backoffMs = min(backoffMs * 2, 1_000)
                } catch {
                    markConnected()
                    if Task.isCancelled || isClosed || streamController.signal.isAborted || footer.isClosed {
                        finishActiveTurn(emitIdle: false)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(backoffMs))
                    backoffMs = min(backoffMs * 2, 1_000)
                }
            }
            markConnected()
            finishActiveTurn(emitIdle: false)
        }

        private func handleEvent(_ event: OpenCodeEvent) {
            if event.type == "server.connected" {
                markConnected()
                return
            }
            let obj = Self.jsonDict(event.data)
            let eventSessionID: String?
            if event.type == "form.created" {
                eventSessionID = Self.jsonString(Self.jsonDict(obj["form"]), "sessionID")
            } else {
                eventSessionID = Self.jsonString(obj, "sessionID")
            }
            guard let activeSessionID = currentSessionID, eventSessionID == activeSessionID else {
                return
            }

            switch event.type {
            case "session.renamed":
                if let title = Self.jsonString(obj, "title") {
                    onSessionTitle?(title)
                }

            case "session.inbox.enqueued":
                if let inboxID = Self.jsonString(obj, "inboxID") {
                    let item = Self.jsonDict(obj["item"])
                    if Self.jsonString(item, "type") == "user",
                       let text = Self.jsonString(Self.jsonDict(item["payload"]), "text")
                    {
                        state.withLock { $0.pendingUserText[inboxID] = text }
                    }
                }

            case "session.inbox.delivered":
                if let inboxID = Self.jsonString(obj, "inboxID") {
                    let pendingText: String? = state.withLock { s in
                        let text = s.pendingUserText.removeValue(forKey: inboxID)
                        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, s.renderedUserIDs.insert(inboxID).inserted {
                            return text
                        }
                        return nil
                    }
                    var commits: [StreamCommit] = []
                    if let pendingText {
                        commits.append(StreamCommit(
                            kind: .user,
                            text: pendingText,
                            phase: .start,
                            source: .system,
                            messageID: inboxID
                        ))
                    }
                    emitOutput(
                        commits: commits,
                        updates: [.streamPatch(FooterPatch(phase: .running, status: "waiting for assistant"))]
                    )
                }

            case "session.execution.started", "session.step.started":
                state.withLock { $0.rootActive = true }
                emitOutput(updates: [.streamPatch(FooterPatch(phase: .running, status: "assistant responding"))])

            case "session.text.started":
                state.withLock { $0.rootActive = true }

            case "session.text.delta":
                let msgID = Self.jsonString(obj, "assistantMessageID") ?? Self.jsonString(obj, "messageID") ?? "msg_stream"
                let ordinal = Self.jsonInt(obj, "ordinal") ?? 0
                let delta = Self.jsonString(obj, "delta") ?? Self.jsonString(obj, "text") ?? ""
                guard !delta.isEmpty else { return }
                let ref = fragmentRef(messageID: msgID, kind: "text", ordinal: ordinal)
                if fragments.delta(ref, delta) != nil {
                    state.withLock { $0.turnEmittedAssistant = true }
                    emitOutput(commits: [
                        StreamCommit(
                            kind: .assistant,
                            text: delta,
                            phase: .progress,
                            source: .assistant,
                            messageID: msgID,
                            partID: ref.partID
                        ),
                    ])
                }

            case "session.text.ended":
                let msgID = Self.jsonString(obj, "assistantMessageID") ?? Self.jsonString(obj, "messageID") ?? "msg_stream"
                let ordinal = Self.jsonInt(obj, "ordinal") ?? 0
                let text = Self.jsonString(obj, "text") ?? ""
                let ref = fragmentRef(messageID: msgID, kind: "text", ordinal: ordinal)
                let update = fragments.end(ref, text: text)
                if text.count > update.previous.count {
                    let suffix = String(text.dropFirst(update.previous.count))
                    state.withLock { $0.turnEmittedAssistant = true }
                    emitOutput(commits: [
                        StreamCommit(
                            kind: .assistant,
                            text: suffix,
                            phase: .progress,
                            source: .assistant,
                            messageID: msgID,
                            partID: ref.partID
                        ),
                    ])
                }

            case "session.reasoning.started":
                state.withLock { $0.rootActive = true }

            case "session.reasoning.delta":
                guard thinking else { return }
                let msgID = Self.jsonString(obj, "assistantMessageID") ?? Self.jsonString(obj, "messageID") ?? "msg_stream"
                let ordinal = Self.jsonInt(obj, "ordinal") ?? 0
                let delta = Self.jsonString(obj, "delta") ?? Self.jsonString(obj, "text") ?? ""
                guard !delta.isEmpty else { return }
                let ref = fragmentRef(messageID: msgID, kind: "reasoning", ordinal: ordinal)
                if let update = fragments.delta(ref, delta) {
                    let rendered = update.previous.isEmpty ? "Thinking: \(delta)" : delta
                    emitOutput(commits: [
                        StreamCommit(
                            kind: .reasoning,
                            text: rendered,
                            phase: .progress,
                            source: .reasoning,
                            messageID: msgID,
                            partID: ref.partID
                        ),
                    ])
                }

            case "session.reasoning.ended":
                guard thinking else { return }
                let msgID = Self.jsonString(obj, "assistantMessageID") ?? Self.jsonString(obj, "messageID") ?? "msg_stream"
                let ordinal = Self.jsonInt(obj, "ordinal") ?? 0
                let text = Self.jsonString(obj, "text") ?? ""
                let ref = fragmentRef(messageID: msgID, kind: "reasoning", ordinal: ordinal)
                let update = fragments.end(ref, text: text)
                if text.count > update.previous.count {
                    let suffix = String(text.dropFirst(update.previous.count))
                    let rendered = update.previous.isEmpty ? "Thinking: \(text)" : suffix
                    emitOutput(commits: [
                        StreamCommit(
                            kind: .reasoning,
                            text: rendered,
                            phase: .progress,
                            source: .reasoning,
                            messageID: msgID,
                            partID: ref.partID
                        ),
                    ])
                }

            case "session.tool.input.started":
                let msgID = Self.jsonString(obj, "assistantMessageID") ?? Self.jsonString(obj, "messageID") ?? "msg_stream"
                let toolID = Self.jsonString(obj, "id") ?? "tool"
                let name = Self.jsonString(obj, "name") ?? "tool"
                let created = Int64(event.created ?? 0)
                let key = "\(msgID)\u{0}\(toolID)"
                let part = SessionMessageSchema.AssistantTool(
                    id: toolID,
                    name: name,
                    state: .streaming(SessionMessageSchema.ToolStateStreaming(input: "")),
                    time: SessionMessageSchema.AssistantTool.Time(created: created)
                )
                state.withLock { $0.tools[key] = TrackedTool(part: part, output: "", version: 0, started: false) }

            case "session.tool.called":
                let msgID = Self.jsonString(obj, "assistantMessageID") ?? Self.jsonString(obj, "messageID") ?? "msg_stream"
                let toolID = Self.jsonString(obj, "id") ?? "tool"
                let key = "\(msgID)\u{0}\(toolID)"
                let created = Int64(event.created ?? 0)
                let inputDict = Self.jsonDict(obj["input"])
                let tracked = state.withLock { $0.tools[key] }
                let name = Self.jsonString(obj, "name") ?? tracked?.part.name ?? "tool"
                let part = SessionMessageSchema.AssistantTool(
                    id: toolID,
                    name: name,
                    state: .running(SessionMessageSchema.ToolStateRunning(input: inputDict, metadata: [:])),
                    time: SessionMessageSchema.AssistantTool.Time(created: tracked?.part.time.created ?? created, ran: created)
                )
                renderToolUpdate(messageID: msgID, part: part)

            case "session.tool.progress":
                let msgID = Self.jsonString(obj, "assistantMessageID") ?? Self.jsonString(obj, "messageID") ?? "msg_stream"
                let toolID = Self.jsonString(obj, "id") ?? "tool"
                let key = "\(msgID)\u{0}\(toolID)"
                let tracked = state.withLock { $0.tools[key] }
                let meta = Self.jsonDict(obj["metadata"])
                let existingInput: [String: JSONValue]
                if let prev = tracked {
                    switch prev.part.state {
                    case .running(let s): existingInput = s.input
                    case .completed(let s): existingInput = s.input
                    case .error(let s): existingInput = s.input
                    case .streaming: existingInput = [:]
                    }
                } else {
                    existingInput = [:]
                }
                let created = Int64(event.created ?? 0)
                let part = SessionMessageSchema.AssistantTool(
                    id: toolID,
                    name: Self.jsonString(obj, "name") ?? tracked?.part.name ?? "tool",
                    state: .running(SessionMessageSchema.ToolStateRunning(input: existingInput, metadata: meta)),
                    time: SessionMessageSchema.AssistantTool.Time(
                        created: tracked?.part.time.created ?? created,
                        ran: tracked?.part.time.ran ?? created
                    )
                )
                renderToolUpdate(messageID: msgID, part: part)

            case "session.tool.success", "session.tool.failed":
                let msgID = Self.jsonString(obj, "assistantMessageID") ?? Self.jsonString(obj, "messageID") ?? "msg_stream"
                let toolID = Self.jsonString(obj, "id") ?? "tool"
                let key = "\(msgID)\u{0}\(toolID)"
                let tracked = state.withLock { $0.tools[key] }
                let existingInput: [String: JSONValue]
                if let prev = tracked {
                    switch prev.part.state {
                    case .running(let s): existingInput = s.input
                    case .completed(let s): existingInput = s.input
                    case .error(let s): existingInput = s.input
                    case .streaming: existingInput = [:]
                    }
                } else {
                    existingInput = [:]
                }
                let created = Int64(event.created ?? 0)
                let name = Self.jsonString(obj, "name") ?? tracked?.part.name ?? "tool"
                let meta = Self.jsonDict(obj["metadata"])
                let content = Self.decodeToolContent(obj["content"])
                let toolState: SessionMessageSchema.ToolState
                if event.type == "session.tool.failed" {
                    let errObj = Self.jsonDict(obj["error"])
                    let errMsg = Self.jsonString(errObj, "message") ?? Self.jsonString(obj, "error") ?? "Tool failed"
                    let errType = Self.jsonString(errObj, "type") ?? "tool_error"
                    toolState = .error(SessionMessageSchema.ToolStateError(
                        input: existingInput,
                        error: SessionErrorSchema.Error(type: errType, message: errMsg),
                        content: content.isEmpty ? nil : content,
                        metadata: meta.isEmpty ? nil : meta
                    ))
                } else {
                    let nonEmptyContent = content.isEmpty ? [SessionMessageSchema.ToolContent.text("")] : content
                    toolState = .completed(SessionMessageSchema.ToolStateCompleted(
                        input: existingInput,
                        content: nonEmptyContent,
                        metadata: meta.isEmpty ? nil : meta
                    ))
                }
                let part = SessionMessageSchema.AssistantTool(
                    id: toolID,
                    name: name,
                    state: toolState,
                    time: SessionMessageSchema.AssistantTool.Time(
                        created: tracked?.part.time.created ?? created,
                        ran: tracked?.part.time.ran,
                        completed: created
                    )
                )
                renderToolUpdate(messageID: msgID, part: part)

            case "session.step.ended":
                let tokens = Self.jsonDict(obj["tokens"])
                let cache = Self.jsonDict(tokens["cache"])
                let total = (Self.jsonInt(tokens, "input") ?? 0)
                    + (Self.jsonInt(tokens, "output") ?? 0)
                    + (Self.jsonInt(tokens, "reasoning") ?? 0)
                    + (Self.jsonInt(cache, "read") ?? 0)
                    + (Self.jsonInt(cache, "write") ?? 0)
                let cost = Self.jsonDouble(obj, "cost")
                if total > 0 || (cost ?? 0) > 0 {
                    emitOutput(updates: [
                        .streamPatch(FooterPatch(usage: FooterUsage(tokens: total, cost: cost))),
                    ])
                }

            case "session.step.failed":
                let msgID = Self.jsonString(obj, "assistantMessageID") ?? Self.jsonString(obj, "messageID") ?? "msg_error"
                let errObj = Self.jsonDict(obj["error"])
                let errMsg = Self.jsonString(errObj, "message") ?? Self.jsonString(obj, "error") ?? "Session execution failed"
                let shouldEmit = state.withLock { $0.renderedErrorIDs.insert(msgID).inserted }
                if shouldEmit {
                    emitOutput(commits: [
                        StreamCommit(
                            kind: .error,
                            text: errMsg,
                            phase: .start,
                            source: .system,
                            messageID: msgID
                        ),
                    ])
                }

            case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted", "session.idle":
                if event.type == "session.execution.failed" {
                    let errObj = Self.jsonDict(obj["error"])
                    let errMsg = Self.jsonString(errObj, "message") ?? Self.jsonString(obj, "error") ?? "Session execution failed"
                    let errKey = event.id.isEmpty ? "exec_err" : event.id
                    if state.withLock({ $0.renderedErrorIDs.insert(errKey).inserted }) {
                        emitOutput(commits: [
                            StreamCommit(kind: .error, text: errMsg, phase: .start, source: .system, messageID: errKey),
                        ])
                    }
                }
                finishActiveTurn(emitIdle: true)

            case "session.status":
                let statusObj = Self.jsonDict(obj["status"])
                let kind = Self.jsonString(statusObj, "type") ?? Self.jsonString(obj, "status") ?? ""
                if kind == "idle" {
                    finishActiveTurn(emitIdle: true)
                } else if kind == "busy" || kind == "running" {
                    state.withLock { $0.rootActive = true }
                    emitOutput(updates: [.streamPatch(FooterPatch(phase: .running, status: "assistant responding"))])
                }

            default:
                break
            }
        }

        private func renderToolUpdate(messageID: String, part rawPart: SessionMessageSchema.AssistantTool) {
            let part = normalizeTool(rawPart)
            let key = "\(messageID)\u{0}\(part.id)"
            if state.withLock({ $0.finishedTools.contains(key) }) { return }
            let previous = state.withLock { $0.tools[key] }

            switch part.state {
            case .streaming:
                state.withLock { $0.tools[key] = TrackedTool(part: part, output: "", version: 0, started: false) }

            case .running(let running):
                let output = Self.jsonString(running.metadata, "output") ?? ""
                let isPrefix = previous.map { output.hasPrefix($0.output) } ?? false
                let version = (previous != nil && !isPrefix) ? (previous!.version + 1) : (previous?.version ?? 0)
                let delta = (previous != nil && isPrefix) ? String(output.dropFirst(previous!.output.count)) : output
                let wasStarted = previous?.started == true
                if tools {
                    if !wasStarted {
                        emitOutput(
                            commits: [toolCommit(part, messageID: messageID, phase: .start, directory: directory, version: version)],
                            updates: [.streamPatch(FooterPatch(phase: .running, status: "running \(part.name)"))]
                        )
                    }
                    if !delta.isEmpty {
                        emitOutput(commits: [
                            toolCommit(part, messageID: messageID, phase: .progress, value: delta, directory: directory, version: version),
                        ])
                    }
                }
                state.withLock {
                    $0.tools[key] = TrackedTool(part: part, output: output, version: version, started: wasStarted || tools)
                }

            case .completed(let completed):
                let output = toolOutputText(part.name, content: completed.content)
                let isPrefix = previous.map { output.hasPrefix($0.output) } ?? false
                let version = (previous != nil && !isPrefix) ? (previous!.version + 1) : (previous?.version ?? 0)
                let delta = (previous != nil && isPrefix) ? String(output.dropFirst(previous!.output.count)) : output
                state.withLock {
                    $0.finishedTools.insert(key)
                    $0.tools.removeValue(forKey: key)
                }
                if tools {
                    var commits: [StreamCommit] = []
                    if previous?.started != true {
                        commits.append(toolCommit(part, messageID: messageID, phase: .start, directory: directory, version: version))
                    }
                    let phase = toolFinalPhase(part)
                    commits.append(toolCommit(
                        part,
                        messageID: messageID,
                        phase: phase,
                        value: phase == .progress ? delta : nil,
                        directory: directory,
                        version: version
                    ))
                    emitOutput(commits: commits)
                }

            case .error(let errState):
                let output = toolOutputText(part.name, content: errState.content)
                let isPrefix = previous.map { output.hasPrefix($0.output) } ?? false
                let version = (previous != nil && !isPrefix) ? (previous!.version + 1) : (previous?.version ?? 0)
                let delta = (previous != nil && isPrefix) ? String(output.dropFirst(previous!.output.count)) : output
                state.withLock {
                    $0.finishedTools.insert(key)
                    $0.tools.removeValue(forKey: key)
                }
                if tools {
                    var commits: [StreamCommit] = []
                    if previous?.started != true {
                        commits.append(toolCommit(part, messageID: messageID, phase: .start, directory: directory, version: version))
                    }
                    if !delta.isEmpty {
                        commits.append(toolCommit(part, messageID: messageID, phase: .progress, value: delta, directory: directory, version: version))
                    }
                    commits.append(toolCommit(part, messageID: messageID, phase: .final, directory: directory, version: version))
                    emitOutput(commits: commits)
                }
            }
        }

        private func reconcileProjectedMessages(sessionID: String, after afterMessageID: String?) async {
            guard let page = try? await client.message.list(
                MessageListInput(sessionID: sessionID, limit: replayLimit ?? 200, order: .desc)
            ) else {
                return
            }
            var messages: [SessionMessageSchema.Info] = []
            for item in page.data {
                if let afterMessageID, item.id.rawValue == afterMessageID {
                    break
                }
                messages.append(item)
            }
            for message in messages.reversed() {
                switch message {
                case .assistant(let assistant):
                    var textOrdinal = 0
                    var reasoningOrdinal = 0
                    for item in assistant.content {
                        switch item {
                        case .text(let textPart):
                            let ref = fragmentRef(messageID: assistant.id.rawValue, kind: "text", ordinal: textOrdinal)
                            textOrdinal += 1
                            let update = fragments.project(ref, text: textPart.text, visible: true)
                            if textPart.text.count > update.previous.count {
                                let suffix = String(textPart.text.dropFirst(update.previous.count))
                                emitOutput(commits: [
                                    StreamCommit(
                                        kind: .assistant,
                                        text: suffix,
                                        phase: .progress,
                                        source: .assistant,
                                        messageID: assistant.id.rawValue,
                                        partID: ref.partID
                                    ),
                                ])
                            }
                        case .reasoning(let reasoningPart):
                            let ref = fragmentRef(messageID: assistant.id.rawValue, kind: "reasoning", ordinal: reasoningOrdinal)
                            reasoningOrdinal += 1
                            let update = fragments.project(ref, text: reasoningPart.text, visible: thinking)
                            if thinking && reasoningPart.text.count > update.previous.count {
                                let suffix = String(reasoningPart.text.dropFirst(update.previous.count))
                                let rendered = update.previous.isEmpty ? "Thinking: \(reasoningPart.text)" : suffix
                                emitOutput(commits: [
                                    StreamCommit(
                                        kind: .reasoning,
                                        text: rendered,
                                        phase: .progress,
                                        source: .reasoning,
                                        messageID: assistant.id.rawValue,
                                        partID: ref.partID
                                    ),
                                ])
                            }
                        case .tool(let toolPart):
                            renderToolUpdate(messageID: assistant.id.rawValue, part: toolPart)
                        }
                    }
                    if let err = assistant.error, state.withLock({ $0.renderedErrorIDs.insert(assistant.id.rawValue).inserted }) {
                        emitOutput(commits: [
                            StreamCommit(kind: .error, text: err.message, phase: .start, source: .system, messageID: assistant.id.rawValue),
                        ])
                    }
                default:
                    break
                }
            }
        }

        private static func jsonDict(_ value: JSONValue?) -> [String: JSONValue] {
            if case .object(let dict) = value { return dict }
            return [:]
        }

        private static func jsonString(_ dict: [String: JSONValue], _ key: String) -> String? {
            if case .string(let s) = dict[key] { return s }
            return nil
        }

        private static func jsonInt(_ dict: [String: JSONValue], _ key: String) -> Int? {
            switch dict[key] {
            case .int(let n): return Int(n)
            case .double(let d): return Int(d)
            default: return nil
            }
        }

        private static func jsonDouble(_ dict: [String: JSONValue], _ key: String) -> Double? {
            switch dict[key] {
            case .double(let d): return d
            case .int(let n): return Double(n)
            default: return nil
            }
        }

        private static func decodeToolContent(_ value: JSONValue?) -> [SessionMessageSchema.ToolContent] {
            guard case .array(let items) = value else { return [] }
            return items.compactMap { item in
                let dict = jsonDict(item)
                let type = jsonString(dict, "type")
                if type == "file", let uri = jsonString(dict, "uri"), let mime = jsonString(dict, "mime") {
                    return .file(uri: uri, mime: mime, name: jsonString(dict, "name"))
                }
                if let text = jsonString(dict, "text") {
                    return .text(text)
                }
                return nil
            }
        }
    }

    // parity: tui/src/mini/stream-v2.transport.ts#createSessionTransport [status=adapted hash=69202b282d92]
    public static func createSessionTransport(
        sessionID: String? = nil,
        footer: any FooterApi,
        client: OpenCodeClient? = nil,
        directory: String? = nil,
        thinking: Bool = true,
        tools: Bool = true,
        replay: Bool = false,
        replayLimit: Int? = nil,
        onCommit: (@Sendable (StreamCommit) -> Void)? = nil,
        onSessionTitle: (@Sendable (String) -> Void)? = nil
    ) async -> SessionTransport {
        guard let client else {
            let tracker = createSubagentTracker(SubagentTrackerInput(
                sessionID: sessionID ?? "",
                thinking: thinking,
                directory: directory
            ) {
                footer.event(.streamSubagent(FooterSubagentState()))
            })
            return SessionTransport(
                runPromptTurn: { _, _ in
                    footer.event(.turnIdle)
                    throw ClientError(reason: .transport, detail: "No OpenCode server client configured")
                },
                admitPromptTurn: { _, _ in
                    throw ClientError(reason: .transport, detail: "No OpenCode server client configured")
                },
                waitForIdle: { await footer.idle() },
                interruptActiveTurn: { footer.event(.turnIdle) },
                selectSubagent: { tracker.select($0) },
                replayOnResize: { input in
                    await input.reset()
                    for row in input.localRows() { footer.append(row.commit) }
                    return true
                },
                close: { tracker.close() }
            )
        }

        let live = MiniLiveSessionTransport(
            sessionID: sessionID,
            footer: footer,
            client: client,
            directory: directory,
            thinking: thinking,
            tools: tools,
            replay: replay,
            replayLimit: replayLimit,
            onCommit: onCommit,
            onSessionTitle: onSessionTitle
        )
        return SessionTransport(
            runPromptTurn: { turn, admitted in
                try await live.runPromptTurn(turn, admitted: admitted)
            },
            admitPromptTurn: { turn, delivery in
                try await live.admitPromptTurn(turn, delivery: delivery)
            },
            waitForIdle: { await live.waitForIdle() },
            interruptActiveTurn: { await live.interruptActiveTurn() },
            selectSubagent: { live.selectSubagent($0) },
            replayOnResize: { input in
                await live.replayOnResize(input)
            },
            close: { await live.close() }
        )
    }

    // MARK: - Footer Width, Menu, Prompt, Panels & RunFooter (`footer*.ts`, `footer*.tsx`)

    public struct FooterAction: Equatable, Hashable, Sendable {
        public let key: String
        public let label: String
        public let expanded: String?

        public init(key: String, label: String, expanded: String? = nil) {
            self.key = key
            self.label = label
            self.expanded = expanded
        }
    }

    // parity: tui/src/mini/footer.width.ts#FooterStatuslineGroup [status=implemented hash=27306991492a]
    public struct FooterStatuslineGroup: Equatable, Hashable, Sendable {
        public struct Part: Equatable, Hashable, Sendable {
            public let text: String
            public let tone: String

            public init(text: String, tone: String) {
                self.text = text
                self.tone = tone
            }
        }

        public let id: String
        public let parts: [Part]

        public init(id: String, parts: [Part]) {
            self.id = id
            self.parts = parts
        }
    }

    // parity: tui/src/mini/footer.width.ts#footerStatuslinePolicy [status=implemented hash=d6128539688f]
    public static func footerStatuslinePolicy(
        width: Int,
        mono: Bool = false,
        status: (text: String, expanded: String?)? = nil,
        escape: FooterAction? = nil,
        work: [(id: String, action: FooterAction)] = [],
        model: (name: String, variant: String?)? = nil,
        agent: String? = nil,
        context: (compact: String, full: String)? = nil,
        cost: String? = nil,
        provider: String? = nil,
        menu: FooterAction? = nil,
        spinner: String? = nil
    ) -> (groups: [FooterStatuslineGroup], text: String) {
        func makeGroup(_ id: String, _ text: String, _ tone: String = "muted") -> FooterStatuslineGroup {
            FooterStatuslineGroup(id: id, parts: [.init(text: text, tone: tone)])
        }
        func makeAction(_ id: String, _ act: FooterAction, expanded: Bool = false) -> FooterStatuslineGroup {
            FooterStatuslineGroup(id: id, parts: [
                .init(text: act.key, tone: "text"),
                .init(text: " \(expanded ? (act.expanded ?? act.label) : act.label)", tone: "muted"),
            ])
        }
        func makeIdentity(_ cells: Int) -> FooterStatuslineGroup {
            let name = model!.name
            let ellipsis = mono ? "..." : "…"
            let display: String
            if cells < Int.max && stringWidth(name) > cells + stringWidth(ellipsis) {
                display = takeDisplayWidth(name, width: cells).trimmingCharacters(in: .whitespaces) + ellipsis
            } else {
                display = name
            }
            let variantSuffix = model!.variant.map { " [\($0)]" } ?? ""
            return makeGroup("model", display + variantSuffix, "text")
        }

        var selected: [String: FooterStatuslineGroup] = [:]
        if let spinner, !spinner.isEmpty { selected["spinner"] = makeGroup("spinner", spinner, "text") }
        if let status, !status.text.isEmpty { selected["status"] = makeGroup("status", status.text, "status") }
        if let escape { selected["escape"] = makeAction("escape", escape) }

        let order = ["spinner", "status", "escape", "queued", "subagents", "agent", "model", "context", "provider", "cost", "menu"]
        func place() -> (groups: [FooterStatuslineGroup], text: String) {
            let groups = order.compactMap { selected[$0] }
            let sep = mono ? " - " : " · "
            var text = ""
            for (idx, item) in groups.enumerated() {
                if idx > 0 { text += groups[idx - 1].id == "spinner" ? " " : sep }
                text += item.parts.map(\.text).joined()
            }
            return (groups, text)
        }

        var layout = place()
        if stringWidth(layout.text) > width || layout.text.contains("\n") { return layout }

        var stages: [FooterStatuslineGroup] = []
        for item in work { stages.append(makeAction(item.id, item.action)) }
        if model != nil { stages.append(makeIdentity(8)) }
        if let agent, !agent.isEmpty { stages.append(makeGroup("agent", agent, "agent")) }
        if let context { stages.append(makeGroup("context", context.compact)) }
        if model != nil { stages.append(makeIdentity(24)) }
        if let context { stages.append(makeGroup("context", context.full)) }
        if let cost, !cost.isEmpty { stages.append(makeGroup("cost", cost)) }
        if let provider, !provider.isEmpty { stages.append(makeGroup("provider", provider)) }
        if let menu { stages.append(makeAction("menu", menu)) }
        if model != nil { stages.append(makeIdentity(Int.max)) }
        for item in work where item.action.expanded != nil {
            stages.append(makeAction(item.id, item.action, expanded: true))
        }
        if let expandedStatus = status?.expanded { stages.append(makeGroup("status", expandedStatus, "status")) }

        for stage in stages {
            let prev = selected[stage.id]
            selected[stage.id] = stage
            let next = place()
            if stringWidth(next.text) > width || next.text.contains("\n") {
                selected[stage.id] = prev
                break
            }
            layout = next
        }
        return layout
    }

    // parity: tui/src/mini/footer.menu.tsx#FOOTER_MENU_ROWS [status=implemented hash=195ea3eb16ed]
    public static let FOOTER_MENU_ROWS = 8

    // parity: tui/src/mini/footer.menu.tsx#FOOTER_COMPACT_WIDTH [status=implemented hash=fe783265c4df]
    public static let FOOTER_COMPACT_WIDTH = 40

    // parity: tui/src/mini/footer.menu.tsx#footerMenuText [status=implemented hash=78ec363d8dd7]
    public static func footerMenuText(_ text: String, width: Int, mono: Bool = false) -> String {
        if stringWidth(text) <= width { return text }
        if !mono {
            if width <= 1 { return width == 1 ? "…" : "" }
            return takeDisplayWidth(text, width: width - 1) + "…"
        }
        let suffix = String(repeating: ".", count: min(3, max(0, width)))
        return takeDisplayWidth(text, width: max(0, width - suffix.count)) + suffix
    }

    // parity: tui/src/mini/footer.menu.tsx#RunFooterMenuItem [status=implemented hash=edce46b42fd0]
    public struct RunFooterMenuItem: Equatable, Hashable, Sendable {
        public let display: String
        public let current: Bool
        public let description: String?
        public let category: String?
        public let footer: String?
        public let footerTone: String?

        public init(
            display: String,
            current: Bool = false,
            description: String? = nil,
            category: String? = nil,
            footer: String? = nil,
            footerTone: String? = nil
        ) {
            self.display = display
            self.current = current
            self.description = description
            self.category = category
            self.footer = footer
            self.footerTone = footerTone
        }
    }

    public final class FooterMenuState: @unchecked Sendable {
        private struct State: Sendable {
            var count: Int
            var limit: Int
            var selected: Int = 0
            var offset: Int = 0
        }

        private let state: Mutex<State>

        public init(count: Int, limit: Int = FOOTER_MENU_ROWS) {
            self.state = Mutex(State(count: max(0, count), limit: max(1, limit)))
        }

        public var selected: Int { state.withLock { $0.selected } }
        public var offset: Int { state.withLock { $0.offset } }
        public var rows: Int { state.withLock { max(1, min($0.limit, $0.count)) } }

        public func reveal(_ index: Int) {
            state.withLock { s in
                guard s.count > 0 else { s.selected = 0; s.offset = 0; return }
                s.selected = max(0, min(s.count - 1, index))
                if s.selected < s.offset { s.offset = s.selected }
                else if s.selected >= s.offset + s.limit { s.offset = s.selected - s.limit + 1 }
            }
        }

        public func move(_ dir: Int) {
            let d = dir >= 0 ? 1 : -1
            reveal(selected + d)
        }

        public func reset() {
            state.withLock { $0.selected = 0; $0.offset = 0 }
        }
    }

    // parity: tui/src/mini/footer.menu.tsx#createFooterMenuState [status=implemented hash=87cadad870f1]
    public static func createFooterMenuState(count: Int, limit: Int = FOOTER_MENU_ROWS) -> FooterMenuState {
        FooterMenuState(count: count, limit: limit)
    }

    // parity: tui/src/mini/footer.menu.tsx#RunFooterMenu [status=adapted hash=01ced16f8abd]
    public static func RunFooterMenu(
        ctx: any RenderContext,
        items: [RunFooterMenuItem],
        selected: Int = 0,
        offset: Int = 0,
        rows: Int = FOOTER_MENU_ROWS,
        empty: String = "No matching items",
        mono: Bool = false,
        theme: RunFooterTheme = RUN_THEME_FALLBACK.footer
    ) -> BoxRenderable {
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(
            width: .percent(100),
            height: .point(Float(max(1, rows))),
            flexDirection: .column
        ))
        if items.isEmpty {
            box.add(TextRenderable(ctx: ctx, options: TextOptions(
                content: .string("\(mono ? "|" : "┃") \(empty)"),
                fg: .rgba(theme.muted)
            )))
            return box
        }
        let end = min(items.count, offset + max(1, rows))
        for idx in max(0, offset)..<end {
            let item = items[idx]
            let active = idx == selected
            let marker = active ? (mono ? ">" : "▌") : " "
            let line = "\(marker) \(item.display)\(item.description.map { "  \($0)" } ?? "")"
            box.add(TextRenderable(ctx: ctx, options: TextOptions(
                content: .string(line),
                fg: .rgba(active ? theme.actionFocusedText : theme.formfieldText),
                bg: active ? .rgba(theme.actionFocusedBg) : nil,
                attributes: active ? createTextAttributes(bold: true) : TextAttributes.none
            )))
        }
        return box
    }

    // parity: tui/src/mini/footer.prompt.tsx#TEXTAREA_MIN_ROWS [status=implemented hash=7147299f0091]
    public static let TEXTAREA_MIN_ROWS = 1

    private static let textareaMaxRows = 6

    // parity: tui/src/mini/footer.prompt.tsx#PROMPT_MAX_ROWS [status=implemented hash=0cf70f514460]
    public static let PROMPT_MAX_ROWS = textareaMaxRows + FOOTER_MENU_ROWS

    public struct FooterPromptLayout: Equatable, Hashable, Sendable {
        public let padding: Int
        public let textarea: Int
        public let menu: Int
        public let images: Int
        public let rows: Int
    }

    // parity: tui/src/mini/footer.prompt.tsx#footerPromptLayout [status=implemented hash=339f5e8a3c39]
    public static func footerPromptLayout(
        height: Int,
        lines: Int = TEXTAREA_MIN_ROWS,
        options: Int = 0,
        statusRows: Int = 1,
        images: Bool = false
    ) -> FooterPromptLayout {
        let padding = height >= PROMPT_MAX_ROWS + 4 ? 1 : 0
        let available = max(1, height - 1 - statusRows - padding * 2)
        let preview = (images && options == 0) ? min(4, available - min(textareaMaxRows, max(1, lines))) : 0
        let imageRows = preview >= 3 ? preview : 0
        let textarea = max(1, min(textareaMaxRows, available - imageRows - (options > 0 ? 1 : 0)))
        let rows = min(textarea, max(1, lines))
        let menu = options > 0 ? max(1, min(FOOTER_MENU_ROWS, min(options, available - rows))) : 0
        return FooterPromptLayout(padding: padding, textarea: textarea, menu: menu, images: imageRows, rows: rows + menu + imageRows)
    }

    // parity: tui/src/mini/footer.prompt.tsx#PromptState [status=adapted hash=2af88bcce6f6]
    public struct PromptState: Equatable, Sendable {
        public var text: String
        public var history: PromptHistoryState
        public var command: PromptCommandSelection?
        public var autocompleteItems: [RunFooterMenuItem]

        public init(
            text: String = "",
            history: PromptHistoryState = createPromptHistory(),
            command: PromptCommandSelection? = nil,
            autocompleteItems: [RunFooterMenuItem] = []
        ) {
            self.text = text
            self.history = history
            self.command = command
            self.autocompleteItems = autocompleteItems
        }
    }

    // parity: tui/src/mini/footer.prompt.tsx#selectedCommand [status=implemented hash=21ac5cbb29b1]
    public static func selectedCommand(_ text: String, command: PromptCommandSelection?) -> PromptCommandSelection? {
        guard let command, let head = TUIPrompt.parseSlashHead(text), head.name == command.name else { return nil }
        return PromptCommandSelection(name: command.name, arguments: head.arguments, source: command.source)
    }

    // parity: tui/src/mini/footer.prompt.tsx#createPromptState [status=adapted hash=a4f10463269f]
    public static func createPromptState(history: [RunPrompt] = []) -> PromptState {
        PromptState(history: createPromptHistory(history))
    }

    // parity: tui/src/mini/footer.prompt.tsx#RunPromptBody [status=adapted hash=0110516b9c75]
    public static func RunPromptBody(
        ctx: any RenderContext,
        text: String = "",
        placeholder: String = "Ask anything...",
        mono: Bool = false,
        theme: RunFooterTheme = RUN_THEME_FALLBACK.footer
    ) -> BoxRenderable {
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: "mini-prompt-body",
            width: .percent(100),
            height: .point(1),
            backgroundColor: .rgba(theme.shade)
        ))
        let display = text.isEmpty ? placeholder : text
        box.add(TextRenderable(ctx: ctx, options: TextOptions(
            content: .string("\(mono ? ">" : "›") \(display)"),
            fg: .rgba(text.isEmpty ? theme.muted : theme.text)
        )))
        return box
    }

    private static let panelListRows = 10
    private static let panelFrameRows = 6
    private static let subagentListRows = 12

    // parity: tui/src/mini/footer.command.tsx#RUN_COMMAND_PANEL_ROWS [status=implemented hash=2e5a1f083f99]
    public static let RUN_COMMAND_PANEL_ROWS = panelListRows + panelFrameRows

    // parity: tui/src/mini/footer.command.tsx#RUN_SUBAGENT_PANEL_ROWS [status=implemented hash=48e65fec546c]
    public static let RUN_SUBAGENT_PANEL_ROWS = subagentListRows + panelFrameRows

    // parity: tui/src/mini/footer.command.tsx#footerPanelLayout [status=implemented hash=b7ae4a50cb2e]
    public static func footerPanelLayout(height: Int, limit: Int = 10) -> (compact: Bool, frame: Int, limit: Int) {
        let available = max(3, height - 1)
        let compact = available < limit + panelFrameRows
        let frame = compact ? 2 : panelFrameRows
        return (compact: compact, frame: frame, limit: max(1, min(limit, available - frame)))
    }

    private static func makePanelBox(
        ctx: any RenderContext,
        id: String,
        title: String,
        items: [RunFooterMenuItem],
        theme: RunFooterTheme
    ) -> BoxRenderable {
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: id, width: .percent(100), flexDirection: .column, backgroundColor: .rgba(theme.pane)
        ))
        box.add(TextRenderable(ctx: ctx, options: TextOptions(
            content: .string(title), fg: .rgba(theme.text), attributes: createTextAttributes(bold: true)
        )))
        box.add(RunFooterMenu(ctx: ctx, items: items, rows: min(max(1, items.count), FOOTER_MENU_ROWS), theme: theme))
        return box
    }

    // parity: tui/src/mini/footer.command.tsx#RunCommandMenuBody [status=adapted hash=58c88c235847]
    public static func RunCommandMenuBody(
        ctx: any RenderContext,
        items: [RunFooterMenuItem] = [],
        theme: RunFooterTheme = RUN_THEME_FALLBACK.footer
    ) -> BoxRenderable {
        makePanelBox(ctx: ctx, id: "mini-command-menu", title: "Commands", items: items, theme: theme)
    }

    // parity: tui/src/mini/footer.command.tsx#RunAgentSelectBody [status=adapted hash=adec20fad097]
    public static func RunAgentSelectBody(
        ctx: any RenderContext,
        agents: [RunAgent] = [],
        current: String? = nil,
        theme: RunFooterTheme = RUN_THEME_FALLBACK.footer
    ) -> BoxRenderable {
        let items = agents.map { RunFooterMenuItem(display: $0.name, current: $0.id == current, description: $0.description) }
        return makePanelBox(ctx: ctx, id: "mini-agent-select", title: "Select Agent", items: items, theme: theme)
    }

    // parity: tui/src/mini/footer.command.tsx#RunSettingsBody [status=adapted hash=5e029d336e64]
    public static func RunSettingsBody(
        ctx: any RenderContext,
        settings: MiniSettings = MiniSettings(),
        theme: RunFooterTheme = RUN_THEME_FALLBACK.footer
    ) -> BoxRenderable {
        let items = [
            RunFooterMenuItem(display: "Verbosity", description: verbosityLabel(matchMiniVerbosity(settings))),
            RunFooterMenuItem(display: "Thinking", description: settings.thinking.rawValue),
            RunFooterMenuItem(display: "Tools", description: settings.tools.rawValue),
            RunFooterMenuItem(display: "Monochrome", description: settings.mono ? "on" : "off"),
        ]
        return makePanelBox(ctx: ctx, id: "mini-settings", title: "Settings", items: items, theme: theme)
    }

    // parity: tui/src/mini/footer.command.tsx#RunSubagentSelectBody [status=adapted hash=74aa63b59b6d]
    public static func RunSubagentSelectBody(
        ctx: any RenderContext,
        tabs: [FooterSubagentTab] = [],
        theme: RunFooterTheme = RUN_THEME_FALLBACK.footer
    ) -> BoxRenderable {
        let items = tabs.map { RunFooterMenuItem(display: $0.label, description: $0.description, footer: $0.status.rawValue) }
        return makePanelBox(ctx: ctx, id: "mini-subagent-select", title: "Subagents", items: items, theme: theme)
    }

    // parity: tui/src/mini/footer.command.tsx#RunQueuedPromptSelectBody [status=adapted hash=5a2256a79d14]
    public static func RunQueuedPromptSelectBody(
        ctx: any RenderContext,
        prompts: [FooterQueuedPrompt] = [],
        theme: RunFooterTheme = RUN_THEME_FALLBACK.footer
    ) -> BoxRenderable {
        let items = prompts.map { RunFooterMenuItem(display: $0.prompt.text, footer: $0.delivery.rawValue) }
        return makePanelBox(ctx: ctx, id: "mini-queued-select", title: "Queued Prompts", items: items, theme: theme)
    }

    // parity: tui/src/mini/footer.command.tsx#RunVariantSelectBody [status=adapted hash=d9e4f34b4fa1]
    public static func RunVariantSelectBody(
        ctx: any RenderContext,
        variants: [String] = [],
        current: String? = nil,
        theme: RunFooterTheme = RUN_THEME_FALLBACK.footer
    ) -> BoxRenderable {
        let items = [RunFooterMenuItem(display: "Default", current: current == nil)]
            + variants.map { RunFooterMenuItem(display: $0, current: $0 == current) }
        return makePanelBox(ctx: ctx, id: "mini-variant-select", title: "Reasoning Variant", items: items, theme: theme)
    }

    // parity: tui/src/mini/footer.command.tsx#RunModelSelectBody [status=adapted hash=b2c5fff0c78c]
    public static func RunModelSelectBody(
        ctx: any RenderContext,
        providers: [RunProvider] = [],
        current: PromptModelSelection? = nil,
        theme: RunFooterTheme = RUN_THEME_FALLBACK.footer
    ) -> BoxRenderable {
        var items: [RunFooterMenuItem] = []
        for p in providers {
            for (mid, m) in p.models.sorted(by: { $0.key < $1.key }) {
                items.append(RunFooterMenuItem(
                    display: m.name ?? mid,
                    current: current?.providerID == p.id && current?.modelID == mid,
                    category: p.name
                ))
            }
        }
        return makePanelBox(ctx: ctx, id: "mini-model-select", title: "Select Model", items: items, theme: theme)
    }

    // parity: tui/src/mini/footer.form.tsx#RunFormBody [status=adapted hash=4aae3ba1864c]
    public static func RunFormBody(
        ctx: any RenderContext,
        request: MiniFormRequest,
        state: FormBodyState,
        theme: RunFooterTheme = RUN_THEME_FALLBACK.footer
    ) -> BoxRenderable {
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: "mini-form-body", width: .percent(100), flexDirection: .column, backgroundColor: .rgba(theme.pane)
        ))
        box.add(TextRenderable(ctx: ctx, options: TextOptions(
            content: .string(request.title), fg: .rgba(theme.text), attributes: createTextAttributes(bold: true)
        )))
        if let field = formCurrent(request.form, state: state) {
            box.add(TextRenderable(ctx: ctx, options: TextOptions(
                content: .string(fieldLabel(field)), fg: .rgba(theme.muted)
            )))
        }
        return box
    }

    // parity: tui/src/mini/footer.permission.tsx#RejectField [status=adapted hash=4e63e2b3b3da]
    public static func RejectField(
        ctx: any RenderContext,
        message: String = "",
        theme: RunFooterTheme = RUN_THEME_FALLBACK.footer
    ) -> BoxRenderable {
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(id: "mini-permission-reject", width: .percent(100)))
        box.add(TextRenderable(ctx: ctx, options: TextOptions(
            content: .string(message.isEmpty ? "Tell OpenCode what to do differently" : message),
            fg: .rgba(message.isEmpty ? theme.muted : theme.text)
        )))
        return box
    }

    // parity: tui/src/mini/footer.permission.tsx#RunPermissionBody [status=adapted hash=a9df5a3536d0]
    public static func RunPermissionBody(
        ctx: any RenderContext,
        request: MiniPermissionRequest,
        state: PermissionBodyState,
        theme: RunFooterTheme = RUN_THEME_FALLBACK.footer
    ) -> BoxRenderable {
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: "mini-permission-body", width: .percent(100), flexDirection: .column, backgroundColor: .rgba(theme.pane)
        ))
        let info = permissionInfo(request)
        box.add(TextRenderable(ctx: ctx, options: TextOptions(
            content: .string("△ Permission required · \(info.title)"),
            fg: .rgba(theme.warning)
        )))
        if state.stage == .reject {
            box.add(RejectField(ctx: ctx, message: state.message, theme: theme))
        } else {
            let choices = permissionOptions(state.stage)
                .map { $0 == state.selected ? "[\(permissionLabel($0))]" : permissionLabel($0) }
                .joined(separator: "  ")
            box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(choices), fg: .rgba(theme.text))))
        }
        return box
    }

    // parity: tui/src/mini/footer.subagent.tsx#SUBAGENT_INSPECTOR_ROWS [status=implemented hash=5cb85f3a78e3]
    public static let SUBAGENT_INSPECTOR_ROWS = 14

    // parity: tui/src/mini/footer.subagent.tsx#RunFooterSubagentBody [status=adapted hash=5de503c1c6f3]
    public static func RunFooterSubagentBody(
        ctx: any RenderContext,
        tab: FooterSubagentTab,
        detail: FooterSubagentDetail? = nil,
        theme: RunFooterTheme = RUN_THEME_FALLBACK.footer
    ) -> BoxRenderable {
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: "mini-subagent-\(tab.sessionID)", width: .percent(100), flexDirection: .column, backgroundColor: .rgba(theme.pane)
        ))
        box.add(TextRenderable(ctx: ctx, options: TextOptions(
            content: .string("\(tab.label) · \(tab.status.rawValue)"),
            fg: .rgba(theme.text),
            attributes: createTextAttributes(bold: true)
        )))
        for commit in (detail?.commits ?? []).suffix(6) {
            box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(commit.text), fg: .rgba(theme.muted))))
        }
        return box
    }

    // parity: tui/src/mini/footer.view.tsx#RunFooterView [status=adapted hash=4b899aa7dc2f]
    public static func RunFooterView(
        ctx: any RenderContext,
        state: FooterState,
        view: FooterView = .prompt,
        promptText: String = "",
        agent: String? = nil,
        width: Int = 80,
        mono: Bool = false,
        theme: RunFooterTheme = RUN_THEME_FALLBACK.footer
    ) -> BoxRenderable {
        let root = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: "mini-footer-view",
            width: .percent(100),
            flexDirection: .column,
            backgroundColor: .rgba(theme.surface)
        ))
        switch view {
        case .prompt:
            root.add(RunPromptBody(ctx: ctx, text: promptText, mono: mono, theme: theme))
        case .permission(let req):
            root.add(RunPermissionBody(ctx: ctx, request: req, state: createPermissionBodyState(req), theme: theme))
        case .form(let req):
            root.add(RunFormBody(ctx: ctx, request: req, state: createFormBodyState(req.form), theme: theme))
        }
        let statusText = state.status.isEmpty ? blockerStatus(view) : state.status
        let statusline = footerStatuslinePolicy(
            width: width,
            mono: mono,
            status: statusText.isEmpty ? nil : (text: statusText, expanded: nil),
            model: state.model.isEmpty ? nil : (name: state.model, variant: nil),
            agent: agent
        )
        root.add(TextRenderable(ctx: ctx, options: TextOptions(
            id: "mini-footer-statusline",
            content: .string(statusline.text),
            fg: .rgba(theme.muted),
            wrapMode: TextWrapMode.none
        )))
        return root
    }

    // parity: tui/src/mini/footer.ts#resolveRunAgent [status=implemented hash=3c73da81de5f]
    public static func resolveRunAgent(_ agents: [RunAgent], current: String?) -> RunAgent? {
        let selectable = agents.filter { $0.mode != .subagent && !$0.hidden }
        guard let current else { return selectable.first }
        return selectable.first { $0.id == current }
    }

    // parity: tui/src/mini/footer.ts#coalesceProgressCommit [status=implemented hash=6ff3d1f9257a]
    public static func coalesceProgressCommit(_ previous: StreamCommit, _ current: StreamCommit) -> StreamCommit? {
        guard previous.phase == .progress,
              current.phase == .progress,
              previous.kind == current.kind,
              previous.source == current.source,
              previous.messageID == current.messageID,
              previous.partID == current.partID,
              previous.tool == current.tool,
              previous.toolState == current.toolState
        else { return nil }
        var merged = current
        merged.text = previous.text + current.text
        return merged
    }

    // parity: tui/src/mini/footer.ts#RunFooter [status=adapted hash=9194f37c1fff]
    public final class RunFooter: FooterApi, @unchecked Sendable {
        public struct StartupSplash: Equatable, Hashable, Sendable {
            public let version: String
            public let detail: String?

            public init(version: String, detail: String? = nil) {
                self.version = version
                self.detail = detail
            }
        }

        private struct Inner: @unchecked Sendable {
            var state: FooterState
            var view: FooterView = .prompt
            var agent: String?
            var history: [RunPrompt] = []
            var queued: [FooterQueuedPrompt] = []
            var subagent: FooterSubagentState = FooterSubagentState()
            var pendingCommits: [StreamCommit] = []
            var closed: Bool = false
            var destroyed: Bool = false
            var startup: StartupSplash?
            var theme: RunTheme
            var miniSettings: MiniSettings
            var themeConfig: TUIConfig.ThemeConfig?
            var promptListeners: [UInt64: @Sendable (RunPrompt) -> Void] = [:]
            var closeListeners: [UInt64: @Sendable () -> Void] = [:]
            var nextID: UInt64 = 1
        }

        private let renderer: CliRenderer
        private let scrollbackLock: Mutex<RunScrollbackStream>
        private let inner: Mutex<Inner>
        private let requestExitHandler: (@Sendable () -> Bool)?

        public init(
            renderer: CliRenderer,
            modelLabel: String = "",
            agent: String? = nil,
            theme: RunTheme = RUN_THEME_FALLBACK,
            mono: Bool = false,
            miniSettings: MiniSettings? = nil,
            themeConfig: TUIConfig.ThemeConfig? = nil,
            startup: StartupSplash? = nil,
            requestExitHandler: (@Sendable () -> Bool)? = nil
        ) {
            let resolvedSettings = miniSettings ?? MiniSettings(mono: mono)
            self.renderer = renderer
            self.scrollbackLock = Mutex(RunScrollbackStream(renderer: renderer, theme: theme, mono: resolvedSettings.mono))
            self.requestExitHandler = requestExitHandler
            self.inner = Mutex(Inner(
                state: FooterState(model: modelLabel),
                agent: agent,
                startup: startup,
                theme: theme,
                miniSettings: resolvedSettings,
                themeConfig: themeConfig
            ))
        }

        // parity: tui/src/mini/footer.ts#RunFooter.finishStartup [status=implemented hash=59ce9702e857]
        public func finishStartup() {
            let splash: (StartupSplash, RunTheme, Bool)? = inner.withLock { s in
                guard let st = s.startup else { return nil }
                s.startup = nil
                guard !s.destroyed else { return nil }
                return (st, s.theme, s.miniSettings.mono)
            }
            guard let (st, theme, mono) = splash else { return }
            try? renderer.writeToScrollback(TUIMini.entrySplash(
                version: st.version,
                detail: st.detail,
                mono: mono,
                theme: theme.splash
            ))
            renderer.requestRender()
        }

        // parity: tui/src/mini/footer.ts#RunFooter.isClosed [status=implemented hash=64af2cbf4bb0]
        public var isClosed: Bool { inner.withLock { $0.closed || $0.destroyed } }
        public var currentState: FooterState { inner.withLock { $0.state } }
        public var currentView: FooterView { inner.withLock { $0.view } }
        public var committedScrollback: [StreamCommit] { scrollbackLock.withLock { $0.committed } }

        // parity: tui/src/mini/footer.ts#RunFooter.onPrompt [status=implemented hash=9ebe65f56883]
        public func onPrompt(_ fn: @escaping @Sendable (RunPrompt) -> Void) -> @Sendable () -> Void {
            let id = inner.withLock { s -> UInt64 in
                let cur = s.nextID; s.nextID &+= 1; s.promptListeners[cur] = fn; return cur
            }
            return { [weak self] in _ = self?.inner.withLock { $0.promptListeners.removeValue(forKey: id) } }
        }

        // parity: tui/src/mini/footer.ts#RunFooter.onClose [status=implemented hash=71748b48f079]
        public func onClose(_ fn: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
            if isClosed {
                fn()
                return {}
            }
            let id = inner.withLock { s -> UInt64 in
                let cur = s.nextID; s.nextID &+= 1; s.closeListeners[cur] = fn; return cur
            }
            return { [weak self] in _ = self?.inner.withLock { $0.closeListeners.removeValue(forKey: id) } }
        }

        public func submitPrompt(_ prompt: RunPrompt) {
            let listeners = inner.withLock { Array($0.promptListeners.values) }
            for fn in listeners { fn(prompt) }
        }

        // parity: tui/src/mini/footer.ts#RunFooter.event [status=implemented hash=8cc8b6864a31]
        public func event(_ next: FooterEvent) {
            inner.withLock { s in
                switch next {
                case .history(let h): s.history = h
                case .agent(let a): s.agent = a
                case .first(let f): s.state.first = f
                case .model(let label, _): s.state.model = label
                case .queuedPrompts(let q): s.queued = q
                case .turnSend: s.state.phase = .running
                case .turnIdle: s.state.phase = .idle; s.state.status = ""
                case .turnDuration(let d): s.state.status = d
                case .streamPatch(let p): s.state = p.applying(to: s.state)
                case .streamView(let v): s.view = v
                case .streamSubagent(let sub): s.subagent = sub
                case .catalog, .models, .variants: break
                }
            }
        }

        // parity: tui/src/mini/footer.ts#RunFooter.append [status=implemented hash=19c4ab69012a]
        public func append(_ commit: StreamCommit) {
            finishStartup()
            inner.withLock { s in
                if let last = s.pendingCommits.last, let merged = coalesceProgressCommit(last, commit) {
                    s.pendingCommits[s.pendingCommits.count - 1] = merged
                } else {
                    s.pendingCommits.append(commit)
                }
            }
            flush()
        }

        public func flush() {
            let batch = inner.withLock { s -> [StreamCommit] in
                let items = s.pendingCommits
                s.pendingCommits.removeAll()
                return items
            }
            let sb = scrollbackLock.withLock { $0 }
            for commit in batch { sb.append(commit) }
        }

        // parity: tui/src/mini/footer.ts#RunFooter.idle [status=implemented hash=2df2d34d13cf]
        public func idle() async {
            flush()
            if inner.withLock({ $0.state.phase == .idle }) {
                let sb = scrollbackLock.withLock { $0 }
                await sb.complete()
            }
            await renderer.idle()
        }

        // parity: tui/src/mini/footer.ts#RunFooter.resetForReplay [status=implemented hash=cf2427d3b257]
        public func resetForReplay(wrote: Bool = false) {
            guard !inner.withLock({ $0.destroyed }) else { return }
            finishStartup()
            let (theme, mono) = inner.withLock { ($0.theme, $0.miniSettings.mono) }
            scrollbackLock.withLock { sb in
                sb.destroy()
                sb = RunScrollbackStream(renderer: renderer, theme: theme, mono: mono, wrote: wrote)
            }
        }

        // parity: tui/src/mini/footer.ts#RunFooter.currentTheme [status=implemented hash=831281c335d4]
        public func currentTheme() -> RunTheme {
            inner.withLock { $0.theme }
        }

        // parity: tui/src/mini/footer.ts#RunFooter.currentMiniSettings [status=implemented hash=f93b3fbfadf6]
        public func currentMiniSettings() -> MiniSettings {
            inner.withLock { $0.miniSettings }
        }

        // parity: tui/src/mini/footer.ts#RunFooter.close [status=implemented hash=b6ee7f8f8ab3]
        public func close() {
            finishStartup()
            flush()
            let listeners = inner.withLock { s -> [@Sendable () -> Void] in
                if s.closed { return [] }
                s.closed = true
                return Array(s.closeListeners.values)
            }
            for fn in listeners { fn() }
        }

        // parity: tui/src/mini/footer.ts#RunFooter.requestExit [status=implemented hash=2ecdf520a239]
        @discardableResult
        public func requestExit() -> Bool {
            if let handler = requestExitHandler {
                return handler()
            }
            let alreadyClosed = inner.withLock { $0.closed || $0.destroyed }
            if alreadyClosed { return true }
            close()
            return true
        }

        // parity: tui/src/mini/footer.ts#RunFooter.destroy [status=implemented hash=c22de2d1779e]
        public func destroy() {
            inner.withLock { $0.destroyed = true }
            close()
            scrollbackLock.withLock { $0.destroy() }
        }

        // parity: tui/src/mini/footer.ts#RunFooter.refreshTheme [status=implemented hash=fab225f45f5d]
        public func refreshTheme() async {
            let (cfg, mono, destroyed) = inner.withLock { ($0.themeConfig, $0.miniSettings.mono, $0.destroyed) }
            guard !destroyed else { return }
            let next = await TUIMini.resolveRunTheme(renderer: renderer, config: cfg, mono: mono)
            inner.withLock { $0.theme = next }
            scrollbackLock.withLock { $0.setTheme(next) }
            renderer.requestRender()
        }
    }

    // MARK: - Runtime Lifecycle, Prompt Queue, Demo & Entrypoint (`runtime*.ts`, `demo.ts`, `index.ts`)

    // parity: tui/src/mini/runtime.lifecycle.ts#LifecycleInput [status=adapted hash=1c0d21be68b5]
    public struct LifecycleInput: @unchecked Sendable {
        public let host: MiniHost
        public let renderer: CliRenderer
        public let directory: String
        public let modelLabel: String
        public let agent: String?
        public let tuiConfig: RunTuiConfig
        public let miniSettings: MiniSettings

        public init(
            host: MiniHost = MiniHost(),
            renderer: CliRenderer,
            directory: String,
            modelLabel: String = "",
            agent: String? = nil,
            tuiConfig: RunTuiConfig = TUIConfig.resolve(TUIConfig.Info()),
            miniSettings: MiniSettings = MiniSettings()
        ) {
            self.host = host
            self.renderer = renderer
            self.directory = directory
            self.modelLabel = modelLabel
            self.agent = agent
            self.tuiConfig = tuiConfig
            self.miniSettings = miniSettings
        }
    }

    // parity: tui/src/mini/runtime.lifecycle.ts#Lifecycle [status=adapted hash=94f57d36b110]
    public struct Lifecycle: @unchecked Sendable {
        public let renderer: CliRenderer
        public let footer: RunFooter
        public let close: @Sendable () -> Void

        public init(renderer: CliRenderer, footer: RunFooter, close: @escaping @Sendable () -> Void) {
            self.renderer = renderer
            self.footer = footer
            self.close = close
        }
    }

    // parity: tui/src/mini/runtime.lifecycle.ts#createRuntimeLifecycle [status=adapted hash=7b9f0f9b5b15]
    public static func createRuntimeLifecycle(_ input: LifecycleInput) async -> Lifecycle {
        let theme = await resolveRunTheme(renderer: input.renderer, config: input.tuiConfig.theme, mono: input.miniSettings.mono)
        if input.miniSettings.splash == .show {
            try? input.renderer.writeToScrollback(entrySplash(
                version: input.host.version,
                detail: input.directory,
                mono: input.miniSettings.mono,
                theme: theme.splash
            ))
        }
        let footer = RunFooter(
            renderer: input.renderer,
            modelLabel: input.modelLabel,
            agent: input.agent,
            theme: theme,
            mono: input.miniSettings.mono
        )
        return Lifecycle(renderer: input.renderer, footer: footer) {
            footer.destroy()
        }
    }

    // parity: tui/src/mini/runtime.queue.ts#QueueInput [status=implemented hash=c5b732c5d215]
    public struct QueueInput: Sendable {
        public let footer: any FooterApi
        public let initialInput: String?
        public let interactive: Bool
        public let onNewSession: (@Sendable () async -> Void)?
        public let onCompact: (@Sendable () async -> Void)?
        public let run: @Sendable (RunPrompt, @escaping @Sendable () -> Void) async throws -> Void

        public init(
            footer: any FooterApi,
            initialInput: String? = nil,
            interactive: Bool = false,
            onNewSession: (@Sendable () async -> Void)? = nil,
            onCompact: (@Sendable () async -> Void)? = nil,
            run: @escaping @Sendable (RunPrompt, @escaping @Sendable () -> Void) async throws -> Void
        ) {
            self.footer = footer
            self.initialInput = initialInput
            self.interactive = interactive
            self.onNewSession = onNewSession
            self.onCompact = onCompact
            self.run = run
        }
    }

    private final class MiniPromptFIFO: @unchecked Sendable {
        private struct Box {
            var items: [RunPrompt] = []
            var waiters: [CheckedContinuation<RunPrompt?, Never>] = []
            var closed: Bool = false
        }

        private let box = Mutex(Box())

        func push(_ prompt: RunPrompt) {
            let waiter = box.withLock { b -> CheckedContinuation<RunPrompt?, Never>? in
                if b.closed { return nil }
                if !b.waiters.isEmpty {
                    return b.waiters.removeFirst()
                }
                b.items.append(prompt)
                return nil
            }
            waiter?.resume(returning: prompt)
        }

        func finish() {
            let waiters = box.withLock { b -> [CheckedContinuation<RunPrompt?, Never>] in
                if b.closed { return [] }
                b.closed = true
                b.items.removeAll()
                let w = b.waiters
                b.waiters.removeAll()
                return w
            }
            for w in waiters { w.resume(returning: nil) }
        }

        func next() async -> RunPrompt? {
            await withCheckedContinuation { continuation in
                let immediate: (Bool, RunPrompt?) = box.withLock { b in
                    if !b.items.isEmpty {
                        return (true, b.items.removeFirst())
                    }
                    if b.closed {
                        return (true, nil)
                    }
                    b.waiters.append(continuation)
                    return (false, nil)
                }
                if immediate.0 {
                    continuation.resume(returning: immediate.1)
                }
            }
        }
    }

    // parity: tui/src/mini/runtime.queue.ts#runPromptQueue [status=adapted hash=45e46630d5d3]
    public static func runPromptQueue(_ input: QueueInput) async {
        func executePrompt(_ prompt: RunPrompt) async -> Bool {
            let trimmed = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true }
            if isExitCommand(trimmed) {
                input.footer.close()
                return false
            }
            if isNewCommand(trimmed) {
                await input.onNewSession?()
                return true
            }
            if isCompactCommand(trimmed) {
                await input.onCompact?()
                return true
            }
            input.footer.event(.turnSend)
            do {
                try await input.run(prompt, {})
            } catch {
                if !input.footer.isClosed {
                    input.footer.append(StreamCommit(
                        kind: .error,
                        text: formatUnknownError(error),
                        phase: .start,
                        source: .system
                    ))
                }
            }
            input.footer.event(.turnIdle)
            return !input.footer.isClosed
        }

        if !input.interactive {
            if let initial = input.initialInput, !initial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = await executePrompt(RunPrompt(text: initial))
            }
            return
        }

        let fifo = MiniPromptFIFO()
        let offPrompt = input.footer.onPrompt { prompt in
            fifo.push(prompt)
        }
        let offClose = input.footer.onClose {
            fifo.finish()
        }
        defer {
            offPrompt()
            offClose()
            fifo.finish()
        }

        if input.footer.isClosed {
            return
        }
        if let initial = input.initialInput, !initial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fifo.push(RunPrompt(text: initial))
        }

        while !Task.isCancelled && !input.footer.isClosed {
            guard let nextPrompt = await fifo.next() else { break }
            if !(await executePrompt(nextPrompt)) {
                break
            }
        }
    }

    // parity: tui/src/mini/demo.ts#createRunDemo [status=adapted hash=32b9cd89b7da]
    public static func createRunDemo(footer: any FooterApi, directory: String = "") -> @Sendable (RunPrompt) -> Void {
        { prompt in
            if let head = TUIPrompt.parseSlashHead(prompt.text), head.name.lowercased() == "fmt" {
                writeSessionOutput(footer: footer, output: StreamOutput(commits: [
                    StreamCommit(kind: .assistant, text: "Demo preview (\(head.arguments)) in \(directory)", phase: .progress, source: .assistant),
                    StreamCommit(kind: .assistant, text: "", phase: .final, source: .assistant),
                ]))
                return
            }
            writeSessionOutput(footer: footer, output: StreamOutput(commits: [
                StreamCommit(kind: .user, text: prompt.text, phase: .start, source: .system),
                StreamCommit(kind: .assistant, text: "Demo reply to: \(prompt.text)", phase: .progress, source: .assistant),
                StreamCommit(kind: .assistant, text: "", phase: .final, source: .assistant),
            ]))
        }
    }

    // parity: tui/src/mini/runtime.ts#RunDeferredInput [status=adapted hash=b3119d8fe799]
    public struct RunDeferredInput: @unchecked Sendable {
        public let host: MiniHost
        public let renderer: CliRenderer
        public let client: OpenCodeClient?
        public let sessionID: String?
        public let directory: String
        public let agent: String?
        public let model: PromptModelSelection?
        public let variant: String?
        public let initialInput: String?
        public let replay: Bool
        public let replayLimit: Int?
        public let demo: Bool
        public let interactive: Bool
        public let tuiConfig: RunTuiConfig?

        public init(
            host: MiniHost = MiniHost(),
            renderer: CliRenderer,
            client: OpenCodeClient? = nil,
            sessionID: String? = nil,
            directory: String,
            agent: String? = nil,
            model: PromptModelSelection? = nil,
            variant: String? = nil,
            initialInput: String? = nil,
            replay: Bool = true,
            replayLimit: Int? = nil,
            demo: Bool = false,
            interactive: Bool = false,
            tuiConfig: RunTuiConfig? = nil
        ) {
            self.host = host
            self.renderer = renderer
            self.client = client
            self.sessionID = sessionID
            self.directory = directory
            self.agent = agent
            self.model = model
            self.variant = variant
            self.initialInput = initialInput
            self.replay = replay
            self.replayLimit = replayLimit
            self.demo = demo
            self.interactive = interactive
            self.tuiConfig = tuiConfig
        }
    }

    // parity: tui/src/mini/runtime.ts#RunRuntimeDeps [status=adapted hash=ead96a090afd]
    public struct RunRuntimeDeps: Sendable {
        public let onComplete: (@Sendable () -> Void)?

        public init(onComplete: (@Sendable () -> Void)? = nil) {
            self.onComplete = onComplete
        }
    }

    // parity: tui/src/mini/runtime.ts#runInteractiveDeferredMode [status=adapted hash=893731d65ab4]
    public static func runInteractiveDeferredMode(
        _ input: RunDeferredInput,
        deps: RunRuntimeDeps? = nil
    ) async {
        let config = await resolveRunTuiConfig(input.tuiConfig, platform: input.host.platform)
        let settings = resolveMiniSettings(config.mini)
        let modelLabel = input.model.map { formatModelLabel($0, variant: input.variant) } ?? ""
        let lifecycle = await createRuntimeLifecycle(LifecycleInput(
            host: input.host,
            renderer: input.renderer,
            directory: input.directory,
            modelLabel: modelLabel,
            agent: input.agent,
            tuiConfig: config,
            miniSettings: settings
        ))
        defer {
            lifecycle.close()
            deps?.onComplete?()
        }

        let theme = await resolveRunTheme(renderer: input.renderer, config: config.theme, mono: settings.mono)
        let draftText = Mutex<String>("")

        let renderFooterView: @Sendable () -> Void = {
            let promptDraft = draftText.withLock { $0 }
            let footerNode = RunFooterView(
                ctx: lifecycle.renderer,
                state: lifecycle.footer.currentState,
                view: lifecycle.footer.currentView,
                promptText: promptDraft,
                agent: input.agent,
                width: lifecycle.renderer.width,
                mono: settings.mono,
                theme: theme.footer
            )
            for child in lifecycle.renderer.root.getChildren() {
                lifecycle.renderer.root.remove(child)
            }
            lifecycle.renderer.root.add(footerNode)
            lifecycle.renderer.requestRender()
        }

        let interruptHandler = Mutex<(@Sendable () async -> Void)?>(nil)
        var keyToken: KeyHandlerToken?
        var pasteToken: KeyHandlerToken?
        if input.interactive {
            renderFooterView()
            keyToken = lifecycle.renderer.keyInput.onKeypress { event in
                if event.ctrl && event.name == "d" {
                    event.preventDefault()
                    lifecycle.footer.close()
                    return
                }
                if event.ctrl && event.name == "c" {
                    event.preventDefault()
                    let cleared = draftText.withLock { text -> Bool in
                        if text.isEmpty { return false }
                        text = ""
                        return true
                    }
                    if cleared {
                        renderFooterView()
                        return
                    }
                    if lifecycle.footer.currentState.phase == .running,
                       let interrupt = interruptHandler.withLock({ $0 })
                    {
                        Task { await interrupt() }
                        return
                    }
                    lifecycle.footer.close()
                    return
                }
                if event.name == "return" || event.name == "enter" {
                    event.preventDefault()
                    let submitted = draftText.withLock { text -> String in
                        let current = text
                        text = ""
                        return current
                    }
                    renderFooterView()
                    if !submitted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lifecycle.footer.submitPrompt(RunPrompt(text: submitted))
                    }
                    return
                }
                if event.name == "backspace" {
                    event.preventDefault()
                    draftText.withLock { text in
                        if !text.isEmpty { _ = text.popLast() }
                    }
                    renderFooterView()
                    return
                }
                if !event.ctrl && !event.meta && !event.sequence.isEmpty {
                    let printable = event.sequence.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
                    if printable {
                        event.preventDefault()
                        draftText.withLock { $0 += event.sequence }
                        renderFooterView()
                    }
                }
            }
            pasteToken = lifecycle.renderer.keyInput.onPaste { event in
                let pasted = String(decoding: event.bytes, as: UTF8.self)
                if !pasted.isEmpty {
                    event.preventDefault()
                    draftText.withLock { $0 += pasted }
                    renderFooterView()
                }
            }
        }
        defer {
            if let keyToken { lifecycle.renderer.keyInput.off(keyToken) }
            if let pasteToken { lifecycle.renderer.keyInput.off(pasteToken) }
        }

        if input.demo {
            let demo = createRunDemo(footer: lifecycle.footer, directory: input.directory)
            await runPromptQueue(QueueInput(
                footer: lifecycle.footer,
                initialInput: input.initialInput,
                interactive: input.interactive
            ) { prompt, admitted in
                admitted()
                demo(prompt)
                if input.interactive { renderFooterView() }
            })
        } else {
            let transportBox = Mutex<SessionTransport?>(nil)
            let makeTransport: @Sendable (String?) async -> SessionTransport = { sid in
                await createSessionTransport(
                    sessionID: sid,
                    footer: lifecycle.footer,
                    client: input.client,
                    directory: input.directory,
                    thinking: settings.thinking != .hide,
                    tools: settings.tools != .hide,
                    replay: input.replay,
                    replayLimit: input.replayLimit
                )
            }
            let initialTransport = await makeTransport(input.sessionID)
            transportBox.withLock { $0 = initialTransport }
            interruptHandler.withLock {
                $0 = {
                    if let active = transportBox.withLock({ $0 }) {
                        await active.interruptActiveTurn()
                    }
                }
            }
            await runPromptQueue(QueueInput(
                footer: lifecycle.footer,
                initialInput: input.initialInput,
                interactive: input.interactive,
                onNewSession: {
                    let prev = transportBox.withLock { $0 }
                    await prev?.close()
                    let fresh = await makeTransport(nil)
                    transportBox.withLock { $0 = fresh }
                    if input.interactive { renderFooterView() }
                },
                onCompact: {
                    if let client = input.client, let sid = input.sessionID, !sid.isEmpty {
                        _ = try? await client.session.compact(SessionCompactInput(sessionID: sid))
                    }
                }
            ) { prompt, admitted in
                guard let active = transportBox.withLock({ $0 }) else { return }
                try await active.runPromptTurn(
                    SessionTurnInput(agent: input.agent, model: input.model, variant: input.variant, prompt: prompt),
                    admitted
                )
                if input.interactive { renderFooterView() }
            })
            if let active = transportBox.withLock({ $0 }) {
                await active.close()
            }
        }
    }

    // parity: tui/src/mini/index.ts#MiniFrontendInput [status=implemented hash=cb038e4c5d1b]
    public typealias MiniFrontendInput = RunDeferredInput

    // parity: tui/src/mini/index.ts#runMiniFrontend [status=adapted hash=d0d166faed5f]
    public static func runMiniFrontend(_ input: MiniFrontendInput) async {
        await runInteractiveDeferredMode(input)
    }

    /// Drives the live interactive Mini TUI over `PlatformTerminalBackend` with raw mode,
    /// non-blocking stdin & terminal resize polling, and real `OpenCodeClient` SSE streaming.
    public static func runMiniInteractiveTerminal(
        backend: PlatformTerminalBackend,
        host: MiniHost = MiniHost(),
        client: OpenCodeClient,
        sessionID: String? = nil,
        directory: String,
        agent: String? = nil,
        model: PromptModelSelection? = nil,
        variant: String? = nil,
        initialInput: String? = nil,
        replay: Bool = true,
        replayLimit: Int? = nil,
        tuiConfig: RunTuiConfig? = nil
    ) async throws {
        let initialSize = await backend.size
        let useMouse = tuiConfig?.mouse ?? true
        let renderer = CliRenderer(
            config: CliRendererConfig(
                width: initialSize.width,
                height: initialSize.height,
                screenMode: .splitFooter,
                footerHeight: 6,
                exitOnCtrlC: false,
                debounceDelay: 0,
                useMouse: useMouse
            )
        )
        try await runWithTerminalBackend(
            renderer: renderer,
            backend: backend,
            options: TerminalBackendRunOptions(
                enterRawMode: true,
                manageTerminalModes: true,
                initialRender: false,
                destroyOnExit: true,
                enableMouseMovement: useMouse
            )
        ) { liveRenderer, session in
            let stopPump = Mutex(false)
            let pumpTask = Task.detached {
                var lastSize = await backend.size
                while !Task.isCancelled && !stopPump.withLock({ $0 }) && !liveRenderer.isDestroyed {
                    let currentSize = await backend.size
                    if currentSize != lastSize {
                        lastSize = currentSize
                        _ = await session.syncSize()
                        await session.renderNow(force: true)
                    }
                    let bytes = (try? backend.pollRead(maxBytes: 4096, timeoutMs: 16)) ?? []
                    if !bytes.isEmpty {
                        session.feedInput(bytes)
                        await session.renderNow(force: false)
                    }
                }
            }
            defer {
                stopPump.withLock { $0 = true }
                pumpTask.cancel()
            }

            let frontendInput = MiniFrontendInput(
                host: host,
                renderer: liveRenderer,
                client: client,
                sessionID: sessionID,
                directory: directory,
                agent: agent,
                model: model,
                variant: variant,
                initialInput: initialInput,
                replay: replay,
                replayLimit: replayLimit,
                demo: false,
                interactive: true,
                tuiConfig: tuiConfig
            )
            await runMiniFrontend(frontendInput)
            await session.flush()
        }
    }
}

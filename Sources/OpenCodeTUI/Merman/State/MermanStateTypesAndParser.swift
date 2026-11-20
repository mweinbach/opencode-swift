import Foundation
import OpenTUICore

extension Merman {
    // MARK: - State Types (`state/types.ts`)

    // parity: merman/src/state/types.ts#StateDiagramDirection [status=implemented hash=d501f92be087]
    public enum StateDiagramDirection: String, Equatable, Hashable, Sendable, Codable {
        case TB
        case TD
        case BT
        case LR
        case RL
    }

    // parity: merman/src/state/types.ts#StateDiagramArrowHeadStyle [status=implemented hash=b0a0907e0420]
    public enum StateDiagramArrowHeadStyle: String, Equatable, Hashable, Sendable, Codable {
        case filled
        case line
    }

    public enum StateDiagramStateKind: String, Equatable, Hashable, Sendable, Codable {
        case state
        case start
        case end
        case choice
    }

    // parity: merman/src/state/types.ts#StateDiagramState [status=implemented hash=b89b50297d7f]
    public struct StateDiagramState: Equatable, Hashable, Sendable, Codable {
        public var id: String
        public var label: String
        public var kind: StateDiagramStateKind
        public var parentId: String?

        public init(id: String, label: String, kind: StateDiagramStateKind = .state, parentId: String? = nil) {
            self.id = id
            self.label = label
            self.kind = kind
            self.parentId = parentId
        }
    }

    // parity: merman/src/state/types.ts#StateDiagramTransition [status=implemented hash=91b3ef22161e]
    public struct StateDiagramTransition: Equatable, Hashable, Sendable, Codable {
        public var from: String
        public var to: String
        public var label: String

        public init(from: String, to: String, label: String = "") {
            self.from = from
            self.to = to
            self.label = label
        }
    }

    // parity: merman/src/state/types.ts#StateDiagramCompositeState [status=implemented hash=5e6954b40ece]
    public struct StateDiagramCompositeState: Equatable, Hashable, Sendable, Codable {
        public var id: String
        public var label: String
        public var parentId: String?

        public init(id: String, label: String, parentId: String? = nil) {
            self.id = id
            self.label = label
            self.parentId = parentId
        }
    }

    public enum StateDiagramNotePosition: String, Equatable, Hashable, Sendable, Codable {
        case left
        case right
    }

    // parity: merman/src/state/types.ts#StateDiagramNote [status=implemented hash=e8f25f6a4bb5]
    public struct StateDiagramNote: Equatable, Hashable, Sendable, Codable {
        public var target: String
        public var position: StateDiagramNotePosition
        public var lines: [String]

        public init(target: String, position: StateDiagramNotePosition, lines: [String]) {
            self.target = target
            self.position = position
            self.lines = lines
        }
    }

    // parity: merman/src/state/types.ts#StateDiagram [status=implemented hash=9b1b300f4e88]
    public struct StateDiagram: Equatable, Hashable, Sendable, Codable {
        public var direction: StateDiagramDirection
        public var states: [StateDiagramState]
        public var transitions: [StateDiagramTransition]
        public var composites: [StateDiagramCompositeState]
        public var notes: [StateDiagramNote]

        public init(
            direction: StateDiagramDirection,
            states: [StateDiagramState],
            transitions: [StateDiagramTransition],
            composites: [StateDiagramCompositeState] = [],
            notes: [StateDiagramNote] = []
        ) {
            self.direction = direction
            self.states = states
            self.transitions = transitions
            self.composites = composites
            self.notes = notes
        }
    }

    // parity: merman/src/state/types.ts#StateDiagramRenderOptions [status=implemented hash=e1c69674c150]
    public struct StateDiagramRenderOptions: Equatable, Hashable, Sendable {
        public var direction: StateDiagramDirection?
        public var borderStyle: BorderStyle?
        public var arrowHeadStyle: StateDiagramArrowHeadStyle?
        public var minStateGap: Int?
        public var layoutMaxWidth: Int?

        public init(
            direction: StateDiagramDirection? = nil,
            borderStyle: BorderStyle? = nil,
            arrowHeadStyle: StateDiagramArrowHeadStyle? = nil,
            minStateGap: Int? = nil,
            layoutMaxWidth: Int? = nil
        ) {
            self.direction = direction
            self.borderStyle = borderStyle
            self.arrowHeadStyle = arrowHeadStyle
            self.minStateGap = minStateGap
            self.layoutMaxWidth = layoutMaxWidth
        }
    }

    // parity: merman/src/state/types.ts#NoteConnectorRampStyle [status=implemented hash=132364858bfb]
    public enum NoteConnectorRampStyle: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case noteConnectorRamp1
        case noteConnectorRamp2
        case noteConnectorRamp3
    }

    // parity: merman/src/state/types.ts#StateDepartureRampStyle [status=implemented hash=88f1a6e14b70]
    public enum StateDepartureRampStyle: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case stateDepartureRamp1
        case stateDepartureRamp2
        case stateDepartureRamp3
    }

    // parity: merman/src/state/types.ts#BaseStateCellStyle [status=implemented hash=bcd654608f8f]
    public enum BaseStateCellStyle: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case state
        case stateBorder
        case composite
        case compositeLabel
        case transition
        case label
        case noteBorder
        case noteText
        case noteConnector
        case start
        case end
        case choice
    }

    // parity: merman/src/state/types.ts#StateCellStyle [status=implemented hash=947503e684ee]
    public enum StateCellStyle: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case state
        case stateBorder
        case composite
        case compositeLabel
        case transition
        case label
        case noteBorder
        case noteText
        case noteConnector
        case start
        case end
        case choice
        case noteConnectorRamp1
        case noteConnectorRamp2
        case noteConnectorRamp3
        case stateDepartureRamp1
        case stateDepartureRamp2
        case stateDepartureRamp3

        var isDepartureRamp: Bool {
            self == .stateDepartureRamp1 || self == .stateDepartureRamp2 || self == .stateDepartureRamp3
        }

        static func fromStateKind(_ kind: StateDiagramStateKind) -> StateCellStyle {
            switch kind {
            case .state: return .state
            case .start: return .start
            case .end: return .end
            case .choice: return .choice
            }
        }
    }

    // MARK: - State Options (`state/options.ts`)

    // parity: merman/src/state/options.ts#DEFAULT_STATE_DIAGRAM_MIN_STATE_GAP [status=implemented hash=1ff65bd54ca1]
    public static let DEFAULT_STATE_DIAGRAM_MIN_STATE_GAP: Int = 5

    // parity: merman/src/state/options.ts#DEFAULT_STATE_BORDER_STYLE [status=implemented hash=d14cba432d8e]
    public static let DEFAULT_STATE_BORDER_STYLE: BorderStyle = .rounded

    // parity: merman/src/state/options.ts#DEFAULT_STATE_ARROW_HEAD_STYLE [status=implemented hash=106da548192a]
    public static let DEFAULT_STATE_ARROW_HEAD_STYLE: StateDiagramArrowHeadStyle = .filled

    // parity: merman/src/state/options.ts#normalizeStateMinStateGap [status=implemented hash=78643579254f]
    public static func normalizeStateMinStateGap(_ value: Int?) -> Int {
        guard let value else { return DEFAULT_STATE_DIAGRAM_MIN_STATE_GAP }
        return max(1, value)
    }

    public static func normalizeStateMinStateGap(_ value: Double?) -> Int {
        guard let value, value.isFinite else { return DEFAULT_STATE_DIAGRAM_MIN_STATE_GAP }
        return max(1, jsTrunc(value))
    }

    // MARK: - State Endpoints (`state/endpoint.ts`)

    public enum StateEndpointPosition: String, Equatable, Hashable, Sendable {
        case from
        case to
    }

    // parity: merman/src/state/endpoint.ts#stateDiagramStartMarkerId [status=implemented hash=beada24eef57]
    public static func stateDiagramStartMarkerId(_ scope: String? = nil) -> String {
        if let scope, !scope.isEmpty { return "\(scope).__start" }
        return "__start"
    }

    // parity: merman/src/state/endpoint.ts#stateDiagramEndMarkerId [status=implemented hash=2b7de99c79b2]
    public static func stateDiagramEndMarkerId(_ scope: String? = nil) -> String {
        if let scope, !scope.isEmpty { return "\(scope).__end" }
        return "__end"
    }

    // parity: merman/src/state/endpoint.ts#stateDiagramMarkerId [status=implemented hash=687d4a428a3e]
    public static func stateDiagramMarkerId(_ position: StateEndpointPosition, scope: String? = nil) -> String {
        position == .from ? stateDiagramStartMarkerId(scope) : stateDiagramEndMarkerId(scope)
    }

    // parity: merman/src/state/endpoint.ts#normalizeStateDiagramEndpoint [status=implemented hash=551fbf7581ec]
    public static func normalizeStateDiagramEndpoint(
        _ value: String,
        position: StateEndpointPosition,
        scope: String? = nil
    ) -> String {
        value == "[*]" ? stateDiagramMarkerId(position, scope: scope) : value
    }

    // MARK: - State Style (`state/style.ts`)

    private static let stateDefaultThemeRgb: [BaseStateCellStyle: DiagramRgb] = [
        .state: (228, 239, 232),
        .stateBorder: (228, 239, 232),
        .composite: (111, 138, 126),
        .compositeLabel: (111, 138, 126),
        .transition: (134, 225, 200),
        .label: (134, 225, 200),
        .noteBorder: (141, 169, 155),
        .noteText: (215, 229, 221),
        .noteConnector: (141, 169, 155),
        .start: (134, 225, 200),
        .end: (230, 177, 126),
        .choice: (134, 225, 200),
    ]

    // parity: merman/src/state/style.ts#NOTE_CONNECTOR_RAMP_STYLES [status=implemented hash=0c8147342f43]
    public static let NOTE_CONNECTOR_RAMP_STYLES: [StateCellStyle] = [
        .noteConnectorRamp1, .noteConnectorRamp2, .noteConnectorRamp3,
    ]

    // parity: merman/src/state/style.ts#STATE_DEPARTURE_RAMP_STYLES [status=implemented hash=3e5fd29c73e0]
    public static let STATE_DEPARTURE_RAMP_STYLES: [StateCellStyle] = [
        .stateDepartureRamp1, .stateDepartureRamp2, .stateDepartureRamp3,
    ]

    // parity: merman/src/state/style.ts#StateStyleColors [status=implemented hash=606549733218]
    public typealias StateStyleColors = [StateCellStyle: RGBA]

    // parity: merman/src/state/style.ts#resolveStateStyleColors [status=implemented hash=1c9870fac878]
    public static func resolveStateStyleColors(
        _ colors: [BaseStateCellStyle: RGBA?] = [:]
    ) -> StateStyleColors {
        let state = (colors[.state] ?? nil) ?? rgba(stateDefaultThemeRgb[.state]!)
        let stateBorder = (colors[.stateBorder] ?? nil) ?? (colors[.state] ?? nil) ?? rgba(stateDefaultThemeRgb[.stateBorder]!)
        let composite = (colors[.composite] ?? nil) ?? rgba(stateDefaultThemeRgb[.composite]!)
        let compositeLabel = (colors[.compositeLabel] ?? nil) ?? (colors[.composite] ?? nil) ?? rgba(stateDefaultThemeRgb[.compositeLabel]!)
        let transition = (colors[.transition] ?? nil) ?? rgba(stateDefaultThemeRgb[.transition]!)
        let noteBorder = (colors[.noteBorder] ?? nil) ?? rgba(stateDefaultThemeRgb[.noteBorder]!)
        let noteConnector = (colors[.noteConnector] ?? nil) ?? rgba(stateDefaultThemeRgb[.noteConnector]!)

        var resolved: StateStyleColors = [
            .state: state,
            .stateBorder: stateBorder,
            .composite: composite,
            .compositeLabel: compositeLabel,
            .transition: transition,
            .label: (colors[.label] ?? nil) ?? rgba(stateDefaultThemeRgb[.label]!),
            .noteBorder: noteBorder,
            .noteText: (colors[.noteText] ?? nil) ?? rgba(stateDefaultThemeRgb[.noteText]!),
            .noteConnector: noteConnector,
            .start: (colors[.start] ?? nil) ?? rgba(stateDefaultThemeRgb[.start]!),
            .end: (colors[.end] ?? nil) ?? rgba(stateDefaultThemeRgb[.end]!),
            .choice: (colors[.choice] ?? nil) ?? rgba(stateDefaultThemeRgb[.choice]!),
        ]
        for (k, v) in createColorRampTheme(NOTE_CONNECTOR_RAMP_STYLES, from: noteConnector, to: noteBorder) {
            resolved[k] = v
        }
        for (k, v) in createColorRampTheme(STATE_DEPARTURE_RAMP_STYLES, from: stateBorder, to: transition) {
            resolved[k] = v
        }
        return resolved
    }

    // MARK: - State Parser (`state/parser.ts`)

    private static let stateDeclPattern = #"^state\s+"([^"]+)"\s+as\s+(\S+)$"#
    private static let stateCompositePattern = #"^state\s+(?:"([^"]+)"\s+as\s+)?(\S+)\s*\{$"#
    private static let stateChoicePattern = #"^state\s+(\S+)\s+<<choice>>$"#
    private static let stateTransitionPattern = #"^(\[\*\]|[^\s:]+)\s*-->\s*(\[\*\]|[^\s:]+)(?:\s*:\s*(.*))?$"#
    private static let stateDirectionPattern = #"^direction\s+(TB|TD|BT|LR|RL)$"#
    private static let stateNoteInlinePattern = #"^note\s+(left|right)\s+of\s+(\S+)\s*:\s*(.*)$"#
    private static let stateNoteStartPattern = #"^note\s+(left|right)\s+of\s+(\S+)\s*$"#
    private static let stateNoteEndPattern = #"^end\s+note$"#

    private static func stateIsHeader(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower == "statediagram-v2" || lower == "statediagram"
    }

    private static func stateNormalizeDirection(_ value: String?) -> StateDiagramDirection {
        guard let upper = value?.uppercased(), let dir = StateDiagramDirection(rawValue: upper) else {
            return .LR
        }
        return dir
    }

    // parity: merman/src/state/parser.ts#isMermaidStateDiagram [status=implemented hash=d67e5e950ad6]
    public static func isMermaidStateDiagram(_ content: String) -> Bool {
        stateIsHeader(firstMeaningfulMermaidLine(content) ?? "")
    }

    // parity: merman/src/state/parser.ts#parseMermaidStateDiagram [status=implemented hash=65f41d1f264c]
    public static func parseMermaidStateDiagram(_ content: String) throws -> StateDiagram {
        var stateOrder: [String] = []
        var statesById: [String: StateDiagramState] = [:]
        var transitions: [StateDiagramTransition] = []
        var composites: [StateDiagramCompositeState] = []
        var notes: [StateDiagramNote] = []
        var parentStack: [(id: String, lineNumber: Int, sourceLine: String)] = []
        var pendingNote: (target: String, position: StateDiagramNotePosition, lines: [String], lineNumber: Int, sourceLine: String)?
        var direction: StateDiagramDirection = .LR

        func ensureState(_ id: String, label: String? = nil, kind: StateDiagramStateKind = .state, parentId: String? = nil) {
            let resolvedLabel = label ?? id
            if var existing = statesById[id] {
                if existing.label == existing.id && resolvedLabel != id {
                    existing.label = resolvedLabel
                }
                if let parentId, existing.parentId == nil {
                    existing.parentId = parentId
                }
                if kind != .state {
                    existing.kind = kind
                    existing.label = resolvedLabel
                }
                statesById[id] = existing
                return
            }
            stateOrder.append(id)
            statesById[id] = StateDiagramState(id: id, label: resolvedLabel, kind: kind, parentId: parentId)
        }

        for source in numberedMermaidLines(content) {
            let line = source.text
            if var note = pendingNote {
                if regexTest(stateNoteEndPattern, in: line, options: [.caseInsensitive]) {
                    notes.append(StateDiagramNote(
                        target: note.target,
                        position: note.position,
                        lines: note.lines.map(decodeMermaidText)
                    ))
                    pendingNote = nil
                } else if !line.isEmpty || !note.lines.isEmpty {
                    note.lines.append(line)
                    pendingNote = note
                }
                continue
            }

            if line.isEmpty || line.hasPrefix("%%") || stateIsHeader(line) { continue }

            if line == "}" {
                if parentStack.isEmpty {
                    throw MermaidSyntaxError(
                        kind: .state,
                        lineNumber: source.lineNumber,
                        sourceLine: line,
                        reason: "Unexpected \"}\" without an open composite state"
                    )
                }
                _ = parentStack.popLast()
                continue
            }

            let parentId = parentStack.last?.id

            if let dirMatch = regexFirstMatch(stateDirectionPattern, in: line, options: [.caseInsensitive]) {
                if !parentStack.isEmpty {
                    throw MermaidSyntaxError(
                        kind: .state,
                        lineNumber: source.lineNumber,
                        sourceLine: line,
                        reason: "Composite-local direction is not supported"
                    )
                }
                direction = stateNormalizeDirection(dirMatch[1])
                continue
            }

            if let inlineNote = regexFirstMatch(stateNoteInlinePattern, in: line, options: [.caseInsensitive]) {
                let pos: StateDiagramNotePosition = (inlineNote[1] ?? "").lowercased() == "left" ? .left : .right
                notes.append(StateDiagramNote(
                    target: inlineNote[2] ?? "",
                    position: pos,
                    lines: splitDiagramLines(decodeMermaidText(jsTrim(inlineNote[3] ?? "")))
                ))
                continue
            }

            if let noteStart = regexFirstMatch(stateNoteStartPattern, in: line, options: [.caseInsensitive]) {
                let pos: StateDiagramNotePosition = (noteStart[1] ?? "").lowercased() == "left" ? .left : .right
                pendingNote = (
                    target: noteStart[2] ?? "",
                    position: pos,
                    lines: [],
                    lineNumber: source.lineNumber,
                    sourceLine: line
                )
                continue
            }

            if let compMatch = regexFirstMatch(stateCompositePattern, in: line, options: [.caseInsensitive]) {
                let id = compMatch[2] ?? ""
                let label = decodeMermaidText(compMatch[1] ?? id)
                composites.append(StateDiagramCompositeState(id: id, label: label, parentId: parentId))
                parentStack.append((id: id, lineNumber: source.lineNumber, sourceLine: line))
                continue
            }

            if let stateMatch = regexFirstMatch(stateDeclPattern, in: line, options: [.caseInsensitive]) {
                ensureState(stateMatch[2] ?? "", label: decodeMermaidText(stateMatch[1] ?? ""), kind: .state, parentId: parentId)
                continue
            }

            if let choiceMatch = regexFirstMatch(stateChoicePattern, in: line, options: [.caseInsensitive]) {
                ensureState(choiceMatch[1] ?? "", label: "", kind: .choice, parentId: parentId)
                continue
            }

            if let transMatch = regexFirstMatch(stateTransitionPattern, in: line) {
                let rawFrom = transMatch[1] ?? ""
                let rawTo = transMatch[2] ?? ""
                if rawFrom.contains("-->") || rawTo.contains("-->") {
                    throw MermaidSyntaxError(kind: .state, lineNumber: source.lineNumber, sourceLine: line)
                }
                let from = normalizeStateDiagramEndpoint(rawFrom, position: .from, scope: parentId)
                let to = normalizeStateDiagramEndpoint(rawTo, position: .to, scope: parentId)
                ensureState(from, label: rawFrom == "[*]" ? "●" : from, kind: rawFrom == "[*]" ? .start : .state, parentId: parentId)
                ensureState(to, label: rawTo == "[*]" ? "◎" : to, kind: rawTo == "[*]" ? .end : .state, parentId: parentId)
                transitions.append(StateDiagramTransition(
                    from: from,
                    to: to,
                    label: decodeMermaidText(jsTrim(transMatch[3] ?? ""))
                ))
                continue
            }

            throw MermaidSyntaxError(kind: .state, lineNumber: source.lineNumber, sourceLine: line)
        }

        if let pendingNote {
            throw MermaidSyntaxError(
                kind: .state,
                lineNumber: pendingNote.lineNumber,
                sourceLine: pendingNote.sourceLine,
                reason: "Unclosed note; expected \"end note\""
            )
        }

        if let unclosed = parentStack.last {
            throw MermaidSyntaxError(
                kind: .state,
                lineNumber: unclosed.lineNumber,
                sourceLine: unclosed.sourceLine,
                reason: "Unclosed composite state; expected \"}\""
            )
        }

        let orderedStates = stateOrder.compactMap { statesById[$0] }
        if composites.isEmpty {
            return StateDiagram(direction: direction, states: orderedStates, transitions: transitions, composites: composites, notes: notes)
        }

        let compositeIds = Set(composites.map(\.id))
        let resolvedTransitions = transitions.map { t -> StateDiagramTransition in
            let from: String
            if compositeIds.contains(t.from) {
                let marker = stateDiagramEndMarkerId(t.from)
                from = statesById[marker] != nil ? marker : t.from
            } else {
                from = t.from
            }
            let to: String
            if compositeIds.contains(t.to) {
                let marker = stateDiagramStartMarkerId(t.to)
                to = statesById[marker] != nil ? marker : t.to
            } else {
                to = t.to
            }
            return StateDiagramTransition(from: from, to: to, label: t.label)
        }
        return StateDiagram(
            direction: direction,
            states: orderedStates.filter { !compositeIds.contains($0.id) },
            transitions: resolvedTransitions,
            composites: composites,
            notes: notes
        )
    }

    // MARK: - Visible Model (`state/visible-model.ts`)

    // parity: merman/src/state/visible-model.ts#StateVisibleTransition [status=implemented hash=7a53cd90f63e]
    public typealias StateVisibleTransition = StateDiagramTransition

    // parity: merman/src/state/visible-model.ts#StateVisibleDiagram [status=implemented hash=ae20512a4299]
    public typealias StateVisibleDiagram = StateDiagram

    // parity: merman/src/state/visible-model.ts#isHiddenCompositeMarker [status=implemented hash=4ab6cb14c96d]
    public static func isHiddenCompositeMarker(_ state: StateDiagramState?) -> Bool {
        guard let state, let parentId = state.parentId, !parentId.isEmpty else { return false }
        return state.kind == .start || state.kind == .end
    }

    private static func stateComposeTransitionLabel(_ incoming: StateDiagramTransition, _ outgoing: StateDiagramTransition) -> String {
        [incoming.label, outgoing.label].filter { !$0.isEmpty }.joined(separator: "<br/>")
    }

    private static func stateCollapseHiddenOnce(
        _ transitions: [StateVisibleTransition],
        hiddenMarkersOrdered: [String]
    ) -> (transitions: [StateVisibleTransition], changed: Bool) {
        if hiddenMarkersOrdered.isEmpty { return (transitions, false) }
        for markerId in hiddenMarkersOrdered {
            var incomingIndices: [Int] = []
            var outgoingIndices: [Int] = []
            for (idx, t) in transitions.enumerated() {
                if t.to == markerId && t.from != markerId { incomingIndices.append(idx) }
                if t.from == markerId && t.to != markerId { outgoingIndices.append(idx) }
            }
            if incomingIndices.isEmpty || outgoingIndices.isEmpty { continue }
            var skipped = Set(incomingIndices)
            skipped.formUnion(outgoingIndices)
            var next: [StateVisibleTransition] = []
            for (idx, t) in transitions.enumerated() where !skipped.contains(idx) {
                next.append(t)
            }
            for inIdx in incomingIndices {
                let inc = transitions[inIdx]
                for outIdx in outgoingIndices {
                    let out = transitions[outIdx]
                    next.append(StateVisibleTransition(from: inc.from, to: out.to, label: stateComposeTransitionLabel(inc, out)))
                }
            }
            return (next, true)
        }
        return (transitions, false)
    }

    // parity: merman/src/state/visible-model.ts#prepareVisibleStateDiagram [status=implemented hash=6701f094bd36]
    public static func prepareVisibleStateDiagram(_ diagram: StateDiagram) -> StateVisibleDiagram {
        let hiddenMarkersOrdered = diagram.states.filter { isHiddenCompositeMarker($0) }.map(\.id)
        var transitions = diagram.transitions
        while true {
            let res = stateCollapseHiddenOnce(transitions, hiddenMarkersOrdered: hiddenMarkersOrdered)
            transitions = res.transitions
            if !res.changed { break }
        }
        let statesById = Dictionary(uniqueKeysWithValues: diagram.states.map { ($0.id, $0) })
        var referencedHidden = Set<String>()
        for t in transitions {
            if let from = statesById[t.from], isHiddenCompositeMarker(from) { referencedHidden.insert(from.id) }
            if let to = statesById[t.to], isHiddenCompositeMarker(to) { referencedHidden.insert(to.id) }
        }
        return StateVisibleDiagram(
            direction: diagram.direction,
            states: diagram.states.filter { !isHiddenCompositeMarker($0) || referencedHidden.contains($0.id) },
            transitions: transitions,
            composites: diagram.composites,
            notes: diagram.notes
        )
    }

    // MARK: - State Note Connector (`state/note.ts`)

    // parity: merman/src/state/note.ts#StateDiagramNoteConnector [status=implemented hash=97f8638d9898]
    public struct StateDiagramNoteConnector: Equatable, Hashable, Sendable, Codable {
        public var points: [DiagramPoint]
        public var connectorY: Int

        public init(points: [DiagramPoint], connectorY: Int) {
            self.points = points
            self.connectorY = connectorY
        }
    }

    // parity: merman/src/state/note.ts#stateDiagramNoteConnector [status=implemented hash=20c4449f02bb]
    public static func stateDiagramNoteConnector(
        _ bounds: StateDiagramNoteBounds,
        target: StateDiagramBoxBounds
    ) -> StateDiagramNoteConnector {
        if let connector = bounds.connector { return connector }
        let noteX = bounds.note.position == .right ? bounds.left - 1 : bounds.left + bounds.width
        let targetX = bounds.note.position == .right ? target.left + target.width : target.left - 1
        let targetBottom = target.top + target.height - 1
        let noteBottom = bounds.top + bounds.height - 1
        let noteAbove = noteBottom < target.top
        let noteBelow = bounds.top > targetBottom

        if noteAbove || noteBelow {
            let connectorY = bounds.centerY
            return StateDiagramNoteConnector(
                points: [
                    point(targetX, noteAbove ? target.top - 1 : targetBottom + 1),
                    point(targetX, connectorY),
                    point(noteX, connectorY),
                ],
                connectorY: connectorY
            )
        }

        let connectorY = max(bounds.top + 1, min(target.centerY, bounds.top + bounds.height - 2))
        return StateDiagramNoteConnector(
            points: [
                point(targetX, connectorY),
                point(noteX, connectorY),
            ],
            connectorY: connectorY
        )
    }

    // MARK: - State Search (`state/search.ts`)

    private static let stateMaxRenderSearchVisits = 250_000

    // parity: merman/src/state/search.ts#StateSearchBudget [status=implemented hash=1a6414241ccc]
    public final class StateSearchBudget {
        public var remaining: Int

        public init(remaining: Int = 250_000) {
            self.remaining = remaining
        }
    }

    // parity: merman/src/state/search.ts#StateSearchSpace [status=implemented hash=face6a50ff84]
    public struct StateSearchSpace: Equatable, Sendable {
        public var blocked: Set<DiagramPoint>
        public var minX: Int
        public var minY: Int
        public var maxX: Int
        public var maxY: Int

        public init(blocked: Set<DiagramPoint>, minX: Int, minY: Int, maxX: Int, maxY: Int) {
            self.blocked = blocked
            self.minX = minX
            self.minY = minY
            self.maxX = maxX
            self.maxY = maxY
        }
    }

    // parity: merman/src/state/search.ts#createStateSearchBudget [status=implemented hash=1e6b71a4e46e]
    public static func createStateSearchBudget() -> StateSearchBudget {
        StateSearchBudget(remaining: stateMaxRenderSearchVisits)
    }

    // parity: merman/src/state/search.ts#createStateSearchSpace [status=implemented hash=501406db08d7]
    public static func createStateSearchSpace(
        _ space: SpatialIndex,
        clearance: (SpatialRole) -> Int = { _ in 0 }
    ) -> StateSearchSpace {
        var blocked = Set<DiagramPoint>()
        var minX = 0
        var minY = 0
        var maxX = 0
        var maxY = 0

        for claim in space.claims {
            let padding = clearance(claim.role)
            for span in claim.spans {
                for y in (span.y - padding)...(span.y + padding) {
                    for x in (span.fromX - padding)...(span.toX + padding) {
                        blocked.insert(point(x, y))
                        if x < minX { minX = x }
                        if y < minY { minY = y }
                        if x > maxX { maxX = x }
                        if y > maxY { maxY = y }
                    }
                }
            }
        }
        return StateSearchSpace(blocked: blocked, minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    // parity: merman/src/state/search.ts#findStateManhattanPath [status=implemented hash=063ce63342c6]
    public static func findStateManhattanPath(
        starts: [DiagramPoint],
        goal: DiagramPoint,
        space: StateSearchSpace,
        minX: Int,
        minY: Int,
        maxX: Int,
        maxY: Int,
        budget: StateSearchBudget,
        isFree: ((DiagramPoint) -> Bool)? = nil
    ) -> [DiagramPoint]? {
        let freeCheck = isFree ?? { !space.blocked.contains($0) }
        var queue: [DiagramPoint] = []
        var visited = Set<DiagramPoint>()
        var parents: [DiagramPoint: DiagramPoint] = [:]
        for pt in starts where freeCheck(pt) {
            if visited.insert(pt).inserted {
                queue.append(pt)
            }
        }

        var cursor = 0
        while cursor < queue.count && budget.remaining > 0 {
            let current = queue[cursor]
            cursor += 1
            budget.remaining -= 1
            if current == goal { break }
            let dx = goal.x > current.x ? 1 : (goal.x < current.x ? -1 : 0)
            let dy = goal.y > current.y ? 1 : (goal.y < current.y ? -1 : 0)
            var candidates: [DiagramPoint] = []
            candidates.reserveCapacity(6)
            if dx != 0 { candidates.append(point(current.x + dx, current.y)) }
            if dy != 0 { candidates.append(point(current.x, current.y + dy)) }
            candidates.append(point(current.x + 1, current.y))
            candidates.append(point(current.x, current.y + 1))
            candidates.append(point(current.x - 1, current.y))
            candidates.append(point(current.x, current.y - 1))

            for cand in candidates {
                if cand.x < minX || cand.x > maxX || cand.y < minY || cand.y > maxY { continue }
                if visited.contains(cand) || !freeCheck(cand) { continue }
                visited.insert(cand)
                parents[cand] = current
                queue.append(cand)
            }
        }

        guard visited.contains(goal) else { return nil }
        var path: [DiagramPoint] = []
        var cur: DiagramPoint? = goal
        while let pt = cur {
            path.append(pt)
            cur = parents[pt]
        }
        return path.reversed()
    }
}

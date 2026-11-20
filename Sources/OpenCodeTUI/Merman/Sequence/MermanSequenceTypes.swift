import Foundation
import OpenTUICore

extension Merman {
    // MARK: - Sequence Types (`sequence/types.ts`)

    // parity: merman/src/sequence/types.ts#SequenceParticipant [status=implemented hash=5670d663d4cb]
    public struct SequenceParticipant: Equatable, Hashable, Sendable, Codable {
        public var id: String
        public var label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    // parity: merman/src/sequence/types.ts#SequenceParticipantGroup [status=implemented hash=006348c25c85]
    public struct SequenceParticipantGroup: Equatable, Hashable, Sendable, Codable {
        public var label: String
        public var participantIds: [String]

        public init(label: String, participantIds: [String] = []) {
            self.label = label
            self.participantIds = participantIds
        }
    }

    public enum SequenceMessageLineStyle: String, Equatable, Hashable, Sendable, Codable {
        case solid
        case dashed
    }

    // parity: merman/src/sequence/types.ts#SequenceArrowHead [status=implemented hash=41e27642fde0]
    public enum SequenceArrowHead: String, Equatable, Hashable, Sendable, Codable {
        case open
        case cross
        case async
    }

    // parity: merman/src/sequence/types.ts#SequenceMessage [status=implemented hash=e596a4486dcc]
    public struct SequenceMessage: Equatable, Hashable, Sendable, Codable {
        public var from: String
        public var to: String
        public var label: String
        public var style: SequenceMessageLineStyle
        public var head: SequenceArrowHead?
        public var number: Int?
        public var activate: String?
        public var deactivate: String?

        public init(
            from: String,
            to: String,
            label: String,
            style: SequenceMessageLineStyle,
            head: SequenceArrowHead? = nil,
            number: Int? = nil,
            activate: String? = nil,
            deactivate: String? = nil
        ) {
            self.from = from
            self.to = to
            self.label = label
            self.style = style
            self.head = head
            self.number = number
            self.activate = activate
            self.deactivate = deactivate
        }
    }

    public enum SequenceNotePosition: String, Equatable, Hashable, Sendable, Codable {
        case over
        case left
        case right
    }

    // parity: merman/src/sequence/types.ts#SequenceNote [status=implemented hash=8d9c5a05bf7a]
    public struct SequenceNote: Equatable, Hashable, Sendable, Codable {
        public var over: [String]
        public var label: String
        public var position: SequenceNotePosition?

        public init(over: [String], label: String, position: SequenceNotePosition? = nil) {
            self.over = over
            self.label = label
            self.position = position
        }
    }

    // parity: merman/src/sequence/types.ts#SequenceActivation [status=implemented hash=568b1bce880c]
    public struct SequenceActivation: Equatable, Hashable, Sendable, Codable {
        public var participant: String
        public var active: Bool

        public init(participant: String, active: Bool) {
            self.participant = participant
            self.active = active
        }
    }

    public enum SequenceFragmentKind: String, Equatable, Hashable, Sendable, Codable {
        case alt
        case `else`
        case loop
        case end
    }

    // parity: merman/src/sequence/types.ts#SequenceFragment [status=implemented hash=9f226c394a20]
    public struct SequenceFragment: Equatable, Hashable, Sendable, Codable {
        public var kind: SequenceFragmentKind
        public var label: String

        public init(kind: SequenceFragmentKind, label: String) {
            self.kind = kind
            self.label = label
        }
    }

    // parity: merman/src/sequence/types.ts#SequenceStep [status=implemented hash=5e4eb4118dbf]
    public enum SequenceStep: Equatable, Hashable, Sendable, Codable {
        case message(SequenceMessage)
        case note(SequenceNote)
        case activation(SequenceActivation)
        case fragment(SequenceFragment)
    }

    // parity: merman/src/sequence/types.ts#SequenceDiagram [status=implemented hash=d98398e374b9]
    public struct SequenceDiagram: Equatable, Hashable, Sendable, Codable {
        public var participants: [SequenceParticipant]
        public var messages: [SequenceMessage]
        public var steps: [SequenceStep]
        public var groups: [SequenceParticipantGroup]

        public init(
            participants: [SequenceParticipant],
            messages: [SequenceMessage],
            steps: [SequenceStep],
            groups: [SequenceParticipantGroup]
        ) {
            self.participants = participants
            self.messages = messages
            self.steps = steps
            self.groups = groups
        }
    }

    // parity: merman/src/sequence/types.ts#SequenceDiagramRenderOptions [status=implemented hash=232cd0624bdc]
    public struct SequenceDiagramRenderOptions: Equatable, Hashable, Sendable {
        public var compact: Bool?
        public var minParticipantGap: Int?
        public var fragmentBorderStyle: BorderStyle?

        public init(
            compact: Bool? = nil,
            minParticipantGap: Int? = nil,
            fragmentBorderStyle: BorderStyle? = nil
        ) {
            self.compact = compact
            self.minParticipantGap = minParticipantGap
            self.fragmentBorderStyle = fragmentBorderStyle
        }
    }

    // parity: merman/src/sequence/types.ts#MessageStyle [status=implemented hash=5ce2cb62b382]
    public enum MessageStyle: String, Equatable, Hashable, Sendable, Codable {
        case request
        case response
    }

    // parity: merman/src/sequence/types.ts#FadeStyle [status=implemented hash=03e362f36123]
    public enum FadeStyle: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case requestFade1, requestFade2, requestFade3, requestFade4, requestFade5
        case responseFade1, responseFade2, responseFade3, responseFade4, responseFade5
    }

    // parity: merman/src/sequence/types.ts#LifelineRampStyle [status=implemented hash=42acfa847a7d]
    public enum LifelineRampStyle: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case lifelineRamp1
        case lifelineRamp2
        case lifelineRamp3
    }

    // parity: merman/src/sequence/types.ts#SequenceCellStyle [status=implemented hash=21316660fbd1]
    public enum SequenceCellStyle: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case participant
        case lifeline
        case group
        case request
        case response
        case requestFade1, requestFade2, requestFade3, requestFade4, requestFade5
        case responseFade1, responseFade2, responseFade3, responseFade4, responseFade5
        case lifelineRamp1, lifelineRamp2, lifelineRamp3
        case fragment
        case fragmentLabel
        case note
        case noteBadge

        static func fromMessageStyle(_ style: MessageStyle) -> SequenceCellStyle {
            style == .request ? .request : .response
        }

        static func fade(_ style: MessageStyle, step: Int) -> SequenceCellStyle {
            switch (style, step) {
            case (.request, 1): return .requestFade1
            case (.request, 2): return .requestFade2
            case (.request, 3): return .requestFade3
            case (.request, 4): return .requestFade4
            case (.request, _): return .requestFade5
            case (.response, 1): return .responseFade1
            case (.response, 2): return .responseFade2
            case (.response, 3): return .responseFade3
            case (.response, 4): return .responseFade4
            case (.response, _): return .responseFade5
            }
        }

        static func lifelineRamp(_ step: Int) -> SequenceCellStyle {
            switch step {
            case 1: return .lifelineRamp1
            case 2: return .lifelineRamp2
            default: return .lifelineRamp3
            }
        }
    }

    // MARK: - Sequence Options (`sequence/options.ts`)

    // parity: merman/src/sequence/options.ts#DEFAULT_MIN_PARTICIPANT_GAP [status=implemented hash=11b12765ce39]
    public static let DEFAULT_MIN_PARTICIPANT_GAP: Int = 18

    // parity: merman/src/sequence/options.ts#DEFAULT_FRAGMENT_BORDER_STYLE [status=implemented hash=814e06440308]
    public static let DEFAULT_FRAGMENT_BORDER_STYLE: BorderStyle = .rounded

    // parity: merman/src/sequence/options.ts#normalizeSequenceMinParticipantGap [status=implemented hash=4782443fd92d]
    public static func normalizeSequenceMinParticipantGap(_ value: Int?) -> Int {
        guard let value else { return DEFAULT_MIN_PARTICIPANT_GAP }
        return max(1, value)
    }

    public static func normalizeSequenceMinParticipantGap(_ value: Double?) -> Int {
        guard let value, value.isFinite else { return DEFAULT_MIN_PARTICIPANT_GAP }
        return max(1, Int(floor(value)))
    }

    // MARK: - Sequence Style (`sequence/style.ts`)

    // parity: merman/src/sequence/style.ts#SequenceStyleColors [status=implemented hash=e130e42acca9]
    public struct SequenceStyleColors: Equatable, Hashable, Sendable {
        public var participant: RGBA?
        public var lifeline: RGBA?
        public var group: RGBA?
        public var request: RGBA?
        public var response: RGBA?
        public var fragment: RGBA?
        public var fragmentLabelBg: RGBA?
        public var note: RGBA?
        public var noteBg: RGBA?

        public init(
            participant: RGBA? = nil,
            lifeline: RGBA? = nil,
            group: RGBA? = nil,
            request: RGBA? = nil,
            response: RGBA? = nil,
            fragment: RGBA? = nil,
            fragmentLabelBg: RGBA? = nil,
            note: RGBA? = nil,
            noteBg: RGBA? = nil
        ) {
            self.participant = participant
            self.lifeline = lifeline
            self.group = group
            self.request = request
            self.response = response
            self.fragment = fragment
            self.fragmentLabelBg = fragmentLabelBg
            self.note = note
            self.noteBg = noteBg
        }
    }

    public struct ResolvedSequenceStyleColors: Equatable, Hashable, Sendable {
        public let participant: RGBA
        public let lifeline: RGBA
        public let group: RGBA
        public let request: RGBA
        public let response: RGBA
        public let fragment: RGBA
        public let fragmentLabelBg: RGBA
        public let note: RGBA
        public let noteBg: RGBA
        public let fades: [SequenceCellStyle: RGBA]

        public subscript(_ style: SequenceCellStyle) -> RGBA {
            switch style {
            case .participant: return participant
            case .lifeline: return lifeline
            case .group: return group
            case .request: return request
            case .response: return response
            case .fragment, .fragmentLabel: return fragment
            case .note, .noteBadge: return note
            default: return fades[style] ?? lifeline
            }
        }
    }

    // parity: merman/src/sequence/style.ts#SEQUENCE_FADE_STEPS [status=implemented hash=23a1c2c97cfa]
    public static let SEQUENCE_FADE_STEPS: [Int] = DIAGRAM_FADE_STEPS

    // parity: merman/src/sequence/style.ts#resolveSequenceStyleColors [status=implemented hash=4a8c52735d7c]
    public static func resolveSequenceStyleColors(
        _ colors: SequenceStyleColors = SequenceStyleColors()
    ) -> ResolvedSequenceStyleColors {
        let participant = colors.participant ?? rgba((228, 239, 232))
        let lifeline = colors.lifeline ?? rgba((111, 138, 126))
        let request = colors.request ?? rgba((134, 225, 200))
        let response = colors.response ?? rgba((230, 177, 126))
        let reqRamp = createColorRampTheme(
            [SequenceCellStyle.requestFade1, .requestFade2, .requestFade3, .requestFade4, .requestFade5],
            from: lifeline,
            to: request
        )
        let respRamp = createColorRampTheme(
            [SequenceCellStyle.responseFade1, .responseFade2, .responseFade3, .responseFade4, .responseFade5],
            from: lifeline,
            to: response
        )
        let lifeRamp = createColorRampTheme(
            [SequenceCellStyle.lifelineRamp1, .lifelineRamp2, .lifelineRamp3],
            from: participant,
            to: lifeline
        )
        var fades = reqRamp
        for (k, v) in respRamp { fades[k] = v }
        for (k, v) in lifeRamp { fades[k] = v }
        return ResolvedSequenceStyleColors(
            participant: participant,
            lifeline: lifeline,
            group: colors.group ?? rgba((76, 99, 89)),
            request: request,
            response: response,
            fragment: colors.fragment ?? rgba((154, 184, 169)),
            fragmentLabelBg: colors.fragmentLabelBg ?? rgba((28, 43, 36)),
            note: colors.note ?? rgba((215, 229, 221)),
            noteBg: colors.noteBg ?? rgba((36, 56, 47)),
            fades: fades
        )
    }

    // parity: merman/src/sequence/style.ts#sequenceStyleColor [status=implemented hash=a64710b9ab0f]
    public static func sequenceStyleColor(
        _ style: SequenceCellStyle?,
        colors: ResolvedSequenceStyleColors
    ) -> RGBA? {
        guard let style else { return nil }
        if style == .noteBadge { return colors.note }
        if style == .fragmentLabel { return colors.fragment }
        return colors[style]
    }

    // parity: merman/src/sequence/style.ts#sequenceStyleBackgroundColor [status=implemented hash=802ecab97f2f]
    public static func sequenceStyleBackgroundColor(
        _ style: SequenceCellStyle?,
        colors: ResolvedSequenceStyleColors
    ) -> RGBA? {
        if style == .note || style == .noteBadge { return colors.noteBg }
        if style == .fragmentLabel { return colors.fragmentLabelBg }
        return nil
    }

    // MARK: - Sequence Parser (`sequence/parser.ts`)

    private static let sequenceMessagePattern = #"^(.+?)\s*(-->>|->>|--x|-x|--\)|-\)|-->|->)([+-]?)\s*(.+?)\s*:\s*(.*)$"#
    private static let sequenceNotePattern = #"^note\s+(over|left\s+of|right\s+of)\s+(.+?)\s*:\s*(.*)$"#
    private static let sequenceParticipantPattern = #"^(?:participant|actor)\s+(\S+)(?:\s+as\s+(.+))?$"#
    private static let sequenceActivationPattern = #"^(activate|deactivate)\s+(.+)$"#
    private static let sequenceBoxPattern = #"^box(?:\s+(.+))?$"#
    private static let sequenceAltPattern = #"^alt\s+(.+)$"#
    private static let sequenceElsePattern = #"^else(?:\s+(.+))?$"#
    private static let sequenceLoopPattern = #"^loop\s+(.+)$"#
    private static let sequenceAutonumberPattern = #"^autonumber(?:\s+(\d+)(?:\s+(\d+))?)?$"#
    private static let sequenceBidirectionalPattern = #"<<-{1,2}>>"#
    private static let sequenceOperatorPattern = #"-->>|->>|--x|-x|--\)|-\)|-->|->"#
    private static let sequenceCssColorNames: Set<String> = [
        "black", "white", "red", "green", "blue", "yellow", "cyan", "magenta",
        "silver", "gray", "grey", "maroon", "olive", "lime", "aqua", "teal",
        "navy", "fuchsia", "purple", "orange", "brightblack", "brightred",
        "brightgreen", "brightblue", "brightyellow", "brightcyan",
        "brightmagenta", "brightwhite",
    ]

    private static func sequenceArrowHeadForSyntax(_ arrow: String) -> SequenceArrowHead? {
        if arrow.hasSuffix("x") { return .cross }
        if arrow.hasSuffix(")") { return .async }
        if arrow.hasSuffix(">") && !arrow.hasSuffix(">>") { return .open }
        return nil
    }

    private static func isSequenceBoxColorToken(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower == "transparent"
            || sequenceCssColorNames.contains(lower)
            || regexTest(#"^#[0-9a-f]{3,8}$"#, in: value, options: [.caseInsensitive])
            || regexTest(#"^rgba?\(.+\)$"#, in: value, options: [.caseInsensitive])
    }

    private static func splitLeadingBoxToken(_ value: String) -> (token: String, rest: String) {
        if regexTest(#"^rgba?\("#, in: value, options: [.caseInsensitive]),
           let closeIndex = value.firstIndex(of: ")")
        {
            let afterClose = value.index(after: closeIndex)
            return (String(value[..<afterClose]), jsTrim(String(value[afterClose...])))
        }
        if let spaceIdx = value.firstIndex(where: \.isWhitespace) {
            return (String(value[..<spaceIdx]), jsTrim(String(value[spaceIdx...])))
        }
        return (value, "")
    }

    private static func sequenceBoxLabelText(_ value: String?) -> String {
        let rawLabel = jsTrim(value ?? "")
        if rawLabel.count >= 2 &&
            ((rawLabel.hasPrefix("\"") && rawLabel.hasSuffix("\"")) ||
             (rawLabel.hasPrefix("'") && rawLabel.hasSuffix("'")))
        {
            return stripMermaidQuotes(rawLabel)
        }
        let label = stripMermaidQuotes(rawLabel)
        if label.isEmpty { return "" }
        let (token, rest) = splitLeadingBoxToken(label)
        return isSequenceBoxColorToken(token) ? stripMermaidQuotes(rest) : label
    }

    private static func ensureSequenceParticipant(
        _ participants: inout [SequenceParticipant],
        id: String,
        label: String? = nil,
        replaceExistingLabel: Bool = false
    ) {
        let resolvedLabel = label ?? id
        if let idx = participants.firstIndex(where: { $0.id == id }) {
            if replaceExistingLabel {
                participants[idx].label = resolvedLabel
            }
            return
        }
        participants.append(SequenceParticipant(id: id, label: resolvedLabel))
    }

    // parity: merman/src/sequence/parser.ts#isMermaidSequenceDiagram [status=implemented hash=326d2a48595e]
    public static func isMermaidSequenceDiagram(_ content: String) -> Bool {
        firstMeaningfulMermaidLine(content)?.lowercased() == "sequencediagram"
    }

    // parity: merman/src/sequence/parser.ts#parseMermaidSequenceDiagram [status=implemented hash=b72560cd30d4]
    public static func parseMermaidSequenceDiagram(_ content: String) throws -> SequenceDiagram {
        var participants: [SequenceParticipant] = []
        var messages: [SequenceMessage] = []
        var steps: [SequenceStep] = []
        var groups: [SequenceParticipantGroup] = []
        var blockStack: [(kind: String, lineNumber: Int, sourceLine: String)] = []
        var groupIndexStack: [Int] = []
        var nextMessageNumber: Int?
        var messageNumberIncrement = 1

        func addParticipantToActiveGroup(_ participantId: String) {
            guard let groupIdx = groupIndexStack.last else { return }
            if !groups[groupIdx].participantIds.contains(participantId) {
                groups[groupIdx].participantIds.append(participantId)
            }
        }

        for source in meaningfulNumberedMermaidLines(content) {
            let line = source.text
            if line.lowercased() == "sequencediagram" { continue }
            if regexTest(sequenceBidirectionalPattern, in: line) {
                throw MermaidSyntaxError(kind: .sequence, lineNumber: source.lineNumber, sourceLine: line)
            }

            if let autonumber = regexFirstMatch(sequenceAutonumberPattern, in: line, options: [.caseInsensitive]) {
                nextMessageNumber = Int(autonumber[1] ?? "1") ?? 1
                messageNumberIncrement = Int(autonumber[2] ?? "1") ?? 1
                continue
            }

            if let boxMatch = regexFirstMatch(sequenceBoxPattern, in: line, options: [.caseInsensitive]) {
                let group = SequenceParticipantGroup(label: sequenceBoxLabelText(boxMatch[1]), participantIds: [])
                groupIndexStack.append(groups.count)
                groups.append(group)
                blockStack.append((kind: "box", lineNumber: source.lineNumber, sourceLine: line))
                continue
            }

            if let participantMatch = regexFirstMatch(sequenceParticipantPattern, in: line, options: [.caseInsensitive]) {
                let id = stripMermaidQuotes(participantMatch[1] ?? "")
                let label = stripMermaidQuotes(participantMatch[2] ?? id)
                ensureSequenceParticipant(&participants, id: id, label: label, replaceExistingLabel: true)
                addParticipantToActiveGroup(id)
                continue
            }

            if let noteMatch = regexFirstMatch(sequenceNotePattern, in: line, options: [.caseInsensitive]) {
                let rawPos = regexReplace(#"\s+of$"#, in: (noteMatch[1] ?? "").lowercased(), with: "")
                let position: SequenceNotePosition? = rawPos == "left" ? .left : (rawPos == "right" ? .right : nil)
                let over = (noteMatch[2] ?? "")
                    .split(separator: ",", omittingEmptySubsequences: false)
                    .map { stripMermaidQuotes(String($0)) }
                    .filter { !$0.isEmpty }
                for participant in over {
                    ensureSequenceParticipant(&participants, id: participant)
                }
                steps.append(.note(SequenceNote(
                    over: over,
                    label: stripMermaidQuotes(noteMatch[3] ?? ""),
                    position: position
                )))
                continue
            }

            if let activationMatch = regexFirstMatch(sequenceActivationPattern, in: line, options: [.caseInsensitive]) {
                let participant = stripMermaidQuotes(activationMatch[2] ?? "")
                ensureSequenceParticipant(&participants, id: participant)
                steps.append(.activation(SequenceActivation(
                    participant: participant,
                    active: (activationMatch[1] ?? "").lowercased() == "activate"
                )))
                continue
            }

            if let altMatch = regexFirstMatch(sequenceAltPattern, in: line, options: [.caseInsensitive]) {
                blockStack.append((kind: "alt", lineNumber: source.lineNumber, sourceLine: line))
                steps.append(.fragment(SequenceFragment(kind: .alt, label: stripMermaidQuotes(altMatch[1] ?? ""))))
                continue
            }

            if let loopMatch = regexFirstMatch(sequenceLoopPattern, in: line, options: [.caseInsensitive]) {
                blockStack.append((kind: "loop", lineNumber: source.lineNumber, sourceLine: line))
                steps.append(.fragment(SequenceFragment(kind: .loop, label: stripMermaidQuotes(loopMatch[1] ?? ""))))
                continue
            }

            if let elseMatch = regexFirstMatch(sequenceElsePattern, in: line, options: [.caseInsensitive]) {
                if blockStack.last?.kind != "alt" {
                    throw MermaidSyntaxError(
                        kind: .sequence,
                        lineNumber: source.lineNumber,
                        sourceLine: line,
                        reason: "Unexpected \"else\" without an open \"alt\" block"
                    )
                }
                steps.append(.fragment(SequenceFragment(kind: .else, label: stripMermaidQuotes(elseMatch[1] ?? ""))))
                continue
            }

            if line.lowercased() == "end" {
                guard let block = blockStack.popLast() else {
                    throw MermaidSyntaxError(
                        kind: .sequence,
                        lineNumber: source.lineNumber,
                        sourceLine: line,
                        reason: "Unexpected \"end\" without an open block"
                    )
                }
                if block.kind == "box" {
                    _ = groupIndexStack.popLast()
                    continue
                }
                steps.append(.fragment(SequenceFragment(kind: .end, label: block.kind)))
                continue
            }

            if let msgMatch = regexFirstMatch(sequenceMessagePattern, in: line) {
                let from = stripMermaidQuotes(msgMatch[1] ?? "")
                let arrow = msgMatch[2] ?? ""
                let activationMarker = msgMatch[3] ?? ""
                let to = stripMermaidQuotes(msgMatch[4] ?? "")
                if regexTest(sequenceOperatorPattern, in: from) || regexTest(sequenceOperatorPattern, in: to) {
                    throw MermaidSyntaxError(kind: .sequence, lineNumber: source.lineNumber, sourceLine: line)
                }
                ensureSequenceParticipant(&participants, id: from)
                ensureSequenceParticipant(&participants, id: to)
                addParticipantToActiveGroup(from)
                addParticipantToActiveGroup(to)
                var message = SequenceMessage(
                    from: from,
                    to: to,
                    label: stripMermaidQuotes(msgMatch[5] ?? ""),
                    style: arrow.hasPrefix("--") ? .dashed : .solid,
                    head: sequenceArrowHeadForSyntax(arrow)
                )
                if let num = nextMessageNumber {
                    message.number = num
                    nextMessageNumber = num + messageNumberIncrement
                }
                if activationMarker == "+" {
                    message.activate = to
                } else if activationMarker == "-" {
                    message.deactivate = from
                }
                messages.append(message)
                steps.append(.message(message))
                continue
            }

            throw MermaidSyntaxError(kind: .sequence, lineNumber: source.lineNumber, sourceLine: line)
        }

        if let unclosed = blockStack.last {
            throw MermaidSyntaxError(
                kind: .sequence,
                lineNumber: unclosed.lineNumber,
                sourceLine: unclosed.sourceLine,
                reason: "Unclosed \(unclosed.kind) block; expected \"end\""
            )
        }

        return SequenceDiagram(participants: participants, messages: messages, steps: steps, groups: groups)
    }
}
